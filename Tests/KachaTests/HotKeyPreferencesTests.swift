import Carbon.HIToolbox
import XCTest
@testable import kacha

final class HotKeyPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HotKeyPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_loadReturnsDefaultHotKeyWhenNoPreferenceWasSaved() {
        let preferences = HotKeyPreferences.load(defaults: defaults)

        XCTAssertEqual(preferences.keyCode, 0)
        XCTAssertEqual(preferences.modifiers, UInt32(controlKey | cmdKey))
    }

    func test_defaultHotKeyRoundTripsThroughIsolatedDefaults() {
        HotKeyPreferences.defaultHotKey.save(defaults: defaults)

        XCTAssertEqual(HotKeyPreferences.load(defaults: defaults), .defaultHotKey)
    }

    func test_saveOverwritesPreviouslySavedHotKey() {
        HotKeyPreferences(keyCode: 0, modifiers: UInt32(cmdKey)).save(defaults: defaults)
        HotKeyPreferences(keyCode: 1, modifiers: UInt32(optionKey | shiftKey)).save(defaults: defaults)

        XCTAssertEqual(
            HotKeyPreferences.load(defaults: defaults),
            HotKeyPreferences(keyCode: 1, modifiers: UInt32(optionKey | shiftKey))
        )
    }

    func test_displayStringUsesControlAndCommandSymbolsBeforeKeyName() {
        let preferences = HotKeyPreferences(keyCode: 0, modifiers: UInt32(controlKey | cmdKey))

        XCTAssertEqual(preferences.displayString, "⌃⌘A")
    }

    func test_displayStringUsesOptionAndShiftSymbolsBeforeKeyName() {
        let preferences = HotKeyPreferences(keyCode: 1, modifiers: UInt32(optionKey | shiftKey))

        XCTAssertEqual(preferences.displayString, "⌥⇧S")
    }

    func test_isValidCombinationRejectsNoModifiers() {
        XCTAssertFalse(HotKeyPreferences.isValidCombination(modifiers: 0))
    }

    func test_isValidCombinationAcceptsCommandModifier() {
        XCTAssertTrue(HotKeyPreferences.isValidCombination(modifiers: UInt32(cmdKey)))
    }

    func test_isValidCombinationAcceptsControlModifier() {
        XCTAssertTrue(HotKeyPreferences.isValidCombination(modifiers: UInt32(controlKey)))
    }
}
