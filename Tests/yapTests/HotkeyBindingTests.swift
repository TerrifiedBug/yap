import CoreGraphics
import XCTest

@testable import yap

/// `HotkeyBinding` is the contract between the config file, the Settings
/// recorder and the event tap. A binding that serializes to something it
/// cannot parse back is a hotkey that silently stops working after a restart,
/// which is the one failure here nobody would attribute to the right cause.
final class HotkeyBindingTests: XCTestCase {
    private func roundTrip(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let binding = HotkeyBinding(parsing: text) else {
            return XCTFail("\(text) did not parse", file: file, line: line)
        }
        XCTAssertEqual(binding.serialized, text, file: file, line: line)
        XCTAssertEqual(
            HotkeyBinding(parsing: binding.serialized), binding, file: file, line: line)
    }

    func testModifierNamesRoundTrip() {
        for name in ["fn", "rightoption", "rightcommand", "rightcontrol", "rightshift",
                     "leftoption", "leftcontrol", "leftshift"] {
            roundTrip(name)
        }
    }

    /// Every config written before free-form bindings existed says one of
    /// these, in this spelling.
    func testLegacyCamelCaseNamesStillParse() {
        XCTAssertEqual(HotkeyBinding(parsing: "rightOption"), HotkeyBinding(parsing: "rightoption"))
        XCTAssertEqual(HotkeyBinding(parsing: "RIGHT_SHIFT"), HotkeyBinding(parsing: "rightshift"))
        XCTAssertEqual(HotkeyBinding(parsing: "fn"), .fn)
    }

    func testChordsRoundTrip() {
        roundTrip("cmd+shift+space")
        roundTrip("ctrl+opt+d")
        roundTrip("f5")
        roundTrip("cmd+grave")
    }

    /// Order and spelling are normalized, so two people writing the same chord
    /// two ways get the same binding — and the file settles on one form.
    func testChordSpellingIsCanonicalized() {
        XCTAssertEqual(HotkeyBinding(parsing: "shift+command+space")?.serialized, "cmd+shift+space")
        XCTAssertEqual(HotkeyBinding(parsing: "alt+control+d")?.serialized, "ctrl+opt+d")
    }

    func testUnknownKeysSurviveAsCodes() {
        let binding = HotkeyBinding(parsing: "ctrl+key:250")
        XCTAssertEqual(binding?.serialized, "ctrl+key:250")
        XCTAssertEqual(binding?.displayName, "⌃Key 250")
    }

    func testGarbageIsRejected() {
        XCTAssertNil(HotkeyBinding(parsing: ""))
        XCTAssertNil(HotkeyBinding(parsing: "cmd+shift"))
        XCTAssertNil(HotkeyBinding(parsing: "cmd+a+b"))
        XCTAssertNil(HotkeyBinding(parsing: "middleshift"))
    }

    /// A bare letter would swallow every one you type anywhere on the machine.
    /// A function key would not, because nothing types those.
    func testBareLetterIsRefusedAndFunctionKeyIsNot() {
        let letter = try? XCTUnwrap(HotkeyBinding(parsing: "a"))
        XCTAssertEqual(letter.flatMap(HotkeyBinding.validate), "needs a modifier")
        XCTAssertNil(HotkeyBinding(parsing: "f5").flatMap(HotkeyBinding.validate))
        XCTAssertNil(HotkeyBinding(parsing: "cmd+a").flatMap(HotkeyBinding.validate))
        XCTAssertNil(HotkeyBinding.validate(.fn))
    }

    /// macOS sets the Fn bit for the whole function and navigation group
    /// whether or not 🌐 is held, so a binding that kept it could never match
    /// the event it was recorded from.
    func testImplicitFnIsStrippedFromFunctionAndArrowKeys() {
        XCTAssertEqual(HotkeyBinding(parsing: "fn+f5")?.serialized, "f5")
        XCTAssertEqual(HotkeyBinding(parsing: "fn+left")?.serialized, "left")
        XCTAssertEqual(HotkeyBinding(parsing: "fn+space")?.serialized, "fn+space")
    }

    func testDisplayNames() {
        XCTAssertEqual(HotkeyBinding(parsing: "fn")?.displayName, "Fn")
        XCTAssertEqual(HotkeyBinding(parsing: "rightoption")?.displayName, "Right ⌥")
        XCTAssertEqual(HotkeyBinding(parsing: "cmd+shift+space")?.displayName, "⌘⇧Space")
        XCTAssertEqual(HotkeyBinding(parsing: "f5")?.displayName, "F5")
        XCTAssertEqual(HotkeyBinding(parsing: "ctrl+opt+d")?.displayName, "⌃⌥D")
    }

    /// The tap shape depends on this: a modifier is a listen-only flagsChanged
    /// tap, a chord has to subscribe to keys and swallow them.
    func testOnlyChordsSubscribeToKeys() {
        XCTAssertFalse(HotkeyBinding.fn.subscribesToKeys)
        XCTAssertTrue(HotkeyBinding(parsing: "cmd+shift+space")?.subscribesToKeys ?? false)
    }

    func testUsesFnCoversBothShapes() {
        XCTAssertTrue(HotkeyBinding.fn.usesFn)
        XCTAssertTrue(HotkeyBinding(parsing: "fn+space")?.usesFn ?? false)
        XCTAssertFalse(HotkeyBinding(parsing: "rightshift")?.usesFn ?? true)
        XCTAssertFalse(HotkeyBinding(parsing: "cmd+shift+space")?.usesFn ?? true)
    }
}
