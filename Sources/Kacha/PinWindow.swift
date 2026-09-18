import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 钉图面板：borderless 浮动置顶、可 key（ESC 关闭依赖）、跨 Space 常驻、透明底、系统阴影。
/// 点击即激活成为 key window（设计 §2.5 的取舍：ESC 语义依赖 key，不避让其他窗口焦点）
final class PinPanel: NSPanel {
    /// ESC 关窗（window key 时）：AppKit 直收，不依赖 SwiftUI 焦点路由。
    /// PinView 的 onExitCommand 为另一路径，二者先到先关（controller.remove 幂等）
    var onCloseHotkey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        // NSPanel 默认仅在需要时才成为 key（becomesKeyOnlyIfNeeded），无文本输入的纯图面板
        // 会被跳过——点击钉图必须成为 key（ESC 依赖），显式关闭该优化
        becomesKeyOnlyIfNeeded = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        hasShadow = true   // 系统窗口阴影（替代描边）；透明圆角内容按内容轮廓投影
        isReleasedWhenClosed = false   // 关闭统一走 orderOut + 引用移除，防隐式 close 释放
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCloseHotkey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 钉图窗口内容：最终合成图（标注 + 圆角）按窗口尺寸显示（合成图自带透明圆角，
/// 透明窗底直接透出，系统阴影按内容轮廓投影）。边缘 8pt 隐形拖拽区命中
/// `PinGeometry.edge` → 方向光标 + 等比缩放（PinGeometry.resized，锚定对边/对角、
/// 最小 64×64、不越屏）；内部拖动 = 移动窗口（不 clamp 屏缘，仅保证一条可回拖条带
/// 留在屏内）；hover 显示左上 12pt 红点关闭钮；ESC（窗口 key 时，AppKit keyDown 兜底）
/// 关闭。
///
/// 拖动位移取 `NSEvent.mouseLocation` 相对起拖点的屏幕全局累计量：窗口自身随拖动
/// 移动/缩放，视图局部坐标系跟着窗口走，SwiftUI translation 的「起点固定在窗口局部」
/// 会被窗口位移抵消（左缘/上缘起拖或整体移动时逐帧归零、拖动冻结）；屏幕全局量
/// 与窗口位置无关，天然满足「自起拖点累计」的调用要求。
struct PinView: View {
    let image: CGImage
    /// 图像纵横比（w/h）：等比缩放基准，恒定
    let aspect: CGFloat
    /// 关闭（统一走 controller.remove：orderOut + 移除引用）
    let close: () -> Void
    /// 宿主面板（weak：面板由 controller 数组持有，这里只借用 setFrame）
    weak var panel: NSPanel?

    /// 拖动后至少留在屏内的可回拖条带宽（「标题区可回拖」的无标题替代）
    private static let grabStrip: CGFloat = 32
    /// 等比缩放最小尺寸
    private static let minSize = CGSize(width: 64, height: 64)

