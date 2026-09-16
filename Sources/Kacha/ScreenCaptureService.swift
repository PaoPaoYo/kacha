import AppKit
import ScreenCaptureKit

/// 一块屏幕与其冻结帧
struct ScreenFrame {
    let screen: NSScreen
    let image: CGImage

    var screenPointSize: CGSize { screen.frame.size }
    var imagePixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// 一次截图会话的完整数据：各屏冻结帧 + 各屏窗口矩形（本屏局部坐标、front-to-back）
struct CaptureSession {
    let frames: [ScreenFrame]
    let windowsByScreen: [CGDirectDisplayID: [CGRect]]
}

enum CaptureError: LocalizedError {
    case noPermission
    case captureFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noPermission: "没有屏幕录制权限"
        case .captureFailed(let e): "屏幕抓取失败：\(e.localizedDescription)"
        }
    }
}

@MainActor
final class ScreenCaptureService {
    /// 逐屏抓取当前帧并枚举窗口（同刻冻结，一次性抓帧，不起持续推流）。
    /// macOS 27 SDK：SCShareableContent.current 为 throws 属性，未授权时抛错。
    func captureSession() async throws -> CaptureSession {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            // 实践中 current 抛错即未授权
            throw CaptureError.noPermission
        }
        guard !content.displays.isEmpty else { throw CaptureError.noPermission }

        var frames: [ScreenFrame] = []
        for screen in NSScreen.screens {
            // 抓帧引擎：/usr/sbin/screencapture 走 WindowServer 管线，保留窗口阴影；
            // SCScreenshotManager（SCK 合成管线）不渲染阴影，故弃用
            let image = try await captureDisplayImage(displayID: screen.displayID)
            frames.append(ScreenFrame(screen: screen, image: image))
        }
        // 窗口枚举（与冻结帧同刻）：普通窗口、在屏、有主 app、非本 app、frame 有效
        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let myPID = ProcessInfo.processInfo.processIdentifier
        // SCShareableContent.windows 顺序未定义（非 Z 序，实测特定 app 间顺序固定且与层级无关）；
        // 用 CGWindowList 的 front-to-back 顺序（文档保证）排序
        let zOrder: [CGWindowID] = {
            guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
            return infos.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        }()
        let zIndex: [CGWindowID: Int] = Dictionary(uniqueKeysWithValues: zOrder.enumerated().map { ($1, $0) })
        let screenWindows = content.windows.filter { window in
            window.windowLayer == 0 && window.isOnScreen // 最小化/其他 Space 的窗口不可见
                && window.owningApplication != nil
                && window.owningApplication?.processID != myPID
                && window.frame.width > 0 && window.frame.height > 0
        }
        // front-to-back 排序；不在 CGWindowList 中的（理论不出现）置末尾
        let ordered = screenWindows.sorted { (zIndex[$0.windowID] ?? .max) < (zIndex[$1.windowID] ?? .max) }
        var windowsByScreen: [CGDirectDisplayID: [CGRect]] = [:]
        for window in ordered {
            for screen in NSScreen.screens {
                let local = WindowGeometry.localRect(window: window.frame, screenFrame: screen.frame, totalHeight: totalHeight)
                let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
                if let clamped = WindowGeometry.clampedToScreen(local, screenBounds: screenBounds) {
                    windowsByScreen[screen.displayID, default: []].append(clamped)
                }
            }
        }
        return CaptureSession(frames: frames, windowsByScreen: windowsByScreen)
    }

    /// 用 /usr/sbin/screencapture 抓单屏当前帧（WindowServer 管线，保留窗口阴影），落盘 PNG 后读回 CGImage
    private func captureDisplayImage(displayID: CGDirectDisplayID) async throws -> CGImage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kacha-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // 进程运行放后台线程，避免 waitUntilExit 卡 MainActor
        let status = try await Task.detached(priority: .userInitiated) {
            () -> Int32 in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-D", String(displayID), "-t", "png", url.path]
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        }.value
        guard status == 0, let provider = CGDataProvider(url: url as CFURL) else {
            throw CaptureError.captureFailed(underlying: NSError(domain: "kacha.screencapture", code: Int(status)))
        }
        guard let image = CGImage(pngDataProviderSource: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw CaptureError.captureFailed(underlying: NSError(domain: "kacha.screencapture", code: -1))
        }
        return image
    }
}

/// macOS 27 SDK：NSScreen 无 displayID 属性，经 deviceDescription 取 CGDirectDisplayID
private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
