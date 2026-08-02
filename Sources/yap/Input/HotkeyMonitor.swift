import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a single modifier key (default: Fn) and emits press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
///
/// The mask is the primitive; `HotkeyMonitor.Key` names the handful of keys
/// that make sense to hold down, and is what `--hotkey` and the config file
/// speak in.
final class HotkeyMonitor {
    enum Event { case pressed, released }
    enum HotkeyError: Error { case tapCreateFailed }

    /// Mask of the modifier we treat as the hotkey. Fn = `.maskSecondaryFn`.
    private var mask: CGEventFlags
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    init(mask: CGEventFlags = .maskSecondaryFn, debug: Bool = false) {
        self.mask = mask
        self.debug = debug
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            warn(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch yap."
            )
            throw HotkeyError.tapCreateFailed
        }

        // flagsChanged only, unless debugging. handle() discards everything
        // else on the next line, so subscribing to keyDown and keyUp handed
        // an accessibility-privileged daemon the keycode of every keystroke
        // typed anywhere on the machine, passwords included, for nothing.
        var mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        if debug {
            mask |= (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    /// Swap the watched key while the tap stays up. The tap subscribes to
    /// every flagsChanged event and `handle` filters by mask, so changing the
    /// key is a field assignment — no re-registration, and no window where a
    /// press would be missed.
    func setKey(_ key: Key) {
        guard key.mask != mask else { return }
        // A press held across the swap would never see its release edge: the
        // old key's flag drops out of a mask we no longer watch. End it here.
        if isPressed {
            isPressed = false
            onEvent?(.released)
        }
        mask = key.mask
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            warn(
                "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))"
            )
        }
        guard type == .flagsChanged else { return }
        let pressed = event.flags.contains(mask)
        guard pressed != isPressed else { return }
        isPressed = pressed
        onEvent?(pressed ? .pressed : .released)
    }

    /// Called from the tap callback after macOS disables the tap.
    fileprivate func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            warn("event tap re-enabled")
        }
        guard isPressed else { return }
        isPressed = false
        DispatchQueue.main.async { [onEvent] in onEvent?(.released) }
    }
}

extension HotkeyMonitor {
    /// The modifiers worth holding a dictation press against.
    ///
    /// Only Fn has a named `CGEventFlags` constant. The right-hand variants
    /// come from the device-dependent low bits macOS packs into the same
    /// flags word (`NX_DEVICER*KEYMASK` in `IOKit/hidsystem/IOLLEvent.h`),
    /// which is the only way to tell right Shift from left Shift at this
    /// level — `.maskShift` is set by both. Left-hand variants are
    /// deliberately absent: they are the ones you actually type with.
    enum Key: String, CaseIterable {
        case fn
        case rightOption
        case rightCommand
        case rightControl
        case rightShift

        var mask: CGEventFlags {
            switch self {
            case .fn: return .maskSecondaryFn
            case .rightOption: return CGEventFlags(rawValue: 0x00000040)
            case .rightCommand: return CGEventFlags(rawValue: 0x00000010)
            case .rightControl: return CGEventFlags(rawValue: 0x00002000)
            case .rightShift: return CGEventFlags(rawValue: 0x00000004)
            }
        }

        /// Parse a user-supplied name. Case-insensitive, and separators are
        /// ignored, so "rightOption", "right-option" and "RIGHT_OPTION" all
        /// land on the same key.
        init?(name: String) {
            let wanted = Self.normalize(name)
            guard let match = Self.allCases.first(where: { Self.normalize($0.rawValue) == wanted })
            else { return nil }
            self = match
        }

        /// Every accepted name, for error messages.
        static var names: String {
            allCases.map(\.rawValue).joined(separator: ", ")
        }

        private static func normalize(_ s: String) -> String {
            s.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " }
        }
    }

    convenience init(key: Key, debug: Bool = false) {
        self.init(mask: key.mask, debug: debug)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS disables the tap when a callback runs long or a Secure Input
        // session starts. Leaving it disabled kills the hotkey for the rest of
        // the session while the daemon still looks healthy. Re-enable from the
        // tap's own run loop, and end any hold in flight, because the matching
        // key-up was never delivered.
        monitor.reenable()
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
