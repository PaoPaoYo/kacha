import XCTest
@testable import kacha

final class SettingsLayoutTests: XCTestCase {
    func test_basicSettingsWindowUsesCompactMinimumSize() {
        XCTAssertEqual(SettingsLayout.minimumWidth, 480)
        XCTAssertEqual(SettingsLayout.minimumHeight, 280)
    }
}
