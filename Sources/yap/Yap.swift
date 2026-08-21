import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

@main
struct Yap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yap",
        abstract:
            "Hold a key, speak, release. On-device dictation, plus a meeting recorder that shares the same loaded model.",
        // The single source of truth for what this binary is. Nothing else
        // holds a version constant, and the release workflow greps this
        // literal against the tag, so a build can never claim the wrong one.
        version: "0.1.8",
        subcommands: [
            Run.self, Start.self, Stop.self, Record.self, Models.self, Doctor.self, Setup.self,
            Install.self, Bench.self,
        ],
        defaultSubcommand: Run.self
    )
}

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon in the foreground."
    )

    @Option(name: .long, help: "Model id to use. Defaults to the configured, then recommended, model.")
    var model: String?

    @Option(name: .long, help: "Push-to-talk key: \(HotkeyMonitor.Key.names).")
    var hotkey: String?

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Flag(name: .long, help: "Press Return after injecting the transcript.")
    var newline: Bool = false

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(
        name: .long,
        help: """
            Write the transcript text to the log as well as its length. Off by \
            default, and the LaunchAgent never passes it, because the log \
            outlives the session.
            """
    )
    var echoTranscripts: Bool = false

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        // Before anything else, because it can replace the process image and
        // everything below would then run twice. See the function.
        Self.reexecInsideAppBundle()

        // First, before anything this run says can land in them: under
        // launch-at-login these two files are the only record of what
        // happened, and they are also the only thing here that grows without
        // bound.
        Paths.trimOversizedLogs()

        let chosenModel = try Resolve.model(model)
        let key = try Resolve.hotkey(hotkey)
        let root = Config.resolveRoot(cliOverride: nil)
        // Outside the doctor block on purpose: that report is skipped entirely
        // by the installed LaunchAgent, and even when it runs it only prints
        // on a hard failure.
        Resolve.warnIfSessionsUnsupported(chosenModel)

        if !skipDoctor {
            try checkStartup(root: root, model: chosenModel, hotkey: key)
        }

        // After the flags, the config and the doctor report have all had their
        // say, so a typo or a missing grant never costs someone the daemon
        // they already had — and before the model loads, so a takeover never
        // holds two copies of it in memory at once.
        guard DaemonLock.claim() else { throw ExitCode.success }

        // One model, loaded once, before anything can ask for it. Warming up
        // front is the difference between a 60 ms press and a press that waits
        // out an ANE compile.
        if !ModelStore.isDownloaded(chosenModel) {
            warn("downloading \(chosenModel.id) (~\(chosenModel.sizeMB) MB) — one-off")
        }
        let transcriber = chosenModel.makeTranscriber()
        do {
            try runBlocking { try await transcriber.warmUp() }
        } catch {
            warn("warmup failed: \(error)")
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let daemon = Daemon(
            transcriber: transcriber,
            model: chosenModel,
            root: root,
            hotkey: key,
            cliModel: model,
            cliHotkey: hotkey,
            noOverlay: noOverlay,
            newlineFlag: newline,
            echoTranscripts: echoTranscripts,
            debugHotkey: debugHotkey
        )
        try daemon.start()
        // NSApplication holds its delegate weakly; `daemon` stays alive
        // because this frame does, and app.run() never leaves it.
        app.delegate = daemon

        let sources = interruptSources {
            warn("\nshutting down")
            // The source fires on the main queue, so this is already the main
            // actor — the handler's own signature just can't say so.
            //
            // Everything live is torn down in applicationWillTerminate,
            // which Cmd-Q and the menu's Quit item also route through.
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }

        var banner =
            "listening on \(key.rawValue) \(Config.tapToToggle() ? "tap" : "hold") · \(chosenModel.id)"
        if Config.meetingDetectionEnabled() {
            banner += " · watching for meetings → \(root.path)"
        }
        banner += " · ^C to quit"
        warn(banner)

        // Hold the signal sources: they are cancelled when released, and a
        // cancelled source with the default disposition already ignored means
        // ^C and launchd stop would both do nothing.
        withExtendedLifetime(sources) { app.run() }
    }

    /// Re-exec through the real binary inside the .app when we were started
    /// through a symlink, so LaunchServices has an identity to publish.
    ///
    /// Homebrew's `/opt/homebrew/bin/yap` is a symlink into the bundle, and
    /// CFBundle derives `Bundle.main` from the path we were *exec'd with*, not
    /// the path that resolves to. Through the shim the main bundle is
    /// `/opt/homebrew/bin`, which is not a bundle, and LaunchServices then
    /// registers us with no bundle identifier: `lsappinfo info -only bundleid`
    /// answers `[ NULL ]` while still reporting
    /// `LSBundlePath=/Applications/yap.app`.
    ///
    /// That splits the menu bar icon in two. Thaw — the maintained Ice fork,
    /// and what this was measured against — names each item
    /// `<owner>:<status item autosave name>`, the owner being the owning
    /// process's bundle identifier when it has one and its process name when it
    /// does not. So the daemon is `yap:Item-0` while the same build launched
    /// from /Applications is `com.terrifiedbug.yap:Item-0` — one app, two
    /// identities, each with a section remembered separately. Both keys were
    /// sitting in its hidden section, and that is self-sustaining: with "new
    /// items appear in hidden" set, an item it has no section for is
    /// cmd-dragged there, AppKit persists the drag as our own saved position —
    /// 430 rewritten to 5518, measured — and we come back hidden on the next
    /// launch.
    ///
    /// Do not test `Bundle.main.bundleIdentifier` here. This binary carries its
    /// own `__TEXT,__info_plist` (Package.swift, so TCC can attribute the
    /// grants), so in-process it answers `com.terrifiedbug.yap` either way —
    /// measured, after it sent one debugging pass down the wrong road. The
    /// question LaunchServices actually asks is whether we were exec'd from
    /// inside a bundle, and the main bundle's path is the answer.
    ///
    /// The grants survive: TCC keys them on the code signature and that
    /// embedded identifier, so the microphone is recorded against
    /// `com.terrifiedbug.yap` and not against a path, and swapping the daemon
    /// onto the bundled path kept the event tap working. `execv` keeps the pid,
    /// so launchd sees one process throughout.
    private static func reexecInsideAppBundle() {
        guard !Bundle.main.bundlePath.hasSuffix(".app"),
            let running = Bundle.main.executablePath
        else { return }

        // Only worth doing when the far side is genuinely a bundled executable:
        // a plain `swift build` binary has no identity to recover. `real` is
        // fully resolved, so it is also what stops this exec'ing in a loop —
        // the second image resolves to the path it was started with.
        let real = URL(fileURLWithPath: running).resolvingSymlinksInPath()
        let contents = real.deletingLastPathComponent().deletingLastPathComponent()
        guard real.path != running,
            contents.lastPathComponent == "Contents",
            FileManager.default.fileExists(
                atPath: contents.appendingPathComponent("Info.plist").path)
        else { return }

        // Our own argv, untouched: `Bundle.main` comes from the exec'd path
        // rather than from `argv[0]`, so there is nothing to rewrite. `ps` will
        // keep showing the symlink in argv[0] while the image is the bundled
        // one.
        execv(real.path, CommandLine.unsafeArgv)

        // Only reachable if the exec failed, which is not fatal: yap carries on
        // under the process-name identity LaunchServices gives it, exactly as it
        // did before this existed.
        warn("note: couldn't re-exec via \(real.path): \(String(cString: strerror(errno)))")
    }

    /// The startup report, and what to do when it fails.
    ///
    /// Nobody reads that report when Finder or launchd started us — stderr is
    /// a log file, and the window the user double-clicked has already gone —
    /// so a first run with a permission missing looks exactly like nothing
    /// happening. The notification is the only thing they will see. A terminal
    /// run is left alone: the report is already on screen, and a notification
    /// saying the same thing is noise.
    private func checkStartup(
        root: URL, model: TranscriptionModel, hotkey: HotkeyMonitor.Key
    ) throws {
        let checks = DoctorReport.run(recordingsRoot: root, model: model, hotkey: hotkey)
        guard !DoctorReport.allOK(checks) else { return }
        warn("startup checks failed:")
        DoctorReport.print(checks)
        warn("\nfix the above or pass --skip-doctor")
        if isatty(STDERR_FILENO) == 0, let failed = DoctorReport.firstFailure(checks) {
            notifyUser(
                title: "yap can't start — \(failed.name)",
                body: failed.remediation ?? "run `yap doctor` in a terminal"
            )
        }
        throw ExitCode(1)
    }
}

