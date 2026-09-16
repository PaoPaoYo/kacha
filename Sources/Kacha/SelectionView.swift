import SwiftUI

/// 单屏框选视图：冻结帧 + 35% 黑遮罩挖洞 + 1pt 白边 + 液态玻璃尺寸胶囊。
/// 两段式交互：拖拽框选（或 idle 态点击窗口，蓝描边悬停高亮）→ 松开进入调整态
/// （角/边缩放、内部平移）→ 双击/回车/按钮确认，ESC 取消。
/// 调整态右下角两行工具栏组（V3：标注工具行 + 输出行）；标注工具激活时选区内拖动为绘制，
/// 实时预览与最终输出共用 AnnotationGeometry.path（同构）。
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
    /// 当前标注工具：select 不接管拖动；arrow/rect/ellipse/pen 接管选区内拖动为绘制
    @State private var activeTool: AnnotationTool = .select
    /// 当前标注颜色（色板 8 色之一）
    @State private var annotationColor: RGBA = .red
    /// 当前标注粗细（三档）
    @State private var annotationWidth: AnnotationWidth = .medium
    /// 进行中的一笔标注（绘制手势期间持有；松开时 isValid 才入栈，随后清空）
    @State private var drawingAnnotation: Annotation?

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
                    // （共用 AnnotationGeometry.path；线帽/线接 round 一致，arrow = 整体 stroke + eoFill 头）。
                    // 渲染在白边之后、move/绘制手势层之前；仅预览层不做命中（allowsHitTesting false）。
                    // 白色标注先 stroke 1pt separator 外扩描边再上色，浅色截图中仍可见（规格约束，仅预览层）。
                    Canvas { context, _ in
                        for a in annotations + [drawingAnnotation].compactMap({ $0 }) {
                            var ctx = context
                            // path 产出选区局部坐标（原点 = 视图原点），Canvas 原点 = sel.minX：平移对齐
                            ctx.translateBy(x: -sel.minX, y: -sel.minY)
                            let path = Path(AnnotationGeometry.path(for: a.kind, in: sel, lineWidth: a.lineWidth))
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
                        // 选区内：拖动整体移动 + 双击确认
                        Color.clear
                            .frame(width: sel.width, height: sel.height)
                            .position(x: sel.midX, y: sel.midY)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("sel"))
                                    .onChanged { value in
                                        if adjustKind == nil {
                                            beginAdjust(.move, at: value.startLocation)
                                        }
                                        updateAdjust(to: value.location, in: geo.size)
                                    }
                                    .onEnded { _ in adjustKind = nil }
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
                            Color.clear
                                .frame(width: sel.width, height: sel.height)
                                .position(x: sel.midX, y: sel.midY)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0, coordinateSpace: .named("sel"))
                                        .onChanged { value in
                                            updateDrawing(to: value.location, start: value.startLocation, in: sel)
                                        }
                                        .onEnded { _ in commitDrawing(in: sel) }
                                )
                        }

                        // 选区右下角两行工具栏组（VStack(alignment: .trailing, spacing: 8)，组高 56 = 24 + 8 + 24）：
                        // 上行 = 标注工具行（工具 / 色板 / 粗细 / 撤销），下行 = 输出行（圆角滑条 + 保存 + 复制）。
                        // 整组布局（右缘锚点 / y / clamp / 光标命中区）见 toolbarRowLayout 单一公式源；
                        // 行内控件均为点击（无拖动手势），调整态父层手势已禁用，不会把操作漏进选区拖动
                        let group = Self.toolbarRowLayout(sel: sel, bounds: geo.size)
                        VStack(alignment: .trailing, spacing: 8) {
                            AnnotationToolbar(tool: $activeTool,
                                              color: $annotationColor,
                                              lineWidth: $annotationWidth,
                                              canUndo: !annotations.isEmpty,
                                              onUndo: undoLastAnnotation)
                            HStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    Text("圆角").font(.system(size: 12, weight: .medium))
                                    Slider(value: $cornerRadius, in: 0...40, step: 1)
                                        .frame(width: 160)
                                    Text("\(Int(cornerRadius))")
                                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                                        .frame(width: 24)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .glassEffect(in: Capsule())
                                ToolbarButton(label: "保存", action: save)
                                ToolbarButton(label: "复制", action: confirm)
                            }
                        }
                        // 组右缘先 pin 到屏右、再 offset 到锚点：右对齐不依赖行宽（行宽随内容自适应）
                        .frame(width: geo.size.width, height: geo.size.height,
                               alignment: Alignment(horizontal: .trailing, vertical: .center))
                        .offset(x: group.right - geo.size.width, y: group.centerY - geo.size.height / 2)
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
                // 工具栏组（两行）命中区与渲染 offset 用同一公式（toolbarRowLayout）；非调整态置空
                cursorState.toolbarZone = phase == .adjusting ? Self.toolbarRowLayout(sel: new, bounds: geo.size).zone : .zero
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

    /// 撤销最后一笔标注（工具行撤销钮）：空栈无操作（钮同时 40% 透明禁用）
    private func undoLastAnnotation() {
        if !annotations.isEmpty {
            annotations.removeLast()
        }
    }

    // MARK: 标注绘制

    /// 绘制中：把选区局部 point 归一化后写入 drawingAnnotation（clamp 由 normalizedPoint 承担）。
    /// arrow = 起点/终点两点；rect/ellipse = 两点 min/max 的归一化矩形；pen = 采样去重后追加。
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
        }
    }

    /// 松开：isValid（太小的标注丢弃）才入撤销栈，随后清进行中标注（无论是否入栈）
    private func commitDrawing(in sel: CGRect) {
        if let drawing = drawingAnnotation, AnnotationGeometry.isValid(drawing.kind, selectionSize: sel.size) {
            annotations.append(drawing)
        }
        drawingAnnotation = nil
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

    /// 整边命中判定（边线 ±8，端点缩 8pt 与 EdgeHandle 命中条一致）：
    /// true = 上下边（resizeUpDown）/ false = 左右边（resizeLeftRight）/ nil = 未命中
    private static func edgeAxis(at p: CGPoint, in sel: CGRect) -> Bool? {
        let inXSpan = p.x >= sel.minX + 8 && p.x <= sel.maxX - 8
        let inYSpan = p.y >= sel.minY + 8 && p.y <= sel.maxY - 8
        if inXSpan, abs(p.y - sel.minY) <= 8 || abs(p.y - sel.maxY) <= 8 { return true }
        if inYSpan, abs(p.x - sel.minX) <= 8 || abs(p.x - sel.maxX) <= 8 { return false }
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

    /// 两行工具栏组（标注工具行 + 输出行，VStack spacing 8，组高 56 = 24 + 8 + 24）布局单一公式源
    /// （渲染 offset / 光标命中区共用）：组右缘锚定选区白边右缘（sel.maxX，与边框对齐）；
    /// 左缘出屏时整组右移（rowWidth 取较宽的标注行估算，保证命中区覆盖两行，右缘允许越过锚点）；
    /// y 用组整体判定贴底/收内侧（belowFits 用组总高）：选区下方放得下整组（组上缘贴选区下 8pt、
    /// 组下缘再留 8pt 屏底余量）时整组在选区外侧下方，否则整组收进选区内侧（组下缘离选区下缘 8pt，
    /// 此时输出行落位与 V2 单行完全一致：中心 sel.maxY - 20）。
    static func toolbarRowLayout(sel: CGRect, bounds: CGSize) -> (right: CGFloat, centerY: CGFloat, zone: CGRect) {
        // 标注行估算宽 ≈451（工具 5×24 + 4×6 ＋ 分隔 1 ＋ 色板 8×14 + 7×6 ＋ 分隔 1 ＋ 粗细 3×18 + 2×6
        // ＋ 分隔 1 ＋ 撤销 24 ＋ 6×10 段间距），命中区左缘含约 9pt 容差 → 460，仅用于光标命中区与左缘 clamp；
        // 实际渲染用右缘 pin + offset，不依赖该估算。
        let rowWidth: CGFloat = 460
        let groupHeight: CGFloat = 56   // 24（工具行）+ 8（行距）+ 24（输出行）
        var right = sel.maxX
        if right - rowWidth < 6 {
            right = 6 + rowWidth
        }
        // belowFits 用组总高：组上缘贴选区下 8pt、组下缘留 8pt 屏底余量
        let belowFits = sel.maxY + 8 + groupHeight + 8 <= bounds.height
        let centerY = belowFits ? sel.maxY + 8 + groupHeight / 2 : sel.maxY - 8 - groupHeight / 2
        // 光标命中区 = 组整体矩形 + 上下各 6pt 容差（与 V2 单行 ±6 一致）
        let zone = CGRect(x: right - rowWidth, y: centerY - groupHeight / 2 - 6,
                          width: rowWidth, height: groupHeight + 12)
        return (right, centerY, zone)
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
        // b. 命中手柄（几何式）：先四角 ±8 → 对角缩放光标，再边线 ±8 → 上下/左右缩放光标
        if let position = cornerPosition(at: p, in: state.selection) {
            NSCursor.frameResize(position: position, directions: .all).set()
            return
        }
        if let vertical = edgeAxis(at: p, in: state.selection) {
            (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
            return
        }
        // b'. 悬停按钮行（圆角滑条 / 保存 / 复制）→ pointingHand
        if state.toolbarZone.contains(p) {
            NSCursor.pointingHand.set()
            return
        }
        // c. 选区内 → 拖动中合掌 / 悬停开掌
        if state.selection.contains(p) {
            if event.type == .leftMouseDragged {
                NSCursor.closedHand.set()
            } else {
                NSCursor.openHand.set()
            }
            return
        }
        // d. 其他 → 十字
        NSCursor.crosshair.set()
    }
}

/// 光标决策所用的可变快照：@State 持同一引用实例，monitor 闭包每次读到最新值
private final class CursorState {
    var hasSelection = false
    var selection: CGRect = .zero
    var viewHeight: CGFloat = 0
    /// 按钮行（圆角滑条 + 保存 + 复制）命中区，toolbarRowLayout 公式回填；悬停 → pointer 光标
    var toolbarZone: CGRect = .zero
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

/// 液态玻璃胶囊文字钮（44×24）：保存 / 复制共用规格
private struct ToolbarButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: Capsule())
    }
}

