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

    func test_compositeRendersMovedArrowAtEditedPosition() {
        let original = Annotation(
            kind: .arrow(start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.3, y: 0.1)),
            color: .red,
            lineWidth: 4
        )
        let moved = AnnotationEditor.transformed(
            original,
            target: .move,
            from: CGPoint(x: 0.2, y: 0.1),
            to: CGPoint(x: 0.5, y: 0.4)
        )

        let out = AnnotationRenderer.composite(
            solidImage(.white, width: 100, height: 100),
            annotations: [moved],
            selectionPointWidth: 100
        )

        XCTAssertRed(pixel(out, 45, 40))
        XCTAssertWhite(pixel(out, 20, 10))
    }

    func test_compositeRendersResizedEllipseAtEditedBounds() {
        let original = Annotation(
            kind: .ellipse(CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)),
            color: .blue,
            lineWidth: 4
        )
        let resized = AnnotationEditor.transformed(
            original,
            target: .resize(.right),
            from: CGPoint(x: 0.6, y: 0.4),
            to: CGPoint(x: 0.8, y: 0.4)
        )

        let out = AnnotationRenderer.composite(
            solidImage(.white, width: 100, height: 100),
            annotations: [resized],
            selectionPointWidth: 100
        )

        XCTAssertBlue(pixel(out, 80, 40))
        XCTAssertWhite(pixel(out, 60, 40))
    }

    func test_compositeRendersRestyledPenWithEditedColor() {
        let pen = Annotation(
            kind: .pen(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)]),
            color: .red,
            lineWidth: 4
        )
        let restyled = AnnotationEditor.updatingStyle(pen, color: .green, lineWidth: 8)

        let out = AnnotationRenderer.composite(
            solidImage(.white, width: 100, height: 100),
            annotations: [restyled],
            selectionPointWidth: 100
        )

        XCTAssertGreen(pixel(out, 50, 50))
        XCTAssertWhite(pixel(out, 50, 35))
    }

    func test_compositeRendersLaterAnnotationAboveEarlierAnnotation() {
        let horizontal = Annotation(
            kind: .pen(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)]),
            color: .red,
            lineWidth: 8
        )
        let vertical = Annotation(
            kind: .pen(points: [CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.8)]),
            color: .blue,
            lineWidth: 8
        )

        let out = AnnotationRenderer.composite(
            solidImage(.white, width: 100, height: 100),
            annotations: [horizontal, vertical],
            selectionPointWidth: 100
        )

        XCTAssertBlue(pixel(out, 50, 50))
        XCTAssertRed(pixel(out, 30, 50))
    }

    private func XCTAssertRed(_ value: (UInt8, UInt8, UInt8), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(Int(value.0), 220, file: file, line: line)
        XCTAssertLessThan(Int(value.1), 100, file: file, line: line)
        XCTAssertLessThan(Int(value.2), 100, file: file, line: line)
    }

    private func XCTAssertGreen(_ value: (UInt8, UInt8, UInt8), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(Int(value.0), 100, file: file, line: line)
        XCTAssertGreaterThan(Int(value.1), 150, file: file, line: line)
        XCTAssertLessThan(Int(value.2), 130, file: file, line: line)
    }

    private func XCTAssertBlue(_ value: (UInt8, UInt8, UInt8), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(Int(value.0), 80, file: file, line: line)
        XCTAssertGreaterThan(Int(value.1), 80, file: file, line: line)
        XCTAssertGreaterThan(Int(value.2), 220, file: file, line: line)
    }

    private func XCTAssertWhite(_ value: (UInt8, UInt8, UInt8), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(Int(value.0), 240, file: file, line: line)
        XCTAssertGreaterThan(Int(value.1), 240, file: file, line: line)
        XCTAssertGreaterThan(Int(value.2), 240, file: file, line: line)
    }

    func test_composite_blurRegionIgnoresColor() {
        // 底图：bitmap 顶部 40 行黑、其余白（CG 底左原点：黑块 = y 60..100）
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 60, width: 100, height: 40))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        let base = ctx.makeImage()!
        // 横向涂抹 point y=10（距黑块边缘 30px，远超 15pt 模糊半径的影响）；红色不参与模糊渲染
        let a = Annotation(kind: .blur(points: [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.8, y: 0.1)], radius: 8),
                           color: .red, lineWidth: 4)
        let out = AnnotationRenderer.composite(base, annotations: [a], selectionPointWidth: 100)
        // 涂抹区内：黑块模糊后仍近黑（实测 ~43/通道：CIGaussianBlur 有效扩散约为半径 2 倍）；
        // 阈值 300 排除红色描边染色（362）与上下镜像取到白区（765）
        let inside = pixel(out, 50, 10)
        XCTAssertLessThan(Int(inside.0) + Int(inside.1) + Int(inside.2), 300)
        // 涂抹区横向之外（x=5 不在 20..80 折线上）仍为底图黑块（clip 未外溢）
        let beside = pixel(out, 5, 10)
        XCTAssertLessThan(Int(beside.0) + Int(beside.1) + Int(beside.2), 120)
        // 黑块之外的底图白区不受影响
        let middle = pixel(out, 50, 50)
        XCTAssertGreaterThan(Int(middle.0) + Int(middle.1) + Int(middle.2), 700)
    }
}
