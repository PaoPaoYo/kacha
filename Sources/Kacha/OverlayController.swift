import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panels: [KeyablePanel] = []

    /// 显示全部屏幕的覆盖窗；用户完成框选后回调裁剪好的图像
    func show(frames: [ScreenFrame], onCapture: @escaping (CGImage) -> Void, onCancel: @escaping () -> Void) {
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

            let view = SelectionView(frame: frame) { [weak self] pointRect in
                self?.handleConfirm(frame: frame, pointRect: pointRect, onCapture: onCapture)
            } onCancel: { [weak self] in
                self?.dismissAll()
                onCancel()
            }
            panel.contentView = NSHostingView(rootView: view)
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
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    private func handleConfirm(frame: ScreenFrame, pointRect: CGRect, onCapture: @escaping (CGImage) -> Void) {
        dismissAll()
        let pixelRect = SelectionGeometry.pixelRect(
            pointRect: pointRect,
            screenPointSize: frame.screenPointSize,
            imagePixelSize: frame.imagePixelSize
        )
        if let cropped = frame.image.cropping(to: pixelRect) {
            onCapture(cropped)
        } else {
            // 像素矩形越界（理论不该发生，pixelRect 已 clamp）：退回整帧
            onCapture(frame.image)
        }
    }
}

/// borderless 窗口也要能成为 key window（接收 ESC）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
