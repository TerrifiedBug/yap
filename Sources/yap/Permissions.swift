import AVFoundation
import AppKit
import ApplicationServices
import Foundation

/// The three things macOS can withhold from yap, and the shortest route to
/// each of them.
///
/// There is no report and no `yap doctor` any more: the menu bar is the
/// onboarding surface, so what used to be a printed checklist is now a row you
/// click. This is the state behind those rows — read live, because a grant can
/// arrive while the daemon runs and the whole point is to notice.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var microphone: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Ask for the microphone. macOS shows the system prompt only while the
    /// status is `.notDetermined`; once denied it answers immediately and the
    /// user has to go to Settings, which is what the menu row is for.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    /// What macOS does with the Fn (🌐) key, or nil when it does nothing —
    /// which is what a clean dictation hotkey needs.
    ///
    /// Never fatal, and never a reason to refuse a press: the tap sees Fn
    /// whatever the system does with it afterwards, so a stock mapping
    /// degrades dictation rather than breaking it. It is worth one menu row
    /// because the degradation is confusing — a Fn press that also opens the
    /// emoji picker looks like yap misbehaving.
    static func fnKeyAction() -> String? {
        guard let value = intDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType")
        else {
            // Unset: whatever macOS ships as the default may intercept it, and
            // we cannot tell which. Say so vaguely rather than not at all.
            return "another action"
        }
        guard value != 0 else { return nil }
        let uses = [1: "Change Input Source", 2: "Show Emoji & Symbols", 3: "Start Dictation"]
        return uses[value] ?? "another action"
    }

    enum Pane {
        case accessibility
        case microphone
        case keyboard

        var url: URL {
            switch self {
            case .accessibility:
                return URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )!
            case .microphone:
                return URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )!
            case .keyboard:
                return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
            }
        }
    }

    /// `NSWorkspace`, not a fork of `/usr/bin/open`: we are an AppKit app now,
    /// and spawning a process to open a URL we can open ourselves is a process
    /// for nothing.
    static func openSystemSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    /// One preference read instead of a `defaults` fork. CFPreferences goes
    /// through cfprefsd exactly as the `defaults` tool does.
    ///
    /// Both shapes accepted: System Settings writes an integer, but a domain
    /// edited by hand can hold the same value as a string.
    private static func intDefault(domain: String, key: String) -> Int? {
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        return value as? Int ?? (value as? String).flatMap(Int.init)
    }
}
