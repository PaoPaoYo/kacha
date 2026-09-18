import XCTest
@testable import kacha

@MainActor
final class HotKeyRegistrationCoordinatorTests: XCTestCase {
    private let previous = HotKeyPreferences(keyCode: 0, modifiers: 1)
    private let candidate = HotKeyPreferences(keyCode: 1, modifiers: 2)

    func test_updateKeepsCurrentPreferencesWhenCandidateRegistrationFails() {
        let coordinator = HotKeyRegistrationCoordinator(current: previous)

        let result = coordinator.update(to: candidate) { _ in false }

        XCTAssertFalse(result)
        XCTAssertEqual(coordinator.current, previous)
        XCTAssertEqual(coordinator.errorMessage, "无法注册该快捷键。它可能已被系统或其他应用占用。")
    }

    func test_updateCommitsCandidateAndClearsErrorWhenRegistrationSucceeds() {
        let coordinator = HotKeyRegistrationCoordinator(current: previous)
        _ = coordinator.update(to: candidate) { _ in false }

        let result = coordinator.update(to: candidate) { _ in true }

        XCTAssertTrue(result)
        XCTAssertEqual(coordinator.current, candidate)
        XCTAssertNil(coordinator.errorMessage)
    }

    func test_initialRegistrationFailureReportsErrorWithoutClaimingSuccess() {
        let coordinator = HotKeyRegistrationCoordinator(current: previous)

        let result = coordinator.registerInitial { _ in false }

        XCTAssertFalse(result)
        XCTAssertEqual(coordinator.current, previous)
        XCTAssertEqual(coordinator.errorMessage, "无法注册当前快捷键。它可能已被系统或其他应用占用。")
    }
}
