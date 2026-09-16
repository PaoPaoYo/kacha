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
            // macOS 27 SDK：NSScreen 无 displayID 属性，经 deviceDescription 取 CGDirectDisplayID
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.showsCursor = false
            // 不设 captureResolution：该 API 在 SCScreenshotManager 路径行为不可靠（实测与 width/height 相互覆盖）。
            // 物理像素实测：CGDisplayPixelsWide 在 HiDPI 返回逻辑值(1512)、SCDisplay.width 头文件标注 points，
            // 唯一可靠来源是 NSScreen point 尺寸 × backingScaleFactor（本机实测 1512×982×2.0=3024×1964）
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                frames.append(ScreenFrame(screen: screen, image: image))
            } catch {
                throw CaptureError.captureFailed(underlying: error)
            }
        }
        // 窗口枚举（与冻结帧同刻）：普通窗口、有主 app、非本 app、frame 有效
        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let myPID = ProcessInfo.processInfo.processIdentifier
        var windowsByScreen: [CGDirectDisplayID: [CGRect]] = [:]
        for window in content.windows {
            guard window.windowLayer == 0,
                  window.isOnScreen, // 最小化/其他 Space 的窗口不可见
                  let owner = window.owningApplication,
                  owner.processID != myPID,
                  window.frame.width > 0, window.frame.height > 0
            else { continue }
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
}

/// macOS 27 SDK：NSScreen 无 displayID 属性，经 deviceDescription 取 CGDirectDisplayID
private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
