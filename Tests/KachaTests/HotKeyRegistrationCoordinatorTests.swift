import XCTest
@testable import kacha

@MainActor
final class HotKeyRegistrationCoordinatorTests: XCTestCase {
    private let previous = HotKeyPreferences(keyCode: 0, modifiers: 1)
    private let candidate = HotKeyPreferences(keyCode: 1, modifiers: 2)

    func test_updateKeepsCurrentPreferencesWhenCandidateRegistrationFails() {
        let coordinator = HotKeyRegistrationCoordinator(current: previous)

        let result = coordinator.update(to: candidate) { _ in .candidateRejected(previousIsActive: true) }

        XCTAssertFalse(result)
        XCTAssertEqual(coordinator.current, previous)
        XCTAssertEqual(coordinator.errorMessage, "无法注册该快捷键。它可能已被系统或其他应用占用。")
    }

    func test_updateCommitsCandidateAndClearsErrorWhenRegistrationSucceeds() {
        let coordinator = HotKeyRegistrationCoordinator(current: previous)
        _ = coordinator.update(to: candidate) { _ in .candidateRejected(previousIsActive: true) }

        let result = coordinator.update(to: candidate) { _ in .registered }

        XCTAssertTrue(result)
        XCTAssertEqual(coordinator.current, candidate)
        XCTAssertTrue(coordinator.isRegistered)
        XCTAssertNil(coordinator.errorMessage)
    }

    func test_updateReportsWhenCandidateFailureAlsoLeavesNoActiveHotKey() {
        let coordinator = HotKeyRegistrationCoordinator(current: previous)

        let result = coordinator.update(to: candidate) { _ in
            .candidateRejected(previousIsActive: false)
        }

        XCTAssertFalse(result)
        XCTAssertEqual(coordinator.current, previous)
        XCTAssertFalse(coordinator.isRegistered)
        XCTAssertEqual(
            coordinator.errorMessage,
            "无法注册该快捷键，且原快捷键未能恢复。请重新设置快捷键。"
        )
    }

    func test_initialRegistrationFailureReportsErrorWithoutClaimingSuccess() {
        let coordinator = HotKeyRegistrationCoordinator(current: previous)

        let result = coordinator.registerInitial { _ in .candidateRejected(previousIsActive: false) }

        XCTAssertFalse(result)
        XCTAssertEqual(coordinator.current, previous)
        XCTAssertEqual(coordinator.errorMessage, "无法注册当前快捷键。它可能已被系统或其他应用占用。")
    }
}
