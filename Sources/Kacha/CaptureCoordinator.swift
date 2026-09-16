import AppKit
import UniformTypeIdentifiers

/// 串联整个截图流程：热键/菜单 → 抓帧 → 覆盖窗 → 剪贴板/文件
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
            let session = try await captureService.captureSession()
            overlay.show(frames: session.frames, windowsByScreen: session.windowsByScreen, onCapture: { image, action in
                switch action {
                case .copy:
                    ClipboardService.write(image)
                    NSSound(named: NSSound.Name("Tink"))?.play()
                case .save:
                    self.saveToFile(image)
                }
            }, onCancel: {})
        } catch CaptureError.noPermission {
            presentPermissionGuide()
        } catch {
            presentError(error)
        }
    }

    /// 保存为 PNG：覆盖窗已由 OverlayController 关闭，弹 NSSavePanel 选位置写文件；
    /// 用户取消面板则静默结束（不写文件不响提示音）
    private func saveToFile(_ image: CGImage) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        let df = DateFormatter()
        df.dateFormat = "截图 yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = df.string(from: Date())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = ClipboardService.pngData(image) else {
            presentError(PNGEncodeError())
            return
        }
        do {
            try data.write(to: url)
            NSSound(named: NSSound.Name("Tink"))?.play()
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

/// PNG 编码失败（理论不发生：CGImage→NSImage→TIFF→BitmapImageRep 链路稳定）
private struct PNGEncodeError: LocalizedError {
    var errorDescription: String? { "截图 PNG 编码失败" }
}