/// The daemon: one hotkey, one menu bar, one loaded model, and — when meeting
/// detection is on — one recording session at a time.
///
/// Both halves live here rather than in two controllers because they share
/// more than they don't: the same transcriber, the same menu-bar state line,
/// and the same microphone. Keeping them together is what lets a dictation
/// press and a meeting recording sit next to each other without either one
/// noticing the other.
@MainActor
final class Daemon: NSObject, NSApplicationDelegate {
    private let transcriber: any Transcriber
    private let coordinator: TranscriptionCoordinator
    private let root: URL
    private let monitor: HotkeyMonitor
    private let capture = AudioCapture()
    private let overlay: RecordingOverlay?
    private let menuBar: MenuBarController
    private var detector: MeetingDetector?
    /// `--newline` only. The config's own `newline_after_release` is read at
    /// the point of use instead, so it can be flipped without a restart.
    private let newlineFlag: Bool
    /// The raw CLI overrides, kept so a config reload can re-run the same
    /// flag-beats-file-beats-default precedence the daemon booted with.
    private let cliModel: String?
    private let cliHotkey: String?
    /// The model actually loaded, for the "restart to pick it up" warning.
    private let loadedModelID: String
    private var configWatcher: ConfigWatcher?
    /// Opt-in. See the doc comment where it is used.
    private let echoTranscripts: Bool

