import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: a GUI over `~/.config/yap/config.json`, covering every
/// key the file has.
///
/// It is a view of the file, not a second store. Every control writes straight
/// back through `Config.update`, the existing `ConfigWatcher` turns that save
/// into a live reload, and "Open Config File" is still there for anyone who
/// would rather type. Nothing here is created until the menu item is clicked —
/// an app that spends most of its life idle does not build a settings window
/// at launch.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    /// Wide enough for a grouped form's labels and controls without the two
    /// columns colliding, narrow enough to stay a settings sheet.
    private static let width: CGFloat = 440

    static func show() {
        let window = self.window ?? make()
        // A fresh view on every open, so the form reflects the file as it is
        // now — including hand edits made since the last time it was open.
        let controller = NSHostingController(rootView: SettingsView())
        // The window owns its size, not the form. Both halves of that matter:
        // `sizingOptions = []` stops the controller pushing a preferred size,
        // and restoring the size around the swap stops AppKit collapsing the
        // window onto the form's *minimum* height — the form is taller than
        // any laptop screen and declares no ideal height of its own, so
        // without this it reopens at 320 pt with everything below Dictation
        // out of sight, and a size the user chose is thrown away too.
        controller.sizingOptions = []
        let size = window.contentRect(forFrameRect: window.frame).size
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        // We run as `.accessory`, which has no dock icon and does not become
        // active on its own. Without this the window opens behind whatever the
        // user was looking at.
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func make() -> NSWindow {
        // As tall as the screen comfortably allows. The whole form does not fit
        // on any laptop display — it scrolls — but at this height the Meetings
        // section, which is the one people open this window to reach, is on
        // screen without a scroll.
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 60
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: min(880, available)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "yap Settings"
        // NSWindow defaults to release-on-close, which over-releases under ARC
        // — and we keep this one around between opens.
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: width, height: 320)
        window.center()
        self.window = window
        return window
    }
}

// MARK: - View

private struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: $model.hotkey) {
                    ForEach(HotkeyMonitor.Key.allCases, id: \.self) { key in
                        Text(SettingsModel.label(for: key)).tag(key.rawValue)
                    }
                }
                Toggle("Tap to toggle", isOn: $model.tapToToggle)
                Toggle("Show recording pill", isOn: $model.overlay)
                Toggle("Press Return after dictating", isOn: $model.newlineAfterRelease)
                Toggle("Mute speakers while dictating", isOn: $model.muteOutput)
                Picker("Model", selection: $model.model) {
                    ForEach(ModelRegistry.shared, id: \.id) { entry in
                        Text("\(entry.displayName) · \(entry.sizeMB) MB").tag(entry.id)
                    }
                }
                Text("Applies after yap restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(model.recordingsDir)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseRecordingsDir() }
                    }
                }
                Text("Applies after yap restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Transcribe recordings automatically", isOn: $model.transcriptionEnabled)
                Toggle("Voice processing on the mic", isOn: $model.micVoiceProcessing)
                LabeledContent("Run after each recording") {
                    TextField("shell command, given the session folder", text: $model.onStop)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Meetings") {
                Toggle("Detect meetings", isOn: $model.meetingDetection)
                Toggle("Record without asking", isOn: $model.meetingAutoRecord)
                    .disabled(!model.meetingDetection)

                LabeledContent("Ignored apps") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.excludedApps.isEmpty {
                            Text("Apps you ignore never trigger a meeting prompt.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.excludedApps) { app in
                                HStack(spacing: 6) {
                                    Image(nsImage: app.icon)
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                    Text(app.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Button {
                                        model.removeExcludedApp(app.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Stop ignoring \(app.name)")
                                }
                            }
                        }
                        Button("Add App…") { model.addExcludedApp() }
                    }
                }
            }

            Section {
                Button("Open Config File") { model.openConfigFile() }
            }
        }
        .formStyle(.grouped)
        // Fills whatever the window is; the window owns the size, and the
        // grouped form scrolls when the content outgrows it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Model

/// Snapshot of the config file, with every setter writing straight back.
///
/// No Apply button: a toggle here is the same act as saving the file, and the
/// daemon reloads either way. It deliberately does not watch the file while
/// open — a fresh snapshot per open is enough, and the loser of a race with a
/// text editor is whichever wrote first.
@MainActor
private final class SettingsModel: ObservableObject {
    struct ExcludedApp: Identifiable {
        /// The bundle identifier, which is what the config file stores.
        let id: String
        let name: String
        let icon: NSImage
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
                icon: NSWorkspace.shared.icon(for: .applicationBundle)
            )
        }
        return ExcludedApp(
            id: bundleID,
            name: FileManager.default.displayName(atPath: url.path),
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
    }
}
