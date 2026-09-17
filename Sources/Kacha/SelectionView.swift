import CoreImage
import SwiftUI

/// 单屏框选视图：冻结帧 + 35% 黑遮罩挖洞 + 1pt 白边 + 液态玻璃尺寸胶囊。
/// 两段式交互：拖拽框选（或 idle 态点击窗口，蓝描边悬停高亮）→ 松开进入调整态
/// （角/边缩放、内部平移）→ 双击/回车/按钮确认，ESC 取消。
/// 调整态右下角单行工具栏（V3：标注工具 + 色板/粗细/圆角收起式面板，面板 overlay 锚定触发钮上方）；
/// 标注工具激活时选区内拖动为绘制（光标统一十字），实时预览与最终输出共用 AnnotationGeometry.path（同构）。
struct SelectionView: View {
    let frame: ScreenFrame
    /// 本屏窗口矩形（局部坐标、front-to-back）；悬停高亮与点击选中用
    let windows: [CGRect]
    /// 确认（复制）时回调：屏幕局部 point 选区（有效性已过滤）+ 圆角半径（point，0 = 直角）+ 已完成标注
    let onConfirm: (CGRect, CGFloat, [Annotation]) -> Void
    /// 保存时回调：屏幕局部 point 选区（有效性已过滤）+ 圆角半径（point，0 = 直角）+ 已完成标注
    let onSave: (CGRect, CGFloat, [Annotation]) -> Void
    let onCancel: () -> Void

    private enum Phase {
        case idle       // 尚未拖拽
        case dragging   // 首次拖拽中
        case adjusting  // 松开后二次调整
    }