    /// True from a successful capture start until the transcript has been
    /// injected. It guards the release edge — a failed `capture.start()` must
    /// not look like a press — and stops a session transcript finishing in the
    /// background from clearing the indicator out from under a live press.
    private var dictating = false
    /// True while the capture engine is live — a press, or a latched tap, in
    /// flight. Distinct from `dictating`, which stays true through the
    /// transcription that follows and only guards the indicator.
    private var recording = false
    /// When the live press started, for telling a tap from a hold in toggle
    /// mode.
    private var pressStartedAt = Date.distantPast
    /// Whether the live press latches (`tap_to_toggle` read at its key-down).
    /// Decided once per press, same reasoning as `overlayShown`: a config
    /// saved mid-press must not change what the release edge means.
    private var pressLatches = false
    /// Monotonic press id. finishDictation only cleans up for its own press,
    /// so a completion racing a newer press cannot tear down that press's
    /// state.
    private var pressGeneration = 0
    /// Longer than this and a toggle-mode press is a hold, not a tap.
    private static let tapThreshold: TimeInterval = 0.5
    /// Pending lift of the detector's dictation suppression. Held so a new
    /// press can cancel the previous press's timer.
    private var unsuppress: DispatchWorkItem?
    /// Whether this press is showing the pill. Decided once, at the press, so
    /// a config saved mid-press cannot strand it.
    private var overlayShown = false

    private var session: RecordingSession?
    /// Whether the live session was started by the meeting prompt rather than
    /// by hand. Only those stop themselves when the call ends — silently
    /// ending a recording someone started deliberately would lose audio they
    /// asked for.
    private var autoStarted = false

    init(
        transcriber: any Transcriber,
        model: TranscriptionModel,
        root: URL,
        hotkey: HotkeyMonitor.Key,
        cliModel: String?,
        cliHotkey: String?,
        noOverlay: Bool,
        newlineFlag: Bool,
        echoTranscripts: Bool,
        debugHotkey: Bool
    ) {
        self.transcriber = transcriber
        self.root = root
        self.cliModel = cliModel
        self.cliHotkey = cliHotkey
        self.loadedModelID = model.id
        self.newlineFlag = newlineFlag
        self.echoTranscripts = echoTranscripts
        self.monitor = HotkeyMonitor(key: hotkey, debug: debugHotkey)
        // --no-overlay is the only thing that removes the panel outright. The
        // config's own toggle is read per press, so it can be flipped while
        // the daemon runs.
        self.overlay = noOverlay ? nil : RecordingOverlay()
        self.menuBar = MenuBarController(
            modelID: model.id,
            hotkeyName: hotkey.rawValue,
            tapToToggle: Config.tapToToggle()
        )
        // Opt-in, and it only ever fires for *other* processes: the detector
        // skips its own pid. Dictation therefore no longer prompts you to
        // record yourself, which it did back when the two halves were separate
        // binaries and holding the hotkey looked to the recorder like a call
        // starting.
        self.detector = Config.meetingDetectionEnabled() ? MeetingDetector() : nil
        // The whole point of the merge: the session queue transcribes through
        // the same warm model dictation uses, so the machine never holds two
        // copies of it. Passing it in also tells the coordinator not to
        // release it — the daemon keeps its model hot.
        self.coordinator = TranscriptionCoordinator(transcriber: transcriber)
        super.init()
    }