    @State private var hovering = false
    /// 进行中的拖拽方位：nil 且 moving = 移动；nil 且 !moving = 未拖拽
    @State private var dragEdge: PinEdge?
    @State private var moving = false
    /// 起拖瞬间鼠标的屏幕全局位置（AppKit 坐标，y 向上）
    @State private var startMouse: CGPoint = .zero
    /// 起拖瞬间窗口的屏局部矩形（左上原点）与所在屏（累计位移的换算基准，此后不变）
    @State private var startLocal: CGRect = .zero
    @State private var startScreen: NSScreen?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                // 关闭钮仅 hover 渲染：未渲染即不可命中（等价 allowsHitTesting 仅 hover 为 true）
                if hovering {
                    closeButton
                        .padding(6)
                }
            }
            .coordinateSpace(name: "pin")
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named("pin")) { phase in
                switch phase {
                case .active(let point): hoverActive(at: point, size: geo.size)
                case .ended: hoverEnded()
                }
            }
            .gesture(dragGesture(size: geo.size))
            .onExitCommand(perform: close)
        }
    }

    /// 左上 12pt 红点关闭钮（NSWindow 关闭钮风格 #FF5F57，内含白色小叉提升辨识）
    private var closeButton: some View {
        Button(action: close) {
            Circle()
                .fill(Color(red: 1, green: 95.0 / 255.0, blue: 87.0 / 255.0))
                .frame(width: 12, height: 12)
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭钉图")
    }

    // MARK: 悬停（光标切换）

    /// 边缘区（内 8pt）切方向光标，内部 arrow；拖拽进行中保持拖拽光标不随 hover 抖动
    private func hoverActive(at point: CGPoint, size: CGSize) {
        hovering = true
        guard !moving else { return }
        let rect = CGRect(origin: .zero, size: size)
        if let edge = PinGeometry.edge(at: point, in: rect) {
            Self.cursor(for: edge).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func hoverEnded() {
        hovering = false
        if !moving { NSCursor.arrow.set() }
    }

    /// PinEdge → 系统光标：四边直向、四角对角 frameResize（与选区缩放光标同源）
    private static func cursor(for edge: PinEdge) -> NSCursor {
        switch edge {
        case .topLeft: NSCursor.frameResize(position: .topLeft, directions: .all)
        case .top, .bottom: .resizeUpDown
        case .topRight: NSCursor.frameResize(position: .topRight, directions: .all)
        case .left, .right: .resizeLeftRight
        case .bottomRight: NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .bottomLeft: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        }
    }

    // MARK: 拖拽（边缘 = 等比缩放 / 内部 = 移动）

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("pin"))
            .onChanged { value in
                if !moving { beginDrag(at: value.startLocation, size: size) }
                continueDrag()
            }
            .onEnded { _ in endDrag() }
    }

    /// 起拖分派：起拖点边缘命中 = 缩放（记 PinEdge），否则 = 移动。
    /// 记录起拖瞬间的鼠标屏幕位置与窗口屏局部矩形（此后窗口动、基准不动）
    private func beginDrag(at startLocation: CGPoint, size: CGSize) {
        guard let panel,
              let (local, screen) = PinWindowController.screenLocalFrame(of: panel) else { return }
        dragEdge = PinGeometry.edge(at: startLocation, in: CGRect(origin: .zero, size: size))
        moving = true
        startMouse = NSEvent.mouseLocation
        startLocal = local
        startScreen = screen
        if let edge = dragEdge { Self.cursor(for: edge).set() }
    }

    private func continueDrag() {
        guard moving, let panel, let screen = startScreen else { return }
        // 屏幕全局累计位移；AppKit y 向上 → CG 左上原点 y 向下取反
        let dx = NSEvent.mouseLocation.x - startMouse.x
        let dy = -(NSEvent.mouseLocation.y - startMouse.y)
        if let edge = dragEdge {
            // 等比缩放：from = 起拖窗口屏局部矩形（锚点在其坐标系内不动），bounds = 屏尺寸
            let newLocal = PinGeometry.resized(
                from: startLocal,
                by: CGSize(width: dx, height: dy),
                edge: edge,
                aspect: aspect,
                minSize: Self.minSize,
                bounds: screen.frame.size)
            panel.setFrame(PinWindowController.appkitFrame(fromLocal: newLocal, on: screen), display: false)
            // 透明异形窗的阴影轮廓需在尺寸变化后重采样（移动不变形，无需重算）
            panel.invalidateShadow()
        } else {
            // 移动不 clamp 屏缘（可拖出），仅保证 grabStrip 宽条带留在屏内可回拖
            let x = min(max(startLocal.minX + dx, -startLocal.width + Self.grabStrip),
                        screen.frame.width - Self.grabStrip)
            let y = min(max(startLocal.minY + dy, -startLocal.height + Self.grabStrip),
                        screen.frame.height - Self.grabStrip)
            let newLocal = CGRect(x: x, y: y, width: startLocal.width, height: startLocal.height)
            panel.setFrame(PinWindowController.appkitFrame(fromLocal: newLocal, on: screen), display: false)
        }
    }

    private func endDrag() {
        moving = false
        dragEdge = nil
        NSCursor.arrow.set()
    }
}

/// 钉图窗口管理：多开互不干扰（每钉一窗入数组），关窗路径统一 `remove`
/// （orderOut + 移除引用），app 终止 `closeAll` 全清。
@MainActor
final class PinWindowController {
    static let shared = PinWindowController()
    private init() {}

    private var panels: [PinPanel] = []

