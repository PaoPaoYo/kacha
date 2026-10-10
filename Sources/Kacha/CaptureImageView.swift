import AppKit
import SwiftUI

/// 截图大图直接画入窗口 backing store，不作为 SwiftUI Image 的历史纹理进入 CA image_cache。
struct CaptureImageView: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> CaptureBitmapView {
        let view = CaptureBitmapView()
        view.image = image
        return view
    }

    func updateNSView(_ view: CaptureBitmapView, context: Context) {
        view.image = image
    }

    static func dismantleNSView(_ view: CaptureBitmapView, coordinator: ()) {
        view.image = nil
        view.layer?.contents = nil
    }
}

final class CaptureBitmapView: NSView {
    var image: CGImage? {
        didSet {
            if image !== oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clear(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

/// 切断 PNG 解码源 / cropping 共享整屏 backing 的所有权；只保留实际输出像素。
enum CaptureBitmap {
    static func detached(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
