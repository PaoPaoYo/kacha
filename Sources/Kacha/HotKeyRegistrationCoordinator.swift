import Foundation

enum HotKeyRegistrationResult {
    case registered
    case candidateRejected(previousIsActive: Bool)
}

@MainActor
final class HotKeyRegistrationCoordinator {
    static let updateFailureMessage = "无法注册该快捷键。它可能已被系统或其他应用占用。"
    static let lostHotKeyMessage = "无法注册该快捷键，且原快捷键未能恢复。请重新设置快捷键。"
    static let initialFailureMessage = "无法注册当前快捷键。它可能已被系统或其他应用占用。"

    private(set) var current: HotKeyPreferences
    private(set) var isRegistered = false
    private(set) var errorMessage: String?

    init(current: HotKeyPreferences) {
        self.current = current
    }

    func update(
        to candidate: HotKeyPreferences,
        register: (HotKeyPreferences) -> HotKeyRegistrationResult
    ) -> Bool {
        switch register(candidate) {
        case .registered:
            current = candidate
            isRegistered = true
            errorMessage = nil
            return true
        case .candidateRejected(let previousIsActive):
            isRegistered = previousIsActive
            errorMessage = previousIsActive ? Self.updateFailureMessage : Self.lostHotKeyMessage
            return false
        }
    }

    func registerInitial(
        register: (HotKeyPreferences) -> HotKeyRegistrationResult
    ) -> Bool {
        switch register(current) {
        case .registered:
            isRegistered = true
            errorMessage = nil
            return true
        case .candidateRejected(let previousIsActive):
            isRegistered = previousIsActive
            errorMessage = Self.initialFailureMessage
            return false
        }
    }
}
