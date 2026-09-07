import AppKit
import ApplicationServices
import Darwin

/// Who is on the microphone: an identity stable enough to keep in the
/// exclusion list, and a name to put in front of the user.
struct MeetingApp {
    /// Bundle id of the outermost app bundle behind the capture client, or the
    /// identifier Core Audio attributes the stream to when there is no bundle.
    let bundleID: String
    /// What to call it on screen.
    let name: String
}

/// Who is on the microphone and what their meeting is called: an identity for
/// the capture pid, and a best-effort title from the window-owning app behind
/// it.
///
/// Cost contract: call only when prompting, accepting, or resuming after a
/// quiet gap — never from the detector poll loop or dictation path. The title
/// lookups each make a handful of AX round-trips bounded by a 0.25 second
/// timeout.
@MainActor
enum MeetingTitle {
    /// Path to the outermost app bundle holding the pid's executable.
    static func appBundlePath(forPID pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(PATH_MAX))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }

        guard let path = String(bytes: buffer[..<Int(length)], encoding: .utf8) else {
            return nil
        }
        return outermostAppBundle(in: path)
    }

    /// Identify the app behind a capture pid, for the prompt's name and the
    /// exclusion list's key. Two routes to the same answer — the outermost
    /// `.app` bundle around the client — because either one can come up empty.
    ///
    /// The executable path is free and usually enough, but it fails in both
    /// directions: `proc_pidpath` returns nothing at all for a process whose
    /// binary was replaced under it (measured on a self-updating app whose
    /// helper held the mic), and a daemon like macOS's own `corespeechd` has
    /// no `.app` around it to find.
    ///
    /// Core Audio answers where the path doesn't. It attributes every input
    /// stream to a bundle id of its own — helpers and system daemons
    /// included — and the read costs 0.02 ms. Empty only for a bare
    /// executable, which genuinely has no identity worth storing: that is the
    /// one case left with no name and no Ignore button.
    static func app(forPID pid: pid_t, audioBundleID: String?) -> MeetingApp? {
        if let app = identify(bundleAt: appBundlePath(forPID: pid)) { return app }
        guard let audioBundleID, !audioBundleID.isEmpty else { return nil }
        // Resolved through the installed copy and collapsed onto its container,
        // so a helper reads as "Google Chrome" rather than "Google Chrome
        // Helper": one Ignore then covers every helper the app starts, under
        // the same id Settings' app picker would have stored.
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: audioBundleID)
        if let app = identify(bundleAt: installed.flatMap { outermostAppBundle(in: $0.path) }) {
            return app
        }
        // A daemon: nothing installed to resolve and no name to look up, but
        // the identifier is stable, so it can still be excluded. Its last
        // component is the closest thing to a name it has.
        return MeetingApp(
            bundleID: audioBundleID,
            name: audioBundleID.components(separatedBy: ".").last ?? audioBundleID
        )
    }

    /// Bundle id and Finder name of an app bundle path, if it has both.
    private static func identify(bundleAt path: String?) -> MeetingApp? {
        guard let path, let bundleID = Bundle(path: path)?.bundleIdentifier else { return nil }
        return MeetingApp(bundleID: bundleID, name: FileManager.default.displayName(atPath: path))
    }

    /// The first `.app` on a path — the one a human would recognise, so a
    /// renderer buried in Chrome's Frameworks directory reads as Chrome.
    private static func outermostAppBundle(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let end = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...end]))
    }

    /// Best-effort meeting name from the capturing app's windows.
    static func capture(forCapturePID pid: pid_t) -> String? {
        let appPath = appBundlePath(forPID: pid)
        let app = application(forCapturePID: pid, appPath: appPath)

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let window = element(attribute, from: app) else { continue }
            if let title = title(of: window, appPath: appPath) { return title }
        }
        guard let windows = windows(of: app) else { return nil }
        return windows.lazy.compactMap { title(of: $0, appPath: appPath) }.first
    }

    /// Whether the capturing app still shows a window carrying this title.
    static func windowExists(_ title: String, forCapturePID pid: pid_t) -> Bool {
        let appPath = appBundlePath(forPID: pid)
        let app = application(forCapturePID: pid, appPath: appPath)
        // Failure is not evidence that the meeting ended. Preserve today's
        // single-session behavior rather than splitting a live recording.
        guard let windows = windows(of: app) else { return true }
        return windows.contains { self.title(of: $0, appPath: appPath) == title }
    }

    /// Folder-safe title, capped at 60 characters.
    nonisolated static func sanitized(_ title: String) -> String {
        let replaced = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let clean = String(
            replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60)
        )
        return clean.contains(where: { $0.isLetter || $0.isNumber }) ? clean : ""
    }

    private static func application(forCapturePID pid: pid_t, appPath: String?) -> AXUIElement {
        let ownerPID = appPath.flatMap { path in
            NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.path == path
            }?.processIdentifier
        } ?? pid
        let app = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return app
    }

    private static func element(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == CFArrayGetTypeID()
        else { return nil }
        return value as? [AXUIElement]
    }

    private static func title(of window: AXUIElement, appPath: String?) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        guard let title = value as? String else { return nil }
        return clean(title, appPath: appPath)
    }

    private static func clean(_ title: String, appPath: String?) -> String? {
        var clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard let appPath else { return clean }

        let appName = FileManager.default.displayName(atPath: appPath)
        for separator in [" | ", " - ", " — "] {
            let suffix = separator + appName
            if clean.hasSuffix(suffix) {
                clean.removeLast(suffix.count)
                clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard !clean.isEmpty, clean.caseInsensitiveCompare(appName) != .orderedSame else {
            return nil
        }
        return clean
    }
}
