import XCTest
import CoreGraphics
@testable import kacha

final class AnnotationRendererTests: XCTestCase {
    /// 生成纯色 CGImage
    private func solidImage(_ rgba: RGBA, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        guard let raw = image.dataProvider?.data else { return (0, 0, 0) }  // CGDataProvider 无 copyData()，取 data
        let bytes = [UInt8](raw as Data)
        // CGImage 位图按左上原点存储，第 (x, y) 像素 = bytes[y * bytesPerRow + x * 4]（premultipliedLast: RGBA）
        let o = y * image.bytesPerRow + x * 4
        return (bytes[o], bytes[o + 1], bytes[o + 2])
    }

    func test_composite_rectStrokeColorsCenter() {
        let base = solidImage(RGBA.white, width: 100, height: 100)
        // 归一化矩形 (0.1,0.45,0.8,0.1)：黑描边 lineWidth 4（point）；scale = 100/100 = 1
        let a = Annotation(kind: .rect(CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.1)),
                           color: .black, lineWidth: 4)
        let out = AnnotationRenderer.composite(base, annotations: [a], selectionPointWidth: 100)
        // 上下边中点应为黑（描边中心线 y=0.45*100=45、0.55*100=55）
        let top = pixel(out, 50, 45)
        let bottom = pixel(out, 50, 55)
        XCTAssertLessThan(Int(top.0) + Int(top.1) + Int(top.2), 60)
        XCTAssertLessThan(Int(bottom.0) + Int(bottom.1) + Int(bottom.2), 60)
        // 矩形内部（非描边）与画布角落仍为白
        let inner = pixel(out, 50, 50)
        XCTAssertGreaterThan(Int(inner.0) + Int(inner.1) + Int(inner.2), 700)
        let corner = pixel(out, 5, 5)
        XCTAssertGreaterThan(Int(corner.0) + Int(corner.1) + Int(corner.2), 700)
    }

    func test_composite_emptyReturnsSameImage() {
        let base = solidImage(RGBA.white, width: 50, height: 50)
        let out = AnnotationRenderer.composite(base, annotations: [], selectionPointWidth: 50)
        XCTAssertTrue(out === base)
    }
}