    @State private var phase: Phase = .idle
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var selection: CGRect = .zero
    @State private var adjustKind: SelectionHandleKind?
    @State private var adjustOrigin: CGRect = .zero
    @State private var adjustPoint: CGPoint = .zero
    /// 光标决策快照（引用类型：@State 持同一实例，monitor 闭包每次读到最新值）
    @State private var cursorState = CursorState()
    /// NSEvent local monitor 令牌（onAppear 安装、onDisappear 移除）
    @State private var cursorMonitor: Any?
    /// 悬停命中的窗口矩形（仅 idle 态更新；dragging 期间保持旧值供 onEnded 窗口分支读取）
    @State private var hoveredWindow: CGRect? = nil
    /// 输出圆角半径（point）：底部滑动条实时调整；@AppStorage 持久化到 UserDefaults，跨会话记忆上次值
    @AppStorage("cornerRadius") private var cornerRadius: Double = 0
    // MARK: 标注状态（V3）
    /// 已完成的标注（撤销栈：撤销钮 removeLast 弹出）
    @State private var annotations: [Annotation] = []
    /// 当前标注工具：select 不接管拖动；arrow/rect/ellipse/pen/blur 接管选区内拖动为绘制
    @State private var activeTool: AnnotationTool = .select
    /// 当前标注颜色（色板 8 色之一）
    @State private var annotationColor: RGBA = .red
    /// 当前标注粗细（三档；blur 工具不用此值，见 blurPenWidth）
    @State private var annotationWidth: AnnotationWidth = .medium
    /// 模糊工具半径（pt，4...20）：固化进每笔标注（撤销后不受后续调节影响）；@AppStorage 跨会话记忆
    @AppStorage("blurRadius") private var blurRadius: Double = 8
    /// 模糊工具笔宽（pt，8...80）：打码范围大，独立于三档 annotationWidth；@AppStorage 跨会话记忆
    @AppStorage("blurPenWidth") private var blurPenWidth: Double = 24
    /// 进行中的一笔标注（绘制手势期间持有；松开时 isValid 才入栈，随后清空）
    @State private var drawingAnnotation: Annotation?
    /// 模糊预览图缓存（单条目，见 blurPreviewImage）
    @State private var blurPreview = BlurPreviewCache()
    /// 收起式弹出面板开关（互斥：同一时间至多展开一个；面板经玻璃外浮层宿主 panelsHost 呈现）：
    /// showStylePanel = 色板+粗细合并样式面板（pen 系）/ showWidthPicker = blur 双滑块 / showRadiusSlider = 圆角
    @State private var showStylePanel = false
    @State private var showWidthPicker = false
    @State private var showRadiusSlider = false
    /// 工具栏自由位置（sel 空间胶囊右下角锚点的绝对点）：nil = 锚定跟随模式（贴选区右下、随选区
    /// 移动）；非 nil = 脱离锚定——不随选区移动/缩放变化、不做屏幕边缘 clamp（用户明确不要避让，
    /// 可拖出屏缘），保持到下次截图（@State 每会话重置）。吸附：松手落点距锚定点 <12pt 回 nil
    /// 恢复跟随。用右下角锚点而非几何中心：锚定渲染是 trailing/bottom 对齐，锚点即渲染参照，
    /// 首帧基线零跳变（中心语义需实测胶囊宽，估算误差会致起步跳动）
    @State private var toolbarPosition: CGPoint? = nil
    /// 工具栏拖动进行中（视觉 scale 1.02 + onChanged 首帧基线标记）
    @State private var toolbarDragging = false
    /// 拖动起始渲染点基线：onChanged 首帧从 toolbarPosition（nil 视作当时锚定点）解包，后续帧累加 translation
    @State private var toolbarDragBase: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            overlayRoot(in: geo)
        }
    }

    /// 主画布（层级 ZStack + 状态同步修饰符）。body 的修饰符链拆成 root/canvas 两段方法：
    /// 整条链写在一个表达式会触发编译器「unable to type-check in reasonable time」
    private func overlayCanvas(in geo: GeometryProxy) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: NSImage(cgImage: frame.image, size: frame.screenPointSize))
                .resizable()
                .frame(width: geo.size.width, height: geo.size.height)

            let maskSelection = validDragRect ?? ((phase != .adjusting) ? hoveredWindow : nil)
            dimmingAndHoverLayers(
                maskSelection: maskSelection,
                maskCornerRadius: validDragRect != nil ? cornerRadius : 0,
                hoverWindow: (phase != .adjusting && validDragRect == nil) ? hoveredWindow : nil)

            if let sel = activeSelection, SelectionGeometry.isValid(sel) {
                selectionLayers(in: geo, sel: sel)
            }
        }
        .onChange(of: selection) { _, new in
            // 面板展开光标带与渲染 offset 用同一公式（toolbarRowLayout 行矩形，含手动拖动偏移）
            syncSelectionState(new: new, bounds: geo.size)
        }
        .onChange(of: showStylePanel || showWidthPicker || showRadiusSlider) { _, _ in
            // 面板展开/收起源同步：任一面板开 → 行矩形向上扩 60pt 光标带，全收起 → .zero
            syncPanelBand(sel: selection, bounds: geo.size)
        }
        .onChange(of: toolbarPosition) { _, _ in
            // 工具栏拖动/吸附源同步：光标带跟随渲染位移后的行矩形（拖动中逐帧更新）
            syncPanelBand(sel: selection, bounds: geo.size)
        }
        .onChange(of: blurPenWidth) { _, new in
            // blur 笔刷光标直径源同步（实时跟随滑块；blurRadius 不影响光标）
            cursorState.blurWidth = CGFloat(new)
        }
        .onChange(of: activeTool) { _, new in
            // 光标快照同步（引用实例，monitor 每次读到最新值）
            cursorState.tool = new
            // 切工具必收面板：残留开启的面板跨工具存活时，新工具触发钮的互斥会把刚点开的
            // 目标面板立即关掉（blur 态宽度面板「点一次没反应」的根因），且面板渲染门槛
            // 镜像触发钮显隐——工具切换后面板理应随之消失。
            // 收起动画由 CaptureToolbar mainRow 的 .animation(value:) 驱动，无需 withAnimation
            showStylePanel = false
            showWidthPicker = false
            showRadiusSlider = false
        }
        .onChange(of: geo.size.height) { _, new in
            cursorState.viewHeight = new
        }
    }

    /// 交互外挂（坐标空间 / 悬停 / 手势 / 按键 / 生命周期），叠在 overlayCanvas 之上
    private func overlayRoot(in geo: GeometryProxy) -> some View {
        overlayCanvas(in: geo)
            .coordinateSpace(name: "sel")
            .onContinuousHover(coordinateSpace: .named("sel")) { hoverPhase in
                // 悬停高亮：仅 idle 更新（按下进入 .dragging 后保持旧值，松手时窗口分支据此判定点击目标）；
                // ended（移出视图）一律清空
                if case .active(let point) = hoverPhase {
                    hoverActive(at: point)
                } else {
                    hoverEnded()
                }
            }
            .contentShape(Rectangle())
            .gesture(blankRedrawGesture)
            .focusable()
            .onKeyPress(.return) {
                confirm()
                return .handled
            }
            .onKeyPress("z", phases: [.down, .repeat]) { press in
                // ⌘Z 撤销最后一笔标注：SDK 的 onKeyPress 无 modifiers 入参变体（接口只有
                // key/keys/characters/phases 五种重载），⌘ 修饰键在闭包内手动判定；
                // 非 ⌘ 的 z 放行（.ignored）。undoLastAnnotation 自带空栈守卫，空栈 no-op 仍吞键
                guard press.modifiers.contains(.command) else { return .ignored }
                undoLastAnnotation()
                return .handled
            }
            .onExitCommand(perform: onCancel)
            .onAppear { installCursorState(height: geo.size.height) }
            .onReceive(NotificationCenter.default.publisher(for: .kachaOverlayDismissed)) { _ in
                // 覆盖窗被 dismissAll 关闭时立即清 monitor（防泄漏）；onDisappear 仅作兜底
                removeCursorMonitor()
            }
            .onDisappear {
                removeCursorMonitor()
            }
    }

    /// selection onChange 源同步：光标快照 + 面板光标带（一行公式源见 panelBand）
    private func syncSelectionState(new: CGRect, bounds: CGSize) {
        cursorState.selection = new
        cursorState.hasSelection = SelectionGeometry.isValid(new)
        syncPanelBand(sel: new, bounds: bounds)
    }

    // MARK: 交互辅助（从 body 修饰链拆出：表达式过大触发编译器「unable to type-check in reasonable time」）

    /// 遮罩挖洞 + idle 悬停窗口蓝描边。挖洞圆角由调用方传入（拖拽/调整态跟随 cornerRadius、
    /// 与白边及最终输出一致所见即所得；悬停窗口洞保持直角即 0）
    @ViewBuilder
    private func dimmingAndHoverLayers(maskSelection: CGRect?, maskCornerRadius: CGFloat, hoverWindow: CGRect?) -> some View {
        DimmingMask(selection: maskSelection, cornerRadius: maskCornerRadius)
            .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

        if let hoverWindow {
            Rectangle()
                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                .frame(width: hoverWindow.width, height: hoverWindow.height)
                .position(x: hoverWindow.midX, y: hoverWindow.midY)
                .allowsHitTesting(false)
        }
    }

    /// 悬停命中窗口（仅 idle 态更新；dragging/adjusting 保持旧值，松手时窗口分支据此判定点击目标）
    private func hoverActive(at point: CGPoint) {
        if phase == .idle {
            hoveredWindow = WindowGeometry.hitTest(point: point, windows: windows)
        }
    }

    /// 指针移出视图：悬停高亮清空
    private func hoverEnded() {
        hoveredWindow = nil
    }

    /// 空白处按下拖拽：画新选区（minimumDistance 0：原地点击也走 onEnded）。
    /// 调整态完全禁用——选区内/外起点都忽略，重画只能从 idle/dragging 起步；
    /// 子层（move/手柄/按钮）手势独立跟踪不受影响，dragStart 也不会被父层污染
    private var blankRedrawGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("sel"))
            .onChanged { value in
                if phase == .adjusting { return }
                phase = .dragging
                dragStart = value.startLocation
                dragCurrent = value.location
            }
            .onEnded { value in
                // 调整态：同 onChanged 全部忽略（选区外拖动什么也不做）
                if phase == .adjusting { return }
                defer { dragStart = nil; dragCurrent = nil }
                let rect = SelectionGeometry.normalize(from: value.startLocation, to: value.location)
                if SelectionGeometry.isValid(rect) {
                    selection = rect
                    phase = .adjusting
                } else if let hw = hoveredWindow, phase != .adjusting {
                    // 点击窗口：以窗口矩形为选区进入调整态（dragStart/dragCurrent 由 defer 清空，
                    // 满足 confirm 的 dragStart == nil 守卫）
                    selection = hw
                    phase = .adjusting
                } else {
                    // 点击空白：无操作（不取消，用户要求移除 V1 误触取消）；
                    // phase 回落 idle，悬停高亮/窗口点击继续可用
                    phase = .idle
                }
            }
    }

    /// 面板展开光标带同步（selection / 面板开关 / toolbarPosition 三类 onChange 源共用）；
    /// 自由位置模式把行矩形按「渲染锚点位移」（position − 锚定点）平移，锚定跟随 = .zero；
    /// 面板全收起时 panelBand 公式自回 .zero
    private func syncPanelBand(sel: CGRect?, bounds: CGSize) {
        var drag: CGSize = .zero
        if let p = toolbarPosition, let sel, SelectionGeometry.isValid(sel) {
            let g = Self.toolbarRowLayout(sel: sel, bounds: bounds)
            drag = CGSize(width: p.x - g.right, height: p.y - g.bottom)
        }
        cursorState.panelBand = Self.panelBand(
            sel: sel, bounds: bounds,
            anyPanelOpen: showStylePanel || showWidthPicker || showRadiusSlider,
            drag: drag)
    }

    /// 光标快照初始化 + 安装单一决策点 monitor（替代 cursorRect / onHover 方案）
    private func installCursorState(height: CGFloat) {
        cursorState.viewHeight = height
        cursorState.selection = selection
        cursorState.hasSelection = SelectionGeometry.isValid(selection)
        cursorState.tool = activeTool
        cursorState.blurWidth = CGFloat(blurPenWidth)
        cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            Self.applyCursor(event: event, state: cursorState, screen: frame.screen)
            return event
        }
    }

    // MARK: 状态推算

    private var activeSelection: CGRect? {
        // 进行中的拖拽优先展示（含调整态下的外部重画）；否则调整态展示已定选区
        if let dragStart, let dragCurrent {
            return SelectionGeometry.normalize(from: dragStart, to: dragCurrent)
        }
        if phase == .adjusting { return selection }
        return nil
    }

    /// 进行中且有效（≥4pt）的拖拽矩形；按下未动/微拖时为 nil
    private var validDragRect: CGRect? {
        guard let sel = activeSelection, SelectionGeometry.isValid(sel) else { return nil }
        return sel
    }

    // MARK: 调整逻辑

    private func beginAdjust(_ kind: SelectionHandleKind, at point: CGPoint) {
        adjustKind = kind
        adjustOrigin = selection
        adjustPoint = point
    }

    private func updateAdjust(to p: CGPoint, in bounds: CGSize) {
        guard adjustKind != nil else { return }
        let o = adjustOrigin
        let minX = max(0, min(p.x, o.maxX - SelectionGeometry.minimumSize))
        let minY = max(0, min(p.y, o.maxY - SelectionGeometry.minimumSize))
        let maxX = min(bounds.width, max(p.x, o.minX + SelectionGeometry.minimumSize))
        let maxY = min(bounds.height, max(p.y, o.minY + SelectionGeometry.minimumSize))
        switch adjustKind {
        case .topLeft:
            selection = CGRect(x: minX, y: minY, width: o.maxX - minX, height: o.maxY - minY)
        case .top:
            selection = CGRect(x: o.minX, y: minY, width: o.width, height: o.maxY - minY)
        case .topRight:
            selection = CGRect(x: o.minX, y: minY, width: maxX - o.minX, height: o.maxY - minY)
        case .right:
            selection = CGRect(x: o.minX, y: o.minY, width: maxX - o.minX, height: o.height)
        case .bottomRight:
            selection = CGRect(x: o.minX, y: o.minY, width: maxX - o.minX, height: maxY - o.minY)
        case .bottom:
            selection = CGRect(x: o.minX, y: o.minY, width: o.width, height: maxY - o.minY)
        case .bottomLeft:
            selection = CGRect(x: minX, y: o.minY, width: o.maxX - minX, height: maxY - o.minY)
        case .left:
            selection = CGRect(x: minX, y: o.minY, width: o.maxX - minX, height: o.height)
        case .move:
            let x = max(0, min(o.minX + p.x - adjustPoint.x, bounds.width - o.width))
            let y = max(0, min(o.minY + p.y - adjustPoint.y, bounds.height - o.height))
            selection = CGRect(x: x, y: y, width: o.width, height: o.height)
        case nil:
            break
        }
    }

    private func confirm() {
        guard phase == .adjusting, dragStart == nil, SelectionGeometry.isValid(selection) else { return }
        onConfirm(selection, CGFloat(cornerRadius), annotations)
    }

    private func save() {
        guard phase == .adjusting, dragStart == nil, SelectionGeometry.isValid(selection) else { return }
        onSave(selection, CGFloat(cornerRadius), annotations)
    }

    /// 撤销最后一笔标注（工具栏撤销钮 / ⌘Z）：空栈无操作（撤销钮空栈时整钮不渲染）
    private func undoLastAnnotation() {
        if !annotations.isEmpty {
            annotations.removeLast()
        }
    }

    // MARK: 选区层（拆自主 body：表达式过大触发编译器「unable to type-check in reasonable time」）

    /// 有效选区的全部视觉与交互层：白边 → 标注预览 Canvas → 尺寸徽标 →（调整态）move/手柄/绘制层 + 工具栏
    @ViewBuilder
    private func selectionLayers(in geo: GeometryProxy, sel: CGRect) -> some View {
        // 白边随圆角实时变化：拖拽/调整态跟随 cornerRadius（含 @AppStorage 记忆值），与挖洞及最终输出一致（所见即所得，共用一处）
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(.white, lineWidth: 1)
            .frame(width: sel.width, height: sel.height)
            .position(x: sel.midX, y: sel.midY)
            .allowsHitTesting(false)

        annotationPreviewCanvas(sel: sel)
            .frame(width: sel.width, height: sel.height)
            .position(x: sel.midX, y: sel.midY)
            .allowsHitTesting(false)

        SizeBadge(rect: sel)
            .position(x: min(sel.midX, geo.size.width - 60),
                      y: max(sel.minY - 28, 26))
            .allowsHitTesting(false)

        if phase == .adjusting {
            adjustmentLayers(in: geo, sel: sel)

            // 选区右下角单行工具栏（紧贴选区，拖动玻璃块上非按钮的像素即可挪开）
            captureToolbar(in: geo, sel: sel)
        }
    }

    /// 标注实时渲染（含进行中的一笔）：屏幕预览与 AnnotationRenderer 像素合成同构
    /// （共用 AnnotationGeometry.path；线帽/线接 round 一致，arrow = 整体 stroke + eoFill 头，
    /// blur = clip 路径展宽 + 底图选区裁剪高斯模糊）。
    /// 渲染在白边之后、move/绘制手势层之前；仅预览层不做命中（allowsHitTesting false 由调用方挂）。
    /// 白色标注先 stroke 1pt separator 外扩描边再上色，浅色截图中仍可见（规格约束，仅预览层）。
    private func annotationPreviewCanvas(sel: CGRect) -> some View {
        Canvas { context, _ in
            for a in annotations + [drawingAnnotation].compactMap({ $0 }) {
                var ctx = context
                // path 产出选区局部坐标（原点 = 视图原点），Canvas 原点 = sel.minX：平移对齐
                ctx.translateBy(x: -sel.minX, y: -sel.minY)
                let path = Path(AnnotationGeometry.path(for: a.kind, in: sel, lineWidth: a.lineWidth))
                if case let .blur(_, radius) = a.kind {
                    // 高斯模糊：涂抹路径展宽为 clip，冻结帧按选区裁剪、CIGaussianBlur（每笔 radius × 像素比）
                    // 后 1:1 绘制（与 AnnotationRenderer 输出同构；颜色不参与渲染，坐标为视图坐标 → 画到 sel）
                    if let blurred = blurPreviewImage(in: sel, radius: radius) {
                        ctx.clip(to: path.strokedPath(StrokeStyle(lineWidth: a.lineWidth,
                                                                  lineCap: .round, lineJoin: .round)))
                        ctx.draw(Image(decorative: blurred, scale: 1), in: sel)
                    }
                    continue
                }
                let color = Color(red: a.color.r, green: a.color.g, blue: a.color.b, opacity: a.color.a)
                if a.color == .white {
                    ctx.stroke(path, with: .color(Color(nsColor: .separatorColor)),
                               style: StrokeStyle(lineWidth: a.lineWidth + 2, lineCap: .round, lineJoin: .round))
                }
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: a.lineWidth, lineCap: .round, lineJoin: .round))
                if case .arrow = a.kind {
                    // 线段子路径零面积对 eoFill 无副作用，与 Renderer 同构（stroke 后 fill 成实心头）
                    ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
                }
            }
        }
    }

    /// 调整态交互层：move 层（选区内拖动整体移动 + 双击确认）→ 8 个缩放手柄 → 标注绘制层
    /// （工具激活时后渲染覆盖命中，move/边/角手势让位）
    @ViewBuilder
    private func adjustmentLayers(in geo: GeometryProxy, sel: CGRect) -> some View {
        // 选区内：拖动整体移动 + 双击确认。
        // 命中泄漏根因：contentShape 必须放在 position 之前——position 把子视图包进
        // 「占满全部可用空间」的定位容器（bounds = 整个 ZStack = 整屏），contentShape
        // 挂在其后定义的命中形状就是容器全屏 bounds，遮罩区远处的拖动也能触发 move
        // （自 V2 潜伏；挂在其前，命中形状 = 选区尺寸的子视图本身）
        Color.clear
            .frame(width: sel.width, height: sel.height)
            .contentShape(Rectangle())
            .position(x: sel.midX, y: sel.midY)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("sel"))
                    .onChanged { value in
                        // 双保险（防御层）：只有起点在选区内（±2pt 容差）才允许开始移动；
                        // 只在起始判定（adjustKind == nil）时检查——移动中 selection 随拖拽
                        // 平移，起点相对「当前选区」无参照意义，逐帧复查会把正常长拖误杀
                        if adjustKind == nil {
                            guard selection.insetBy(dx: -2, dy: -2).contains(value.startLocation) else { return }
                            beginAdjust(.move, at: value.startLocation)
                        }
                        updateAdjust(to: value.location, in: geo.size)
                    }
                    .onEnded { value in
                        // 同源防御：起点在选区外的手势结束不触碰状态（其开始已被 onChanged 拦截）；
                        // 本层自己的 .move 结束照常清 adjustKind（不按已平移的当前选区复查起点）
                        if adjustKind == .move || selection.insetBy(dx: -2, dy: -2).contains(value.startLocation) {
                            adjustKind = nil
                        }
                    }
            )
            .onTapGesture(count: 2) { confirm() }

        // 8 个缩放手柄（四角 + 四边中点）
        HandleLayer(selection: sel)
            .environment(\.adjustStarter) { kind, point in
                beginAdjust(kind, at: point)
            }
            .environment(\.adjustUpdater) { point in
                updateAdjust(to: point, in: geo.size)
            }
            .environment(\.adjustEnder) { adjustKind = nil }

        // 标注绘制层：工具激活时渲染在 move 层/手柄之上——后渲染覆盖命中，
        // move/边/角手势让位（双击确认随之失效，回车/按钮/右键仍可用）；
        // 「选择」工具时本层不存在，恢复 move/手柄/双击现状。
        // minimumDistance 0：原地点击也走 onChanged/onEnded（点一下的无效小标注由 isValid 丢弃）
        if activeTool.takesOverDrag {
            // 绘制层与 move 层同型泄漏：contentShape 同样移到 position 之前，
            // 命中限定在选区尺寸内（否则绘制工具激活时遮罩区拖动会喂进 updateDrawing）
            Color.clear
                .frame(width: sel.width, height: sel.height)
                .contentShape(Rectangle())
                .position(x: sel.midX, y: sel.midY)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("sel"))
                        .onChanged { value in
                            updateDrawing(to: value.location, start: value.startLocation, in: sel)
                        }
                        .onEnded { _ in commitDrawing(in: sel) }
                )
        }
    }

    /// 选区右下角单行工具栏：锚定跟随（toolbarPosition == nil，紧贴选区右下、随选区移动）或
    /// 自由绝对位置（拖动后 toolbarPosition 非 nil，不随选区移动/缩放、不 clamp 屏缘，
    /// 保持到下次截图会话重置）：
    /// [选择|箭头|矩形|椭圆|画笔|模糊] ‖ [当前色][当前粗细][圆角]（按工具显隐）‖ [撤销]（空栈隐藏）‖ [保存][复制]；
    /// 色板/粗细/圆角面板为触发钮 overlay（浮于钮正上方、可盖选区、不占布局）。
    /// 锚定点/光标带基底见 toolbarRowLayout 单一公式源。
    /// 独立成方法：主 body 过大触发编译器「unable to type-check in reasonable time」，拆块缓解
    @ViewBuilder
    private func captureToolbar(in geo: GeometryProxy, sel: CGRect) -> some View {
        let group = Self.toolbarRowLayout(sel: sel, bounds: geo.size)
        // 渲染锚点：自由位置 = toolbarPosition（胶囊右下角在 sel 空间的绝对点）；锚定跟随 = 组锚点。
        // 选区移动/缩放只变 group，renderPoint 不变 → 自由态工具栏纹丝不动（需求核心）
        let renderPoint = toolbarPosition ?? CGPoint(x: group.right, y: group.bottom)
        CaptureToolbar(tool: $activeTool,
                       color: $annotationColor,
                       lineWidth: $annotationWidth,
                       cornerRadius: $cornerRadius,
                       blurRadius: $blurRadius,
                       blurPenWidth: $blurPenWidth,
                       showStylePanel: $showStylePanel,
                       showWidthPicker: $showWidthPicker,
                       showRadiusSlider: $showRadiusSlider,
                       toolbarPosition: $toolbarPosition,
                       toolbarDragging: $toolbarDragging,
                       toolbarDragBase: $toolbarDragBase,
                       anchor: CGPoint(x: group.right, y: group.bottom),
                       canUndo: !annotations.isEmpty,
                       onUndo: undoLastAnnotation,
                       onSave: save,
                       onCopy: confirm)
        // 拖动经玻璃块背景层（拖非按钮的空白像素；按钮/滑块命中优先、不下落）；
        // 拖动中轻微放大反馈。不加 hover 光标——applyCursor monitor 的 mouseMoved
        // arrow 兜底会覆盖 onHover 设置，保持 arrow（macOS 工具栏惯例）
        .scaleEffect(toolbarDragging ? 1.02 : 1)
        // 全屏 wrapper 右下对齐（右对齐不依赖行宽；底缘锚定主行——面板展开向上生长不推挤主行），
        // 再 offset 把胶囊右下角送到 renderPoint：锚定态 = 组锚点（原行为），自由态 = 手动绝对位置
        .frame(width: geo.size.width, height: geo.size.height,
               alignment: Alignment(horizontal: .trailing, vertical: .bottom))
        .offset(x: renderPoint.x - geo.size.width,
                y: renderPoint.y - geo.size.height)
    }

    // MARK: 标注绘制

    /// 绘制中：把选区局部 point 归一化后写入 drawingAnnotation（clamp 由 normalizedPoint 承担）。
    /// arrow = 起点/终点两点；rect/ellipse = 两点 min/max 的归一化矩形；pen/blur = 采样去重后追加。
    private func updateDrawing(to point: CGPoint, start: CGPoint, in sel: CGRect) {
        let color = annotationColor
        let width = annotationWidth.pt
        switch activeTool {
        case .select:
            break   // 不接管拖动（绘制层此时不存在）
        case .arrow:
            drawingAnnotation = Annotation(
                kind: .arrow(start: AnnotationGeometry.normalizedPoint(start, in: sel),
                             end: AnnotationGeometry.normalizedPoint(point, in: sel)),
                color: color, lineWidth: width)
        case .rect, .ellipse:
            let n = Self.normalizedRect(from: start, to: point, in: sel)
            drawingAnnotation = Annotation(kind: activeTool == .rect ? Annotation.Kind.rect(n) : .ellipse(n),
                                           color: color, lineWidth: width)
        case .pen:
            let p = AnnotationGeometry.normalizedPoint(point, in: sel)
            if drawingAnnotation == nil {
                // 初始含首点（起点恒记录，同 shouldAppendPenPoint after nil）
                drawingAnnotation = Annotation(kind: .pen(points: [AnnotationGeometry.normalizedPoint(start, in: sel)]),
                                               color: color, lineWidth: width)
            } else if var drawing = drawingAnnotation, case let .pen(points) = drawing.kind {
                // 去重阈值是 1pt：在局部 point 空间判定（归一化间距无 pt 语义），存储仍为归一化坐标
                let lastLocal = points.last.map { AnnotationGeometry.localPoint($0, in: sel) }
                if AnnotationGeometry.shouldAppendPenPoint(point, after: lastLocal) {
                    drawing.kind = .pen(points: points + [p])
                    drawingAnnotation = drawing
                }
            }
        case .blur:
            // 同 pen：采样归一化追加（去重 1pt）；颜色照存但不参与模糊渲染。
            // 半径/笔宽在下笔瞬间取自 @AppStorage 并固化进本笔（绘制中滑块不可达，值恒定；
            // 追加时沿用 stroke 起笔固化的 radius，不回读 AppStorage）
            let p = AnnotationGeometry.normalizedPoint(point, in: sel)
            if drawingAnnotation == nil {
                drawingAnnotation = Annotation(
                    kind: .blur(points: [AnnotationGeometry.normalizedPoint(start, in: sel)],
                                radius: CGFloat(blurRadius)),
                    color: color, lineWidth: CGFloat(blurPenWidth))
            } else if var drawing = drawingAnnotation, case let .blur(points, radius) = drawing.kind {
                let lastLocal = points.last.map { AnnotationGeometry.localPoint($0, in: sel) }
                if AnnotationGeometry.shouldAppendPenPoint(point, after: lastLocal) {
                    drawing.kind = .blur(points: points + [p], radius: radius)
                    drawingAnnotation = drawing
                }
            }
        }
    }

    /// 松开：isValid（太小的标注丢弃）才入撤销栈，随后清进行中标注（无论是否入栈）
    private func commitDrawing(in sel: CGRect) {
        if let drawing = drawingAnnotation, AnnotationGeometry.isValid(drawing.kind, selectionSize: sel.size) {
            annotations.append(drawing)
        }
        drawingAnnotation = nil
    }

    /// 模糊预览图（带单条目缓存）：依赖只有冻结帧、选区与半径，涂抹拖动期间三者不变，同键复用
    /// （引用类型缓存：@State 持有不触发视图刷新，Canvas 绘制期只读）
    private func blurPreviewImage(in sel: CGRect, radius: CGFloat) -> CGImage? {
        if blurPreview.sel == sel, blurPreview.radius == radius, let cached = blurPreview.image { return cached }
        let image = Self.makeBlurPreview(base: frame.image, pointSize: frame.screenPointSize, sel: sel, radius: radius)
        blurPreview.sel = sel
        blurPreview.radius = radius
        blurPreview.image = image
        return image
    }

    /// 预览与 AnnotationRenderer 输出同构：冻结帧按选区像素裁剪（CGImage 图像坐标，左上原点）→
    /// CIGaussianBlur（每笔 radius pt × 像素/点），输出保持裁剪原分辨率（1:1 绘制无插值问题）。
    /// nil = 裁剪/模糊失败（该笔预览跳过，输出层 AnnotationRenderer 仍正常）
    private static func makeBlurPreview(base: CGImage, pointSize: CGSize, sel: CGRect, radius: CGFloat) -> CGImage? {
        let pixelScale = CGFloat(base.width) / max(pointSize.width, 1)
        guard pixelScale > 0 else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let crop = imageBounds.intersection(CGRect(x: sel.minX * pixelScale, y: sel.minY * pixelScale,
                                                   width: sel.width * pixelScale, height: sel.height * pixelScale))
        guard !crop.isEmpty, crop.width >= 1, crop.height >= 1,
              let cropped = base.cropping(to: crop) else { return nil }
        let ciImage = CIImage(cgImage: cropped)
        let clamped = ciImage.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radius * pixelScale, forKey: kCIInputRadiusKey)
        let blurred = (filter.outputImage ?? clamped).cropped(to: ciImage.extent)
        return AnnotationRenderer.sharedCIContext.createCGImage(blurred, from: ciImage.extent)
    }

    /// 两点 min/max 的归一化矩形（x/y/w/h 由两点 min/max；clamp 由 normalizedPoint 逐角承担）
    private static func normalizedRect(from start: CGPoint, to point: CGPoint, in selection: CGRect) -> CGRect {
        let a = AnnotationGeometry.normalizedPoint(
            CGPoint(x: min(start.x, point.x), y: min(start.y, point.y)), in: selection)
        let b = AnnotationGeometry.normalizedPoint(
            CGPoint(x: max(start.x, point.x), y: max(start.y, point.y)), in: selection)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// 移除光标 monitor（幂等）：覆盖窗被 dismissAll 时经通知触发，onDisappear 兜底重复调用
    private func removeCursorMonitor() {
        if let cursorMonitor {
            NSEvent.removeMonitor(cursorMonitor)
        }
        cursorMonitor = nil
    }

    // MARK: 光标（NSEvent monitor 单一决策点）

    /// 四角命中判定（每点 ±8pt 方形命中区），返回对应对角 frameResize 位置
    private static func cornerPosition(at p: CGPoint, in sel: CGRect) -> NSCursor.FrameResizePosition? {
        let corners: [(CGPoint, NSCursor.FrameResizePosition)] = [
            (CGPoint(x: sel.minX, y: sel.minY), .topLeft),
            (CGPoint(x: sel.maxX, y: sel.minY), .topRight),
            (CGPoint(x: sel.maxX, y: sel.maxY), .bottomRight),
            (CGPoint(x: sel.minX, y: sel.maxY), .bottomLeft),
        ]
        for (cp, position) in corners where abs(p.x - cp.x) <= 8 && abs(p.y - cp.y) <= 8 {
            return position
        }
        return nil
    }

    /// 整边命中判定（内侧 8pt / 外侧 3pt，与 EdgeHandle 命中条同几何；端点缩 8pt 与边条一致）：
    /// true = 上下边（resizeUpDown）/ false = 左右边（resizeLeftRight）/ nil = 未命中。
    /// 外侧由 8pt 收窄为 3pt：光标与命中一致，不再在紧贴工具栏的缝隙处给出手势暗示
    private static func edgeAxis(at p: CGPoint, in sel: CGRect) -> Bool? {
        let inXSpan = p.x >= sel.minX + 8 && p.x <= sel.maxX - 8
        let inYSpan = p.y >= sel.minY + 8 && p.y <= sel.maxY - 8
        let nearTop = p.y >= sel.minY - 3 && p.y <= sel.minY + 8
        let nearBottom = p.y >= sel.maxY - 8 && p.y <= sel.maxY + 3
        let nearLeft = p.x >= sel.minX - 3 && p.x <= sel.minX + 8
        let nearRight = p.x >= sel.maxX - 8 && p.x <= sel.maxX + 3
        if inXSpan, nearTop || nearBottom { return true }
        if inYSpan, nearLeft || nearRight { return false }
        return nil
    }

    /// V2 单行按钮锚点公式（ButtonCentersTests 钉住防回归）：copyX/saveX 右缘 clamp / 左缘下界、
    /// y = belowFits ? sel.maxY + 20 : sel.maxY - 20（单行 24pt 时代的 belowFits = sel.maxY + 36 <= 高）。
    /// V3 工具栏扩为两行组后，渲染与光标命中区改由 toolbarRowLayout 的组公式决定
    /// （belowFits 改用组总高 56）；本函数不再被渲染消费，仅作 V2 公式存档与测试钉。
    static func buttonCenters(sel: CGRect, bounds: CGSize) -> (save: CGPoint, copy: CGPoint) {
        let spacing: CGFloat = 52
        let copyX = min(sel.maxX - 16, bounds.width - 28)
        let saveX = max(28, copyX - spacing)
        let belowFits = sel.maxY + 20 + 16 <= bounds.height
        let y = belowFits ? sel.maxY + 20 : sel.maxY - 20
        return (CGPoint(x: saveX, y: y), CGPoint(x: copyX, y: y))
    }

    /// 单行工具栏（主行 24pt；色板/粗细/圆角面板为触发钮 overlay，不占布局）布局单一公式源
    /// （锚定锚点 = 渲染/吸附判定参照、面板光标带基底共用）：组右缘锚定选区白边右缘（sel.maxX，
    /// 与边框对齐）；锚定模式左缘出屏时整组右移（rowWidth 取主行估算宽 + 容差，右缘允许越过锚点；
    /// 仅约束锚定初始位置，拖动后的自由位置不 clamp）；
    /// 锚点 = 主行底缘 bottom，整组紧贴选区：下方放得下（组顶贴 sel.maxY + 4、组底再留 8pt 屏底余量）
    /// 时组底缘 sel.maxY + 38（主行中心 sel.maxY + 21），否则收进选区内侧组底缘 sel.maxY - 4
    /// （主行 34pt 高：底部留 4pt，主体伸入选区内 38pt）。
    static func toolbarRowLayout(sel: CGRect, bounds: CGSize) -> (right: CGFloat, bottom: CGFloat, row: CGRect) {
        // 玻璃胶囊实际宽：全显（pen 系 + 撤销栈非空）≈405（工具 6×24+5×6 ＋ 分隔 1
        // ＋ 样式钮 24 ＋ 圆角钮 48 ＋ 分隔 1 ＋ 撤销 24 ＋ 分隔 1 ＋ 保存钮 24 ＋ 复制钮 24
        // ＋ 9×8 段间距 ＋ 胶囊水平留白 10×2）；select 态最窄（样式/撤销隐藏）≈283，blur 态 ≈364，
        // 均被保守覆盖；常量保留 482（历史值，全显宽 + 约 77pt 容差）——仅用于锚定初始位置的
        // 左缘保护与光标带基底（偏保守只影响带略宽/锚点略右，无正确性问题）；实际渲染用右下角
        // 锚点 pin + offset，不依赖该估算。
        let rowWidth: CGFloat = 482
        let rowHeight: CGFloat = 34
        var right = sel.maxX
        if right - rowWidth < 6 {
            right = 6 + rowWidth
        }
        // 紧贴选区（组顶 sel.maxY + 4）：下方需组顶间距 4 + 胶囊 34 + 屏底余量 8
        let belowFits = sel.maxY + 4 + rowHeight + 8 <= bounds.height
        let bottom = belowFits ? sel.maxY + 4 + rowHeight : sel.maxY - 4
        // 主行矩形（面板展开期间光标带的基底，见 panelBand）
        let row = CGRect(x: right - rowWidth, y: bottom - rowHeight,
                         width: rowWidth, height: rowHeight)
        return (right, bottom, row)
    }

    /// 面板展开期间的光标带：主行矩形（含手动拖动的渲染位移）向上扩 60pt（面板 overlay 向上生长、
    /// 几何上常盖住选区，带内一律箭头，不透出选区光标）。无有效选区或面板全收起时为 .zero（不拦光标）。
    /// drag = 自由位置渲染锚点相对锚定点的位移（锚定跟随 = .zero，见 syncPanelBand 换算）。
    static func panelBand(sel: CGRect?, bounds: CGSize, anyPanelOpen: Bool, drag: CGSize = .zero) -> CGRect {
        guard anyPanelOpen, let sel, SelectionGeometry.isValid(sel) else { return .zero }
        return toolbarRowLayout(sel: sel, bounds: bounds).row
            .offsetBy(dx: drag.width, dy: drag.height)
            .insetBy(dx: 0, dy: -60)
    }

    /// 单一光标决策点：mouseMoved / leftMouseDragged 统一在此判定（cursorRect 已停用）
    @MainActor
    private static func applyCursor(event: NSEvent, state: CursorState, screen: NSScreen) {
        // 多屏过滤：全局坐标不在本屏则不动光标（每屏一个 monitor，别抢别屏的光标）
        guard screen.frame.contains(NSEvent.mouseLocation) else { return }
        // 窗口左下原点 → 视图左上原点
        let p = CGPoint(x: event.locationInWindow.x, y: state.viewHeight - event.locationInWindow.y)
        // a. 还没有有效选区 → 十字
        guard state.hasSelection else {
            NSCursor.crosshair.set()
            return
        }
        // b'. 面板展开期间：主行向上扩 60pt 的带内一律箭头（面板 overlay 常盖住选区，
        // 不透出角/边/选区光标——用户抱怨的「透到底底」即此）
        if state.panelBand.contains(p) {
            NSCursor.arrow.set()
            return
        }
        // b. 命中手柄（几何式）：先四角 ±8 → 对角缩放光标，再边线（内 8 外 3）→ 上下/左右缩放光标
        if let position = cornerPosition(at: p, in: state.selection) {
            NSCursor.frameResize(position: position, directions: .all).set()
            return
        }
        if let vertical = edgeAxis(at: p, in: state.selection) {
            (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
            return
        }
        // c. 选区内 → 绘制工具：blur = 空心圆笔刷光标（直径实时跟随滑块）/ 其他 = 十字；
        //    选择工具拖动中合掌 / 悬停开掌
        if state.selection.contains(p) {
            if state.tool == .blur {
                ringCursor(diameter: state.blurWidth).set()
            } else if state.tool.takesOverDrag {
                NSCursor.crosshair.set()
            } else if event.type == .leftMouseDragged {
                NSCursor.closedHand.set()
            } else {
                NSCursor.openHand.set()
            }
            return
        }
        // d. 其余（遮罩区域、工具栏、二级面板）→ 默认箭头（macOS 惯例：按钮 hover 也是箭头）
        NSCursor.arrow.set()
    }

    /// blur 笔刷光标缓存：按直径（blurPenWidth step 2，条目有限）；MainActor 隔离满足 Swift 6
    @MainActor
    private static var ringCursorCache: [CGFloat: NSCursor] = [:]

    /// 空心圆笔刷光标（blur 工具选区内）：CGContext 画双层圆环——外 1.5pt 黑 + 内 1pt 白
    /// （任意背景可见），中心透明，hotSpot = 圆心。直径 clamp 到 8...128（NSCursor 图像过大
    /// 系统拒绝/裁剪）；2× 位图保 retina 锐利；按直径缓存；任一步失败回退 crosshair
    @MainActor
    private static func ringCursor(diameter: CGFloat) -> NSCursor {
        let d = min(max(diameter, 8), 128)
        if let cached = ringCursorCache[d] { return cached }
        let pointSize = d + 4                      // 环外缘 R + 0.75pt，余 4pt 容 AA
        let pixel = Int(pointSize * 2)
        guard pixel > 0,
              let ctx = CGContext(data: nil, width: pixel, height: pixel,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .crosshair }
        ctx.scaleBy(x: 2, y: 2)                    // 2× 位图，NSImage 尺寸按 point
        let c = pointSize / 2
        let r = d / 2
        // 黑圈覆盖 R±0.75，白圈内缘 R-1.75…R-0.75 相接成 2.5pt 双层环；中心不填充保持透明
        let rings: [(CGFloat, CGColor, CGFloat)] = [
            (r, CGColor(red: 0, green: 0, blue: 0, alpha: 1), 1.5),
            (r - 1.25, CGColor(red: 1, green: 1, blue: 1, alpha: 1), 1.0),
        ]
        for (ringR, color, w) in rings {
            ctx.addEllipse(in: CGRect(x: c - ringR, y: c - ringR, width: ringR * 2, height: ringR * 2))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.strokePath()
        }
        guard let cgImage = ctx.makeImage() else { return .crosshair }
        let cursor = NSCursor(image: NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize)),
                              hotSpot: NSPoint(x: c, y: c))
        ringCursorCache[d] = cursor
        return cursor
    }
}