    func start() throws {
        menuBar.onStartRecording = { [weak self] in self?.startSession() }
        menuBar.onStopRecording = { [weak self] in self?.stopSession() }
        menuBar.setIdle()

        do {
            try monitor.start { [weak self] event in
                // The tap callback has already hopped to the main queue.
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } catch {
            // launchd relaunches anything exiting non-zero (KeepAlive
            // SuccessfulExit:false). A missing Accessibility grant is not a
            // transient failure — it is a box only the user can tick, and
            // retrying changes nothing. Exiting 1 here is precisely what turns
            // launch-at-login into a relaunch loop, so say what is wrong and
            // exit cleanly. The agent stays down until the grant exists and
            // the next login (or `launchctl kickstart`) starts it again.
            //
            // --skip-doctor does NOT cover this: it only skips the startup
            // report above, while the tap still fails here.
            if !AXIsProcessTrusted() {
                warn("accessibility not granted — yap cannot see the hotkey.")
                warn(
                    "grant it in System Settings → Privacy & Security → Accessibility, "
                        + "then run `yap start`.")
                // Naming the command matters. This process exits 0 so KeepAlive
                // leaves it alone, which means ticking the box changes nothing
                // by itself and the next login would otherwise be the only
                // thing that brings the agent back.
                notifyUser(
                    title: "yap needs Accessibility",
                    body: "Grant it in Privacy & Security, then run `yap start`."
                )
                throw ExitCode.success
            }
            warn("failed to register hotkey tap: \(error)")
            warn("run `yap setup` to configure permissions.")
            throw ExitCode(1)
        }

        if let detector {
            wire(detector)
            detector.start()
        }

        Task { [coordinator, root] in
            // The handler fires on whatever executor the coordinator drains
            // on, so hop back before touching the menu bar. Weak, or the
            // coordinator would own the daemon that owns it.
            await coordinator.setStatusHandler { [weak self] busy in
                Task { @MainActor in self?.show(busy: busy) }
            }
            await coordinator.setTranscriptReadyHandler { dir in
                // Fires on the coordinator's executor; hop to the main actor
                // for AppKit.
                Task { @MainActor in
                    showToast(
                        title: "Transcript ready",
                        body: dir.lastPathComponent,
                        button: "Open"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [dir.appendingPathComponent("transcript.md")]
                        )
                    }
                }
            }
            await coordinator.resumePending(root: root)
        }

        // Hot reload. Create the file first, so the watcher arms on an inode
        // rather than standing on the directory waiting for one, and so
        // "Edit config…" always has something to show.
        Config.ensureFileExists()
        // And bring it up to date: an upgrade adds settings, and a config
        // written by an older yap has no line for any of them. Runs before the
        // watcher is armed so our own write is not reported as someone editing
        // the file.
        Config.ensureEveryKeyPresent()
        configWatcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
    }

