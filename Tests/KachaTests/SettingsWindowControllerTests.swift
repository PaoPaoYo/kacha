import AppKit
import XCTest
@testable import kacha

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func test_showCreatesOneReusableSettingsWindow() {
        let appDelegate = AppDelegate()
        let controller = SettingsWindowController(appDelegate: appDelegate)

        controller.show()
        let firstWindow = try! XCTUnwrap(controller.window)
        controller.show()

        XCTAssertTrue(controller.window === firstWindow)
    }
}
