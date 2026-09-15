import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey，零第三方依赖）
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 热键签名 'KACH'
    private static let signature: FourCharCode = 0x4B_41_43_48
    private nonisolated(unsafe) static var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.action = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
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
                HotKeyCenter.action?()
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
