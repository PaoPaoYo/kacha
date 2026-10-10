import AppKit
import XCTest
@testable import kacha

@MainActor
final class CapturePreviewTests: XCTestCase {
    func testBitmapViewDrawsImageWithoutFlippingRows() throws {
        let source = makeImage(width: 40, height: 30) { y, x in UInt8(truncatingIfNeeded: y * 7 + x) }
        let view = CaptureBitmapView(frame: CGRect(x: 0, y: 0, width: 40, height: 30))
        view.image = source
        let rendered = try render(view)
        XCTAssertEqual(pixels(of: rendered), pixels(of: source))
    }

    func testAnnotationPreviewMatchesExportIncludingBlurAndLayerOrder() throws {
        let source = makeImage(width: 120, height: 100) { y, x in UInt8(truncatingIfNeeded: x * 11 + y * 17) }
        let annotations: [Annotation] = [
            Annotation(kind: .rect(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6)), color: .red, lineWidth: 4),
            Annotation(kind: .blur(points: [CGPoint(x: 0.1, y: 0.3), CGPoint(x: 0.7, y: 0.3)], radius: 5), color: .black, lineWidth: 14),
            Annotation(kind: .text(at: CGPoint(x: 0.12, y: 0.55), string: "咔嚓 Aa", fontSize: 14, width: 0.75), color: .green, lineWidth: 1),
            Annotation(kind: .arrow(start: CGPoint(x: 0.2, y: 0.8), end: CGPoint(x: 0.8, y: 0.8)), color: .blue, lineWidth: 4)
        ]
        let rect = CGRect(x: 0, y: 0, width: 120, height: 100)
        let view = CaptureAnnotationBitmapView(frame: rect)
        view.update(image: source, pointSize: rect.size, selection: rect, annotations: annotations)
        let overlay = try render(view)
        // 将透明预览叠到底图上，与独立的导出链路比对，覆盖 Y 翻转、裁剪和绘制顺序。
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: rect)
        context.draw(overlay, in: rect)
        let composited = try XCTUnwrap(context.makeImage())
        let exported = AnnotationRenderer.composite(source, annotations: annotations, selectionPointWidth: 120)
        let actual = pixels(of: composited)
        let expected = pixels(of: exported)
        XCTAssertEqual(actual.count, expected.count)
        let mismatch = zip(actual, expected).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertLessThan(mismatch, 120 * 100 / 100, "预览和输出的颜色、位置、层序应一致（允许少量边缘舍入）")
        view.clear()
    }

    private func render(_ view: NSView) throws -> CGImage {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: width * 4, bitsPerPixel: 32))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(view.bounds)
        view.draw(view.bounds)
        return try XCTUnwrap(bitmap.cgImage)
    }
}
