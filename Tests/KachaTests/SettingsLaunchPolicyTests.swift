import XCTest
@testable import kacha

@MainActor
final class SettingsLaunchPolicyTests: XCTestCase {
    func test_coldLaunchAlwaysOpensSettings() {
        XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnLaunch)
    }

    func test_coldLaunchSchedulesSettingsAfterCurrentRunLoop() {
        let scheduled = expectation(description: "settings opening is scheduled")
        var didRun = false

        SettingsLaunchPolicy.scheduleSettingsAfterColdLaunch {
            didRun = true
            scheduled.fulfill()
        }

        XCTAssertFalse(didRun)
        wait(for: [scheduled], timeout: 1)
        XCTAssertTrue(didRun)
    }

    func test_reopenWithHiddenMenuBarIconOpensSettings() {
        XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: false))
    }

    func test_reopenWithVisibleMenuBarIconDoesNotOpenSettings() {
        XCTAssertFalse(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: true))
    }
}
