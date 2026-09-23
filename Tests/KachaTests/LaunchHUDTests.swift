import XCTest
@testable import kacha

@MainActor
final class LaunchHUDTests: XCTestCase {
    func test_panelIsClickThroughAndNeverTakesFocus() {
        let panel = LaunchHUDController.makePanel()

        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    func test_frameIsCenteredNearTopOfVisibleScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = LaunchHUDController.frame(in: screen, panelSize: CGSize(width: 280, height: 72))

        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screen.maxY - 56, accuracy: 0.001)
    }

    func test_successPresentationAdvertisesRegisteredShortcut() {
        let presentation = LaunchHUDController.presentation(
            hotKey: .defaultHotKey,
            hotKeyErrorMessage: nil
        )
        XCTAssertEqual(presentation.title, "咔嚓已启动")
        XCTAssertTrue(presentation.message.contains(HotKeyPreferences.defaultHotKey.displayString))
        XCTAssertFalse(presentation.isWarning)
    }

    func test_hotKeyFailurePresentationDoesNotAdvertiseBrokenShortcut() {
        let presentation = LaunchHUDController.presentation(
            hotKey: .defaultHotKey,
            hotKeyErrorMessage: "注册失败"
        )
        XCTAssertEqual(presentation.title, "咔嚓已启动")
        XCTAssertEqual(presentation.message, "快捷键注册失败，请打开设置")
        XCTAssertTrue(presentation.isWarning)
    }
}
