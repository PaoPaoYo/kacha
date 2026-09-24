import CoreGraphics
import XCTest
@testable import kacha

final class ScrollingChromeTests: XCTestCase {
    func testCompactToolbarPreservesOriginalRightBottomAnchor() {
        let frame = ScrollingToolbarGeometry.localFrame(anchor: CGPoint(x: 416, y: 298))

        XCTAssertEqual(frame, CGRect(x: 340, y: 264, width: 76, height: 34))
    }

    func testCompactToolbarFollowsDraggedToolbarPosition() {
        let frame = ScrollingToolbarGeometry.localFrame(anchor: CGPoint(x: 220, y: 130))

        XCTAssertEqual(frame.maxX, 220)
        XCTAssertEqual(frame.maxY, 130)
    }
}
