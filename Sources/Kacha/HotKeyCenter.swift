import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey，零第三方依赖）
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 热键签名 'KACH'
    private static let signature: FourCharCode = 0x4B_41_43_48
    private nonisolated(unsafe) static var action: (() -> Void)?
    private nonisolated(unsafe) static var scrollingEscapeAction: (() -> Void)?
    private var scrollingEscapeRef: EventHotKeyRef?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registration: Registration?

    private struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    /// 注册新热键。注册失败时尝试恢复旧热键，并报告恢复是否成功。
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void
    ) -> HotKeyRegistrationResult {
        guard installHandlerIfNeeded() else {
            return .candidateRejected(previousIsActive: registration != nil)
        }

        let previous = registration
        unregisterCurrentHotKey()

        guard let hotKeyRef = registerHotKey(keyCode: keyCode, modifiers: modifiers) else {
            return .candidateRejected(previousIsActive: restore(previous))
        }

        self.hotKeyRef = hotKeyRef
        registration = Registration(keyCode: keyCode, modifiers: modifiers, action: action)
        Self.action = action
        return .registered
    }

    func unregister() {
        unregisterCurrentHotKey()
        registration = nil
        Self.action = nil
    }

    func registerScrollingEscape(action: @escaping () -> Void) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        unregisterScrollingEscape()
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 2)
        guard RegisterEventHotKey(UInt32(kVK_Escape), 0, id,
                                  GetApplicationEventTarget(), 0, &reference) == noErr,
              let reference else { return false }
        scrollingEscapeRef = reference
        Self.scrollingEscapeAction = action
        return true
    }

    func unregisterScrollingEscape() {
        if let scrollingEscapeRef {
            UnregisterEventHotKey(scrollingEscapeRef)
            self.scrollingEscapeRef = nil
        }
        Self.scrollingEscapeAction = nil
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard id.signature == HotKeyCenter.signature else { return noErr }
            // Carbon 热键在主事件循环（主线程）派发
            MainActor.assumeIsolated {
                switch id.id {
                case 1: HotKeyCenter.action?()
                case 2: HotKeyCenter.scrollingEscapeAction?()
                default: break
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        return status == noErr
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else { return nil }
        return hotKeyRef
    }

    private func unregisterCurrentHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func restore(_ previous: Registration?) -> Bool {
        guard let previous,
              let hotKeyRef = registerHotKey(
                keyCode: previous.keyCode,
                modifiers: previous.modifiers
              ) else {
            registration = nil
            Self.action = nil
            return false
        }

        self.hotKeyRef = hotKeyRef
        registration = previous
        Self.action = previous.action
        return true
    }
}
