import AppKit
import Carbon.HIToolbox
import XCTest
@testable import kacha

@MainActor
final class ScrollingEscapeTests: XCTestCase {
    func testEscapeCancelsOnlyWhileScrollingCaptureIsActive() throws {
        var cancellations = 0
        let hotKeys = HotKeyCenter.shared
        XCTAssertTrue(hotKeys.registerScrollingEscape { cancellations += 1 })
        defer { hotKeys.unregisterScrollingEscape() }

        try sendHotKeyEvent(id: 2)
        XCTAssertEqual(cancellations, 1)

        hotKeys.unregisterScrollingEscape()
        try sendHotKeyEvent(id: 2)
        XCTAssertEqual(cancellations, 1)
    }

    func testEscapeDiscardsScrollingCaptureBeforeFirstFrame() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let dismissed = expectation(description: "长截图会话关闭")
        let session = ScrollingCaptureSession(screen: screen, selection: CGRect(x: 0, y: 0, width: 100, height: 100),
                                              toolbarAnchor: CGPoint(x: 100, y: 120),
                                              onDismiss: { dismissed.fulfill() },
                                              onOutput: { _, _ in XCTFail("取消不应输出截图") })
        let hotKeys = HotKeyCenter.shared
        XCTAssertTrue(hotKeys.registerScrollingEscape { [weak session] in session?.cancel() })
        defer { hotKeys.unregisterScrollingEscape() }

        try sendHotKeyEvent(id: 2)
        await fulfillment(of: [dismissed], timeout: 2)
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.preview, "取消后不应留下任何已采集内容")
    }

    private func sendHotKeyEvent(id hotKeyNumber: UInt32) throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), 0, &event), noErr)
        let hotKeyEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(hotKeyEvent) }
        var hotKeyID = EventHotKeyID(signature: 0x4B_41_43_48, id: hotKeyNumber)
        XCTAssertEqual(SetEventParameter(hotKeyEvent, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size,
                                         &hotKeyID), noErr)
        XCTAssertEqual(SendEventToEventTarget(hotKeyEvent, GetApplicationEventTarget()), noErr)
    }
}
