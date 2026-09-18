import Carbon.HIToolbox
import Foundation

struct HotKeyPreferences: Equatable {
    static let defaultHotKey = Self(keyCode: 0, modifiers: UInt32(controlKey | cmdKey))

    var keyCode: UInt32
    var modifiers: UInt32

    var displayString: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + localizedKeyName
    }

    private var localizedKeyName: String {
        if let specialKeyName { return specialKeyName }

        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return fallbackKeyName
        }

        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let layout = CFDataGetBytePtr(data) else { return fallbackKeyName }

        guard keyCode <= UInt32(UInt16.max) else { return fallbackKeyName }

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            UnsafeRawPointer(layout).assumingMemoryBound(to: UCKeyboardLayout.self),
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return fallbackKeyName }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private var specialKeyName: String? {
        switch Int(keyCode) {
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Space: "Space"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "⎋"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_F16: "F16"
        case kVK_F17: "F17"
        case kVK_F18: "F18"
        case kVK_F19: "F19"
        case kVK_F20: "F20"
        default: nil
        }
    }

    private var fallbackKeyName: String {
        "Key \(keyCode)"
    }

    static func isValidCombination(modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let keyCode = defaults.object(forKey: "hotKeyCode") as? NSNumber,
              let modifiers = defaults.object(forKey: "hotKeyModifiers") as? NSNumber else {
            return defaultHotKey
        }
        return Self(keyCode: keyCode.uint32Value, modifiers: modifiers.uint32Value)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(keyCode, forKey: "hotKeyCode")
        defaults.set(modifiers, forKey: "hotKeyModifiers")
    }
}
