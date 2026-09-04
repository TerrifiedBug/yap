import Foundation

/// Optional user config at `~/.config/yap/config.json`:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true },
///       "mic_voice_processing": true,
///       "meeting_detection": false,
///       "meeting_auto_record": false,
///       "meeting_excluded_apps": [],
///       "on_stop": "my-hook",
///       "dictation": {
///         "model": "parakeet-tdt-ctc-110m",
///         "hotkey": "fn",
///         "tap_to_toggle": false,
///         "overlay": true,
///         "newline_after_release": false,
///         "mute_output": false
///       }
///     }
///
/// Every key is optional and CLI flags win over the file. `on_stop` is a shell
/// command spawned with the session directory as its argument — after the
/// transcript is written, or right after recording when transcription is off.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/yap/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    // MARK: - Recording

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    /// Never gates dictation: the hotkey always transcribes.
    static func transcriptionEnabled() -> Bool {
        section("transcription")?["enabled"] as? Bool ?? true
    }

    /// Whether yap offers to record when something else starts using the mic.
    /// Opt-in — omit the key and nothing watches your microphone.
    ///
    /// Never fires for a dictation press: the detector is suppressed for the
    /// length of one. Not because the press is ours — measured, yap does not
    /// appear on the mic at all — but because holding the hotkey wakes macOS's
    /// own speech daemon, which does, under a pid of its own.
    static func meetingDetectionEnabled() -> Bool {
        load()?["meeting_detection"] as? Bool ?? false
    }

    /// Record detected meetings without asking. Only meaningful with meeting
    /// detection enabled. Default off and read at each detection event.
    static func meetingAutoRecord() -> Bool {
        load()?["meeting_auto_record"] as? Bool ?? false
    }

    /// Bundle identifiers that never trigger the meeting prompt. Built by the
    /// "Ignore <App>" button on the prompt and editable in Settings.
    ///
    /// An exclusion list rather than an allowlist: detection stays fail-open,
    /// so a meeting app nobody has heard of still gets offered. Bundle ids,
    /// not names or paths — stable across renames and localization, and
    /// resolvable back to an icon and a name through `NSWorkspace`.
    static func meetingExcludedApps() -> [String] {
        load()?["meeting_excluded_apps"] as? [String] ?? []
    }


    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default on: the mic track always pairs with a system track, so
    /// without cancellation everything the other side says is transcribed
    /// twice. Routes where the voice unit delivers silence recover on their
    /// own — `MicRecorder`'s liveness check restarts capture raw within a
    /// second. Set false to record the raw mic regardless.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? true
    }

    // MARK: - Dictation

    /// Registry id of the model used for dictation. Defaults to whichever
    /// entry the registry marks recommended.
    static func dictationModel() -> String? {
        guard let id = section("dictation")?["model"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Push-to-talk binding, as `HotkeyBinding` serializes it: a modifier
    /// name like `fn`, a chord like `cmd+shift+space`, or a lone function key.
    static func hotkey() -> String? {
        guard let key = section("dictation")?["hotkey"] as? String, !key.isEmpty else { return nil }
        return key
    }

    /// Tap the hotkey to start recording and tap again to stop, instead of
    /// holding it. A press held longer than half a second still behaves like
    /// push-to-talk — release ends it — so the mode never traps a hold user
    /// with a latched-open mic. Default off.
    static func tapToToggle() -> Bool {
        section("dictation")?["tap_to_toggle"] as? Bool ?? false
    }

    /// Show the recording pill at the bottom of the screen. Default on.
    static func overlayEnabled() -> Bool {
        section("dictation")?["overlay"] as? Bool ?? true
    }

    /// Silence the speakers while the hotkey is held. Default off.
    ///
    /// The mic hears the room, and the room includes your speakers, so a video
    /// playing behind a press gets transcribed along with you. Muting the
    /// output removes it at the source.
    ///
    /// Off by default because it is audible: whatever you are listening to
    /// stops every time you speak. That is a preference rather than a fix
    /// everyone wants, and it only reaches your own default output — a second
    /// machine, or someone talking nearby, is untouched either way.
    static func muteOutputWhileDictating() -> Bool {
        section("dictation")?["mute_output"] as? Bool ?? false
    }

    /// Press Return after injecting the transcript. Handy when you dictate
    /// into chat boxes and want the message sent on release; irritating when
    /// you dictate into a document. Default off.
    static func newlineAfterRelease() -> Bool {
        section("dictation")?["newline_after_release"] as? Bool ?? false
    }

    // MARK: - Loading

    private static func section(_ key: String) -> [String: Any]? {
        load()?[key] as? [String: Any]
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            warn("warning: \(path.path) is not valid JSON — ignoring config")
            return nil
        }
        return json
    }

    /// Where recorded sessions land.
    static func resolveRoot() -> URL {
        recordingsDir() ?? defaultRoot
    }

    // MARK: - File

    /// Every value here is the built-in default, so writing this file changes
    /// nothing about how yap behaves — it exists so "Open Config File" has
    /// something to open and the watcher has something to watch. `on_stop` is
    /// left out deliberately: there is no sensible default hook.
    static let template = """
        {
          "recordings_dir": "~/Recordings",
          "transcription": { "enabled": true },
          "mic_voice_processing": true,
          "meeting_detection": false,
          "meeting_auto_record": false,
          "meeting_excluded_apps": [],
          "dictation": {
            "model": "parakeet-tdt-ctc-110m",
            "hotkey": "fn",
            "tap_to_toggle": false,
            "overlay": true,
            "newline_after_release": false,
            "mute_output": false
          }
        }

        """

    /// Create `~/.config/yap/config.json` from the template if it is missing.
    /// Failing is not fatal — the daemon runs on defaults either way, so this
    /// warns the same way a malformed config does and carries on.
    static func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try template.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            warn("warning: could not create \(path.path): \(error)")
        }
    }

    // MARK: - Writing

    /// Apply a change to the config file. The Settings window's only write
    /// path; the watcher turns the save back into a live reload.
    ///
    /// A file that does not parse is left exactly as it is. Someone is
    /// mid-edit in a text editor, and losing their work to a toggle click is
    /// far worse than a setting that does not stick.
    static func update(_ mutate: (inout [String: Any]) -> Void) {
        ensureFileExists()
        guard
            let data = try? Data(contentsOf: path),
            var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            warn("warning: \(path.path) is not valid JSON — not writing")
            return
        }
        mutate(&config)
        do {
            try serialized(config).write(to: path, atomically: true, encoding: .utf8)
        } catch {
            warn("warning: could not write \(path.path): \(error)")
        }
    }

    /// The config file as text: two-space JSON with keys in template order,
    /// so a file the GUI writes reads like the one the template writes.
    ///
    /// Everything round-trips. Keys yap has never heard of keep their values
    /// and land after the ones it has, ordered among themselves by name —
    /// hand-adding a key to this file must never be punished by a click in
    /// the Settings window.
    static func serialized(_ config: [String: Any]) -> String {
        var lines: [String] = []
        for key in inTemplateOrder(config.keys) {
            guard let value = config[key] else { continue }
            // `dictation` is the one object the template spreads over lines;
            // every other value, nested objects included, is one token.
            if key == "dictation", let section = value as? [String: Any] {
                var inner: [String] = []
                for name in inTemplateOrder(section.keys) {
                    guard let value = section[name] else { continue }
                    inner.append("    \"\(name)\": \(token(value))")
                }
                lines.append("  \"\(key)\": {\n" + inner.joined(separator: ",\n") + "\n  }")
            } else {
                lines.append("  \"\(key)\": \(token(value))")
            }
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    /// One JSON value on one line, spelled the way the template spells it.
    ///
    /// A nested object gets `{ "k": v }` rather than Foundation's
    /// `{"k":v}` — `transcription` is written this way in the template, and a
    /// GUI click should not reformat a line the user never touched.
    private static func token(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            guard !object.isEmpty else { return "{}" }
            let pairs = inTemplateOrder(object.keys).compactMap { key -> String? in
                object[key].map { "\"\(key)\": \(token($0))" }
            }
            return "{ " + pairs.joined(separator: ", ") + " }"
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }
}

/// Calls back, on the main queue, whenever the config file is saved.
///
/// kqueue through `DispatchSource`, not a poll: the kernel wakes us on a
/// write and nothing at all runs in between, which is the only kind of
/// background work this app allows.
///
/// The awkward part is that almost nothing rewrites a file in place. Editors
/// — and `String.write(atomically:)`, and `mv` — save by writing a temporary
/// file and renaming it over the target, so the descriptor we hold is left
/// pointing at the old, now-unlinked inode and goes permanently silent. The
/// `.delete`/`.rename` events are how we find out: on either one we drop the
/// source and reopen the path, which lands us on whatever inode lives there
/// now. Without that, hot reload would work exactly once. When there is
/// nothing to reopen, the directory stands in until a file turns up.
final class ConfigWatcher {
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// Only live while the file is missing. See `watchDirectory`.
    private var directory: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// Whether anything in the current debounce window replaced the inode.
    private var replaced = false

    /// The file does not have to exist: a missing one falls back to watching
    /// the directory, and arms properly the moment something creates it.
    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        if !arm() { watchDirectory() }
    }

    deinit {
        pending?.cancel()
        source?.cancel()
        directory?.cancel()
    }

    /// Open the file as it exists right now and subscribe to it.
    private func arm() -> Bool {
        // O_EVTONLY: for event delivery only, and notably does not count as a
        // reference that would keep an ejected volume busy.
        let fd = open(Config.path.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // .extend and .link are over-subscription: harmless, because the
            // debounce coalesces them, and they cover editors whose save
            // dance does not look like a plain write.
            eventMask: [.write, .delete, .rename, .extend, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let data = self.source?.data else { return }
            self.schedule(replaced: !data.isDisjoint(with: [.delete, .rename]))
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        return true
    }

    /// One save fires several events. Coalesce them, and remember whether any
    /// of them replaced the inode.
    private func schedule(replaced: Bool) {
        self.replaced = self.replaced || replaced
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func fire() {
        pending = nil
        if replaced {
            replaced = false
            source?.cancel()
            source = nil
            if !arm() { watchDirectory() }
        }
        MainActor.assumeIsolated { onChange() }
    }

    /// The file is gone. Watch its directory instead and re-arm the moment
    /// something puts one back: a rename still in flight, an editor that
    /// unlinks before it writes, or someone deleting the config and getting
    /// it back from "Open Config File". A directory kqueue costs exactly what a
    /// file one does — nothing until the kernel has news — and the
    /// alternative is hot reload staying dead until the next restart.
    private func watchDirectory() {
        guard directory == nil else { return }
        let fd = open(Config.path.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else {
            warn("cannot watch \(Config.path.path) — config changes need a restart")
            return
        }
        // .write on a directory is any entry appearing, going, or being
        // renamed. It stops as soon as the one we want appears.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.fileReappeared() }
        source.setCancelHandler { close(fd) }
        directory = source
        source.resume()
        // Closes the gap between arm() failing and this source coming up: a
        // rename that landed in between would otherwise never be noticed.
        fileReappeared()
        // Recovered in that window, so there is nothing to report.
        guard directory != nil else { return }
        warn("\(Config.path.path) is gone — running on defaults until it is back")
    }

    private func fileReappeared() {
        guard source == nil, arm() else { return }
        directory?.cancel()
        directory = nil
        // Debounced like any other change: whatever just created the file is
        // very likely still writing it, and parsing a half-written one only
        // produces a warning we would immediately contradict.
        schedule(replaced: false)
    }
}
