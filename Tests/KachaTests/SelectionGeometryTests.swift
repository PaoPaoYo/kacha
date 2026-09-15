import XCTest
@testable import kacha

final class SelectionGeometryTests: XCTestCase {
    // MARK: normalize

    func test_normalize_rightDownDrag() {
        let rect = SelectionGeometry.normalize(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 220))
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 100, height: 200))
    }

    func test_normalize_leftUpDrag() {
        let rect = SelectionGeometry.normalize(from: CGPoint(x: 110, y: 220), to: CGPoint(x: 10, y: 20))
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 100, height: 200))
    }

    func test_normalize_zeroWidth() {
        let rect = SelectionGeometry.normalize(from: CGPoint(x: 50, y: 10), to: CGPoint(x: 50, y: 80))
        XCTAssertEqual(rect.width, 0)
        XCTAssertEqual(rect.height, 70)
    }

    // MARK: isValid

    func test_isValid_atThreshold() {
        XCTAssertTrue(SelectionGeometry.isValid(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    func test_isValid_belowThresholdWidth() {
        XCTAssertFalse(SelectionGeometry.isValid(CGRect(x: 0, y: 0, width: 3.9, height: 100)))
    }

    func test_isValid_belowThresholdHeight() {
        XCTAssertFalse(SelectionGeometry.isValid(CGRect(x: 0, y: 0, width: 100, height: 3.9)))
    }

    // MARK: pixelRect

    func test_pixelRect_retina2x() {
        let rect = SelectionGeometry.pixelRect(
            pointRect: CGRect(x: 10, y: 20, width: 100, height: 200),
            screenPointSize: CGSize(width: 1000, height: 800),
            imagePixelSize: CGSize(width: 2000, height: 1600)
        )
        XCTAssertEqual(rect, CGRect(x: 20, y: 40, width: 200, height: 400))
    }

    func test_pixelRect_1x() {
        let rect = SelectionGeometry.pixelRect(
            pointRect: CGRect(x: 10, y: 20, width: 100, height: 200),
            screenPointSize: CGSize(width: 1000, height: 800),
            imagePixelSize: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 100, height: 200))
    }

    func test_pixelRect_clampsToImageBounds() {
        // 拖拽超出屏幕边界：clamp 到图像内
        let rect = SelectionGeometry.pixelRect(
            pointRect: CGRect(x: 990, y: 790, width: 100, height: 100),
            screenPointSize: CGSize(width: 1000, height: 800),
            imagePixelSize: CGSize(width: 2000, height: 1600)
        )
        XCTAssertEqual(rect, CGRect(x: 1980, y: 1580, width: 20, height: 20))
    }

    func test_pixelRect_nonUniformScale() {
        // 各轴比例不同（如帧被系统缩放）：独立换算
        let rect = SelectionGeometry.pixelRect(
            pointRect: CGRect(x: 100, y: 100, width: 100, height: 100),
            screenPointSize: CGSize(width: 1000, height: 800),
            imagePixelSize: CGSize(width: 3000, height: 1600)
        )
        XCTAssertEqual(rect, CGRect(x: 300, y: 200, width: 300, height: 200))
    }

    func test_pixelRect_zeroScreenSizeReturnsZero() {
        let rect = SelectionGeometry.pixelRect(
            pointRect: CGRect(x: 1, y: 1, width: 5, height: 5),
            screenPointSize: .zero,
            imagePixelSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect, .zero)
    }
}
