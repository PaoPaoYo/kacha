import AppKit
import SwiftUI

/// 模糊预览也直接绘制，避免 Canvas.draw(Image) 缓存每个选区/半径对应的大图。
struct CaptureAnnotationPreview: NSViewRepresentable {
    let image: CGImage
    let pointSize: CGSize
    let selection: CGRect
    let annotations: [Annotation]

    func makeNSView(context: Context) -> CaptureAnnotationBitmapView { CaptureAnnotationBitmapView() }

    func updateNSView(_ view: CaptureAnnotationBitmapView, context: Context) {
        view.update(image: image, pointSize: pointSize, selection: selection, annotations: annotations)
    }

    static func dismantleNSView(_ view: CaptureAnnotationBitmapView, coordinator: ()) { view.clear() }
}

final class CaptureAnnotationBitmapView: NSView {
    private var source: CGImage?
    private var selection: CGRect = .zero
    private var pointSize: CGSize = .zero
    private var annotations: [Annotation] = []
    private var cachedCrop: CGImage?
    private var cache: [CGFloat: CGImage] = [:]

    func update(image: CGImage, pointSize: CGSize, selection: CGRect, annotations: [Annotation]) {
        if source !== image || self.selection != selection || self.pointSize != pointSize {
            cachedCrop = nil
            cache.removeAll()
        }
        self.source = image
        self.pointSize = pointSize
        self.selection = selection
        self.annotations = annotations
        let radii = Set(self.annotations.compactMap { annotation -> CGFloat? in
            if case let .blur(_, radius) = annotation.kind { return radius }
            return nil
        })
        cache = cache.filter { radii.contains($0.key) }
        needsDisplay = true
    }

    func clear() {
        source = nil
        cachedCrop = nil
        cache.removeAll()
        annotations.removeAll()
        layer?.contents = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(bounds)
        guard !annotations.isEmpty, let source, pointSize.width > 0 else { return }
        let pixelRect = SelectionGeometry.pixelRect(pointRect: selection, screenPointSize: pointSize,
            imagePixelSize: CGSize(width: source.width, height: source.height))
        if cachedCrop == nil { cachedCrop = source.cropping(to: pixelRect) }
        guard let crop = cachedCrop else { return }
        let pixelScale = CGFloat(crop.width) / max(selection.width, 1)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let rect = CGRect(origin: .zero, size: bounds.size)
        for annotation in annotations {
            let path = AnnotationGeometry.path(for: annotation.kind, in: rect, lineWidth: annotation.lineWidth)
            if case let .blur(_, radius) = annotation.kind {
                if cache[radius] == nil {
                    cache[radius] = AnnotationRenderer.gaussianBlurred(crop, scale: pixelScale, radius: radius)
                }
                guard let blurred = cache[radius] else { continue }
                context.saveGState()
                context.addPath(path)
                context.setLineWidth(annotation.lineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.replacePathWithStrokedPath()
                context.clip()
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(blurred, in: rect)
                context.restoreGState()
                continue
            }
            if case let .text(at, string, fontSize, width) = annotation.kind {
                let textRect = AnnotationTextLayout.localRect(at: at, string: string,
                    fontSize: fontSize, width: width, selection: rect)
                AnnotationTextLayout.draw(context, string: string, fontSize: fontSize,
                    color: annotation.color, at: textRect.origin, maxWidth: textRect.width)
                continue
            }
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if annotation.color == .white {
                context.addPath(path)
                context.setLineWidth(annotation.lineWidth + 2)
                context.setStrokeColor(NSColor.separatorColor.cgColor)
                context.strokePath()
            }
            let color = annotation.color
            let cgColor = CGColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
            context.addPath(path)
            context.setLineWidth(annotation.lineWidth)
            context.setStrokeColor(cgColor)
            context.strokePath()
            if case .arrow = annotation.kind {
                context.addPath(path)
                context.setFillColor(cgColor)
                context.fillPath(using: .evenOdd)
            }
        }
    }
}
