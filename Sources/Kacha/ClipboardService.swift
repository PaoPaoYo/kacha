import AppKit
import CoreGraphics

enum ClipboardService {
    /// 把截图写进系统剪贴板（PNG + TIFF 两种类型）
    static func write(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // size 用像素尺寸：粘贴到多数应用时保持原始像素
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let tiff = nsImage.tiffRepresentation else { return }
        pasteboard.setData(tiff, forType: .tiff)
        if let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
    }
}
