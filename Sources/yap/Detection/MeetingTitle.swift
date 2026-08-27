import AppKit
import ApplicationServices
import Darwin

/// Best-effort meeting titles from the window-owning app behind a capture pid.
///
/// Cost contract: call only when prompting, accepting, or resuming after a
/// quiet gap — never from the detector poll loop or dictation path. Each call
/// makes a handful of AX round-trips bounded by a 0.25 second timeout.
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
