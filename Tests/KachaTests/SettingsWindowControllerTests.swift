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

    func test_createdWindowUsesSettingsLayoutMinimumSize() {
        let controller = SettingsWindowController(appDelegate: AppDelegate())

        controller.show()
        let window = try! XCTUnwrap(controller.window)
        XCTAssertEqual(window.minSize.width, SettingsLayout.minimumWidth)
        XCTAssertEqual(window.minSize.height, SettingsLayout.minimumHeight)
    }
}