/// 模糊预览图的单条目缓存：引用类型，@State 持有不触发视图刷新
///（涂抹拖动期间选区不变，Canvas 每帧重绘直接命中缓存，避免逐帧重复 CI 模糊）
private final class BlurPreviewCache {
    var sel: CGRect = .zero
    var radius: CGFloat = 0
    var image: CGImage?
}

/// 光标决策所用的可变快照：@State 持同一引用实例，monitor 闭包每次读到最新值
private final class CursorState {
    var hasSelection = false
    var selection: CGRect = .zero
    var viewHeight: CGFloat = 0
    /// 当前标注工具：绘制工具激活时选区内十字
    var tool: AnnotationTool = .select
    /// 面板展开期间的光标带（主行矩形向上扩 60pt，见 panelBand）；全收起时 .zero
    var panelBand: CGRect = .zero
    /// blur 工具笔刷光标直径（= blurPenWidth，实时跟随滑块）
    var blurWidth: CGFloat = 0
}

/// 调整态可拖拽的部位：8 个手柄 + 选区内部（整体移动）
/// （brief 原为 SelectionView 内 private 嵌套 enum，因外部类型不可引用而提为文件顶层，行为不变）
enum SelectionHandleKind {
    case topLeft, top, topRight, right
    case bottomRight, bottom, bottomLeft, left
    case move
}