    /// 钉图开窗：显示在选区原位置（`frame` = 选区的 AppKit 全局矩形，由 OverlayController
    /// 经 `appkitFrame(fromLocal:on:)` 从屏局部 point 选区换算而来）。尺寸等比 clamp 目标屏内
    /// （保比例整体缩小、不变形），位置仍贴选区原位、clamp 使窗口完整落在所在屏内；
    /// makeKeyAndOrderFront 纳入管理。目标屏 = 含选区中心的屏（NSScreen.screens 含 frame 检查），
    /// 无命中回退主屏；无效尺寸/无屏不开窗（理论不发生）
    func pin(_ image: CGImage, frame: CGRect) {
        guard frame.width > 0, frame.height > 0,
              let screen = Self.containingScreen(for: frame) ?? NSScreen.main else { return }
        let screenFrame = screen.frame
        // 等比 clamp：超屏按比例整体缩小（短边约束生效），不变形
        let scale = min(1, screenFrame.width / frame.width, screenFrame.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        // 位置贴选区原位，逐轴 clamp 到所在屏内（缩放后必能完整放下）
        let origin = CGPoint(
            x: min(max(frame.minX, screenFrame.minX), screenFrame.maxX - size.width),
            y: min(max(frame.minY, screenFrame.minY), screenFrame.maxY - size.height))

        let panel = PinPanel(contentRect: CGRect(origin: origin, size: size))
        // self 是常驻单例（shared），强持有无副作用；panel weak 防止已关窗误触发
        let close = { [weak panel] in
            if let panel { self.remove(panel) }
        }
        panel.onCloseHotkey = close
        let view = PinView(
            image: image,
            aspect: frame.width / frame.height,
            close: close,
            panel: panel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panels.append(panel)
    }

    /// 关窗统一出口：orderOut + 移除引用（幂等：已移除再进 no-op）
    func remove(_ panel: PinPanel) {
        guard panels.contains(where: { $0 === panel }) else { return }
        panels.removeAll { $0 === panel }
        panel.orderOut(nil)
    }

    /// app 终止全清（KachaApp.applicationWillTerminate 调用）
    func closeAll() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    // MARK: 坐标换算（AppKit 全局左下原点 ↔ 屏局部 CG 左上原点）

    /// 各屏 AppKit frame.maxY 的最大值（AppKit ↔ CG 全局换算基准，同 WindowGeometry 约定）
    private static var totalHeight: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? 0
    }

    /// NSPanel frame（AppKit 全局、左下原点）→ 所在屏局部 CG 矩形（左上原点）与所在屏。
    /// 所在屏 = 包含窗口中心的屏，否则相交面积最大的屏，否则主屏；nil = 系统无屏
    static func screenLocalFrame(of panel: NSPanel) -> (rect: CGRect, screen: NSScreen)? {
        guard let screen = containingScreen(for: panel.frame) else { return nil }
        return (screenLocalRect(panel.frame, on: screen), screen)
    }

    private static func containingScreen(for frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max {
                $0.frame.intersection(frame).width * $0.frame.intersection(frame).height
                    < $1.frame.intersection(frame).width * $1.frame.intersection(frame).height
            }
            ?? NSScreen.main
    }

    /// AppKit 全局 frame → 屏局部 CG 矩形：先翻 y 成 CG 全局，再减屏 CG 原点
    private static func screenLocalRect(_ frame: CGRect, on screen: NSScreen) -> CGRect {
        let cg = CGRect(x: frame.minX, y: totalHeight - frame.maxY, width: frame.width, height: frame.height)
        let origin = WindowGeometry.screenOriginGlobalCG(frame: screen.frame, totalHeight: totalHeight)
        return cg.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// 屏局部 CG 矩形 → AppKit 全局 frame（screenLocalRect 的逆变换）
    static func appkitFrame(fromLocal local: CGRect, on screen: NSScreen) -> CGRect {
        let origin = WindowGeometry.screenOriginGlobalCG(frame: screen.frame, totalHeight: totalHeight)
        let cg = local.offsetBy(dx: origin.x, dy: origin.y)
        return CGRect(x: cg.minX, y: totalHeight - cg.maxY, width: cg.width, height: cg.height)
    }
}