    /// Finalize anything live before the process goes away. A session killed
    /// mid-write loses its meta.json and would never be picked up again;
    /// stopped cleanly it lands on disk with no transcript, which is exactly
    /// what `resumePending` looks for on the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        detector?.stop()
        // A press in flight holds the mic gain lease. Without this the daemon
        // exits leaving the user's input turned up.
        capture.stop()
        guard let session else { return }
        session.stop()
        self.session = nil
        warn("○ stopped · \(session.dir.path) · will transcribe on next launch")
    }

    // MARK: - dictation

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            // Pressed while the mic is live only happens for a latched tap —
            // hold mode's edges strictly alternate — and it means "stop".
            // Deliberately not gated on the config: a latch must always be
            // stoppable, even if the setting was turned off underneath it.
            if recording { endDictation() } else { beginDictation() }
        case .released:
            guard recording else { return }
            // Hold mode always ends here. Toggle mode ends here too when the
            // key was held past the threshold — push-to-talk keeps working —
            // and otherwise the quick tap leaves the recording latched.
            let wasHeld = Date().timeIntervalSince(pressStartedAt) > Self.tapThreshold
            if !pressLatches || wasHeld { endDictation() }
        }
    }

    private func beginDictation() {
        // State bookkeeping must not re-run under a second press: capture.start
        // is idempotent, the generation bump below is not.
        guard !recording else { return }
        // Decided once per press. The file can be saved mid-press, and a pill
        // that appears halfway through — or a level pump feeding a window
        // nobody can see — is worse than honouring the answer we started on.
        if let overlay, Config.overlayEnabled() {
            overlayShown = true
            // Fires on an audio thread; pushLevel is nonisolated for exactly
            // this reason.
            capture.onLevel = { level in overlay.pushLevel(level) }
        } else {
            overlayShown = false
            capture.onLevel = nil
        }
        do {
            try capture.start()
        } catch {
            warn("capture failed: \(error)")
            return
        }
        // After the mic is actually ours, never before: a failed start that
        // returned above would otherwise leave detection suppressed forever.
        //
        // Holding the hotkey wakes macOS's own speech daemon, which takes the
        // mic under its own pid and so reads as a call starting. Nothing seen
        // during our own press is evidence of a meeting.
        unsuppress?.cancel()
        unsuppress = nil
        detector?.suppressed = true
        dictating = true
        recording = true
        pressStartedAt = Date()
        pressLatches = Config.tapToToggle()
        pressGeneration += 1
        warn("● dictating")
        if overlayShown { overlay?.show(.recording) }
        menuBar.setDictating(true)
    }

    private func endDictation() {
        guard recording else { return }
        // Cleared before the mic goes down, so the stopping tap's own release
        // edge — and any synthetic release from setKey/reenable — is a no-op.
        recording = false
        let samples = capture.stop()

        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        let rms = computeRMS(samples)
        warn(String(format: "○ captured %.2fs · rms %.3f", seconds, rms))
        guard !samples.isEmpty else {
            finishDictation(generation: pressGeneration)
            return
        }

        if overlayShown { overlay?.show(.transcribing) }
        menuBar.setTranscribing()
        // Whose press this is. finishDictation refuses to clean up for anyone
        // else's, so a newer press starting while this one transcribes keeps
        // its indicator, its overlay and its capture.
        let generation = pressGeneration
        // Inherits this method's main-actor isolation, so injection and the
        // menu-bar reset need no hop; the await on the transcriber suspends
        // rather than blocks, leaving the main actor free the whole time.
        Task { [transcriber, newlineFlag, echoTranscripts, generation, weak self] in
            // Timed from the moment the key came up, through injection, so the
            // log reports what the user actually waits for rather than just
            // the model. Transcription is nearly all of it, but injection is a
            // synthetic key event and is not free, and quoting inference alone
            // would flatter us against tools that report end to end.
            let started = Date()
            do {
                let text = try await transcriber.transcribe(samples)
                let transcribed = Date().timeIntervalSince(started)
                // A press that caught only silence transcribes to nothing.
                // There is no text to place and nothing to tell the user, so
                // neither branch runs: a bare Return would fire a half-typed
                // chat message, and the clipboard would lose whatever it held
                // in exchange for an empty string. The timing line below still
                // reports the press.

                // Which placement ran. The timing line said "inject" for both,
                // so a transcript that quietly went to the pasteboard read
                // exactly like one that was typed.
                var route = "no text"
                if !text.isEmpty {
                    if TextInjector.focusedElementAcceptsText() {
                        route = "typed"
                        TextInjector.inject(text)
                        // Send-on-release. A real key event rather than a "\n"
                        // in the text, because chat inputs bind send to the
                        // Return key code. The config half of this is read
                        // here, after injection and off the measured path, so
                        // it survives a save with no restart.
                        if newlineFlag || Config.newlineAfterRelease() {
                            TextInjector.pressReturn()
                        }
                    } else {
                        route = "clipboard"
                        // Nowhere to type: posting the events would drop the
                        // transcript on the floor, and Return with no field is
                        // worse than useless. Clobbering the pasteboard is the
                        // lesser loss, and the notification says so.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        notifyUser(
                            title: "yap",
                            body: "No text field focused — transcript copied to clipboard"
                        )
                    }
                    // Both routes: typing can land in the wrong field just as
                    // the clipboard can be taken away by the next copy. The
                    // menu holds it in memory only — see setLastTranscript.
                    self?.menuBar.setLastTranscript(text)
                }
                let total = Date().timeIntervalSince(started)
                // Length, never the words. Under launch-at-login this line
                // goes to a log file that outlives the session, and a daemon
                // that quietly keeps a plaintext record of everything you
                // have ever dictated is a worse problem than any bug it would
                // help diagnose. --echo-transcripts opts in, and the
                // LaunchAgent never passes it.
                let body = echoTranscripts ? " · \(text)" : " · \(text.count) chars"
                warn(
                    String(
                        format: "→ %.0fms (%.0fms model + %.0fms %@)%@",
                        total * 1000, transcribed * 1000,
                        (total - transcribed) * 1000, route, body
                    ))
            } catch {
                warn("transcription failed: \(error)")
            }
            self?.finishDictation(generation: generation)
        }
    }

    private func finishDictation(generation: Int) {
        // A newer press owns the indicator, the overlay and the detector
        // suppression now. Clearing them here is the race this guards against:
        // it used to hide the new press's pill and, because `dictating` went
        // false under it, leave its capture running with no release to stop it.
        guard generation == pressGeneration else { return }
        dictating = false
        overlay?.hide()
        overlayShown = false
        // The speech daemon holds the input stream for a beat after the key
        // comes up — measured at about three seconds against a two second
        // press. Lifting the suppression here would hand the detector that
        // tail and let it read as a call, so it waits the tail out.
        //
        // A fixed wait rather than tracking which pids were up during the
        // press: this only ever *delays* a real prompt, never drops one. A
        // call that starts inside the window is still capturing when the
        // window closes, and prompts a moment later — against a detector that
        // already sits on two polls before asking, three seconds is nothing.
        //
        // Cancellable, and replaced on every press: two quick presses would
        // otherwise have the first one's timer fire during the second one's
        // tail and hand the detector exactly what this avoids. Only the
        // newest press can lift it.
        unsuppress?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.unsuppress = nil
            self?.detector?.suppressed = false
        }
        unsuppress = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
        // setIdle restores the session line underneath, if a recording is live.
        menuBar.setIdle()
    }

    // MARK: - sessions

    private func startSession(auto: Bool = false) {
        guard session == nil else { return }
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            autoStarted = auto
            if !auto {
                // Started from the menu, so any prompt on screen is offering
                // something we're already doing — and the pause below would
                // strand it there for its full two-minute timeout.
                retirePrompt()
                // Holding the mic ourselves makes every audio client look
                // busy, so the detector would scan all of them once a second
                // to answer a question we'd ignore anyway: a call starting
                // can't prompt while a session is live. An auto-started
                // session keeps it, to notice the call it came from ending.
                detector?.stop()
            }
            warn("● recording → \(newSession.dir.path)")
            menuBar.setRecording(true, since: newSession.startedAt)
        } catch {
            warn("recording start failed: \(error)")
            notifyUser(title: "yap — recording failed", body: "\(error)")
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = formatElapsed(Date().timeIntervalSince(session.startedAt))
        warn("○ stopped · \(elapsed) · \(session.dir.path)")
        self.session = nil
        autoStarted = false
        // No-op when the detector is already running, and nil when detection
        // is off entirely.
        detector?.start()
        menuBar.setRecording(false, since: nil)

        let dir = session.dir
        Task { [coordinator] in await coordinator.enqueue(dir) }
    }

    /// Attach the daemon's handlers. Starting the detector is the caller's
    /// call: a manual session holds the mic, and detection must stay down
    /// until it ends.
    private func wire(_ detector: MeetingDetector) {
        detector.onMeetingStart = { [weak self, weak detector] appName in
            let who = appName ?? "Your microphone"
            warn("◆ \(who) is in use")
            // Already recording: nothing to offer.
            guard let self, self.session == nil else { return }
            askUser(
                title: appName.map { "\($0) is in a call" } ?? "Your microphone is in use",
                body: "Record this meeting?",
                button: "Record",
                // "No" holds for this call. A quiet poll clears the detector's
                // own record of having asked, so without this a brief mic
                // dropout would ask again after you declined.
                onDismiss: { detector?.declineCurrentMeeting() }
            ) { [weak self] in
                // Recording may have started manually while the prompt was up.
                guard let self, self.session == nil else { return }
                detector?.acceptCurrentMeeting()
                self.startSession(auto: true)
            }
        }
        // An unanswered prompt outlives the call it asked about (it sits for
        // two minutes). Accepting it then would start a session no later end
        // event could stop, so it goes as soon as the mic frees.
        detector.onMeetingQuiet = { retirePrompt() }
        detector.onMeetingEnd = { [weak self] in
            guard let self, self.session != nil, self.autoStarted else { return }
            warn("◇ call ended")
            self.stopSession()
        }
    }

    /// The config file was saved. Everything that can change without a
    /// restart is re-applied here; the rest is read at the point of use.
    private func reloadConfig() {
        // Resolve re-runs flag > file > default, so a CLI-set hotkey resolves
        // to itself and both calls below no-op. It only throws on a bad
        // *flag*, which was validated at boot.
        if let key = try? Resolve.hotkey(cliHotkey) {
            monitor.setKey(key)
            menuBar.setHotkeyName(key.rawValue)
        }
        // Only the idle menu line: the mode itself is read at each key-down, so
        // a flip takes effect on the next press either way.
        menuBar.setTapToToggle(Config.tapToToggle())

        let wantDetector = Config.meetingDetectionEnabled()
        if wantDetector, detector == nil {
            let newDetector = MeetingDetector()
            detector = newDetector
            wire(newDetector)
            // Born mid-press, it would start clean and prompt for the speech
            // daemon our own hotkey woke. Inherit the suppression: `dictating`
            // covers a press in flight, a pending lift covers its tail. That
            // same work item reads `detector` when it fires, so it releases
            // this one correctly.
            newDetector.suppressed = dictating || unsuppress != nil
            // A manual session holds the mic, which makes every audio client
            // look busy; startSession stops the detector for that reason and
            // stopSession starts it again. Do not undo that here.
            if session == nil { newDetector.start() }
        } else if !wantDetector, let detector {
            detector.stop()
            self.detector = nil
            // The prompt belongs to the detector, and only its quiet event
            // retires it. Left up, "Record" stays live for two minutes after
            // the feature was switched off, and would start an auto session
            // nothing could ever stop — onMeetingEnd went with the detector.
            retirePrompt()
            // A session it auto-started earlier does keep recording: silently
            // ending audio someone is relying on is worse than an orphan, and
            // it comes off the menu like a manual one.
        }

        // A few hundred MB of model is not worth reloading under someone's cursor.
        if let model = try? Resolve.model(cliModel), model.id != loadedModelID {
            warn("config: model changed to \(model.id) — restart yap to load it")
        }

        // Same reasoning, different reason: a live session is writing into the
        // old root, and resumePending was handed it at boot. Moving the daemon
        // mid-flight would strand both.
        if Config.resolveRoot(cliOverride: nil) != root {
            warn("config: recordings_dir changed — restart yap to use it")
        }

        warn("config reloaded")
    }

    /// The menu bar has one state line and nowhere to put a queue depth, so a
    /// draining queue is simply "transcribing". Failures reach the user
    /// through a notification and the session's transcribe.log instead.
    private func show(busy: Bool) {
        // A live dictation press owns the indicator; it will call setIdle
        // itself when it lands.
        guard !dictating else { return }
        if busy { menuBar.setTranscribing() } else { menuBar.setIdle() }
    }
}

