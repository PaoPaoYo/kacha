import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 直接编码最终位图，避免 NSImage → TIFF → 再解码 → PNG 的额外整图副本。
enum ClipboardService {
    static func write(_ image: CGImage) {
        autoreleasepool {
            guard let png = pngData(image) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            // 保留 TIFF 粘贴兼容性；顺序编码，两种格式不再彼此转换。
            if let tiff = encodedData(image, type: UTType.tiff) {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        encodedData(image, type: .png)
    }

    static func encodedData(_ image: CGImage, type: UTType) -> Data? {
        autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}
