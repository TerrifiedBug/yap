import AppKit
import CoreGraphics
import XCTest

@testable import yap

/// What the recorder field does with the keys pressed into it.
///
/// The view, not the click: driving AppKit's hit-testing from a test buys
/// nothing, while the capture rules — commit a modifier on release, commit a
/// chord on key-down, refuse a bare letter, cancel on Escape — are the part
/// that can be wrong, and the part that writes to the config file.
@MainActor
final class HotkeyRecorderTests: XCTestCase {
    private func makeRecorder() -> (HotkeyRecorderView, () -> [String]) {
        let view = HotkeyRecorderView()
        var written: [String] = []
        view.onChange = { written.append($0) }
        // The same way a person arms it: a click in the field. No window is
        // needed — `mouseDown` only asks one to make it first responder.
        view.mouseDown(with: Self.mouseDown())
        return (view, { written })
    }

    private static func mouseDown() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func keyEvent(_ keyCode: CGKeyCode, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(keyCode))!
    }

    /// Built from a CGEvent so the device-specific bit survives — that bit is
    /// the only thing telling right Option from left, and `modifierFlags`
    /// does not carry it.
    private func flagsEvent(_ flags: CGEventFlags) -> NSEvent {
        let cg = CGEvent(keyboardEventSource: nil, virtualKey: 0x3D, keyDown: true)!
        cg.type = .flagsChanged
        cg.flags = flags
        return NSEvent(cgEvent: cg)!
    }

    // MARK: - modifier capture

    /// Right Option, held and let go with no key in between.
    func testHeldModifierCommitsOnRelease() {
        let (view, written) = makeRecorder()
        let rightOption = CGEventFlags(rawValue: 0x0000_0040).union(.maskAlternate)

        view.flagsChanged(with: flagsEvent(rightOption))
        XCTAssertTrue(view.isRecording, "still listening while the key is down")
        XCTAssertEqual(written(), [])

        view.flagsChanged(with: flagsEvent([]))
        XCTAssertEqual(written(), ["rightoption"])
        XCTAssertFalse(view.isRecording)
    }

    func testLeftShiftIsOfferedAndDistinctFromRight() {
        let (view, written) = makeRecorder()
        let leftShift = CGEventFlags(rawValue: 0x0000_0002).union(.maskShift)
        view.flagsChanged(with: flagsEvent(leftShift))
        view.flagsChanged(with: flagsEvent([]))
        XCTAssertEqual(written(), ["leftshift"])
    }

    // MARK: - chord capture

    func testChordCommitsOnKeyDown() {
        let (view, written) = makeRecorder()
        view.flagsChanged(with: flagsEvent([.maskCommand]))
        view.keyDown(with: keyEvent(49, modifiers: [.command, .shift]))
        XCTAssertEqual(written(), ["cmd+shift+space"])
        XCTAssertFalse(view.isRecording)
    }

    /// A lone function key is a legitimate binding: nothing types one.
    func testFunctionKeyAloneIsAccepted() {
        let (view, written) = makeRecorder()
        view.keyDown(with: keyEvent(96, modifiers: [.function]))
        XCTAssertEqual(written(), ["f5"], "the implicit Fn bit must not become part of it")
    }

    /// A bare letter would swallow every one you type. It is refused, the
    /// reason is shown, and nothing is written.
    func testBareLetterIsRefusedAndKeepsListening() {
        let (view, written) = makeRecorder()
        view.keyDown(with: keyEvent(0, modifiers: []))
        XCTAssertEqual(written(), [], "nothing written")
        XCTAssertTrue(view.isRecording, "still listening, so the next try lands")
        XCTAssertEqual(view.complaint, "needs a modifier")

        // And the next, valid, attempt still works.
        view.keyDown(with: keyEvent(0, modifiers: [.command]))
        XCTAssertEqual(written(), ["cmd+a"])
    }

    // MARK: - cancelling

    func testEscapeAloneCancelsWithoutWriting() {
        let (view, written) = makeRecorder()
        view.keyDown(with: keyEvent(53, modifiers: []))
        XCTAssertEqual(written(), [])
        XCTAssertFalse(view.isRecording)
    }

    /// Escape with a modifier is a binding like any other, so only the bare
    /// press backs out.
    func testEscapeWithAModifierIsABinding() {
        let (view, written) = makeRecorder()
        view.keyDown(with: keyEvent(53, modifiers: [.control]))
        XCTAssertEqual(written(), ["ctrl+escape"])
    }

    func testLosingFocusCancels() {
        let (view, written) = makeRecorder()
        _ = view.resignFirstResponder()
        XCTAssertFalse(view.isRecording)
        XCTAssertEqual(written(), [])
    }

    /// Keys pressed while the field is not armed belong to whatever else is
    /// on screen.
    func testIdleRecorderWritesNothing() {
        let view = HotkeyRecorderView()
        var written: [String] = []
        view.onChange = { written.append($0) }
        view.keyDown(with: keyEvent(49, modifiers: [.command, .shift]))
        XCTAssertEqual(written, [])
    }
}
