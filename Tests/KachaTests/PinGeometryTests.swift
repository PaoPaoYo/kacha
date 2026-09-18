import XCTest
@testable import kacha

final class PinGeometryTests: XCTestCase {
    // 命中测试用矩形：minX 10, maxX 210, minY 10, maxY 110
    private let rect = CGRect(x: 10, y: 10, width: 200, height: 100)
    private let minSize = CGSize(width: 64, height: 64)
    private let bigBounds = CGSize(width: 2000, height: 2000)

    // MARK: - edge(at:in:) 边缘命中

    func test_edge_fourCorners() {
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 12, y: 12), in: rect), .topLeft)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 207, y: 12), in: rect), .topRight)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 12, y: 107), in: rect), .bottomLeft)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 207, y: 107), in: rect), .bottomRight)
    }

    func test_edge_fourSides() {
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 110, y: 12), in: rect), .top)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 110, y: 107), in: rect), .bottom)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 12, y: 60), in: rect), .left)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 207, y: 60), in: rect), .right)
    }

    func test_edge_interiorReturnsNil() {
        XCTAssertNil(PinGeometry.edge(at: CGPoint(x: 110, y: 60), in: rect))
    }

    func test_edge_outsideReturnsNil() {
        XCTAssertNil(PinGeometry.edge(at: CGPoint(x: 300, y: 60), in: rect))
        XCTAssertNil(PinGeometry.edge(at: CGPoint(x: 5, y: 60), in: rect))
        XCTAssertNil(PinGeometry.edge(at: CGPoint(x: 110, y: 200), in: rect))
    }

    func test_edge_cornerZoneWinsOverSideZones() {
        // 距左/上均 5pt：两轴都在容差内 → 判角而非任一边
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 15, y: 15), in: rect), .topLeft)
    }

    func test_edge_toleranceBoundaryInclusive() {
        let t = PinGeometry.edgeTolerance
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: rect.minX + t, y: 60), in: rect), .left)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: 110, y: rect.minY + t), in: rect), .top)
        XCTAssertEqual(PinGeometry.edge(at: CGPoint(x: rect.maxX - t, y: rect.maxY - t), in: rect), .bottomRight)
        // 超出容差 1pt → 内部
        XCTAssertNil(PinGeometry.edge(at: CGPoint(x: rect.minX + t + 1, y: 60), in: rect))
    }

    // MARK: - resized 角锚定（对角不动）

    func test_resized_bottomRightAnchorsTopLeft_widthDriven() {
        let from = CGRect(x: 100, y: 50, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 40, height: 20), edge: .bottomRight, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 100, y: 50, width: 240, height: 120))
        assertAspect(new, 2)
    }

    func test_resized_bottomRightAnchorsTopLeft_heightDriven() {
        // 角拖动以相对变化更大的轴为主轴：dy 相对 0.5 > dx 相对 0 → 高度驱动
        let from = CGRect(x: 100, y: 50, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 0, height: 50), edge: .bottomRight, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 100, y: 50, width: 300, height: 150))
        assertAspect(new, 2)
    }

    func test_resized_topLeftAnchorsBottomRight() {
        let from = CGRect(x: 100, y: 50, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: -40, height: -20), edge: .topLeft, aspect: 2, minSize: minSize, bounds: bigBounds)
        // 锚点 = 右下角 (300, 150) 不动，向左上生长
        assertFrame(new, CGRect(x: 60, y: 30, width: 240, height: 120))
        assertAspect(new, 2)
    }

    // MARK: - resized 单边锚定（对边不动，另一轴绕中线对称，等比换算）

    func test_resized_rightEdge_keepsLeftEdge() {
        let from = CGRect(x: 100, y: 100, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 50, height: 0), edge: .right, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 100, y: 87.5, width: 250, height: 125))
        assertAspect(new, 2)
    }

    func test_resized_leftEdge_keepsRightEdge() {
        let from = CGRect(x: 100, y: 100, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: -30, height: 0), edge: .left, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 70, y: 92.5, width: 230, height: 115))
        assertAspect(new, 2)
    }

    func test_resized_topEdge_keepsBottomEdge() {
        let from = CGRect(x: 100, y: 100, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 0, height: -50), edge: .top, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 50, y: 50, width: 300, height: 150))
        assertAspect(new, 2)
    }

    func test_resized_bottomEdge_keepsTopEdge() {
        let from = CGRect(x: 100, y: 100, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 0, height: 20), edge: .bottom, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 80, y: 100, width: 240, height: 120))
        assertAspect(new, 2)
    }

    // MARK: - clamp 最小尺寸

    func test_resized_minClamp_cornerShrink() {
        // 向内猛拖：高度驱动到 0 → 保比例最小解 128×64（min 64×64）
        let from = CGRect(x: 100, y: 50, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: -100, height: -100), edge: .bottomRight, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 100, y: 50, width: 128, height: 64))
        assertAspect(new, 2)
    }

    func test_resized_minClamp_edge() {
        let from = CGRect(x: 100, y: 100, width: 80, height: 40)
        let new = PinGeometry.resized(from: from, by: CGSize(width: -100, height: 0), edge: .right, aspect: 2, minSize: minSize, bounds: bigBounds)
        assertFrame(new, CGRect(x: 100, y: 88, width: 128, height: 64))
        assertAspect(new, 2)
    }

    // MARK: - clamp 屏内

    func test_resized_boundsClamp_widthDriven() {
        let from = CGRect(x: 100, y: 100, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 500, height: 0), edge: .bottomRight, aspect: 2, minSize: minSize, bounds: CGSize(width: 400, height: 300))
        assertFrame(new, CGRect(x: 100, y: 100, width: 300, height: 150))
        assertAspect(new, 2)
        XCTAssertLessThanOrEqual(new.maxX, 400)
        XCTAssertLessThanOrEqual(new.maxY, 300)
    }

    func test_resized_boundsClamp_heightDriven() {
        let from = CGRect(x: 100, y: 100, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 0, height: 400), edge: .bottomRight, aspect: 2, minSize: minSize, bounds: CGSize(width: 1000, height: 400))
        assertFrame(new, CGRect(x: 100, y: 100, width: 600, height: 300))
        assertAspect(new, 2)
        XCTAssertLessThanOrEqual(new.maxY, 400)
    }

    func test_resized_boundsClamp_topEdge_centeredX() {
        // 顶边上拖：底边固定、左右对称生长，clamp 后不越屏
        let from = CGRect(x: 400, y: 300, width: 200, height: 100)
        let new = PinGeometry.resized(from: from, by: CGSize(width: 0, height: -500), edge: .top, aspect: 2, minSize: minSize, bounds: CGSize(width: 1000, height: 800))
        assertFrame(new, CGRect(x: 100, y: 0, width: 800, height: 400))
        assertAspect(new, 2)
        XCTAssertGreaterThanOrEqual(new.minX, 0)
        XCTAssertGreaterThanOrEqual(new.minY, 0)
    }

    // MARK: - 比例保持（非整数 aspect）

    func test_resized_aspectPreserved_nonIntegerAspect() {
        let aspect: CGFloat = 1.5
        let from = CGRect(x: 0, y: 0, width: 150, height: 100)
        let grow = PinGeometry.resized(from: from, by: CGSize(width: 37, height: 13), edge: .bottomRight, aspect: aspect, minSize: minSize, bounds: bigBounds)
        assertFrame(grow, CGRect(x: 0, y: 0, width: 187, height: 187 / 1.5))
        assertAspect(grow, aspect)
        // min clamp 后仍保比例：96×64
        let shrink = PinGeometry.resized(from: from, by: CGSize(width: -300, height: -300), edge: .bottomRight, aspect: aspect, minSize: minSize, bounds: bigBounds)
        assertFrame(shrink, CGRect(x: 0, y: 0, width: 96, height: 64))
        assertAspect(shrink, aspect)
    }

    // MARK: - 断言辅助

    private func assertFrame(_ frame: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(frame.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(frame.height, expected.height, accuracy: 0.01, file: file, line: line)
    }

    private func assertAspect(_ frame: CGRect, _ aspect: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            abs(frame.width / frame.height - aspect) < 0.01,
            "比例 \(frame.width)/\(frame.height) ≠ \(aspect)",
            file: file,
            line: line
        )
    }
}
