import Foundation

@MainActor
final class HotKeyRegistrationCoordinator {
    static let updateFailureMessage = "无法注册该快捷键。它可能已被系统或其他应用占用。"
    static let initialFailureMessage = "无法注册当前快捷键。它可能已被系统或其他应用占用。"

    private(set) var current: HotKeyPreferences
    private(set) var errorMessage: String?

    init(current: HotKeyPreferences) {
        self.current = current
    }

    func update(
        to candidate: HotKeyPreferences,
        register: (HotKeyPreferences) -> Bool
    ) -> Bool {
        guard register(candidate) else {
            errorMessage = Self.updateFailureMessage
            return false
        }

        current = candidate
        errorMessage = nil
        return true
    }

    func registerInitial(register: (HotKeyPreferences) -> Bool) -> Bool {
        guard register(current) else {
            errorMessage = Self.initialFailureMessage
            return false
        }

        errorMessage = nil
        return true
    }
}
