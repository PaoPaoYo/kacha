import AppKit
import Carbon.HIToolbox
import XCTest
@testable import kacha

final class HotKeyRecordingTests: XCTestCase {
    func test_carbonModifiersMapsCommandControlOptionAndShiftFlags() {
        let flags: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .capsLock, .function]

        XCTAssertEqual(
            HotKeyRecording.carbonModifiers(from: flags),
            UInt32(cmdKey | controlKey | optionKey | shiftKey)
        )
    }

    func test_combinationBuildsPreferencesFromKeyCodeAndEventFlags() {
        let combination = HotKeyRecording.combination(
            keyCode: 0,
            eventFlags: [.command, .control]
        )

        XCTAssertEqual(
            combination,
            HotKeyPreferences(keyCode: 0, modifiers: UInt32(cmdKey | controlKey))
        )
    }

    func test_combinationRejectsShiftOnlyShortcut() {
        XCTAssertNil(HotKeyRecording.combination(keyCode: 0, eventFlags: [.shift]))
    }
}
