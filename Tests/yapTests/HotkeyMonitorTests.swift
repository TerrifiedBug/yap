import CoreGraphics
import XCTest

@testable import yap

/// `classify` is the decision the tap makes on every keystroke the machine
/// produces, and the one place yap can break other apps: a chord that is not
/// swallowed leaks into whatever you were typing into, and one that is
/// swallowed too eagerly eats a shortcut yap has no business touching.
///
/// Real `CGEvent`s, not a stand-in, because the flags word is the thing under
/// test — `.maskNonCoalesced` and the implicit Fn bit are exactly the details a
/// hand-rolled double would get wrong.
final class HotkeyMonitorTests: XCTestCase {
    private func event(
        _ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags = []
    ) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
        event.flags = flags
        return event
    }

    private func flagsEvent(_ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x3F, keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        return event
    }

    // MARK: - held modifier

    func testFnPressAndReleaseAreEdgesAndAreNeverSwallowed() {
        let monitor = HotkeyMonitor(binding: .fn)

        let down = monitor.classify(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn))
        XCTAssertEqual(down.edge, .pressed)
        XCTAssertFalse(down.swallow)

        let up = monitor.classify(type: .flagsChanged, event: flagsEvent([]))
        XCTAssertEqual(up.edge, .released)
        XCTAssertFalse(up.swallow)
    }

    func testRepeatedFlagsWithoutAChangeAreNotEdges() {
        let monitor = HotkeyMonitor(binding: .fn)
        _ = monitor.classify(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn))
        let again = monitor.classify(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn))
        XCTAssertNil(again.edge)
    }

    /// A left-Shift binding must not fire on right Shift. Only the
    /// device-specific bit tells them apart.
    func testSidedModifiersDoNotCrossFire() {
        let leftShift = HotkeyBinding(parsing: "leftShift")!
        let monitor = HotkeyMonitor(binding: leftShift)
        let right = CGEventFlags(rawValue: 0x0000_0004).union(.maskShift)
        XCTAssertNil(monitor.classify(type: .flagsChanged, event: flagsEvent(right)).edge)

        let left = CGEventFlags(rawValue: 0x0000_0002).union(.maskShift)
        XCTAssertEqual(monitor.classify(type: .flagsChanged, event: flagsEvent(left)).edge, .pressed)
    }

    // MARK: - chord

    func testChordPressAndReleaseAreSwallowed() {
        let binding = HotkeyBinding(parsing: "cmd+shift+space")!
        let monitor = HotkeyMonitor(binding: binding)
        let flags: CGEventFlags = [.maskCommand, .maskShift]

        let down = monitor.classify(type: .keyDown, event: event(49, down: true, flags: flags))
        XCTAssertEqual(down.edge, .pressed)
        XCTAssertTrue(down.swallow, "the app underneath must not receive the chord")

        let up = monitor.classify(type: .keyUp, event: event(49, down: false, flags: flags))
        XCTAssertEqual(up.edge, .released)
        XCTAssertTrue(up.swallow)
    }

    /// Autorepeat while the chord is held is not a second press, and must not
    /// reach the app either.
    func testAutorepeatIsSwallowedWithoutAnEdge() {
        let monitor = HotkeyMonitor(binding: HotkeyBinding(parsing: "cmd+shift+space")!)
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        _ = monitor.classify(type: .keyDown, event: event(49, down: true, flags: flags))

        let repeated = event(49, down: true, flags: flags)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let result = monitor.classify(type: .keyDown, event: repeated)
        XCTAssertNil(result.edge)
        XCTAssertTrue(result.swallow)
    }

    /// Everything else on the machine has to pass through untouched. This is
    /// the assertion that stands between yap and eating other shortcuts.
    func testUnrelatedKeysAndModifierMismatchesPassThrough() {
        let monitor = HotkeyMonitor(binding: HotkeyBinding(parsing: "cmd+shift+space")!)

        let otherKey = monitor.classify(
            type: .keyDown, event: event(0, down: true, flags: [.maskCommand, .maskShift]))
        XCTAssertNil(otherKey.edge)
        XCTAssertFalse(otherKey.swallow)

        // Same key, ⌘ only: that is ⌘Space, the Spotlight shortcut.
        let wrongFlags = monitor.classify(
            type: .keyDown, event: event(49, down: true, flags: [.maskCommand]))
        XCTAssertNil(wrongFlags.edge)
        XCTAssertFalse(wrongFlags.swallow)
    }

    /// Letting go of ⌘ before Space ends the press — otherwise the mic stays
    /// open with no release edge coming.
    func testDroppingAModifierEndsTheChord() {
        let monitor = HotkeyMonitor(binding: HotkeyBinding(parsing: "cmd+shift+space")!)
        _ = monitor.classify(
            type: .keyDown, event: event(49, down: true, flags: [.maskCommand, .maskShift]))

        let result = monitor.classify(type: .flagsChanged, event: flagsEvent([.maskShift]))
        XCTAssertEqual(result.edge, .released)
        XCTAssertFalse(result.swallow, "the modifier itself is not ours to swallow")
    }

    /// A lone function key still matches when macOS sets the Fn bit for it,
    /// which it does on every laptop keyboard.
    func testFunctionKeyMatchesDespiteTheImplicitFnBit() {
        let monitor = HotkeyMonitor(binding: HotkeyBinding(parsing: "f5")!)
        let down = monitor.classify(
            type: .keyDown, event: event(96, down: true, flags: [.maskSecondaryFn]))
        XCTAssertEqual(down.edge, .pressed)
        XCTAssertTrue(down.swallow)
    }

    // MARK: - suspension

    /// While the Settings recorder is armed every keystroke belongs to it.
    func testSuspendedMonitorClassifiesNothing() {
        let monitor = HotkeyMonitor(binding: .fn)
        monitor.setSuspended(true)
        let result = monitor.classify(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn))
        XCTAssertNil(result.edge)
        XCTAssertFalse(result.swallow)
    }

    /// Suspending mid-press must not leave the monitor believing the key is
    /// still down: the next press has to read as a fresh press.
    func testSuspendingDuringAPressClearsTheHeldState() {
        let monitor = HotkeyMonitor(binding: .fn)
        _ = monitor.classify(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn))
        monitor.setSuspended(true)
        monitor.setSuspended(false)

        let again = monitor.classify(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn))
        XCTAssertEqual(again.edge, .pressed)
    }
}
