import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted with `["active": Bool]` while the recorder is listening. The
    /// daemon suspends the hotkey tap for the duration, so recording ⌘⇧Space
    /// does not also start dictating.
    static let yapHotkeyRecording = Notification.Name("yap.hotkeyRecording")
}

/// The "click here and press a key" field, as every app with a shortcut has.
///
/// AppKit has no such control, and SwiftUI has none either — `KeyboardShortcut`
/// is for menu items, not for capturing one. So this is an NSView that takes
/// first responder and reads the events itself.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.onChange = { value = $0 }
        view.binding = HotkeyBinding(parsing: value)
        return view
    }

    func updateNSView(_ view: HotkeyRecorderView, context: Context) {
        view.onChange = { value = $0 }
        // Only when it is not mid-capture: overwriting the field while someone
        // is holding a chord down would throw their press away.
        guard !view.isRecording else { return }
        view.binding = HotkeyBinding(parsing: value)
    }
}

final class HotkeyRecorderView: NSView {
    var onChange: ((String) -> Void)?

    var binding: HotkeyBinding? {
        didSet { needsDisplay = true }
    }

    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            NotificationCenter.default.post(
                name: .yapHotkeyRecording, object: nil, userInfo: ["active": isRecording])
        }
    }

    /// A modifier held with nothing else yet. Committed on release, so holding
    /// right ⌥ and letting go binds right ⌥, while holding ⌘ and pressing
    /// Space binds the chord.
    private var heldModifier: CGEventFlags?
    /// Set once any key goes down during a capture, so releasing the modifier
    /// afterwards does not also commit it on its own.
    private var sawKey = false
    /// Shown instead of the binding for a moment when a candidate is refused.
    private var complaint: String?
    private var complaintClear: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        let field = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: field, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.textBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = complaint ?? (isRecording ? "Press keys…" : (binding?.displayName ?? "—"))
        let colour: NSColor =
            complaint != nil
            ? .systemRed : (isRecording ? .secondaryLabelColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: colour,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }

    // MARK: - capture

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        beginRecording()
    }

    private func beginRecording() {
        heldModifier = nil
        sawKey = false
        complaint = nil
        isRecording = true
    }

    private func endRecording() {
        guard isRecording else { return }
        heldModifier = nil
        sawKey = false
        isRecording = false
    }

    /// ⌘-chords never reach `keyDown`: AppKit offers them to the menu first,
    /// and ⌘W would close the Settings window instead of being recorded.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        sawKey = true
        // Escape alone cancels. With a modifier it is a legitimate binding,
        // so only the bare press backs out.
        let modifiers = Self.flags(from: event.modifierFlags)
            .intersection(HotkeyBinding.relevantFlags(for: event.keyCode))
        if event.keyCode == 53, modifiers.isEmpty {
            endRecording()
            return
        }
        let candidate = HotkeyBinding.chord(modifiers: modifiers, keyCode: event.keyCode)
        if let reason = HotkeyBinding.validate(candidate) {
            flash(reason)
            return
        }
        commit(candidate)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        // The device-specific bits, which `NSEvent.modifierFlags` does not
        // carry: only the CGEvent behind it can tell left Shift from right.
        let raw = event.cgEvent?.flags ?? []
        let held = HotkeyBinding.modifierMasks.values.first { raw.contains($0) && $0.rawValue != 0 }

        if let held, heldModifier == nil, !sawKey {
            heldModifier = held
            complaint = nil
            needsDisplay = true
            return
        }
        // Everything let go, and no key was pressed in between: the user was
        // binding the modifier itself.
        guard let candidate = heldModifier,
            raw.isDisjoint(with: HotkeyBinding.relevantFlags)
        else { return }
        heldModifier = nil
        guard !sawKey else { return }
        commit(.modifier(candidate))
    }

    private func commit(_ binding: HotkeyBinding) {
        self.binding = binding
        endRecording()
        onChange?(binding.serialized)
    }

    private func flash(_ reason: String) {
        complaint = reason
        needsDisplay = true
        complaintClear?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.complaint = nil
            self?.needsDisplay = true
        }
        complaintClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// Nothing is written on the way out: losing focus is not a decision.
    override func resignFirstResponder() -> Bool {
        endRecording()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResigned() {
        endRecording()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // A view torn down mid-capture would otherwise leave the daemon's tap
        // suspended for the rest of the session.
        if isRecording {
            NotificationCenter.default.post(
                name: .yapHotkeyRecording, object: nil, userInfo: ["active": false])
        }
    }

    private static func flags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers.contains(.command) { result.insert(.maskCommand) }
        if modifiers.contains(.shift) { result.insert(.maskShift) }
        if modifiers.contains(.control) { result.insert(.maskControl) }
        if modifiers.contains(.option) { result.insert(.maskAlternate) }
        if modifiers.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}
