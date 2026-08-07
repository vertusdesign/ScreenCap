import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored in Cocoa terms and translated to Carbon
/// only at registration time.
struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// Raw value of `NSEvent.ModifierFlags`, already masked to the device-independent set.
    var modifierFlags: UInt

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(.deviceIndependentFlagsMask)
    }

    /// Carbon modifier mask used by `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        let flags = cocoaModifiers
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// A shortcut is valid if it carries at least one modifier, or is a function key
    /// (F1–F20 work unmodified, the way Lightshot uses PrtSc on Windows).
    var isValid: Bool {
        !cocoaModifiers.isEmpty || KeyCodeNames.isFunctionKey(keyCode)
    }

    var displayString: String {
        KeyCodeNames.modifierGlyphs(cocoaModifiers) + KeyCodeNames.name(for: keyCode)
    }
}

enum KeyCodeNames {
    private static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Return): "\u{21A9}",
        UInt16(kVK_Tab): "\u{21E5}",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "\u{232B}",
        UInt16(kVK_ForwardDelete): "\u{2326}",
        UInt16(kVK_Escape): "\u{238B}",
        UInt16(kVK_Home): "\u{2196}",
        UInt16(kVK_End): "\u{2198}",
        UInt16(kVK_PageUp): "\u{21DE}",
        UInt16(kVK_PageDown): "\u{21DF}",
        UInt16(kVK_LeftArrow): "\u{2190}",
        UInt16(kVK_RightArrow): "\u{2192}",
        UInt16(kVK_UpArrow): "\u{2191}",
        UInt16(kVK_DownArrow): "\u{2193}",
        UInt16(kVK_ANSI_KeypadEnter): "\u{2324}",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20"
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        guard let name = specialKeys[keyCode] else { return false }
        return name.hasPrefix("F") && name.count <= 3
    }

    static func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "\u{2303}" }
        if flags.contains(.option) { out += "\u{2325}" }
        if flags.contains(.shift) { out += "\u{21E7}" }
        if flags.contains(.command) { out += "\u{2318}" }
        return out
    }

    /// Human-readable name of a key, resolved against the *current* keyboard layout
    /// so that a shortcut shows "Ж" on a Russian layout instead of a raw code.
    static func name(for keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }
        if let translated = translate(keyCode: keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static func translate(keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
