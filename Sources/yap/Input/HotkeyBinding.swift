import CoreGraphics
import Foundation

/// What yap listens for: a modifier held on its own, or a chord.
///
/// Two shapes rather than one, because they are genuinely different events. A
/// held modifier is a `flagsChanged` edge and nothing else on the machine can
/// tell — which is why the default is Fn, and why yap can watch for it with a
/// listen-only tap that never sees a keycode. A chord is a real key press, so
/// it has to be swallowed or the app underneath gets a stray ⌘⇧Space every
/// time you dictate.
///
/// The serialized form is what `~/.config/yap/config.json` holds and what the
/// Settings recorder writes.
enum HotkeyBinding: Equatable {
    /// One modifier, identified by its device-specific mask so left and right
    /// can be told apart.
    case modifier(CGEventFlags)
    /// A key with zero or more modifiers, device-independent.
    case chord(modifiers: CGEventFlags, keyCode: CGKeyCode)

    static let fn = HotkeyBinding.modifier(.maskSecondaryFn)

    /// Whether the tap has to subscribe to key events — and therefore whether
    /// it has to be a `.defaultTap` that can swallow them.
    var subscribesToKeys: Bool {
        if case .chord = self { return true }
        return false
    }

    /// Whether Fn is part of this binding, which is the only case where what
    /// macOS has the 🌐 key doing matters.
    var usesFn: Bool {
        switch self {
        case .modifier(let mask): return mask == .maskSecondaryFn
        case .chord(let modifiers, _): return modifiers.contains(.maskSecondaryFn)
        }
    }

    // MARK: - parsing and printing

    init?(parsing text: String) {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return nil }
        // A bare modifier name first: "fn" and "rightShift" are not chords,
        // and they are what a config file says.
        if let mask = Self.modifierMask(named: normalized) {
            self = .modifier(mask)
            return
        }

        var modifiers: CGEventFlags = []
        var key: CGKeyCode?
        for part in normalized.split(separator: "+").map(String.init) {
            if let flag = Self.chordModifiers[part] {
                modifiers.insert(flag)
                continue
            }
            // Only one key per chord: a second one is a typo, not a binding.
            guard key == nil else { return nil }
            if let code = Self.keyCodes[part] {
                key = code
            } else if part.hasPrefix("key:"), let raw = UInt16(part.dropFirst(4)) {
                key = CGKeyCode(raw)
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self = .chord(modifiers: modifiers.intersection(Self.relevantFlags(for: key)), keyCode: key)
    }

    /// The canonical text form. Round-trips through `init(parsing:)`.
    var serialized: String {
        switch self {
        case .modifier(let mask):
            return Self.modifierMasks.first { $0.value == mask }?.key ?? "fn"
        case .chord(let modifiers, let keyCode):
            var parts = Self.orderedModifiers.compactMap { name, flag in
                modifiers.contains(flag) ? name : nil
            }
            parts.append(Self.keyName(keyCode))
            return parts.joined(separator: "+")
        }
    }

    /// What a person reads: "Fn", "Right ⌥", "⌘⇧Space".
    var displayName: String {
        switch self {
        case .modifier(let mask):
            return Self.modifierLabels[serialized] ?? "\(mask.rawValue)"
        case .chord(let modifiers, let keyCode):
            let glyphs = Self.orderedModifiers.compactMap { _, flag in
                modifiers.contains(flag) ? Self.glyphs[flag.rawValue] : nil
            }.joined()
            return glyphs + Self.keyLabel(keyCode)
        }
    }

    /// Why this binding cannot be used, or nil when it can.
    ///
    /// A bare letter is the case that matters: bound alone it swallows every
    /// "a" you type anywhere on the machine. Function keys are exempt because
    /// nothing types them.
    static func validate(_ binding: HotkeyBinding) -> String? {
        switch binding {
        case .modifier:
            return nil
        case .chord(let modifiers, let keyCode):
            if !modifiers.isEmpty { return nil }
            return Self.functionKeyCodes.contains(keyCode) ? nil : "needs a modifier"
        }
    }

    // MARK: - tables

    /// Modifiers worth holding on their own, by the device-specific low bits
    /// macOS packs into the flags word (`NX_DEVICE*KEYMASK` in
    /// `IOKit/hidsystem/IOLLEvent.h`). Only Fn has a named `CGEventFlags`
    /// constant; the sided ones are the only way to tell right Shift from left
    /// Shift at this level, because `.maskShift` is set by both.
    ///
    /// These spellings are the ones already in people's config files —
    /// `HotkeyMonitor.Key` was a `String` enum and the Settings window wrote
    /// its `rawValue` — so they stay exactly as they were. Renaming them would
    /// have been a silent data migration for the sake of tidier casing, and
    /// every hotkey it failed to migrate would come back as Fn.
    ///
    /// Left Command is deliberately absent. Too much of macOS begins with it,
    /// and a dictation press that starts every ⌘-anything is a trap.
    static let modifierMasks: [String: CGEventFlags] = [
        "fn": .maskSecondaryFn,
        "rightOption": CGEventFlags(rawValue: 0x0000_0040),
        "rightCommand": CGEventFlags(rawValue: 0x0000_0010),
        "rightControl": CGEventFlags(rawValue: 0x0000_2000),
        "rightShift": CGEventFlags(rawValue: 0x0000_0004),
        "leftOption": CGEventFlags(rawValue: 0x0000_0020),
        "leftControl": CGEventFlags(rawValue: 0x0000_0001),
        "leftShift": CGEventFlags(rawValue: 0x0000_0002),
    ]

    /// Lookup by the normalized form, so a name typed into the file by hand
    /// finds its mask whatever case and separators it was written with —
    /// exactly what `HotkeyMonitor.Key.init(name:)` always did.
    static func modifierMask(named normalized: String) -> CGEventFlags? {
        modifierMasks.first { normalize($0.key) == normalized }?.value
    }

    private static let modifierLabels: [String: String] = [
        "fn": "Fn",
        "rightOption": "Right ⌥",
        "rightCommand": "Right ⌘",
        "rightControl": "Right ⌃",
        "rightShift": "Right ⇧",
        "leftOption": "Left ⌥",
        "leftControl": "Left ⌃",
        "leftShift": "Left ⇧",
    ]

    /// Device-independent bits, for chords. A chord does not care which Shift.
    static let chordModifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "fn": .maskSecondaryFn,
    ]

