import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// Snapshot of the config file, with every setter writing straight back.
///
/// No Apply button: a toggle here is the same act as saving the file, and the
/// daemon reloads either way. It deliberately does not watch the file while
/// open — a fresh snapshot per open is enough, and the loser of a race with a
/// text editor is whichever wrote first.
@MainActor
final class SettingsModel: ObservableObject {
    struct ExcludedApp: Identifiable {
        /// The bundle identifier, which is what the config file stores.
        let id: String
        let name: String
        /// Nil when the app is no longer installed; the row draws its own
        /// placeholder rather than the generic application icon.
        let icon: NSImage?
        /// Whether the app is still on this Mac.
        let installed: Bool
    }

    @Published var hotkey: String { didSet { writeDictation("hotkey", hotkey) } }
    @Published var tapToToggle: Bool { didSet { writeDictation("tap_to_toggle", tapToToggle) } }
    @Published var overlay: Bool { didSet { writeDictation("overlay", overlay) } }
    @Published var newlineAfterRelease: Bool {
        didSet { writeDictation("newline_after_release", newlineAfterRelease) }
    }
    @Published var muteOutput: Bool { didSet { writeDictation("mute_output", muteOutput) } }
    @Published var model: String { didSet { writeDictation("model", model) } }

    @Published var recordingsDir: String { didSet { write("recordings_dir", recordingsDir) } }
    @Published var transcriptionEnabled: Bool {
        didSet { writeTranscription("enabled", transcriptionEnabled) }
    }
    @Published var micVoiceProcessing: Bool {
        didSet { write("mic_voice_processing", micVoiceProcessing) }
    }
    /// Debounced, unlike every other control: a keystroke is not a decision,
    /// and writing per character would rewrite the file — and wake the
    /// watcher — a dozen times while someone types a command.
    @Published var onStop: String { didSet { scheduleOnStopWrite() } }

    @Published var meetingDetection: Bool { didSet { write("meeting_detection", meetingDetection) } }
    @Published var meetingAutoRecord: Bool {
        didSet { write("meeting_auto_record", meetingAutoRecord) }
    }
    @Published private(set) var excludedApps: [ExcludedApp]

    /// Suppresses the write-through while `init` fills the properties in.
    private var loading = true
    private var onStopWrite: Task<Void, Never>?

    init() {
        hotkey = HotkeyMonitor.Key(name: Config.hotkey() ?? "")?.rawValue
            ?? HotkeyMonitor.Key.fn.rawValue
        tapToToggle = Config.tapToToggle()
        overlay = Config.overlayEnabled()
        newlineAfterRelease = Config.newlineAfterRelease()
        muteOutput = Config.muteOutputWhileDictating()
        model = Config.dictationModel().flatMap { ModelRegistry.find($0)?.id }
            ?? ModelRegistry.recommended()?.id ?? ""
        recordingsDir = Self.abbreviated(Config.recordingsDir() ?? Config.defaultRoot)
        transcriptionEnabled = Config.transcriptionEnabled()
        micVoiceProcessing = Config.micVoiceProcessing()
        onStop = Config.onStop() ?? ""
        meetingDetection = Config.meetingDetectionEnabled()
        meetingAutoRecord = Config.meetingAutoRecord()
        excludedApps = Config.meetingExcludedApps().map(Self.resolve)
        loading = false
    }

    // MARK: actions

    func chooseRecordingsDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = Config.recordingsDir() ?? Config.defaultRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingsDir = Self.abbreviated(url)
    }

    func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // An app with no identifier in its Info.plist has nothing we could
        // store, and nothing to match a capture pid against later.
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        guard !excludedApps.contains(where: { $0.id == bundleID }) else { return }
        excludedApps.append(Self.resolve(bundleID))
        writeExcludedApps()
    }

    func removeExcludedApp(_ bundleID: String) {
        excludedApps.removeAll { $0.id == bundleID }
        writeExcludedApps()
    }

    func openConfigFile() {
        Config.ensureFileExists()
        // Before it opens, not after: a config written by an earlier yap has
        // no line for the settings added since, and this is the moment someone
        // is looking for them.
        Config.ensureEveryKeyPresent()
        NSWorkspace.shared.open(Config.path)
    }

    static func label(for key: HotkeyMonitor.Key) -> String {
        switch key {
        case .fn: return "Fn (Globe)"
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .rightShift: return "Right Shift ⇧"
        }
    }

    // MARK: writing

    private func write(_ key: String, _ value: Any?) {
        guard !loading else { return }
        Config.update { config in
            if let value {
                config[key] = value
            } else {
                config.removeValue(forKey: key)
            }
        }
    }

    private func writeDictation(_ key: String, _ value: Any) {
        writeSection("dictation", key, value)
    }

    private func writeTranscription(_ key: String, _ value: Any) {
        writeSection("transcription", key, value)
    }

    /// A nested key, creating the object if the file has never had one.
    private func writeSection(_ section: String, _ key: String, _ value: Any) {
        guard !loading else { return }
        Config.update { config in
            var object = config[section] as? [String: Any] ?? [:]
            object[key] = value
            config[section] = object
        }
    }

    private func writeExcludedApps() {
        write("meeting_excluded_apps", excludedApps.map(\.id))
    }

    private func scheduleOnStopWrite() {
        guard !loading else { return }
        onStopWrite?.cancel()
        let command = onStop.trimmingCharacters(in: .whitespacesAndNewlines)
        onStopWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            // An empty hook is no hook: drop the key rather than leave an
            // empty string for `Config.onStop()` to filter out forever.
            self?.write("on_stop", command.isEmpty ? nil : command)
        }
    }

    // MARK: lookups

    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Bundle id back to something a person recognises. An app that has since
    /// been deleted keeps its place in the list under its raw identifier —
    /// removing an exclusion the user cannot see is not ours to decide.
    private static func resolve(_ bundleID: String) -> ExcludedApp {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return ExcludedApp(
                id: bundleID,
                name: bundleID,
                icon: nil,
                installed: false
            )
        }
        return ExcludedApp(
            id: bundleID,
            name: FileManager.default.displayName(atPath: url.path),
            icon: NSWorkspace.shared.icon(forFile: url.path),
            installed: true
        )
    }
}
