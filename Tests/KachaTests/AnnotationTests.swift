import XCTest
@testable import kacha

final class AnnotationTests: XCTestCase {
    let sel = CGRect(x: 100, y: 50, width: 200, height: 100)

    // MARK: 归一化换算

    func test_normalizedPoint_center() {
        let n = AnnotationGeometry.normalizedPoint(CGPoint(x: 200, y: 100), in: sel)
        XCTAssertEqual(n, CGPoint(x: 0.5, y: 0.5))
    }

    func test_normalizedPoint_clampsOutside() {
        let n = AnnotationGeometry.normalizedPoint(CGPoint(x: -50, y: 400), in: sel)
        XCTAssertEqual(n, CGPoint(x: 0, y: 1))
    }

    func test_localPoint_roundTrip() {
        let n = CGPoint(x: 0.25, y: 0.75)
        let p = AnnotationGeometry.localPoint(n, in: sel)
        XCTAssertEqual(p, CGPoint(x: 150, y: 125))
        XCTAssertEqual(AnnotationGeometry.normalizedPoint(p, in: sel), n)
    }

    // MARK: 箭头头几何

    func test_arrowHeadLength_minimum10() {
        XCTAssertEqual(AnnotationGeometry.arrowHeadLength(lineWidth: 2), 10)
    }

    func test_arrowHeadLength_scalesWithWidth() {
        XCTAssertEqual(AnnotationGeometry.arrowHeadLength(lineWidth: 8), 24)
    }

    // MARK: pen 采样

    func test_penAppend_firstPointAlways() {
        XCTAssertTrue(AnnotationGeometry.shouldAppendPenPoint(CGPoint(x: 1, y: 1), after: nil))
    }

    func test_penAppend_dedup() {
        let last = CGPoint(x: 10, y: 10)
        XCTAssertFalse(AnnotationGeometry.shouldAppendPenPoint(CGPoint(x: 10.5, y: 10.5), after: last))
        XCTAssertTrue(AnnotationGeometry.shouldAppendPenPoint(CGPoint(x: 12, y: 10), after: last))
    }

    // MARK: 有效性

    func test_valid_arrowTooShort() {
        // 归一化 (0.5,0.5)→(0.52,0.5)：局部 4pt 宽、高 0 → 最长边 4pt，等于阈值判有效；再短无效
        XCTAssertFalse(AnnotationGeometry.isValid(.arrow(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.51, y: 0.5)), selectionSize: sel.size))
        XCTAssertTrue(AnnotationGeometry.isValid(.arrow(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.6, y: 0.5)), selectionSize: sel.size))
    }

    func test_valid_penNeedsTwoPoints() {
        XCTAssertFalse(AnnotationGeometry.isValid(.pen(points: [CGPoint(x: 0.5, y: 0.5)]), selectionSize: sel.size))
        XCTAssertTrue(AnnotationGeometry.isValid(.pen(points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.5)]), selectionSize: sel.size))
    }

    // MARK: path

    func test_path_rectBoundingBox() {
        let n = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let p = AnnotationGeometry.path(for: .rect(n), in: sel, lineWidth: 4)
        // rect 以中心线建 path，boundingBox 即归一化 × 选区（未做 inset——stroke 由渲染层处理）
        XCTAssertEqual(p.boundingBox, CGRect(x: 120, y: 70, width: 100, height: 30))
    }

    func test_path_ellipseBoundingBox() {
        let n = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let p = AnnotationGeometry.path(for: .ellipse(n), in: sel, lineWidth: 4)
        XCTAssertEqual(p.boundingBox, CGRect(x: 120, y: 70, width: 100, height: 30))
    }

    func test_path_arrowContainsHead() {
        let p = AnnotationGeometry.path(for: .arrow(start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5)), in: sel, lineWidth: 4)
        // 头三角在 end 附近（局部 (300, 100)），boundingBox 应覆盖到端点附近
        XCTAssertGreaterThanOrEqual(p.boundingBox.maxX, 299)
        XCTAssertLessThanOrEqual(p.boundingBox.minX, 100)
    }

    func test_path_penPolyline() {
        let p = AnnotationGeometry.path(for: .pen(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]), in: sel, lineWidth: 4)
        XCTAssertEqual(p.boundingBox, CGRect(x: 100, y: 50, width: 200, height: 100))
    }
}
