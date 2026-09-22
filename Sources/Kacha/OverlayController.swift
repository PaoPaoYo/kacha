import AppKit
import SwiftUI

/// 用户完成框选后的动作：复制到剪贴板 / 保存为文件 / 钉成置顶图钉
enum CaptureAction {
    case copy
    case save
    case pin
}

/// 覆盖窗全部关闭的广播：SelectionView 借此立即移除自身的 NSEvent monitor（防泄漏）
extension Notification.Name {
    static let kachaOverlayDismissed = Notification.Name("kachaOverlayDismissed")
    /// keyDown monitor 判定应删除选中标注（焦点不在 SwiftUI focusable 时 onKeyPress 收不到）
    static let kachaDeleteSelectedAnnotation = Notification.Name("kachaDeleteSelectedAnnotation")
}

@MainActor
final class OverlayController {
    private var panels: [KeyablePanel] = []

    /// 显示全部屏幕的覆盖窗；用户完成框选后回调裁剪好的图像、所选动作与选区 AppKit 全局 frame
    /// （屏局部 point 选区经 `PinWindowController.appkitFrame(fromLocal:on:)` 换算，钉图原位开窗用）。
    /// windowsByScreen：各屏窗口矩形（本屏局部坐标、front-to-back），透传给各屏 SelectionView
    func show(frames: [ScreenFrame], windowsByScreen: [CGDirectDisplayID: [CGRect]], onCapture: @escaping (CGImage, CaptureAction, CGRect) -> Void, onCancel: @escaping () -> Void) {
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
            let view = SelectionView(frame: frame, windows: windowsByScreen[displayID] ?? []) { [weak self] pointRect, cornerRadius, annotations in
                self?.handleConfirm(frame: frame, pointRect: pointRect, cornerRadius: cornerRadius, annotations: annotations, action: .copy, onCapture: onCapture)
            } onSave: { [weak self] pointRect, cornerRadius, annotations in
                self?.handleConfirm(frame: frame, pointRect: pointRect, cornerRadius: cornerRadius, annotations: annotations, action: .save, onCapture: onCapture)
            } onPin: { [weak self] pointRect, cornerRadius, annotations in
                self?.handleConfirm(frame: frame, pointRect: pointRect, cornerRadius: cornerRadius, annotations: annotations, action: .pin, onCapture: onCapture)
            } onCancel: { [weak self] in
                self?.dismissAll()
                onCancel()
            }
            let hosting = CrosshairHostingView(rootView: view)
            hosting.frame = panel.contentView?.bounds ?? frame.screen.frame
            hosting.autoresizingMask = [.width, .height]
            // 右击取消（与 ESC 等价）
            hosting.onRightClick = { [weak self] in
                self?.dismissAll()
                onCancel()
            }
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

    /// 关闭全部覆盖窗 → 裁剪像素 → 标注合成 →（按需）圆角化 → 带动作回调（复制 / 保存 / 钉图共用裁剪链路）
    private func handleConfirm(frame: ScreenFrame, pointRect: CGRect, cornerRadius: CGFloat, annotations: [Annotation], action: CaptureAction, onCapture: @escaping (CGImage, CaptureAction, CGRect) -> Void) {
        dismissAll()
        let pixelRect = SelectionGeometry.pixelRect(
            pointRect: pointRect,
            screenPointSize: frame.screenPointSize,
            imagePixelSize: frame.imagePixelSize
        )
        // 选区屏局部 point 矩形（左上原点）→ AppKit 全局 frame（左下原点，钉图原位显示用）
        let globalFrame = PinWindowController.appkitFrame(fromLocal: pointRect, on: frame.screen)
        if let cropped = frame.image.cropping(to: pixelRect) {
            // 标注先画进直角图（无标注时 renderer 原图直通），圆角化在其上 clip，
            // 保证「标注 + 圆角」并存时标注与底图一起被圆角裁切（与预览所见一致）
            let composited = AnnotationRenderer.composite(cropped, annotations: annotations, selectionPointWidth: pointRect.width)
            let output: CGImage
            if cornerRadius > 0 {
                // point 半径 → 像素半径（各屏 scale = 像素尺寸 / point 尺寸）
                let scale = frame.imagePixelSize.width / frame.screenPointSize.width
                output = roundedCornerImage(composited, pixelRadius: cornerRadius * scale)
            } else {
                // r == 0：零成本直通
                output = composited
            }
            onCapture(output, action, globalFrame)
        } else {
            // 像素矩形越界（理论不该发生，pixelRect 已 clamp）：退回整帧
            onCapture(frame.image, action, globalFrame)
        }
    }

    /// alpha 圆角化（premultiplied）：圆角矩形路径 clip 后重绘，四角透出透明；失败时退回原图
    private func roundedCornerImage(_ image: CGImage, pixelRadius: CGFloat) -> CGImage {
        let w = image.width, h = image.height
        // 半径 clamp 到半短边：极小选区（如 4pt 选区 × 2x = 8px）时 40pt 半径会超过 CGPath 圆角矩形的合法上限
        let radius = min(pixelRadius, CGFloat(min(w, h)) / 2)
        guard w > 0, h > 0, radius > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

/// borderless 窗口也要能成为 key window（接收 ESC）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 光标宿主视图：cursorRect 机制已停用——cursorRect 会在每次 mouseMoved 时被 AppKit 重设，
/// 覆盖 SelectionView 的 NSEvent monitor 光标；光标现由该 monitor 统一管理（单一决策点）。
/// 右击取消截图（与 ESC 等价），经 onRightClick 回调 OverlayController。
final class CrosshairHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {}

    /// 右击回调（show() 中接线：dismissAll + onCancel）
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
