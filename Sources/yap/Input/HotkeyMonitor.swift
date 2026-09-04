import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches the configured binding and emits press/release edges. Requires
/// Accessibility permission; `start()` throws when the grant is missing, and
/// the daemon puts a row in the menu bar rather than exiting.
///
/// `HotkeyBinding` is what it speaks in — see that file for the two shapes and
/// why they are different.
final class HotkeyMonitor {
    enum Event { case pressed, released }
    enum HotkeyError: Error { case tapCreateFailed }

    private var binding: HotkeyBinding
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    /// Set while the Settings recorder is armed. Every keystroke then belongs
    /// to the recorder, and a press that also started dictation would record
    /// the user saying "what". See `setSuspended`.
    private var suspended = false

    init(binding: HotkeyBinding, debug: Bool = false) {
        self.binding = binding
        self.debug = debug
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        // Asking is the caller's job now: the daemon raises the system prompt
        // once at first launch and watches for the grant, so a tap that cannot
        // be created here is simply reported and retried when the box is
        // ticked. `tapCreate` returns nil without the grant.
        guard AXIsProcessTrusted() else { throw HotkeyError.tapCreateFailed }
        try createTap()
    }

    func stop() {
        teardownTap()
        onEvent = nil
    }

    /// Swap the binding while the daemon runs.
    ///
    /// Cheap when the shape is unchanged — the tap subscribes to the same
    /// events and `classify` filters — and a full re-create when it is not,
    /// because a chord needs key events and the ability to swallow them while
    /// a bare modifier needs neither. The re-create raises no prompt: the
    /// grant is already held by the time any of this can happen.
    func setBinding(_ new: HotkeyBinding) {
        guard new != binding else { return }
        // A press held across the swap would never see its release edge: the
        // old binding's key is one we no longer watch. End it here.
        if isPressed {
            isPressed = false
            onEvent?(.released)
        }
        let shapeChanged = new.subscribesToKeys != binding.subscribesToKeys
        binding = new
        guard shapeChanged, tap != nil else { return }
        teardownTap()
        do {
            try createTap()
        } catch {
            warn("failed to re-register hotkey tap for \(new.serialized): \(error)")
        }
    }

    /// Stand down without tearing the tap down. The Settings recorder holds
    /// this for as long as it is listening for a new binding.
    func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        guard on, isPressed else { return }
        isPressed = false
        onEvent?(.released)
    }

    // MARK: -

    private func createTap() throws {
        var mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        // flagsChanged only, unless the binding is a chord or we are
        // debugging. Subscribing to keyDown and keyUp hands an
        // accessibility-privileged daemon the keycode of every keystroke typed
        // anywhere on the machine, passwords included — worth it only when the
        // binding genuinely is a key, and even then the keycode is compared
        // and dropped, never logged outside --debug-hotkey.
        if binding.subscribesToKeys || debug {
            mask |= (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        }
        // A chord has to be swallowed, and only a .defaultTap can do that. A
        // held modifier is passed straight through, so it stays listen-only —
        // byte-identical to what yap has always installed for Fn.
        let options: CGEventTapOptions = binding.subscribesToKeys ? .defaultTap : .listenOnly
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
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

    private func teardownTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    /// Decide what an event means, and whether the app underneath should see
    /// it. Runs synchronously on the tap's own callback, because a swallow
    /// decision cannot be made after the event has already been passed on.
    ///
    /// Internal rather than fileprivate so the decision table can be tested
    /// against real `CGEvent`s; every other member of this class stays private.
    func classify(type: CGEventType, event: CGEvent) -> (edge: Event?, swallow: Bool) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            warn(
                "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))"
            )
        }
        guard !suspended else { return (nil, false) }

        switch binding {
        case .modifier(let mask):
            guard type == .flagsChanged else { return (nil, false) }
            let pressed = event.flags.contains(mask)
            guard pressed != isPressed else { return (nil, false) }
            isPressed = pressed
            // Never swallowed: the tap is listen-only, and a held modifier is
            // something other apps are entitled to see.
            return (pressed ? .pressed : .released, false)

        case .chord(let modifiers, let keyCode):
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            switch type {
            case .keyDown:
                guard code == keyCode,
                    event.flags.intersection(HotkeyBinding.relevantFlags(for: keyCode)) == modifiers
                else { return (nil, false) }
                // Autorepeat while held is not a second press, but it must not
                // reach the app either.
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !isPressed else {
                    return (nil, true)
                }
                isPressed = true
                return (.pressed, true)
            case .keyUp:
                guard code == keyCode, isPressed else { return (nil, false) }
                isPressed = false
                return (.released, true)
            case .flagsChanged:
                // Letting go of ⌘ before Space ends the press. Not swallowed:
                // the modifier itself is not ours.
                guard isPressed, !event.flags.contains(modifiers) else { return (nil, false) }
                isPressed = false
                return (.released, false)
            default:
                return (nil, false)
            }
        }
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

    fileprivate func deliver(_ edge: Event) {
        DispatchQueue.main.async { [onEvent] in onEvent?(edge) }
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

    // Classification is synchronous — the swallow decision is this function's
    // return value and cannot be deferred — while the work it triggers still
    // hops to the main queue, so nothing the daemon does can stall the tap
    // into being disabled for running long.
    let (edge, swallow) = monitor.classify(type: type, event: event)
    if let edge { monitor.deliver(edge) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
