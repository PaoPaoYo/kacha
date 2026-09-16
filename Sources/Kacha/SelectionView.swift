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
    /// 当前标注粗细（三档）
    @State private var annotationWidth: AnnotationWidth = .medium
    /// 进行中的一笔标注（绘制手势期间持有；松开时 isValid 才入栈，随后清空）
    @State private var drawingAnnotation: Annotation?
    /// 模糊预览图缓存（单条目，见 blurPreviewImage）
    @State private var blurPreview = BlurPreviewCache()
    /// 收起式弹出面板开关（互斥：同一时间至多展开一个，打开一个即关其他；面板为触发钮 overlay，不占布局）
    @State private var showColorPalette = false
    @State private var showWidthPicker = false
    @State private var showRadiusSlider = false

    var body: some View {
        GeometryReader { geo in
            let sel = activeSelection

            ZStack(alignment: .topLeading) {
                Image(nsImage: NSImage(cgImage: frame.image, size: frame.screenPointSize))
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                let maskSelection = validDragRect ?? ((phase != .adjusting) ? hoveredWindow : nil)
                // 挖洞圆角跟随 cornerRadius（拖拽/调整态含 @AppStorage 记忆值），与白边及最终输出一致（所见即所得）；悬停窗口洞保持直角
                DimmingMask(selection: maskSelection, cornerRadius: validDragRect != nil ? cornerRadius : 0)
                    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                if let hw = hoveredWindow, phase != .adjusting, validDragRect == nil {
                    Rectangle()
                        .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                        .frame(width: hw.width, height: hw.height)
                        .position(x: hw.midX, y: hw.midY)
                        .allowsHitTesting(false)
                }

                if let sel, SelectionGeometry.isValid(sel) {
                    // 白边随圆角实时变化：拖拽/调整态跟随 cornerRadius（含 @AppStorage 记忆值），与挖洞及最终输出一致（所见即所得，共用一处）
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white, lineWidth: 1)
                        .frame(width: sel.width, height: sel.height)
                        .position(x: sel.midX, y: sel.midY)
                        .allowsHitTesting(false)

                    // 标注实时渲染（含进行中的一笔）：屏幕预览与 AnnotationRenderer 像素合成同构
                    // （共用 AnnotationGeometry.path；线帽/线接 round 一致，arrow = 整体 stroke + eoFill 头，
                    // blur = clip 路径展宽 + 底图选区裁剪高斯模糊）。
                    // 渲染在白边之后、move/绘制手势层之前；仅预览层不做命中（allowsHitTesting false）。
                    // 白色标注先 stroke 1pt separator 外扩描边再上色，浅色截图中仍可见（规格约束，仅预览层）。
                    Canvas { context, _ in
                        for a in annotations + [drawingAnnotation].compactMap({ $0 }) {
                            var ctx = context
                            // path 产出选区局部坐标（原点 = 视图原点），Canvas 原点 = sel.minX：平移对齐
                            ctx.translateBy(x: -sel.minX, y: -sel.minY)
                            let path = Path(AnnotationGeometry.path(for: a.kind, in: sel, lineWidth: a.lineWidth))
                            if case .blur = a.kind {
                                // 高斯模糊：涂抹路径展宽为 clip，冻结帧按选区裁剪、CIGaussianBlur（15pt × 像素比）
                                // 后 1:1 绘制（与 AnnotationRenderer 输出同构；颜色不参与渲染，坐标为视图坐标 → 画到 sel）
                                if let blurred = blurPreviewImage(in: sel) {
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
                    .frame(width: sel.width, height: sel.height)
                    .position(x: sel.midX, y: sel.midY)
                    .allowsHitTesting(false)

                    SizeBadge(rect: sel)
                        .position(x: min(sel.midX, geo.size.width - 60),
                                  y: max(sel.minY - 28, 26))
                        .allowsHitTesting(false)

                    if phase == .adjusting {
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

                        // 选区右下角单行工具栏（紧贴选区）：
                        // [选择|箭头|矩形|椭圆|画笔|模糊] ‖ [当前色][当前粗细][圆角] ‖ [撤销] ‖ [保存][复制]；
                        // 色板/粗细/圆角面板为触发钮 overlay（浮于钮正上方、可盖选区、不占布局）。
                        // 整组布局（右缘锚点 / 底缘 / clamp / 面板光标带基底）见 toolbarRowLayout 单一公式源；
                        // 行内控件均为点击（无拖动手势），调整态父层手势已禁用，不会把操作漏进选区拖动
                        let group = Self.toolbarRowLayout(sel: sel, bounds: geo.size)
                        CaptureToolbar(tool: $activeTool,
                                       color: $annotationColor,
                                       lineWidth: $annotationWidth,
                                       cornerRadius: $cornerRadius,
                                       showColorPalette: $showColorPalette,
                                       showWidthPicker: $showWidthPicker,
                                       showRadiusSlider: $showRadiusSlider,
                                       canUndo: !annotations.isEmpty,
                                       onUndo: undoLastAnnotation,
                                       onSave: save,
                                       onCopy: confirm)
                        // 组右缘/底缘先 pin 到屏右屏底、再 offset 到锚点：右对齐不依赖行宽（行宽随内容自适应）；
                        // 底缘锚定主行——面板展开向上生长，不推挤主行（主行不跳动）
                        .frame(width: geo.size.width, height: geo.size.height,
                               alignment: Alignment(horizontal: .trailing, vertical: .bottom))
                        .offset(x: group.right - geo.size.width, y: group.bottom - geo.size.height)
                    }
                }
            }
            .coordinateSpace(name: "sel")
            .onContinuousHover(coordinateSpace: .named("sel")) { hoverPhase in
                // 仅 idle 更新：按下进入 .dragging 后保持旧值，松手时窗口分支据此判定点击目标；
                // ended（移出视图）一律清空
                switch hoverPhase {
                case .active(let point):
                    if phase == .idle {
                        hoveredWindow = WindowGeometry.hitTest(point: point, windows: windows)
                    }
                case .ended:
                    hoveredWindow = nil
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // 空白处按下拖拽：画新选区（minimumDistance 0：原地点击也走 onEnded）
                DragGesture(minimumDistance: 0, coordinateSpace: .named("sel"))
                    .onChanged { value in
                        // 调整态：父层（空白重画）手势完全禁用——选区内/外起点都忽略，重画只能从 idle/dragging 起步；
                        // 子层（move/手柄/按钮）手势独立跟踪不受影响，dragStart 也不会被父层污染
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
            )
            .focusable()
            .onChange(of: selection) { _, new in
                cursorState.selection = new
                cursorState.hasSelection = SelectionGeometry.isValid(new)
                // 面板展开光标带与渲染 offset 用同一公式（toolbarRowLayout 行矩形）；
                // 选区源同步（面板全收起时为 .zero）
                cursorState.panelBand = Self.panelBand(
                    sel: new, bounds: geo.size,
                    anyPanelOpen: showColorPalette || showWidthPicker || showRadiusSlider)
            }
            .onChange(of: showColorPalette || showWidthPicker || showRadiusSlider) { _, open in
                // 面板展开/收起源同步：任一面板开 → 行矩形向上扩 60pt 光标带，全收起 → .zero
                cursorState.panelBand = Self.panelBand(sel: selection, bounds: geo.size, anyPanelOpen: open)
            }
            .onChange(of: activeTool) { _, new in
                // 光标快照同步（引用实例，monitor 每次读到最新值）：绘制工具激活 → 选区内统一十字
                cursorState.tool = new
            }
            .onChange(of: geo.size.height) { _, new in
                cursorState.viewHeight = new
            }
            .onKeyPress(.return) {
                confirm()
                return .handled
            }
            .onExitCommand(perform: onCancel)
            .onAppear {
                // 光标快照初始化 + 安装单一决策点 monitor（替代 cursorRect / onHover 方案）
                cursorState.viewHeight = geo.size.height
                cursorState.selection = selection
                cursorState.hasSelection = SelectionGeometry.isValid(selection)
                cursorState.tool = activeTool
                cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
                    Self.applyCursor(event: event, state: cursorState, screen: frame.screen)
                    return event
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kachaOverlayDismissed)) { _ in
                // 覆盖窗被 dismissAll 关闭时立即清 monitor（防泄漏）；onDisappear 仅作兜底
                removeCursorMonitor()
            }
            .onDisappear {
                removeCursorMonitor()
            }
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

    /// 撤销最后一笔标注（工具栏撤销钮）：空栈无操作（钮同时 40% 透明禁用）
    private func undoLastAnnotation() {
        if !annotations.isEmpty {
            annotations.removeLast()
        }
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
            // 同 pen：采样归一化追加（去重 1pt）；颜色照存但不参与模糊渲染
            let p = AnnotationGeometry.normalizedPoint(point, in: sel)
            if drawingAnnotation == nil {
                drawingAnnotation = Annotation(kind: .blur(points: [AnnotationGeometry.normalizedPoint(start, in: sel)]),
                                               color: color, lineWidth: width)
            } else if var drawing = drawingAnnotation, case let .blur(points) = drawing.kind {
                let lastLocal = points.last.map { AnnotationGeometry.localPoint($0, in: sel) }
                if AnnotationGeometry.shouldAppendPenPoint(point, after: lastLocal) {
                    drawing.kind = .blur(points: points + [p])
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

    /// 模糊预览图（带单条目缓存）：依赖只有冻结帧与选区，涂抹拖动期间选区不变，同选区复用
    /// （引用类型缓存：@State 持有不触发视图刷新，Canvas 绘制期只读）
    private func blurPreviewImage(in sel: CGRect) -> CGImage? {
        if blurPreview.sel == sel, let cached = blurPreview.image { return cached }
        let image = Self.makeBlurPreview(base: frame.image, pointSize: frame.screenPointSize, sel: sel)
        blurPreview.sel = sel
        blurPreview.image = image
        return image
    }

    /// 预览与 AnnotationRenderer 输出同构：冻结帧按选区像素裁剪（CGImage 图像坐标，左上原点）→
    /// CIGaussianBlur（半径 15pt × 像素/点），输出保持裁剪原分辨率（1:1 绘制无插值问题）。
    /// nil = 裁剪/模糊失败（该笔预览跳过，输出层 AnnotationRenderer 仍正常）
    private static func makeBlurPreview(base: CGImage, pointSize: CGSize, sel: CGRect) -> CGImage? {
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
        filter.setValue(15.0 * pixelScale, forKey: kCIInputRadiusKey)
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
    /// 时组底缘 sel.maxY + 28（主行中心 sel.maxY + 16），否则收进选区内侧组底缘 sel.maxY - 4
    /// （主行中心 sel.maxY - 16，上下对称留 4pt）。
    static func toolbarRowLayout(sel: CGRect, bounds: CGSize) -> (right: CGFloat, bottom: CGFloat, row: CGRect) {
        // 主行实际宽 ≈417（工具 6×24 + 5×6 ＋ 分隔 1 ＋ 色钮 24 ＋ 粗细钮 24 ＋ 圆角钮 48 ＋ 分隔 1
        // ＋ 撤销 24 ＋ 分隔 1 ＋ 保存钮 24 ＋ 复制钮 24 ＋ 9×8 段间距），左缘含约 9pt 容差 → 426，
        // 仅用于面板光标带基底与左缘 clamp；实际渲染用右缘 pin + offset，不依赖该估算。
        let rowWidth: CGFloat = 426
        let rowHeight: CGFloat = 24
        var right = sel.maxX
        if right - rowWidth < 6 {
            right = 6 + rowWidth
        }
        // 紧贴选区（组顶 sel.maxY + 4）：下方需组顶间距 4 + 主行 24 + 屏底余量 8
        let belowFits = sel.maxY + 4 + rowHeight + 8 <= bounds.height
        let bottom = belowFits ? sel.maxY + 4 + rowHeight : sel.maxY - 4
        // 主行矩形（面板展开期间光标带的基底，见 panelBand）
        let row = CGRect(x: right - rowWidth, y: bottom - rowHeight,
                         width: rowWidth, height: rowHeight)
        return (right, bottom, row)
    }

    /// 面板展开期间的光标带：主行矩形向上扩 60pt（面板 overlay 向上生长、几何上常盖住选区，
    /// 带内一律箭头，不透出选区光标）。无有效选区或面板全收起时为 .zero（不拦光标）。
    static func panelBand(sel: CGRect?, bounds: CGSize, anyPanelOpen: Bool) -> CGRect {
        guard anyPanelOpen, let sel, SelectionGeometry.isValid(sel) else { return .zero }
        return toolbarRowLayout(sel: sel, bounds: bounds).row.insetBy(dx: 0, dy: -60)
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
        // c. 选区内 → 绘制工具十字；选择工具拖动中合掌 / 悬停开掌
        if state.selection.contains(p) {
            if state.tool.takesOverDrag {
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
}

/// 模糊预览图的单条目缓存：引用类型，@State 持有不触发视图刷新
///（涂抹拖动期间选区不变，Canvas 每帧重绘直接命中缓存，避免逐帧重复 CI 模糊）
private final class BlurPreviewCache {
    var sel: CGRect = .zero
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

/// 液态玻璃圆形图标钮（24×24）：标注工具 / 撤销 / 保存 / 复制共用规格；
/// selected 时 accent 描边高亮（仅选择态工具钮用，动作钮恒 false）；
/// tint 非 nil 时玻璃叠加色染色、图标转白，形成实心主按钮（primary action）观感
private struct ToolbarIconButton: View {
    let symbol: String
    let selected: Bool
    /// 无障碍标签（图标钮可读性，全部钮显式传入中文名）
    let accessibilityLabel: String
    /// 玻璃染色（如复制钮 accent 主按钮观感）；nil = regular 玻璃 + primary 前景
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint != nil ? Color.white : .primary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: Circle())
        .accessibilityLabel(accessibilityLabel)
        .overlay {
            if selected {
                Circle().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
            }
        }
    }
}

/// 选区右下角单行工具栏（24pt 主行 + 收起式弹出面板）：
/// [选择|箭头|矩形|椭圆|画笔|模糊] ‖ [当前色][当前粗细][圆角] ‖ [撤销] ‖ [保存][复制]。
/// 色板/粗细/圆角面板为触发钮的 overlay：浮于钮正上方（间隙 4pt）、可盖选区、不占布局（组高恒 24）。
/// 互斥至多展开一个：色/粗细选中即收起，圆角拖动不收起（再点圆角钮收起）。
/// arrow/rect/ellipse/pen/blur 的绘制手势由 SelectionView 经 activeTool.takesOverDrag 接入选区拖动。
private struct CaptureToolbar: View {
    @Binding var tool: AnnotationTool
    @Binding var color: RGBA
    @Binding var lineWidth: AnnotationWidth
    @Binding var cornerRadius: Double
    @Binding var showColorPalette: Bool
    @Binding var showWidthPicker: Bool
    @Binding var showRadiusSlider: Bool
    /// 撤销可用（annotations 非空）：不可用时撤销钮 40% 透明并禁用
    let canUndo: Bool
    let onUndo: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void

    /// 面板锚定偏移（overlay alignment .bottom 上再 offset）：钮半高 12 ＋ 面板半高 12 ＋ 间隙 4
    /// → 面板底缘贴钮顶上方 4pt
    private let panelAnchorOffset: CGFloat = -(12 + 24 / 2 + 4)

    var body: some View {
        mainRow
    }

    // MARK: 主行

    private var mainRow: some View {
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
            separator
            currentColorButton
            currentWidthButton
            radiusButton
            separator
            ToolbarIconButton(symbol: "arrow.uturn.backward", selected: false, accessibilityLabel: "撤销", action: onUndo)
                .opacity(canUndo ? 1 : 0.4)
                .disabled(!canUndo)
            separator
            // 动作钮：与其他工具钮统一 24×24 玻璃圆钮规格（无选中态），accessibilityLabel 保可读性；
            // 复制 = 主操作：accent tint 玻璃 + 白色图标（实心主按钮观感），保存保持 regular
            ToolbarIconButton(symbol: "square.and.arrow.down",
                              selected: false,
                              accessibilityLabel: "保存",
                              action: onSave)
            ToolbarIconButton(symbol: "doc.on.doc",
                              selected: false,
                              accessibilityLabel: "复制",
                              tint: Color(nsColor: .controlAccentColor),
                              action: onCopy)
        }
        .frame(height: 24)
    }

    /// 当前色钮（24×24 玻璃圆钮内嵌 14pt 色圆点）：点击展开/收起色板面板（浮于钮正上方）
    private var currentColorButton: some View {
        Button {
            togglePanel { showColorPalette.toggle() }
        } label: {
            colorDot(color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
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

    /// 当前粗细钮（24×24 玻璃圆钮内嵌 dotDiameter 实心圆点）：点击展开/收起粗细面板（浮于钮正上方）
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
        .glassEffect(in: Circle())
        .overlay(alignment: .bottom) {
            if showWidthPicker {
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

    /// 圆角钮（玻璃胶囊：rectangle.roundedtop 圆角矩形符号（比 ruler 更直观，probe 实证存在）
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
        .glassEffect(in: Capsule())
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
