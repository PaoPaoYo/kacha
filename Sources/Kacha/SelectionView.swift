import SwiftUI

/// 单屏框选视图：冻结帧 + 35% 黑遮罩挖洞 + 1pt 白边 + 液态玻璃尺寸胶囊。
/// 两段式交互：拖拽框选 → 松开进入调整态（手柄缩放 / 内部平移 / 外部重选）
/// → 双击或回车确认，ESC 取消。
struct SelectionView: View {
    let frame: ScreenFrame
    /// 确认（复制）时回调：屏幕局部 point 选区（有效性已过滤）
    let onConfirm: (CGRect) -> Void
    /// 保存时回调：屏幕局部 point 选区（有效性已过滤）
    let onSave: (CGRect) -> Void
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

    var body: some View {
        GeometryReader { geo in
            let sel = activeSelection

            ZStack(alignment: .topLeading) {
                Image(nsImage: NSImage(cgImage: frame.image, size: frame.screenPointSize))
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                DimmingMask(selection: sel)
                    .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                if let sel, SelectionGeometry.isValid(sel) {
                    Rectangle()
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

                        // 右下角按钮组（液态玻璃胶囊文字钮）：保存（复制左侧 12pt）+ 复制；位置 clamp——下方空间不足时收进选区内侧
                        let centers = Self.buttonCenters(sel: sel, bounds: geo.size)
                        ToolbarButton(label: "保存", action: save)
                            .position(x: centers.save.x, y: centers.save.y)
                        ToolbarButton(label: "复制", action: confirm)
                            .position(x: centers.copy.x, y: centers.copy.y)
                    }
                }
            }
            .coordinateSpace(name: "sel")
            .contentShape(Rectangle())
            .gesture(
                // 空白处按下拖拽：画新选区（minimumDistance 0：原地点击也走 onEnded）
                DragGesture(minimumDistance: 0, coordinateSpace: .named("sel"))
                    .onChanged { value in
                        // 调整态下，选区内（含手柄命中区外扩 10pt）或任一按钮上起点的触摸归子层（move/手柄/两按钮），
                        // 父层忽略，避免 minDist-0 的父层手势与子层同时跟踪污染 dragStart/dragCurrent
                        //（按钮若被父层污染，dragStart 未清时会卡 confirm()/save() 的 dragStart == nil 守卫）
                        let inChildZone: Bool
                        if phase == .adjusting {
                            inChildZone = selection.insetBy(dx: -10, dy: -10).contains(value.startLocation)
                                || Self.buttonFrames(sel: selection, in: geo.size).contains { $0.contains(value.startLocation) }
                        } else {
                            inChildZone = false
                        }
                        if inChildZone { return }
                        // 调整态下重画不改写 phase：松开无效时仍按调整态处理（保留当前选区）
                        if phase != .adjusting { phase = .dragging }
                        dragStart = value.startLocation
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        let inChildZone: Bool
                        if phase == .adjusting {
                            inChildZone = selection.insetBy(dx: -10, dy: -10).contains(value.startLocation)
                        } else {
                            inChildZone = false
                        }
                        if inChildZone { return }
                        defer { dragStart = nil; dragCurrent = nil }
                        let rect = SelectionGeometry.normalize(from: value.startLocation, to: value.location)
                        if SelectionGeometry.isValid(rect) {
                            selection = rect
                            phase = .adjusting
                        } else if phase != .adjusting {
                            // 非调整态的误触（原地点击）才取消；调整态下无效点击保留当前选区
                            onCancel()
                        }
                    }
            )
            .focusable()
            .onChange(of: selection) { _, new in
                cursorState.selection = new
                cursorState.hasSelection = SelectionGeometry.isValid(new)
                // 两按钮 frame 与按钮 position 用同一公式；非调整态置空
                cursorState.buttonFrames = phase == .adjusting ? Self.buttonFrames(sel: new, in: geo.size) : []
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
                NSLog("Kacha SelectionView onAppear: screenPointSize=%@, imagePixelSize=%@, geoSize=%@", NSStringFromSize(frame.screenPointSize), NSStringFromSize(frame.imagePixelSize), NSStringFromSize(geo.size))
                // 光标快照初始化 + 安装单一决策点 monitor（替代 cursorRect / onHover 方案）
                cursorState.viewHeight = geo.size.height
                cursorState.selection = selection
                cursorState.hasSelection = SelectionGeometry.isValid(selection)
                cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
                    Self.applyCursor(event: event, state: cursorState, screen: frame.screen)
                    return event
                }
            }
            .onDisappear {
                if let cursorMonitor {
                    NSEvent.removeMonitor(cursorMonitor)
                }
                cursorMonitor = nil
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
        onConfirm(selection)
    }

