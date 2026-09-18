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
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return ""
        }

        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let layout = CFDataGetBytePtr(data) else { return "" }

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
        guard status == noErr else { return "" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
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