// MARK: - record

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a session now — mic and system audio as two tracks — then transcribe."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Flag(
        name: .long,
        help: """
            Cancel speaker echo on the mic track. Use this when the call plays \
            through speakers, or both sides get transcribed twice.
            """
    )
    var micVoiceProcessing: Bool = false

    func run() throws {
        let root = Config.resolveRoot(cliOverride: out)
        // Before the microphone opens, not after the meeting. `yap record` has
        // no --model flag, so this is whatever config resolves to; an id that
        // does not resolve is left to the coordinator, which says so better.
        if let model = try? Resolve.model(nil) {
            Resolve.warnIfSessionsUnsupported(model)
        }
        let session = try RecordingSession(root: root)
        try session.start(
            voiceProcessing: micVoiceProcessing || Config.micVoiceProcessing()
        )
        warn("● recording → \(session.dir.path) · ^C to stop")

        waitForInterrupt()

        session.stop()
        let elapsed = formatElapsed(Date().timeIntervalSince(session.startedAt))
        warn("\n○ stopped · \(elapsed) · \(session.dir.path)")

        if Config.transcriptionEnabled() {
            warn("transcribing...")
        }
        // No transcriber handed over: this is a one-shot, so the coordinator
        // loads a model, uses it and releases it rather than keeping it warm
        // for a next press that isn't coming. It also fires the on_stop hook
        // itself once the transcript is on disk — don't run it again here.
        let coordinator = TranscriptionCoordinator()
        let dir = session.dir
        try runBlocking { await coordinator.transcribeNow(dir) }
    }
}

