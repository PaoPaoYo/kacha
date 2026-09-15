import AppKit
import ScreenCaptureKit

/// 一块屏幕与其冻结帧
struct ScreenFrame {
    let screen: NSScreen
    let image: CGImage

    var screenPointSize: CGSize { screen.frame.size }
    var imagePixelSize: CGSize { CGSize(width: image.width, height: image.height) }
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
    /// 逐屏抓取当前帧（一次性抓帧，不起持续推流）。
    /// macOS 27 SDK：SCShareableContent.current 为 throws 属性，未授权时抛错。
    func captureAllDisplays() async throws -> [ScreenFrame] {
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
            // macOS 27 SDK：NSScreen 无 displayID 属性，经 deviceDescription 取 CGDirectDisplayID
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                frames.append(ScreenFrame(screen: screen, image: image))
            } catch {
                throw CaptureError.captureFailed(underlying: error)
            }
        }
        return frames
    }
}
