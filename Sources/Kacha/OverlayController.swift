import AppKit
import SwiftUI

/// 用户完成框选后的动作：复制到剪贴板 / 保存为文件
enum CaptureAction {
    case copy
    case save
}

/// 覆盖窗全部关闭的广播：SelectionView 借此立即移除自身的 NSEvent monitor（防泄漏）
extension Notification.Name {
    static let kachaOverlayDismissed = Notification.Name("kachaOverlayDismissed")
}

@MainActor
final class OverlayController {
    private var panels: [KeyablePanel] = []

    /// 显示全部屏幕的覆盖窗；用户完成框选后回调裁剪好的图像与所选动作。
    /// windowsByScreen：各屏窗口矩形（本屏局部坐标、front-to-back），透传给各屏 SelectionView
    func show(frames: [ScreenFrame], windowsByScreen: [CGDirectDisplayID: [CGRect]], onCapture: @escaping (CGImage, CaptureAction) -> Void, onCancel: @escaping () -> Void) {
        dismissAll()
        NSApp.activate(ignoringOtherApps: true)

        for (index, frame) in frames.enumerated() {
            let panel = KeyablePanel(
                contentRect: frame.screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false

            let displayID = frame.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let view = SelectionView(frame: frame, windows: windowsByScreen[displayID] ?? []) { [weak self] pointRect in
                self?.handleConfirm(frame: frame, pointRect: pointRect, action: .copy, onCapture: onCapture)
            } onSave: { [weak self] pointRect in
                self?.handleConfirm(frame: frame, pointRect: pointRect, action: .save, onCapture: onCapture)
            } onCancel: { [weak self] in
                self?.dismissAll()
                onCancel()
            }
            let hosting = CrosshairHostingView(rootView: view)
            hosting.frame = panel.contentView?.bounds ?? frame.screen.frame
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            // 第一块屏的 panel 成为 key window（接收 ESC），其余仅前置
            if index == 0 {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            panels.append(panel)
        }
    }

    func dismissAll() {
        // 先广播再关窗：各屏 SelectionView 收到后立即移除光标 monitor（onDisappear 为兜底路径）
        NotificationCenter.default.post(name: .kachaOverlayDismissed, object: nil)
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    /// 关闭全部覆盖窗 → 裁剪像素 → 带动作回调（复制 / 保存共用裁剪链路）
    private func handleConfirm(frame: ScreenFrame, pointRect: CGRect, action: CaptureAction, onCapture: @escaping (CGImage, CaptureAction) -> Void) {
        dismissAll()
        let pixelRect = SelectionGeometry.pixelRect(
            pointRect: pointRect,
            screenPointSize: frame.screenPointSize,
            imagePixelSize: frame.imagePixelSize
        )
        if let cropped = frame.image.cropping(to: pixelRect) {
            onCapture(cropped, action)
        } else {
            // 像素矩形越界（理论不该发生，pixelRect 已 clamp）：退回整帧
            onCapture(frame.image, action)
        }
    }
}

/// borderless 窗口也要能成为 key window（接收 ESC）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 光标宿主视图：cursorRect 机制已停用——cursorRect 会在每次 mouseMoved 时被 AppKit 重设，
/// 覆盖 SelectionView 的 NSEvent monitor 光标；光标现由该 monitor 统一管理（单一决策点）。
final class CrosshairHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {}
}