/// 液态玻璃圆形图标钮（24×24）：标注工具 / 撤销共用规格；selected 时 accent 描边高亮
private struct ToolbarIconButton: View {
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .overlay {
            if selected {
                Circle().strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
            }
        }
    }
}

/// 标注工具行（24pt）：5 工具玻璃圆钮 ─ 分隔 ─ 8 色板圆点 ─ 分隔 ─ 3 粗细圆点 ─ 分隔 ─ 撤销钮。
/// 仅状态与 UI（选中态 accent 高亮、撤销弹出 annotations 栈）；
/// arrow/rect/ellipse/pen 的绘制手势由 SelectionView 经 activeTool.takesOverDrag 接入选区拖动。
private struct AnnotationToolbar: View {
    @Binding var tool: AnnotationTool
    @Binding var color: RGBA
    @Binding var lineWidth: AnnotationWidth
    /// 撤销可用（annotations 非空）：不可用时撤销钮 40% 透明并禁用
    let canUndo: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ToolbarIconButton(symbol: "move", selected: tool == .select) { tool = .select }
                ToolbarIconButton(symbol: "arrow.up.right", selected: tool == .arrow) { tool = .arrow }
                ToolbarIconButton(symbol: "rectangle", selected: tool == .rect) { tool = .rect }
                ToolbarIconButton(symbol: "circle", selected: tool == .ellipse) { tool = .ellipse }
                ToolbarIconButton(symbol: "scribble", selected: tool == .pen) { tool = .pen }
            }
            separator
            HStack(spacing: 6) {
                ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { _, swatch in
                    colorSwatch(swatch)
                }
            }
            separator
            HStack(spacing: 6) {
                ForEach(AnnotationWidth.allCases, id: \.pt) { w in
                    widthButton(w)
                }
            }
            separator
            ToolbarIconButton(symbol: "arrow.uturn.backward", selected: false, action: onUndo)
                .opacity(canUndo ? 1 : 0.4)
                .disabled(!canUndo)
        }
        .frame(height: 24)
    }

    /// 分隔线 1×16 半透明
    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.25))
            .frame(width: 1, height: 16)
    }

    /// 色板圆点（14pt）：白/黑加 1pt separator 描边保可见；当前色外套 2pt accent ring（内缘贴圆点边缘）
    private func colorSwatch(_ c: RGBA) -> some View {
        Button {
            color = c
        } label: {
            Circle()
                .fill(Color(red: c.r, green: c.g, blue: c.b, opacity: c.a))
                .frame(width: 14, height: 14)
                .overlay {
                    if c == .black || c == .white {
                        Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                }
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

    /// 粗细钮（垂直居中实心圆点，直径 = dotDiameter）：当前档外套 2pt accent ring
    private func widthButton(_ w: AnnotationWidth) -> some View {
        Button {
            lineWidth = w
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

/// 8 个缩放手柄（四角 + 四边中点），白点 8pt，命中区 16pt
private struct HandleLayer: View {
    let selection: CGRect

    var body: some View {
        let edges: [(SelectionHandleKind, CGRect)] = [
            // 命中条厚 16pt（边线 ±8），端点各缩 8pt 让角区独占（角手柄后渲染、命中优先）
            (.top, CGRect(x: selection.minX + 8, y: selection.minY - 8, width: selection.width - 16, height: 16)),
            (.bottom, CGRect(x: selection.minX + 8, y: selection.maxY - 8, width: selection.width - 16, height: 16)),
            (.left, CGRect(x: selection.minX - 8, y: selection.minY + 8, width: 16, height: selection.height - 16)),
            (.right, CGRect(x: selection.maxX - 8, y: selection.minY + 8, width: 16, height: selection.height - 16)),
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
