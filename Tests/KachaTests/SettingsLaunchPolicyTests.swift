import XCTest
@testable import kacha

@MainActor
final class SettingsLaunchPolicyTests: XCTestCase {
    func test_coldLaunchDoesNotOpenSettings() {
        XCTAssertFalse(SettingsLaunchPolicy.shouldOpenSettingsOnLaunch)
    }

    func test_coldLaunchShowsLaunchHUD() {
        XCTAssertTrue(SettingsLaunchPolicy.shouldShowLaunchHUDOnLaunch)
    }

    func test_reopenWithHiddenMenuBarIconOpensSettings() {
        XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: false))
    }

    func test_reopenWithVisibleMenuBarIconDoesNotOpenSettings() {
        XCTAssertFalse(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: true))
    }
}
