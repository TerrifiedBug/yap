import ApplicationServices
import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    /// Press Return at the current cursor location.
    ///
    /// A real virtual-key event rather than a "\n" appended to the injected
    /// string: chat inputs bind send to the Return *key code*, and most of
    /// them ignore a newline that arrives as a Unicode payload. Flags are
    /// cleared explicitly so a modifier still physically held at release
    /// can't turn send into insert-newline.
    static func pressReturn() {
        // kVK_Return. Hard-coded rather than importing Carbon for one constant.
        let returnKey: CGKeyCode = 36

        let down = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: true)
        down?.flags = []
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: false)
        up?.flags = []
        up?.post(tap: .cgSessionEventTap)
    }

    /// One system-wide accessibility element for the process, with a messaging
    /// timeout well under a human's patience. The default is six seconds, and
    /// these queries run on the main actor between key release and text on
    /// screen: a frontmost app that stops answering would otherwise freeze the
    /// thing you are dictating into. A timeout arrives as `.cannotComplete`,
    /// which is the same answer an app that never implements accessibility
    /// gives, so both take the keystrokes rather than the pasteboard. Set once
    /// here; it applies to every message this process sends.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    /// True when injection has somewhere to land.
    ///
    /// Synthetic key events go to whatever is focused and are silently
    /// discarded when that is nothing editable, so a transcript dictated at
    /// the desktop just disappears. Asking the accessibility API first lets
    /// the caller divert to the clipboard instead of losing it.
    ///
    /// The only question accessibility can actually answer here is "is
    /// anything focused", not "is that thing editable". An app owes the tree
    /// nothing below its window: Sublime Text reports `AXWindow` and never
    /// exposes its editor, and custom-drawn Java and Qt editors report less
    /// than that. All of them accept injected keystrokes perfectly well.
    ///
    /// So a role allow-list reads "an app I recognise", not "somewhere to
    /// type", and every app it fails to recognise loses its dictation to the
    /// pasteboard. That is the expensive direction to be wrong in: diverting
    /// destroys whatever you had copied and silently stops the feature
    /// working, while injecting into a window with no field costs one
    /// repeated press. Only a confident no is worth the pasteboard.
    static func focusedElementAcceptsText() -> Bool {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let element = focused,
              CFGetTypeID(element) == AXUIElementGetTypeID()
        else {
            // `.cannotComplete` is an app that does not answer accessibility
            // at all rather than an absent target, so it fails open like any
            // other opaque tree. Trust is checked rather than inferred: a
            // denied grant fails the same way, and injecting there would post
            // into a void with nothing left on the pasteboard to recover.
            let trusted = AXIsProcessTrusted()
            let opaque = status == .cannotComplete && trusted
            if !opaque {
                let note = "  declined: no focused element "
                    + "(AXError \(status.rawValue), trusted=\(trusted))\n"
                FileHandle.standardError.write(Data(note.utf8))
            }
            return opaque
        }
        return true
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        // Payload on the key-down only. Attaching it to key-up as well made
        // inputs that read both insert the transcript twice.
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.post(tap: .cgSessionEventTap)
    }
}
