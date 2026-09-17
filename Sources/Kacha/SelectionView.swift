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
    /// 收起式弹出面板开关（互斥：同一时间至多展开一个，打开一个即关其他；面板为触发钮 overlay，不占布局）
    @State private var showColorPalette = false
    @State private var showWidthPicker = false
    @State private var showRadiusSlider = false
    /// 工具栏手动拖动偏移：nil = 默认锚定（选区右下，toolbarRowLayout）；非 nil = 相对锚定位置的
    /// 偏移（松手时 clamp 到屏内 6/4pt 边距后的合法值；吸附阈值内置回 nil）
    @State private var toolbarOffset: CGSize? = nil
    /// 工具栏拖动进行中（视觉 scale 1.02 + onChanged 首帧基线标记）
    @State private var toolbarDragging = false
    /// 拖动起始偏移基线：onChanged 首帧从 toolbarOffset（nil 视作 .zero）解包，后续帧累加 translation
    @State private var toolbarDragBase: CGSize = .zero

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
        .onChange(of: showColorPalette || showWidthPicker || showRadiusSlider) { _, _ in
            // 面板展开/收起源同步：任一面板开 → 行矩形向上扩 60pt 光标带，全收起 → .zero
            syncPanelBand(sel: selection, bounds: geo.size)
        }
        .onChange(of: toolbarOffset) { _, _ in
            // 工具栏拖动源同步：光标带跟随含偏移的最终组矩形（拖动中逐帧更新）
            syncPanelBand(sel: selection, bounds: geo.size)
        }
        .onChange(of: blurPenWidth) { _, new in
            // blur 笔刷光标直径源同步（实时跟随滑块；blurRadius 不影响光标）
            cursorState.blurWidth = CGFloat(new)
        }
        .onChange(of: activeTool) { _, new in
            // 光标快照同步（引用实例，monitor 每次读到最新值）
            cursorState.tool = new
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

    /// 面板展开光标带同步（selection / 面板开关 / toolbarOffset 三类 onChange 源共用）；
    /// 面板全收起时 panelBand 公式自回 .zero
    private func syncPanelBand(sel: CGRect?, bounds: CGSize) {
        cursorState.panelBand = Self.panelBand(
            sel: sel, bounds: bounds,
            anyPanelOpen: showColorPalette || showWidthPicker || showRadiusSlider,
            drag: toolbarOffset ?? .zero)
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

    /// 选区右下角单行工具栏（紧贴选区，拖动玻璃块上非按钮的像素即可挪开）：
    /// [选择|箭头|矩形|椭圆|画笔|模糊] ‖ [当前色][当前粗细][圆角]（按工具显隐）‖ [撤销]（空栈隐藏）‖ [保存][复制]；
    /// 色板/粗细/圆角面板为触发钮 overlay（浮于钮正上方、可盖选区、不占布局）。
    /// 整组布局（右缘锚点 / 底缘 / clamp / 面板光标带基底）见 toolbarRowLayout 单一公式源。
    /// 独立成方法：主 body 过大触发编译器「unable to type-check in reasonable time」，拆块缓解
    @ViewBuilder
    private func captureToolbar(in geo: GeometryProxy, sel: CGRect) -> some View {
        let group = Self.toolbarRowLayout(sel: sel, bounds: geo.size)
        let toolbarDrag = toolbarOffset ?? .zero
        CaptureToolbar(tool: $activeTool,
                       color: $annotationColor,
                       lineWidth: $annotationWidth,
                       cornerRadius: $cornerRadius,
                       blurRadius: $blurRadius,
                       blurPenWidth: $blurPenWidth,
                       showColorPalette: $showColorPalette,
                       showWidthPicker: $showWidthPicker,
                       showRadiusSlider: $showRadiusSlider,
                       toolbarOffset: $toolbarOffset,
                       toolbarDragging: $toolbarDragging,
                       toolbarDragBase: $toolbarDragBase,
                       clampRow: group.row,
                       screenBounds: geo.size,
                       canUndo: !annotations.isEmpty,
                       onUndo: undoLastAnnotation,
                       onSave: save,
                       onCopy: confirm)
        // 拖动经玻璃块背景层（拖非按钮的空白像素；按钮/滑块命中优先、不下落）；
        // 拖动中轻微放大反馈。不加 hover 光标——applyCursor monitor 的 mouseMoved
        // arrow 兜底会覆盖 onHover 设置，保持 arrow（macOS 工具栏惯例）
        .scaleEffect(toolbarDragging ? 1.02 : 1)
        // 组右缘/底缘先 pin 到屏右屏底、再 offset 到锚点 + 手动拖动偏移：右对齐不依赖行宽；
        // 底缘锚定主行——面板展开向上生长，不推挤主行（主行不跳动）
        .frame(width: geo.size.width, height: geo.size.height,
               alignment: Alignment(horizontal: .trailing, vertical: .bottom))
        .offset(x: group.right - geo.size.width + toolbarDrag.width,
                y: group.bottom - geo.size.height + toolbarDrag.height)
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
    /// （渲染 offset / 面板光标带基底共用）：组右缘锚定选区白边右缘（sel.maxX，与边框对齐）；
    /// 左缘出屏时整组右移（rowWidth 取主行估算宽 + 容差，右缘允许越过锚点）；
    /// 锚点 = 主行底缘 bottom，整组紧贴选区：下方放得下（组顶贴 sel.maxY + 4、组底再留 8pt 屏底余量）
    /// 时组底缘 sel.maxY + 38（主行中心 sel.maxY + 21），否则收进选区内侧组底缘 sel.maxY - 4
    /// （主行 34pt 高：底部留 4pt，主体伸入选区内 38pt）。
    static func toolbarRowLayout(sel: CGRect, bounds: CGSize) -> (right: CGFloat, bottom: CGFloat, row: CGRect) {
        // 玻璃胶囊实际宽：全显（标注工具 + 撤销栈非空）≈437（工具 6×24+5×6 ＋ 分隔 1
        // ＋ 色钮 24 ＋ 粗细钮 24 ＋ 圆角钮 48 ＋ 分隔 1 ＋ 撤销 24 ＋ 分隔 1 ＋ 保存钮 24 ＋ 复制钮 24
        // ＋ 10×8 段间距 ＋ 胶囊水平留白 10×2）；select 态最窄（色/宽/撤销隐藏）≈315，blur 态 ≈364，
        // 均被保守覆盖；常量保留 482（历史值，全显宽 + 约 45pt 容差）——仅用于面板光标带基底与
        // 左缘 clamp（偏保守只影响带略宽/clamp 略早，无正确性问题）；实际渲染用右缘 pin + offset，
        // 不依赖该估算。
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

    /// 面板展开期间的光标带：主行矩形（含手动拖动偏移）向上扩 60pt（面板 overlay 向上生长、
    /// 几何上常盖住选区，带内一律箭头，不透出选区光标）。无有效选区或面板全收起时为 .zero（不拦光标）。
    static func panelBand(sel: CGRect?, bounds: CGSize, anyPanelOpen: Bool, drag: CGSize = .zero) -> CGRect {
        guard anyPanelOpen, let sel, SelectionGeometry.isValid(sel) else { return .zero }
        return toolbarRowLayout(sel: sel, bounds: bounds).row
            .offsetBy(dx: drag.width, dy: drag.height)
            .insetBy(dx: 0, dy: -60)
    }

    /// 工具栏拖动 offset 的屏内 clamp：组矩形（layout.row 估算矩形 + offset）整体保持在屏内，
    /// 左右 6pt、上下 4pt 边距；区间倒挂（屏极窄/矮容不下组）时取上界——尽量靠右/下。
    static func clampedToolbarOffset(_ offset: CGSize, row: CGRect, bounds: CGSize) -> CGSize {
        CGSize(width: min(max(offset.width, 6 - row.minX), bounds.width - 6 - row.maxX),
               height: min(max(offset.height, 4 - row.minY), bounds.height - 4 - row.maxY))
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

/// 选区右下角单行工具栏（整体液态玻璃胶囊 ~34pt + 收起式弹出面板）：
/// [选择|箭头|矩形|椭圆|画笔|模糊] ‖ [当前色][当前粗细]（按工具显隐）[圆角] ‖ [撤销]（空栈隐藏）‖ [保存][复制]。
/// 视觉重构：整行包进单一 glassEffect(in: Capsule())（左右留白 10 / 上下 5，高 24+10=34），
/// 钮全部无底色；色板/粗细/圆角面板仍为触发钮的独立玻璃胶囊 overlay（浮于钮正上方、间隙 4pt、
/// 可盖选区、不占布局）。互斥至多展开一个：色/粗细选中即收起，圆角拖动不收起（再点圆角钮收起）。
/// 拖动走玻璃块背景拖动层（拖非按钮的空白像素；按钮/滑块命中优先、不下落，Slider tracking 不被抢占）；
/// 色/宽钮按工具自动显隐：select 无绘制参数全隐，blur 无颜色语义（色钮隐、宽度钮=双滑块触发），
/// arrow/rect/ellipse/pen 全显。
/// arrow/rect/ellipse/pen/blur 的绘制手势由 SelectionView 经 activeTool.takesOverDrag 接入选区拖动。
private struct CaptureToolbar: View {
    @Binding var tool: AnnotationTool
    @Binding var color: RGBA
    @Binding var lineWidth: AnnotationWidth
    @Binding var cornerRadius: Double
    /// 模糊工具专属双滑块值（半径 4...20 / 笔宽 8...80），仅 blur 面板消费
    @Binding var blurRadius: Double
    @Binding var blurPenWidth: Double
    @Binding var showColorPalette: Bool
    @Binding var showWidthPicker: Bool
    @Binding var showRadiusSlider: Bool
    /// 工具栏手动拖动偏移（nil = 锚定选区右下；背景拖动层手势经此回写，渲染 offset 与 panelBand 消费）
    @Binding var toolbarOffset: CGSize?
    /// 工具栏拖动进行中（背景拖动层手势标记；外层 scaleEffect 视觉反馈消费）
    @Binding var toolbarDragging: Bool
    /// 拖动起始偏移基线（onChanged 首帧从 toolbarOffset 解包，后续帧累加 translation）
    @Binding var toolbarDragBase: CGSize
    /// 拖动 clamp 基准：toolbarRowLayout 的 row 估算矩形与屏幕 bounds（clampedToolbarOffset 消费）
    let clampRow: CGRect
    let screenBounds: CGSize
    /// 撤销可用（annotations 非空）：空栈时整钮不渲染（原 40% 置灰删除）
    let canUndo: Bool
    let onUndo: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void

    /// 面板锚定偏移（overlay alignment .bottom 上再 offset）：钮半高 12 ＋ 面板半高 12 ＋ 间隙 4
    /// → 面板底缘贴钮顶上方 4pt
    private let panelAnchorOffset: CGFloat = -(12 + 24 / 2 + 4)
    /// 模糊双滑块面板锚定偏移：面板高自适应 ~48（半高 24），同式保持 4pt 间隙
    private let blurPanelAnchorOffset: CGFloat = -(12 + 48 / 2 + 4)

    var body: some View {
        mainRow
    }

    // MARK: 主行

    private var mainRow: some View {
        // 背景拖动层结构：ZStack 底层接管空白像素的拖动，上层按钮内容正常命中。
        // SwiftUI 命中测试自上而下：按钮/滑块/分隔命中即不下落（Slider 的 tracking 不再被
        // 容器手势抢占——滑块拖不动的正确修法）；钮间隙与 padding 的空白像素落到
        // dragBackground，即「拖动非按钮的像素就支持拖动」
        ZStack {
            dragBackground
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
                // 按工具自动显隐：色/宽钮仅标注绘制工具（arrow/rect/ellipse/pen）显示；
                // select 无绘制参数（均隐藏）；blur 无颜色语义但宽度在双滑块面板——宽度钮保留为面板触发
                if tool != .select && tool != .blur {
                    separator
                    currentColorButton
                    currentWidthButton
                } else if tool == .blur {
                    separator
                    currentWidthButton
                }
                radiusButton
                // 撤销：空栈整钮不渲染（原 40% 置灰改为按需显隐）
                if canUndo {
                    separator
                    ToolbarIconButton(symbol: "arrow.uturn.backward", selected: false, accessibilityLabel: "撤销", action: onUndo)
                }
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
            .frame(height: 24)
        }
        // 整体玻璃块：单行内容包进一个胶囊（左右 10 / 上下 5 留白，高 24+10=34），
        // 替代原先每钮独立玻璃圆钮
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(in: Capsule())
    }

    /// 背景拖动层（ZStack 最底）：透明铺满玻璃块、contentShape 圈住全部像素，拖动非按钮的
    /// 空白像素（钮间隙、padding）即可挪动整块——上层按钮/滑块命中优先、不下落，容器手势
    /// 不再抢占 NSSlider tracking（滑块拖不动的回归修复）。
    /// onChanged 首帧锁定基线（toolbarOffset nil 视作 .zero）后累加 translation；onEnded 距零 <12pt
    /// 吸附归位，否则 clamp 屏内（左右 6pt / 上下 4pt）
    private var dragBackground: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("sel"))
                    .onChanged { value in
                        if !toolbarDragging {
                            toolbarDragging = true
                            toolbarDragBase = toolbarOffset ?? .zero
                        }
                        toolbarOffset = CGSize(width: toolbarDragBase.width + value.translation.width,
                                               height: toolbarDragBase.height + value.translation.height)
                    }
                    .onEnded { value in
                        toolbarDragging = false
                        let offset = CGSize(width: toolbarDragBase.width + value.translation.width,
                                            height: toolbarDragBase.height + value.translation.height)
                        // 吸附归位：拖回距默认锚定 < 12pt 视为放弃手动位置，回归锚定
                        if hypot(offset.width, offset.height) < 12 {
                            toolbarOffset = nil
                            return
                        }
                        toolbarOffset = SelectionView.clampedToolbarOffset(offset, row: clampRow, bounds: screenBounds)
                    }
            )
    }

    /// 当前色钮（24×24 命中区，内嵌 14pt 色圆点，无底色）：点击展开/收起色板面板（浮于钮正上方）
    private var currentColorButton: some View {
        Button {
            togglePanel { showColorPalette.toggle() }
        } label: {
            colorDot(color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showColorPalette {
                panelCapsule {
                    HStack(spacing: 6) {
                        ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { _, c in
                            colorSwatch(c) { showColorPalette = false }
                        }
                    }
                }
                .offset(y: panelAnchorOffset)
            }
        }
    }

    /// 当前粗细钮（24×24 命中区，内嵌 dotDiameter 实心圆点，无底色）：点击展开/收起粗细面板（浮于钮正上方）。
    /// 面板内容按工具分支：普通工具 = 三档圆点；blur 工具 = 半径/笔宽双滑块（两行，~48 高）
    private var currentWidthButton: some View {
        Button {
            togglePanel { showWidthPicker.toggle() }
        } label: {
            Circle()
                .fill(Color.primary)
                .frame(width: lineWidth.dotDiameter, height: lineWidth.dotDiameter)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showWidthPicker {
                if tool == .blur {
                    panelCapsuleAdaptive {
                        blurSliderPanel
                    }
                    .offset(y: blurPanelAnchorOffset)
                } else {
                    panelCapsule {
                        HStack(spacing: 6) {
                            ForEach(AnnotationWidth.allCases, id: \.pt) { w in
                                widthButton(w) { showWidthPicker = false }
                            }
                        }
                    }
                    .offset(y: panelAnchorOffset)
                }
            }
        }
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
    /// + 当前值 10pt monospacedDigit）：点击展开/收起圆角滑条面板（浮于钮正上方；滑条拖动不收起，再点钮收起）
    private var radiusButton: some View {
        Button {
            togglePanel { showRadiusSlider.toggle() }
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
        .overlay(alignment: .bottom) {
            if showRadiusSlider {
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
        }
    }

    // MARK: 弹出面板（互斥）

    /// 面板互斥开关：先执行目标开关取反，再把展开中的其他面板全部关掉
    private func togglePanel(_ target: () -> Void) {
        target()
        if showColorPalette { showWidthPicker = false; showRadiusSlider = false }
        if showWidthPicker { showColorPalette = false; showRadiusSlider = false }
        if showRadiusSlider { showColorPalette = false; showWidthPicker = false }
    }

    /// 面板容器：玻璃胶囊（高 24，水平内边距 10）
    private func panelCapsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .glassEffect(in: Capsule())
    }

    /// 面板容器（高度自适应变体）：玻璃胶囊（水平 10 / 垂直 6 内边距），blur 双滑块面板 ~48 高
    private func panelCapsuleAdaptive<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: Capsule())
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