// MARK: - models

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the built-in models.")

        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let have = ModelStore.isDownloaded(m) ? "✓" : " "
                let langs = m.languages.count > 2
                    ? "[\(m.languages.count) langs]"
                    : "[\(m.languages.joined(separator: ","))]"
                let size = String(format: "%5d MB", m.sizeMB)
                // Only the models that cannot do sessions are marked. Doctor
                // sends people here to pick a replacement, so the limitation
                // has to be visible — but tagging every capable model with
                // "sessions" would be noise for the common case where they all
                // are.
                let limit = m.supportsSessions ? "" : "  · dictation only"
                print(
                    "\(star)\(have) \(pad(m.id, 26)) \(size)  \(pad(langs, 11))  "
                        + "\(m.displayName)\(limit)")
            }
            print()
            print("★ default · ✓ downloaded")
            if ModelRegistry.shared.contains(where: { !$0.supportsSessions }) {
                print("· dictation only — cannot transcribe recorded sessions")
            }
            print("  models: \(ModelStore.displayPath(ModelStore.modelsRoot))")
        }
    }

    struct Download: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fetch a model ahead of time.")

        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let model = ModelRegistry.find(id) else {
                throw ValidationError(
                    "unknown model: \(id) — run `yap models list` to see options")
            }
            if ModelStore.isDownloaded(model) {
                print("✓ \(model.id) already downloaded")
                return
            }
            print("→ downloading \(model.id) (~\(model.sizeMB) MB), then compiling for the ANE...")
            // warmUp, not just a download: the first load compiles for the ANE
            // and that is the slow half. Paying it here means the daemon's
            // first press doesn't.
            try runBlocking { try await model.makeTranscriber().warmUp() }
            print("✓ \(model.id)")
        }
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check permissions, key mapping, recordings folder, and the selected model."
    )

    func run() throws {
        let model = try Resolve.model(nil)
        let key = try Resolve.hotkey(nil)
        let checks = DoctorReport.run(
            recordingsRoot: Config.resolveRoot(cliOverride: nil),
            model: model,
            hotkey: key
        )
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

// MARK: - shared resolution

/// Flags beat the config file beats the built-in default, resolved in one
/// place so `yap doctor` reports on exactly what `yap run` would load.
enum Resolve {
    /// Say up front that recorded sessions will be skipped.
    ///
    /// `yap doctor` reports this too, but that is not enough on its own: the
    /// startup report is only printed when some check hard-fails, and the
    /// installed LaunchAgent runs with `--skip-doctor`, so a warning row would
    /// never reach the daemon at all.
    ///
    /// A warning, not a refusal. Dictation is unaffected, and a recording made
    /// on an incapable model is still worth having — refusing to record would
    /// throw away the meeting to avoid a missing transcript.
    ///
    /// It promises retained audio and nothing more. Sessions under the
    /// configured recordings root are picked up by `resumePending` on the next
    /// launch with a capable model, but one written elsewhere by
    /// `yap record --out` is never rescanned, and there is no command to
    /// transcribe an existing folder. Claiming it would transcribe later would
    /// be a promise this can't keep.
    static func warnIfSessionsUnsupported(_ model: TranscriptionModel) {
        guard Config.transcriptionEnabled(), !model.supportsSessions else { return }
        warn(
            "warning: \(model.id) cannot transcribe recorded sessions — "
                + "audio is kept, but no transcript is written")
    }

    /// An unknown id on the command line is fatal — you asked for something
    /// specific and didn't get it. An unknown id in the config file only
    /// warns: bricking the daemon over a typo in a file edited weeks ago is
    /// worse than quietly running the default.
    static func model(_ override: String?) throws -> TranscriptionModel {
        if let id = override {
            guard let model = ModelRegistry.find(id) else {
                throw ValidationError(
                    "unknown model: \(id) — run `yap models list` to see options")
            }
            return model
        }
        if let id = Config.dictationModel() {
            if let model = ModelRegistry.find(id) { return model }
            warn("warning: unknown model \"\(id)\" in \(Config.path.path) — using the default")
        }
        guard let model = ModelRegistry.recommended() else {
            throw ValidationError("no models registered")
        }
        return model
    }

    /// Same precedence as `model`. Never falls back silently on an explicit
    /// `--hotkey`: a push-to-talk key that isn't the one you asked for is
    /// worse than a startup error, because you find out by speaking into
    /// nothing.
    static func hotkey(_ override: String?) throws -> HotkeyMonitor.Key {
        if let name = override {
            guard let key = HotkeyMonitor.Key(name: name) else {
                throw ValidationError(
                    "unknown hotkey: \(name) — one of: \(HotkeyMonitor.Key.names)")
            }
            return key
        }
        if let name = Config.hotkey() {
            if let key = HotkeyMonitor.Key(name: name) { return key }
            warn("warning: unknown hotkey \"\(name)\" in \(Config.path.path) — using fn")
        }
        return .fn
    }
}

// MARK: - plumbing

/// Carries a result across the concurrency boundary in `runBlocking`. The
/// semaphore is the happens-before edge that makes reading it safe.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Bridge from ArgumentParser's synchronous `run()` into async work.
///
/// A detached task plus a semaphore, deliberately: nothing in the CLI needs
/// the main run loop until `NSApp.run()`, and blocking the calling thread is
/// far easier to reason about than spinning a nested one.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.result = .success(try await body())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    // Signalled means written.
    return try box.result!.get()
}

