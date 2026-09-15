import AppKit

/// 串联整个截图流程：热键/菜单 → 抓帧 → 覆盖窗 → 剪贴板
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let captureService = ScreenCaptureService()
    private let overlay = OverlayController()
    private var isRunning = false

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            let frames = try await captureService.captureAllDisplays()
            overlay.show(frames: frames) { image in
                ClipboardService.write(image)
                NSSound(named: NSSound.Name("Tink"))?.play()
            } onCancel: {}
        } catch CaptureError.noPermission {
            presentPermissionGuide()
        } catch {
            presentError(error)
        }
    }

    private func presentPermissionGuide() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「咔嚓」需要屏幕录制权限"
        alert.informativeText = "请在 系统设置 › 隐私与安全性 › 屏幕录制 中允许「咔嚓」，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }

    private func presentError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