    /// The mask a chord is compared against, so an unrelated bit — caps lock,
    /// the non-coalesced flag — never stops a press matching.
    static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
    ]

    /// The flags worth comparing for a particular key.
    ///
    /// macOS sets the Fn bit for the whole function and navigation group
    /// whether or not the 🌐 key is held — F5 on a laptop reports it either
    /// way, and so does an arrow key. Comparing it there would either record a
    /// binding that can never match or refuse one that should.
    static func relevantFlags(for keyCode: CGKeyCode) -> CGEventFlags {
        implicitFnKeys.contains(keyCode)
            ? relevantFlags.subtracting(.maskSecondaryFn) : relevantFlags
    }

    /// Function keys, arrows, and the navigation cluster: everything macOS
    /// marks with the Fn bit on its own.
    private static let implicitFnKeys: Set<CGKeyCode> =
        functionKeyCodes.union([115, 116, 117, 119, 121, 123, 124, 125, 126])

    /// One canonical order for both the text and the glyphs, so a binding
    /// reads the same in the config file and in the menu bar.
    private static let orderedModifiers: [(String, CGEventFlags)] = [
        ("fn", .maskSecondaryFn),
        ("cmd", .maskCommand),
        ("ctrl", .maskControl),
        ("opt", .maskAlternate),
        ("shift", .maskShift),
    ]

    private static let glyphs: [UInt64: String] = [
        CGEventFlags.maskSecondaryFn.rawValue: "fn",
        CGEventFlags.maskCommand.rawValue: "⌘",
        CGEventFlags.maskControl.rawValue: "⌃",
        CGEventFlags.maskAlternate.rawValue: "⌥",
        CGEventFlags.maskShift.rawValue: "⇧",
    ]

    /// ANSI/US virtual key codes, from `Carbon/HIToolbox/Events.h`. Names, not
    /// numbers, so a config file is readable; anything not here round-trips as
    /// `key:<code>` rather than being rejected.
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "equal": 24, "minus": 27, "rightbracket": 30, "leftbracket": 33,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "quote": 39, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44,
        "period": 47, "grave": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113,
        "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119,
        "f2": 120, "pagedown": 121, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static let functionKeyCodes: Set<CGKeyCode> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    private static func keyName(_ code: CGKeyCode) -> String {
        keyCodes.first { $0.value == code }?.key ?? "key:\(code)"
    }

    private static func keyLabel(_ code: CGKeyCode) -> String {
        guard let name = keyCodes.first(where: { $0.value == code })?.key else {
            return "Key \(code)"
        }
        // Single characters read better upper-cased; the named keys read
        // better capitalized. Both are what a shortcut looks like elsewhere.
        return name.count == 1 ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Case-insensitive, and separators are ignored, so "rightOption",
    /// "right-option" and "RIGHT_OPTION" all land on the same binding.
    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " }
    }
}