/// Signal handling for both long-running commands.
///
/// Ignore the default disposition first: between `resume()` and a signal
/// arriving, the default disposition would still kill the process before the
/// handler ever ran. SIGTERM as well as SIGINT, because launchd stops the
/// agent with SIGTERM and both callers have teardown that puts the user's mic
/// gain back.
///
/// The returned sources must be held for as long as the handler should fire.
/// They are cancelled when released, and a cancelled source over an
/// already-ignored disposition means ^C and a launchd stop would both do
/// nothing at all.
private func interruptSources(_ handler: @escaping @Sendable () -> Void)
    -> [DispatchSourceSignal]
{
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}

/// Block until ^C, servicing the main run loop meanwhile. Core Audio and
/// AVAudioEngine both deliver work on the main queue, so a bare `sleep` would
/// starve a recording that looks like it is running fine.
private func waitForInterrupt() {
    let sources = interruptSources { CFRunLoopStop(CFRunLoopGetMain()) }
    CFRunLoopRun()
    sources.forEach { $0.cancel() }
}

/// `m:ss`, widening to `h:mm:ss` only once there is an hour to show. Every
/// duration a user reads goes through here: the menu bar's live session
/// counter, the line printed when a recording stops, and the timestamps in
/// transcript.md.
func formatElapsed(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

/// Right-pad without truncating. `String.padding(toLength:)` cuts anything
/// longer than the target, which silently mangles a long model id.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}
