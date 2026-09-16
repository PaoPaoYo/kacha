import SwiftUI

/// 单屏框选视图：冻结帧 + 35% 黑遮罩挖洞 + 1pt 白边 + 液态玻璃尺寸胶囊。
/// 两段式交互：拖拽框选（或 idle 态点击窗口，蓝描边悬停高亮）→ 松开进入调整态
/// （角/边缩放、内部平移）→ 双击/回车/按钮确认，ESC 取消。
struct SelectionView: View {
    let frame: ScreenFrame
    /// 本屏窗口矩形（局部坐标、front-to-back）；悬停高亮与点击选中用
    let windows: [CGRect]
    /// 确认（复制）时回调：屏幕局部 point 选区（有效性已过滤）+ 圆角半径（point，0 = 直角）
    let onConfirm: (CGRect, CGFloat) -> Void
    /// 保存时回调：屏幕局部 point 选区（有效性已过滤）+ 圆角半径（point，0 = 直角）
    let onSave: (CGRect, CGFloat) -> Void
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

    var body: some View {
        GeometryReader { geo in
            let sel = activeSelection

            ZStack(alignment: .topLeading) {
                Image(nsImage: NSImage(cgImage: frame.image, size: frame.screenPointSize))
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                let maskSelection = sel ?? ((phase == .idle) ? hoveredWindow : nil)
                // 挖洞圆角与白边一致（选区洞）；idle 悬停窗口洞保持直角
                DimmingMask(selection: maskSelection, cornerRadius: sel != nil ? cornerRadius : 0)
                    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                if phase == .idle, let hw = hoveredWindow {
                    Rectangle()
                        .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                        .frame(width: hw.width, height: hw.height)
                        .position(x: hw.midX, y: hw.midY)
                        .allowsHitTesting(false)
                }

                if let sel, SelectionGeometry.isValid(sel) {
                    // 白边随圆角实时变化（dragging 态 cornerRadius 恒 0，即直角，共用一处）
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white, lineWidth: 1)
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

                        // 选区右下角按钮行：圆角滑条（实时更新白边预览与输出半径）+ 保存 + 复制，
                        // 整行布局（右缘锚点 / y / clamp / 光标命中区）见 toolbarRowLayout 单一公式源；
                        // 行内滑条命中区在选区外亦不与父层手势冲突（调整态父层手势已禁用）
                        let row = Self.toolbarRowLayout(sel: sel, bounds: geo.size)
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
                        // 右缘先 pin 到屏右、再 offset 到锚点：右对齐不依赖行宽（行宽随内容自适应）
                        .frame(width: geo.size.width, height: geo.size.height,
                               alignment: Alignment(horizontal: .trailing, vertical: .center))
                        .offset(x: row.right - geo.size.width, y: row.centerY - geo.size.height / 2)
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
                // 按钮行命中区与渲染 offset 用同一公式（toolbarRowLayout）；非调整态置空
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
        onConfirm(selection, CGFloat(cornerRadius))
    }

    private func save() {
        guard phase == .adjusting, dragStart == nil, SelectionGeometry.isValid(selection) else { return }
        onSave(selection, CGFloat(cornerRadius))
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

    /// 按钮行锚点（单一公式源，toolbarRowLayout 消费）：复制钮中心 x/y 决定整行右缘锚点与 y；
    /// 右缘 clamp 到屏内、下方空间不足时 y 收进选区内侧
    static func buttonCenters(sel: CGRect, bounds: CGSize) -> (save: CGPoint, copy: CGPoint) {
        let spacing: CGFloat = 52
        let copyX = min(sel.maxX - 16, bounds.width - 28)
        let saveX = max(28, copyX - spacing)
        let belowFits = sel.maxY + 20 + 16 <= bounds.height
        let y = belowFits ? sel.maxY + 20 : sel.maxY - 20
        return (CGPoint(x: saveX, y: y), CGPoint(x: copyX, y: y))
    }

    /// 按钮行（圆角滑条胶囊 + 保存 + 复制）布局单一公式源（渲染 offset / 光标命中区共用）：
    /// 右缘锚定原复制钮右缘（copyX + 22，copyX 沿用 buttonCenters clamp——贴右缘选区时已收进屏内）；
    /// 左缘出屏时整行右移（滑条优先保证可见，右缘允许越过锚点）；y 沿用按钮 y
    /// （belowFits ? sel.maxY + 20 : sel.maxY - 20，下方放不下时整行随按钮一起收进选区内侧）。
    /// 行宽 376 为估算常量（胶囊 ≈256 + 12 + 保存 44 + 12 + 复制 44，命中区左缘含约 8pt 容差），仅用于光标命中区；
    /// 实际渲染用右缘 pin + offset，不依赖该估算。
    static func toolbarRowLayout(sel: CGRect, bounds: CGSize) -> (right: CGFloat, centerY: CGFloat, zone: CGRect) {
        let rowWidth: CGFloat = 376
        let centers = buttonCenters(sel: sel, bounds: bounds)
        var right = centers.copy.x + 22
        if right - rowWidth < 6 {
            right = 6 + rowWidth
        }
        return (right, centers.copy.y, CGRect(x: right - rowWidth, y: centers.copy.y - 18, width: rowWidth, height: 36))
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
