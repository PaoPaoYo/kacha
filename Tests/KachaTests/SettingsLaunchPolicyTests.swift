import XCTest
@testable import kacha

@MainActor
final class SettingsLaunchPolicyTests: XCTestCase {
    func test_coldLaunchAlwaysOpensSettings() {
        XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnLaunch)
    }

    func test_coldLaunchUsesDirectSettingsPresentation() {
        XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnLaunch)
    }

    func test_reopenWithHiddenMenuBarIconOpensSettings() {
        XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: false))
    }

    func test_reopenWithVisibleMenuBarIconDoesNotOpenSettings() {
        XCTAssertFalse(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: true))
    }
}