/// 整屏矩形挖去选区的遮罩形状（配合 eoFill 挖洞）：洞为圆角矩形（radius 0 即直角）
private struct DimmingMask: Shape {
    let selection: CGRect?
    /// 洞的圆角（point）：选区洞与白边一致，窗口高亮洞为 0
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Rectangle().path(in: rect)
        if let selection {
            path.addPath(RoundedRectangle(cornerRadius: cornerRadius).path(in: selection))
        }
        return path
    }
}

/// 液态玻璃尺寸胶囊
private struct SizeBadge: View {
    let rect: CGRect

    var body: some View {
        Text("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(in: Capsule())
    }
}

/// 无底色图标钮（24×24 命中区）：标注工具 / 撤销 / 保存 / 复制共用规格。
/// 视觉重构后整行共享一个液态玻璃胶囊，钮本身不带底色（前景 .primary）；
/// 仅左侧六个工具钮有选中态：20×20 accent 实心内圆 + 白色图标（旧 accent 描边态已删）；
/// 保存/复制/撤销等动作钮恒 false（纯图标）
private struct ToolbarIconButton: View {
    let symbol: String
    let selected: Bool
    /// 无障碍标签（图标钮可读性，全部钮显式传入中文名）
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 24, height: 24)
                .background {
                    // 选中态底色画在 24×24 命中区上层居中（20×20 内圆，四周留 2pt 呼吸）
                    if selected {
                        Circle().fill(Color(nsColor: .controlAccentColor))
                            .frame(width: 20, height: 20)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 弹出面板标识（锚点 preference 的 key；互斥开关按其寻址）：style = 色+宽合并样式面板
/// （pen 系专用钮触发）、width = blur 双滑块面板、radius = 圆角
private enum PanelID: String, CaseIterable {
    case style, width, radius
}

/// 显隐槽（按钮显隐的布局机制）：恒在布局的定宽容器 + **TimelineView 手动逐帧插值宽度**。
/// 为什么不用 .animation/withAnimation（探针逐帧实证，macOS 26 SDK）：glassEffect 容器丢弃
/// 跨其边界的动画事务——动画挂玻璃外只得到「容器瞬变 + 内容先反向瞬移 Δ 再弹簧归位」的
/// 两相错位（用户看到的「先整体移动一截再伸缩」；探针数据：行右缘瞬跳 700→667 再弹回），
/// 挂玻璃内（含 withAnimation 事务）被整体吞掉直接瞬变。改为 TimelineView(.animation)
/// 逐帧直接驱动 frame(width:)：每帧真实重排（HStack/玻璃胶囊/锚点复刻层同步），全屏 wrapper
/// 逐帧右缘钉住——探针标准达标：**右缘恒定 0.00pt、左缘 easeOut 单调伸缩（无过冲）、
/// 圆角钮等右侧项位移 0.1-0.3pt**。
/// 内容 trailing 对齐 + clipped（中间态向左溢出裁切）；透明度随宽度渐进（显=淡入 隐=淡出）；
/// 宽度 ≤0.5 时内容不渲染（clipped 只裁绘制不裁命中，必须 if 移除内容防隐形钮命中残留）。
/// 插值状态持引用类型类（视图身份重置至多丢一次动画，不会反向）；首帧（lastTarget == nil）
/// 直接落位不动画（工具栏初现无弹跳）
private struct RevealSlot<Content: View>: View {
    /// 目标宽度（0 = 全隐）
    let target: CGFloat
    /// 全宽：透明度渐变归一基准（= 展开后的槽宽 33）
    let fullWidth: CGFloat
    @ViewBuilder let content: () -> Content

    final class Anim {
        var lastTarget: CGFloat? = nil
        var start: CGFloat = 0
        var began = Date.distantPast
        var shown: CGFloat = 0
    }
    @State private var anim = Anim()
    /// easeOut 二次曲线（单调无过冲），显/隐同款
    private let duration: Double = 0.28

    private func current(_ now: Date) -> CGFloat {
        if anim.lastTarget != target {
            if anim.lastTarget != nil { anim.start = anim.shown } else { anim.start = target }
            anim.began = now
            anim.lastTarget = target
        }
        let t = now.timeIntervalSince(anim.began) / duration
        guard t >= 0, t < 1, anim.start != target else {
            anim.shown = target
            return target
        }
        let p = 1 - pow(1 - t, 2)
        let w = anim.start + (target - anim.start) * p
        anim.shown = w
        return w
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let w = current(timeline.date)
            ZStack(alignment: .trailing) {
                if w > 0.5 {
                    content()
                        .opacity(Double(min(1, w / fullWidth * 1.6)))
                }
            }
            .frame(width: max(w, 0), height: 24)
            .clipped()
        }
    }
}

/// 触发钮锚点 preference：[PanelID.rawValue: 胶囊本地空间中点 x]。只由测量复刻层发布
/// （真实行不发布 → 空默认值 merge 无副作用），在玻璃外上溯（glassEffect 容器会吞噬
/// 子层 preference 与命名坐标空间上溯，probe 实证）
private struct PanelAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 选区右下角单行工具栏（整体液态玻璃胶囊 ~34pt + 收起式弹出面板）：
/// [选择|箭头|矩形|椭圆|画笔|模糊] ‖ [样式钮]（pen 系，按工具显隐；blur 显 [宽钮]）[圆角] ‖ [撤销]（空栈隐藏）‖ [保存][复制]。
/// 视觉重构：整行包进单一 glassEffect(in: Capsule())（左右留白 10 / 上下 5，高 24+10=34），
/// 钮全部无底色。样式（色板+粗细合并双层面板）/blur 双滑块面板为 16pt 圆角玻璃矩形、
/// 圆角面板为玻璃胶囊（偏矮小，胶囊合适），
/// 浮于触发钮正上方、统一间隙 16pt（一个 slot 常量）、可盖选区、不占布局——但不再挂触发钮
/// overlay：glassEffect 容器裁剪超出胶囊边界的命中（面板点不中/滑块拖不动的回归根因，
/// probe 实证），改挂玻璃外面板浮层宿主（panelsHost），经玻璃外测量复刻层上报的锚点复现
/// 原锚定几何（命中与视觉严格一致）。互斥至多展开一个，开合带系统动画（opacity + 底部滑入，
/// 见 panelsHost/mainRow）：样式面板选色/选档即时生效不收起（点样式钮或互斥收起），
/// 圆角拖动不收起（再点圆角钮收起）。
/// 拖动走玻璃块背景拖动层（拖非按钮的空白像素；按钮/滑块命中优先、不下落，Slider tracking 不被抢占）；
/// 样式钮/宽钮按工具自动显隐（显隐槽机制见 revealSlot）：select 无绘制参数全隐（槽宽 0），
/// pen 系显样式钮（色+宽合并触发）、blur 显宽钮（双滑块触发）。
/// arrow/rect/ellipse/pen/blur 的绘制手势由 SelectionView 经 activeTool.takesOverDrag 接入选区拖动。
private struct CaptureToolbar: View {
    @Binding var tool: AnnotationTool
    @Binding var color: RGBA
    @Binding var lineWidth: AnnotationWidth
    @Binding var cornerRadius: Double
    /// 模糊工具专属双滑块值（半径 4...20 / 笔宽 8...80），仅 blur 面板消费
    @Binding var blurRadius: Double
    @Binding var blurPenWidth: Double
    /// 色板+粗细合并样式面板开关（pen 系样式钮触发）
    @Binding var showStylePanel: Bool
    @Binding var showWidthPicker: Bool
    @Binding var showRadiusSlider: Bool
    /// 工具栏自由位置（nil = 锚定跟随；sel 空间胶囊右下角锚点绝对点，背景拖动层手势经此回写，
    /// 渲染 offset 与 panelBand 消费；不 clamp 屏缘，@State 每会话重置）
    @Binding var toolbarPosition: CGPoint?
    /// 工具栏拖动进行中（背景拖动层手势标记；外层 scaleEffect 视觉反馈消费）
    @Binding var toolbarDragging: Bool
    /// 拖动起始渲染点基线（onChanged 首帧从 toolbarPosition ?? anchor 解包，后续帧累加 translation）
    @Binding var toolbarDragBase: CGPoint
    /// 当前锚定点（sel 空间胶囊右下角 = toolbarRowLayout 的 right/bottom；基线解包与吸附判定参照）
    let anchor: CGPoint
    /// 撤销可用（annotations 非空）：空栈时整钮不渲染（原 40% 置灰删除）
    let canUndo: Bool
    let onUndo: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void

    /// 面板锚定偏移（锚定槽 overlay alignment .bottom 上再 offset，四个面板统一一个 slot）：
    /// 钮高 24 ＋ 统一间隙 16 → 面板底缘贴钮顶上方 16pt。原普通面板 4pt 过紧（用户要求留出
    /// 可见间距），blur 双滑块面板本就是 -40（间隙 16）——两常量合一，面板底缘同高对齐
    private let panelAnchorOffset: CGFloat = -(24 + 16)
    /// 触发钮锚点（测量复刻层上报，胶囊本地空间中点 x；key = PanelID.rawValue）——
    /// 面板浮层宿主定位消费。锚点经玻璃外 preference 送达（玻璃内上报会被容器吞噬）
    @State private var panelAnchors: [String: CGFloat] = [:]

    var body: some View {
        mainRow
    }

    // MARK: 主行

    /// 主行 = 行内容（玻璃包裹）+ 锚点测量复刻层（玻璃外）+ 面板浮层宿主（玻璃外）。
    /// 关键约束（probe 实证，macOS 26 SDK）：glassEffect 把被包裹内容装进以玻璃形状为界的
    /// 容器——容器内超出胶囊边界的部分（按钮 overlay 上的弹出面板）命中被裁剪吞掉
    /// （点不中、滑块拖不动），且容器的 preference/命名坐标空间上溯也被吞噬。
    /// 因此：① 弹出面板必须挂到玻璃之外（本结构 .overlay 兄弟层）；② 面板锚定所需的
    /// 触发钮位置测量也要在玻璃之外做——用同一 rowContent 构建器渲染一份不可见复刻层
    /// （几何恒同），preference 在玻璃外上报，面板浮层按锚点 slot 复现「overlay 于触发钮」
    /// 的原锚定几何。玻璃内只留按钮 + 拖动层（09dd5e0 的 z 序语义不变）
    private var mainRow: some View {
        rowContent(measure: false)
            .frame(height: 24)
            // 整体玻璃块：单行内容包进一个胶囊（左右 10 / 上下 5 留白，高 24+10=34），
            // 替代原先每钮独立玻璃圆钮
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // 拖动层必须挂在 glassEffect 之前（夹在按钮与玻璃之间，玻璃处于最底层）：
            // glassEffect 把玻璃材质画在「被包裹内容」的底层，.background 若挂在其后，
            // 拖动层会沉到玻璃之下——玻璃材质层本身参与命中测试，非按钮像素的命中
            // 终止在玻璃上、永远落不到拖动层（拖不动回归根因）。挂在前则 z 序自下而上
            // 为 玻璃 → 拖动层 → 按钮：空白像素（钮间隙/padding）命中拖动层即可挪动整块，
            // 按钮命中优先不下落；背景层是滑块的兄弟层而非祖先，NSSlider tracking 不被抢占。
            // 仍用 .background 而非 ZStack 独立子层：background 内容被宿主实际尺寸约束、
            // 精确跟随胶囊——ZStack 子层的 Color.clear 是 flexible，会吃满全屏定位 wrapper
            // 的提议尺寸把玻璃块撑成整屏（全屏回归根因，同 V2 move 层 position-wrapper 陷阱）
            .background {
                dragBackground
            }
            .glassEffect(in: Capsule())
            // 锚点测量复刻层：同一 rowContent（几何与真实行恒同）、不可见不可命中；
            // 复刻层经 .overlay 挂载（居中于同尺寸宿主 = 精确重合），其 padding 后本地
            // 坐标空间即胶囊本地空间（面板 slot 定位共用）
            .overlay {
                rowContent(measure: true)
                    .frame(height: 24)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .coordinateSpace(name: "panelAnchorSpace")
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // 面板浮层宿主：玻璃之上的兄弟层，命中不被玻璃容器裁剪（面板可点可拖的修复本体）
            .overlay {
                panelsHost
            }
            .onPreferenceChange(PanelAnchorKey.self) { panelAnchors = $0 }
            // 系统级显隐动画（仅面板开合）：面板浮层宿主在玻璃之外，其 transition
            // （.opacity + .move）经这些 .animation(value:) 正常驱动；value: tool 同时驱动
            // 切工具时的面板收起动画。按钮显隐不走这里——玻璃容器丢弃跨边界动画事务
            // （见 RevealSlot 注释），由 RevealSlot 的 TimelineView 手动逐帧插值。
            // .animation(value:) 是纯驱动修饰符：不创建容器、不参与命中，玻璃 z 序、
            // 拖动层挂载与面板浮层宿主结构均不受影响
            .animation(.snappy, value: showStylePanel)
            .animation(.snappy, value: showWidthPicker)
            .animation(.snappy, value: showRadiusSlider)
            .animation(.snappy, value: tool)
    }

    /// 行内容单一构建源（真实行与测量复刻层共用，几何恒同）：measure = true 时三个
    /// 触发钮经 background GR 上报锚点（背景不占布局，真实行 measure = false 无影响）
    @ViewBuilder
    private func rowContent(measure: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                // 「move」在 macOS 26 SDK 缺失（NSImage(systemSymbolName:) 返回 nil）；cursorarrow 视觉不佳，
                // 选择工具改用手型 hand.draw（probe 实证存在）
                ToolbarIconButton(symbol: "hand.draw", selected: tool == .select, accessibilityLabel: "选择") { tool = .select }
                ToolbarIconButton(symbol: "arrow.up.right", selected: tool == .arrow, accessibilityLabel: "箭头") { tool = .arrow }
                ToolbarIconButton(symbol: "rectangle", selected: tool == .rect, accessibilityLabel: "矩形") { tool = .rect }
                ToolbarIconButton(symbol: "circle", selected: tool == .ellipse, accessibilityLabel: "椭圆") { tool = .ellipse }
                ToolbarIconButton(symbol: "scribble", selected: tool == .pen, accessibilityLabel: "画笔") { tool = .pen }
                ToolbarIconButton(symbol: "drop.fill", selected: tool == .blur, accessibilityLabel: "模糊") { tool = .blur }
            }
            // 样式/宽度段左分隔符（**恒定**，在槽外）：样式槽 select 态收起时仍保证工具组
            // 与圆角钮之间有分隔（随槽收起会只剩留白）；pen/blur 态几何与随槽版完全一致
            // （工具组—8—sep—8—钮）
            separator
            // 按工具自动显隐（显隐槽 RevealSlot，手动逐帧插值——见 RevealSlot 注释）：
            // pen 系显样式钮（色+宽合并面板触发）；select 无绘制参数（槽宽 0 全隐）；
            // blur 显宽钮（双滑块面板触发）。槽内容只剩钮（宽 24）——左分隔符已移出槽外恒显，
            // 单子层内容直接放（无前轮 Group 拍平垂直堆叠问题）
            RevealSlot(target: Self.revealSlotWidth(tool: tool), fullWidth: 24) {
                if tool == .blur {
                    currentWidthButton
                        .background { if measure { anchorPublisher(.width) } }
                } else {
                    styleButton
                        .background { if measure { anchorPublisher(.style) } }
                }
            }
            radiusButton
                .background { if measure { anchorPublisher(.radius) } }
            // 撤销：空栈整钮不渲染（原 40% 置灰改为按需显隐）；同款显隐槽手动插值伸缩。
            // 撤销段左分隔符留在槽内随槽收起（与样式段不同）：撤销收起后右侧紧跟保存段
            // 的恒定分隔符，不存在「只剩留白」问题；分隔符随槽收起反而避免双分隔相邻
            RevealSlot(target: canUndo ? 33 : 0, fullWidth: 33) {
                HStack(spacing: 8) {
                    separator
                    ToolbarIconButton(symbol: "arrow.uturn.backward", selected: false, accessibilityLabel: "撤销", action: onUndo)
                }
            }
            // 保存/复制段的左分隔符（恒定）：撤销槽收起时仍在，保证动作段始终有左分隔
            separator
            // 动作钮：与其他钮统一 24×24 无底色纯图标规格（无选中态），accessibilityLabel 保可读性
            ToolbarIconButton(symbol: "square.and.arrow.down",
                              selected: false,
                              accessibilityLabel: "保存",
                              action: onSave)
            ToolbarIconButton(symbol: "doc.on.doc",
                              selected: false,
                              accessibilityLabel: "复制",
                              action: onCopy)
        }
    }

    /// 显隐槽宽度单一公式源（与 rowContent 显隐槽内容一一对应）：样式/宽槽内容仅钮 24
    /// （左分隔符已移出槽外恒显）；select = 0（全隐）。撤销槽不走此公式（内容含左分隔符，
    /// 恒 33，见 rowContent 调用处）
    private static func revealSlotWidth(tool: AnnotationTool) -> CGFloat {
        tool == .select ? 0 : 24
    }

    /// 背景拖动层（挂 mainRow 的 .background、且必须挂 .glassEffect 之前——顺序语义见
    /// mainRow 注释；尺寸被宿主约束 = 玻璃胶囊实际大小）：
    /// 透明铺满玻璃块、contentShape 圈住全部像素，拖动非按钮的
    /// 空白像素（钮间隙、padding）即可挪动整块——上层按钮/滑块命中优先、不下落，容器手势
    /// 不再抢占 NSSlider tracking（滑块拖不动的回归修复）。
    /// onChanged 首帧锁定基线（toolbarPosition nil 视作当时锚定点 anchor——起步零跳变）后累加
    /// translation；onEnded 落点距锚定点 <12pt → nil 吸附回跟随，否则存绝对位置——
    /// 不做屏幕 clamp（用户明确不要避让，可拖出屏缘，保持到下次截图会话重置）
    private var dragBackground: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("sel"))
                    .onChanged { value in
                        if !toolbarDragging {
                            toolbarDragging = true
                            toolbarDragBase = toolbarPosition ?? anchor
                        }
                        toolbarPosition = CGPoint(x: toolbarDragBase.x + value.translation.width,
                                                  y: toolbarDragBase.y + value.translation.height)
                    }
                    .onEnded { value in
                        toolbarDragging = false
                        let point = CGPoint(x: toolbarDragBase.x + value.translation.width,
                                            y: toolbarDragBase.y + value.translation.height)
                        // 吸附回跟随：落点距当前锚定点 < 12pt 视为放弃自由位置，恢复锚定
                        if hypot(point.x - anchor.x, point.y - anchor.y) < 12 {
                            toolbarPosition = nil
                        } else {
                            toolbarPosition = point
                        }
                    }
            )
    }

    /// 样式钮（24×24 命中区，内嵌当前色 14pt 圆点——colorDot 复用，白/黑自带 separator 描边）：
    /// pen 系专用，点击开合「色板+粗细」合并样式面板（上行 8 色、下行 3 档粗细，见 panelsHost）。
    /// 面板不再挂本钮 overlay——玻璃容器会裁剪超出胶囊边界的命中（见 mainRow 注释），
    /// 改经 panelsHost 锚定槽浮于钮正上方（视觉与命中同几何）
    private var styleButton: some View {
        Button {
            togglePanel(.style)
        } label: {
            colorDot(color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 宽钮（24×24 命中区，内嵌 dotDiameter 实心圆点，无底色）：blur 工具专用，
    /// 点击展开/收起半径/笔宽双滑块面板（挂 panelsHost，命中不被裁剪）
    private var currentWidthButton: some View {
        Button {
            togglePanel(.width)
        } label: {
            Circle()
                .fill(Color.primary)
                .frame(width: lineWidth.dotDiameter, height: lineWidth.dotDiameter)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 模糊工具双滑块面板：上行「半径」4...20（step 1，固化进每笔）、下行「宽度」8...80（step 2）；
    /// 数值等宽数字不跳动；拖动实时生效（进行中笔画沿用起笔固化值，下一笔生效）
    private var blurSliderPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("半径").font(.system(size: 12, weight: .medium))
                Slider(value: $blurRadius, in: 4...20, step: 1)
                    .frame(width: 120)
                Text("\(Int(blurRadius))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 24)
            }
            HStack(spacing: 8) {
                Text("宽度").font(.system(size: 12, weight: .medium))
                Slider(value: $blurPenWidth, in: 8...80, step: 2)
                    .frame(width: 120)
                Text("\(Int(blurPenWidth))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 24)
            }
        }
        .foregroundStyle(.primary)
    }

    /// 圆角钮（无底色：rectangle.roundedtop 圆角矩形符号（比 ruler 更直观，probe 实证存在）
    /// + 当前值 10pt monospacedDigit）：点击展开/收起圆角滑条面板（浮于钮正上方；滑条拖动不收起，再点钮收起）。
    /// 面板同样改挂 panelsHost（玻璃外）
    private var radiusButton: some View {
        Button {
            togglePanel(.radius)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.roundedtop")
                    .font(.system(size: 12, weight: .medium))
                Text("\(Int(cornerRadius))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(.primary)
            .frame(width: 48, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 面板浮层宿主（玻璃外）

    /// 面板浮层宿主（挂 mainRow 玻璃合成体的 .overlay，玻璃外兄弟层）：按互斥开关渲染
    /// 当前展开的面板，锚定槽对准测量复刻层上报的触发钮中点 x。渲染门槛同时镜像触发钮
    /// 的显隐条件（触发钮因工具切换消失时面板随之消失，同旧 overlay 行为）与锚点已测得
    /// （锚点在首次布局即上报；面板只经触发钮点击打开，不存在锚点未就位窗口）
    @ViewBuilder
    private var panelsHost: some View {
        GeometryReader { _ in
            if showStylePanel, tool != .select, tool != .blur,
               let anchorX = panelAnchors[PanelID.style.rawValue] {
                panelSlot(anchorX: anchorX) {
                    // 色板+粗细合并样式面板（两行 VStack，同 blur 双滑块面板节奏）：
                    // 上行 8 色板（当前色 ring）、下行 3 档粗细（当前档 ring）；
                    // 选色/选档即时生效不收起——收起沿用现有交互（点样式钮 / 互斥切面板）。
                    // 内容额外 .padding(.horizontal, 6)：8 色板首尾色与容器边缘留出明显
                    // 间隙（原 10pt 留白下首尾色几乎贴边），粗细行同样受益
                    panelCapsuleAdaptive {
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { _, c in
                                    colorSwatch(c) { }
                                }
                            }
                            HStack(spacing: 6) {
                                ForEach(AnnotationWidth.allCases, id: \.pt) { w in
                                    widthButton(w) { }
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                    }
                    .offset(y: panelAnchorOffset)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if showWidthPicker, tool != .select,
               let anchorX = panelAnchors[PanelID.width.rawValue] {
                if tool == .blur {
                    panelSlot(anchorX: anchorX) {
                        panelCapsuleAdaptive {
                            blurSliderPanel
                        }
                        .offset(y: panelAnchorOffset)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    panelSlot(anchorX: anchorX) {
                        panelCapsule {
                            HStack(spacing: 6) {
                                ForEach(AnnotationWidth.allCases, id: \.pt) { w in
                                    widthButton(w) { showWidthPicker = false }
                                }
                            }
                        }
                        .offset(y: panelAnchorOffset)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            if showRadiusSlider, let anchorX = panelAnchors[PanelID.radius.rawValue] {
                panelSlot(anchorX: anchorX) {
                    panelCapsule {
                        HStack(spacing: 12) {
                            Text("圆角").font(.system(size: 12, weight: .medium))
                            Slider(value: $cornerRadius, in: 0...40, step: 1)
                                .frame(width: 160)
                            Text("\(Int(cornerRadius))")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .frame(width: 24)
                        }
                    }
                    .offset(y: panelAnchorOffset)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// 面板锚定槽：24×24 透明槽（与触发钮同尺寸）复现「overlay 于触发钮」的原锚定几何——
    /// 面板 overlay 挂在槽的 24×24 frame 上、bottom 对齐 + 原 offset，再整体 .position 到
    /// 锚点。顺序关键（probe 实证，同 V2 contentShape-after-position 陷阱的镜像）：
    /// overlay 必须挂在 .position 之前——position 之后再挂 overlay 会锚到定位包装器的
    /// 全部提议区域（整个胶囊），面板错位到胶囊中心
    private func panelSlot<Panel: View>(anchorX: CGFloat, @ViewBuilder panel: () -> Panel) -> some View {
        Color.clear
            .frame(width: 24, height: 24)
            .overlay(alignment: .bottom) {
                panel()
            }
            .position(x: anchorX, y: 17)   // 触发钮中心：胶囊高 34 − 垂直留白 5 − 半钮 12
    }

    /// 锚点上报层（仅测量复刻行使用）：触发钮在 panelAnchorSpace（复刻层 padding 后本地
    /// 空间 = 胶囊本地空间）的中点 x，经 preference 在玻璃外上报（玻璃内上报会被吞噬）
    private func anchorPublisher(_ id: PanelID) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: PanelAnchorKey.self,
                                   value: [id.rawValue: g.frame(in: .named("panelAnchorSpace")).midX])
        }
    }

    // MARK: 弹出面板（互斥）

    /// 面板互斥开关（**一步切到目标**）：目标已开 → 仅收起目标；目标未开 → 无条件关掉其余
    /// 面板并开目标。旧实现（先 toggle 目标、再按「当前哪些面板开着」顺序互斥）在其他面板
    /// 残留开启时会把刚打开的目标立即关掉——色板残留时点宽度钮「点一次没反应、再点才开」
    /// 的根因；配合切工具全收面板（SelectionView 的 onChange(of: activeTool)）双保险
    private func togglePanel(_ id: PanelID) {
        if isOpen(id) {
            setPanel(id, false)
        } else {
            for other in PanelID.allCases where other != id {
                setPanel(other, false)
            }
            setPanel(id, true)
        }
    }

    /// 面板开关的读取/写入单一出口（互斥逻辑经 PanelID 寻址，不写三份 if）
    private func isOpen(_ id: PanelID) -> Bool {
        switch id {
        case .style: showStylePanel
        case .width: showWidthPicker
        case .radius: showRadiusSlider
        }
    }

    private func setPanel(_ id: PanelID, _ value: Bool) {
        switch id {
        case .style: showStylePanel = value
        case .width: showWidthPicker = value
        case .radius: showRadiusSlider = value
        }
    }

    /// 面板容器：玻璃胶囊（高 24，水平内边距 10）
    private func panelCapsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .glassEffect(in: Capsule())
    }

    /// 面板容器（高度自适应变体，仅样式面板与 blur 双滑块面板使用）：玻璃圆角矩形
    /// （16pt 圆角——面板偏高大，胶囊半圆端过鼓；水平 10 / 垂直 6 内边距），
    /// blur 双滑块面板 ~48 高。圆角滑条面板仍走 panelCapsule（胶囊）不变
    private func panelCapsuleAdaptive<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 复用控件

    /// 分隔线 1×16 半透明
    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.25))
            .frame(width: 1, height: 16)
    }

    /// 色圆点（14pt）：白/黑加 1pt separator 描边保可见（色板与当前色钮共用）
    private func colorDot(_ c: RGBA) -> some View {
        Circle()
            .fill(Color(red: c.r, green: c.g, blue: c.b, opacity: c.a))
            .frame(width: 14, height: 14)
            .overlay {
                if c == .black || c == .white {
                    Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
    }

    /// 色板圆点钮：当前色外套 2pt accent ring（内缘贴圆点边缘）；选中后执行 onSelect（面板内 = 收起）
    private func colorSwatch(_ c: RGBA, onSelect: @escaping () -> Void) -> some View {
        Button {
            color = c
            onSelect()
        } label: {
            colorDot(c)
                .overlay {
                    if c == color {
                        Circle().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                            .frame(width: 18, height: 18)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// 粗细钮（垂直居中实心圆点，直径 = dotDiameter）：当前档外套 2pt accent ring；选中后执行 onSelect
    private func widthButton(_ w: AnnotationWidth, onSelect: @escaping () -> Void) -> some View {
        Button {
            lineWidth = w
            onSelect()
        } label: {
            Circle()
                .fill(Color.primary)
                .frame(width: w.dotDiameter, height: w.dotDiameter)
                .frame(width: 18, height: 24)   // 扩大命中区到行高，圆点保持垂直居中
                .overlay {
                    if w == lineWidth {
                        Circle().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                            .frame(width: w.dotDiameter + 4, height: w.dotDiameter + 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 手柄

private struct AdjustStarterKey: EnvironmentKey {
    // Swift 6 严格并发：闭包类型默认值不满足 Sendable，no-op 默认值 + 环境注入均在主线程，
    // 用 nonisolated(unsafe) 显式豁免
    nonisolated(unsafe) static let defaultValue: (SelectionHandleKind, CGPoint) -> Void = { _, _ in }
}
private struct AdjustUpdaterKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (CGPoint) -> Void = { _ in }
}
private struct AdjustEnderKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: () -> Void = {}
}

// brief 原为 private extension：private 成员的 key path 在 Handle 的 @Environment 处不可见
//（编译报 "cannot infer key path type"），改为默认 internal 使同模块可见。
extension EnvironmentValues {
    var adjustStarter: (SelectionHandleKind, CGPoint) -> Void {
        get { self[AdjustStarterKey.self] } set { self[AdjustStarterKey.self] = newValue }
    }
    var adjustUpdater: (CGPoint) -> Void {
        get { self[AdjustUpdaterKey.self] } set { self[AdjustUpdaterKey.self] = newValue }
    }
    var adjustEnder: () -> Void {
        get { self[AdjustEnderKey.self] } set { self[AdjustEnderKey.self] = newValue }
    }
}

/// 8 个缩放手柄（四角 + 四边中点）：白点 8pt；角命中 ±8，整边命中条内侧 8pt / 外侧 3pt
private struct HandleLayer: View {
    let selection: CGRect

    var body: some View {
        let edges: [(SelectionHandleKind, CGRect)] = [
            // 命中条：内侧 8pt / 外侧 3pt（厚 11pt）——外侧不再扩 8pt，避免伸入选区与紧贴工具栏
            // 之间的 4pt 缝隙（缝隙/工具栏上拖动误触单边缩放的回归修复，光标判定 edgeAxis 同几何）；
            // 端点各缩 8pt 让角区独占（角手柄后渲染、命中优先，四角保持 ±8 有白点视觉指示）
            (.top, CGRect(x: selection.minX + 8, y: selection.minY - 3, width: selection.width - 16, height: 11)),
            (.bottom, CGRect(x: selection.minX + 8, y: selection.maxY - 8, width: selection.width - 16, height: 11)),
            (.left, CGRect(x: selection.minX - 3, y: selection.minY + 8, width: 11, height: selection.height - 16)),
            (.right, CGRect(x: selection.maxX - 8, y: selection.minY + 8, width: 11, height: selection.height - 16)),
        ]
        let handles: [(SelectionHandleKind, CGPoint)] = [
            (.topLeft, CGPoint(x: selection.minX, y: selection.minY)),
            (.top, CGPoint(x: selection.midX, y: selection.minY)),
            (.topRight, CGPoint(x: selection.maxX, y: selection.minY)),
            (.right, CGPoint(x: selection.maxX, y: selection.midY)),
            (.bottomRight, CGPoint(x: selection.maxX, y: selection.maxY)),
            (.bottom, CGPoint(x: selection.midX, y: selection.maxY)),
            (.bottomLeft, CGPoint(x: selection.minX, y: selection.maxY)),
            (.left, CGPoint(x: selection.minX, y: selection.midY)),
        ]

        ZStack(alignment: .topLeading) {
            // 先渲染整边命中条，后渲染角手柄：重叠区角优先
            ForEach(edges, id: \.0) { kind, rect in
                EdgeHandle(kind: kind, rect: rect)
            }
            ForEach(handles, id: \.0) { kind, position in
                Handle(kind: kind, position: position)
            }
        }
    }
}

/// 整边命中条（透明）：拖动任意一条边改变大小，手势模式与 Handle 一致
private struct EdgeHandle: View {
    let kind: SelectionHandleKind
    let rect: CGRect

    @Environment(\.adjustStarter) private var starter
    @Environment(\.adjustUpdater) private var updater
    @Environment(\.adjustEnder) private var ender
    /// 手势已开始标志：minimumDistance 1 下首个 onChanged 的 translation 通常已非零，
    /// 不能用 `translation == .zero` 判起点（否则 starter 永不触发、手柄失效）
    @State private var began = false

    var body: some View {
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("sel"))
                    .onChanged { value in
                        if !began {
                            began = true
                            starter(kind, value.startLocation)
                        }
                        updater(value.location)
                    }
                    .onEnded { _ in
                        began = false
                        ender()
                    }
            )
    }
}

private struct Handle: View {
    let kind: SelectionHandleKind
    let position: CGPoint

    @Environment(\.adjustStarter) private var starter
    @Environment(\.adjustUpdater) private var updater
    @Environment(\.adjustEnder) private var ender
    /// 手势已开始标志：minimumDistance 1 下首个 onChanged 的 translation 通常已非零，
    /// 不能用 `translation == .zero` 判起点（否则 starter 永不触发、手柄失效）
    @State private var began = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 8, height: 8)
            .shadow(radius: 1)
            .frame(width: 16, height: 16)   // 扩大命中区
            .contentShape(Rectangle())
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("sel"))
                    .onChanged { value in
                        if !began {
                            began = true
                            starter(kind, value.startLocation)
                        }
                        updater(value.location)
                    }
                    .onEnded { _ in
                        began = false
                        ender()
                    }
            )
    }
}