    private func save() {
        guard phase == .adjusting, dragStart == nil, SelectionGeometry.isValid(selection) else { return }
        onSave(selection)
    }

    // MARK: 光标（NSEvent monitor 单一决策点）

    /// 8 手柄命中判定（每点 ±8pt 方形命中区），返回对应系统 frameResize 位置
    private static func handlePosition(at p: CGPoint, in sel: CGRect) -> NSCursor.FrameResizePosition? {
        let handles: [(CGPoint, NSCursor.FrameResizePosition)] = [
            (CGPoint(x: sel.minX, y: sel.minY), .topLeft),
            (CGPoint(x: sel.midX, y: sel.minY), .top),
            (CGPoint(x: sel.maxX, y: sel.minY), .topRight),
            (CGPoint(x: sel.maxX, y: sel.midY), .right),
            (CGPoint(x: sel.maxX, y: sel.maxY), .bottomRight),
            (CGPoint(x: sel.midX, y: sel.maxY), .bottom),
            (CGPoint(x: sel.minX, y: sel.maxY), .bottomLeft),
            (CGPoint(x: sel.minX, y: sel.midY), .left),
        ]
        for (hp, position) in handles where abs(p.x - hp.x) <= 8 && abs(p.y - hp.y) <= 8 {
            return position
        }
        return nil
    }

    /// 按钮组中心位置（单一公式源，按钮 position / 光标命中 / 父层手势 gate 三处共用）：
    /// 复制按钮在选区右下角外侧，保存按钮在其左 52pt（44 按钮 + 8 间距）；
    /// 右缘 clamp 到屏内、左缘 clamp ≥ 28（半钮宽 22 + 6 边距），下方空间不足时收进选区内侧
    static func buttonCenters(sel: CGRect, bounds: CGSize) -> (save: CGPoint, copy: CGPoint) {
        let spacing: CGFloat = 52
        let copyX = min(sel.maxX - 16, bounds.width - 28)
        let saveX = max(28, copyX - spacing)
        let belowFits = sel.maxY + 20 + 16 <= bounds.height
        let y = belowFits ? sel.maxY + 20 : sel.maxY - 20
        return (CGPoint(x: saveX, y: y), CGPoint(x: copyX, y: y))
    }

    /// 两个按钮的 44×24 命中框（与按钮 position 同一公式，供光标判定与父层手势 gate 使用）
    private static func buttonFrames(sel: CGRect, in size: CGSize) -> [CGRect] {
        let c = buttonCenters(sel: sel, bounds: size)
        return [c.save, c.copy].map { CGRect(x: $0.x - 22, y: $0.y - 12, width: 44, height: 24) }
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
        // b. 命中 8 手柄 → 对应方向缩放光标
        if let position = handlePosition(at: p, in: state.selection) {
            NSCursor.frameResize(position: position, directions: .all).set()
            return
        }
        // b'. 悬停保存/复制按钮 → pointingHand
        if state.buttonFrames.contains(where: { $0.contains(p) }) {
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
    var buttonFrames: [CGRect] = []
}

/// 调整态可拖拽的部位：8 个手柄 + 选区内部（整体移动）
/// （brief 原为 SelectionView 内 private 嵌套 enum，因外部类型不可引用而提为文件顶层，行为不变）
enum SelectionHandleKind {
    case topLeft, top, topRight, right
    case bottomRight, bottom, bottomLeft, left
    case move
}

/// 整屏矩形挖去选区的遮罩形状（配合 eoFill 挖洞）
private struct DimmingMask: Shape {
    let selection: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Rectangle().path(in: rect)
        if let selection {
            path.addRect(selection)
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
            ForEach(handles, id: \.0) { kind, position in
                Handle(kind: kind, position: position)
            }
        }
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
