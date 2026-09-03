import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

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
    private let overlay = RecordingOverlay()
    private let menuBar: MenuBarController
    private var detector: MeetingDetector?
    /// The model this daemon loaded, for the state line, the "restart to pick
    /// it up" warning, and the retry the menu offers when warm-up fails.
    private let model: TranscriptionModel
    /// False until the model is warm. Both the hotkey and the record item
    /// refuse until it flips: a press that silently records into a model that
    /// cannot transcribe it is worse than a press that says so.
    private var modelReady = false
    /// Observer for the system's "the Accessibility list changed" broadcast.
    /// Held so it can be removed on the way out.
    private var accessibilityObserver: NSObjectProtocol?
    /// Observer for the Settings recorder arming and disarming.
    private var recordingObserver: NSObjectProtocol?
    /// The binding the tap watches. Held here as well as in the monitor
    /// because the Fn setup row only applies when Fn is part of it.
    private var hotkey: HotkeyBinding
    /// Whether the event tap is up. The grant can arrive at any time, so
    /// `evaluateSetup` may be called many times before it succeeds and must
    /// not create a second tap once it has.
    private var tapRunning = false
    /// Whether the microphone prompt has been raised this launch. macOS only
    /// shows it while the status is undetermined, but asking repeatedly for
    /// an answer the user is still looking at is noise.
    private var micRequested = false
    /// Our subscription to the updater, and the version it has staged. The
    /// menu item's enablement depends on daemon state the updater knows
    /// nothing about, so the version is held here and re-published whenever a
    /// press or a session starts or ends.
    private var updateObserver: UUID?
    private var stagedUpdate: String?
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
        hotkey: HotkeyBinding,
        echoTranscripts: Bool,
        debugHotkey: Bool
    ) {
        self.transcriber = transcriber
        self.root = root
        self.model = model
        self.hotkey = hotkey
        self.echoTranscripts = echoTranscripts
        self.monitor = HotkeyMonitor(binding: hotkey, debug: debugHotkey)
        self.menuBar = MenuBarController(
            modelID: model.id,
            hotkeyName: hotkey.displayName,
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

    func start() {
        menuBar.onStartRecording = { [weak self] in self?.startSession() }
        menuBar.onStopRecording = { [weak self] in
            guard let self else { return }
            if self.autoStarted { self.detector?.declineCurrentMeeting() }
            self.stopSession()
        }
        menuBar.onGrantAccessibility = { Permissions.openSystemSettings(.accessibility) }
        menuBar.onGrantMicrophone = { Permissions.openSystemSettings(.microphone) }
        menuBar.onOpenKeyboardSettings = { Permissions.openSystemSettings(.keyboard) }
        menuBar.onRetryModel = { [weak self] in self?.loadModel() }
        menuBar.onInstallUpdate = { Updater.shared.installAndRestart() }
        // Cheaper and more accurate than polling: the only moment the rows
        // have to be right is the moment someone opens the menu to look at
        // them.
        menuBar.onMenuWillOpen = { [weak self] in self?.evaluateSetup() }

        // The handlers before the queue that fires them: `resumePending`
        // below runs as soon as the model is warm, and a session finishing
        // against an unset handler would fall back to a bare notification.
        Task { [coordinator] in
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
                        button: "Open",
                        secondaryButton: "Name…",
                        onSecondary: { [weak self] in self?.promptForName(of: dir) },
                        destructiveButton: "Delete",
                        onDestructive: { [weak self] in self?.trashSession(dir) }
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [dir.appendingPathComponent("transcript.md")]
                        )
                    }
                }
            }
        }

        // First launch asks, rather than telling a log file. Everything after
        // that is `evaluateSetup`, which is also what turns the tap on the
        // moment the box is ticked — no relaunch.
        if !Permissions.accessibilityGranted {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        // Not Apple-documented, but it is what every app that watches for this
        // grant uses: TCC broadcasts it when the Accessibility list changes.
        // Event-driven, so nothing runs while idle.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateSetup() }
        }
        evaluateSetup()

        if let detector {
            wire(detector)
            detector.start()
        }

        // The Settings recorder is listening for the very keys the tap
        // watches. Without this, binding ⌘⇧Space also dictates the sentence
        // you were not saying.
        recordingObserver = NotificationCenter.default.addObserver(
            forName: .yapHotkeyRecording, object: nil, queue: .main
        ) { [weak self] note in
            let active = note.userInfo?["active"] as? Bool ?? false
            MainActor.assumeIsolated { self?.monitor.setSuspended(active) }
        }

        loadModel()

        // Anything a previous run staged and never installed. Two directory
        // reads, once, at the only moment nothing is using it.
        Updater.cleanStaging()

        // Hot reload. Create the file first, so the watcher arms on an inode
        // rather than standing on the directory waiting for one, and so
        // "Open Config File" always has something to show.
        Config.ensureFileExists()
        // And bring it up to date: an upgrade adds settings, and a config
        // written by an older yap has no line for any of them. Runs before the
        // watcher is armed so our own write is not reported as someone editing
        // the file.
        Config.ensureEveryKeyPresent()
        configWatcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
    }

    // MARK: - startup state

    /// Warm the model, off the launch path.
    ///
    /// The status item is up before this runs, which is the whole point: a
    /// cold cache is a several-hundred-megabyte download, and yap used to
    /// spend it invisible. Retryable, because the one thing that can fail
    /// here is a network the user can fix.
    private func loadModel() {
        modelReady = false
        menuBar.setModelLoading(
            downloading: !ModelStore.isDownloaded(model), sizeMB: model.sizeMB)
        if !ModelStore.isDownloaded(model) {
            warn("downloading \(model.id) (~\(model.sizeMB) MB) — one-off")
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.warmUp()
                self.modelReady = true
                self.menuBar.setModelReady()
                warn("model ready · \(self.model.id)")
                // Only now: a backlog transcribing through a model that is
                // still loading would queue behind the same warm-up anyway,
                // and this way the state line tells one story at a time.
                await self.coordinator.resumePending(root: self.root)
                self.startUpdater()
            } catch {
                warn("warmup failed: \(error)")
                self.menuBar.setModelFailed()
            }
        }
    }

    /// Subscribe the menu bar to the updater, and arm the daily check if the
    /// config wants it.
    ///
    /// After the model, deliberately: the first thing a fresh install does is
    /// download several hundred megabytes, and competing with that for
    /// bandwidth to ask about a release is the wrong order.
    private func startUpdater() {
        guard updateObserver == nil else { return }
        updateObserver = Updater.shared.observe { [weak self] state in
            guard let self else { return }
            if case .ready(let version, _) = state {
                self.stagedUpdate = version
            } else {
                self.stagedUpdate = nil
            }
            self.refreshUpdateItem()
        }
        if Config.updatesAutomatic() { Updater.shared.startAutomaticChecks() }
    }

    /// A restart mid-recording loses the meeting, and mid-press loses the
    /// sentence. The item stays visible and goes grey instead of vanishing,
    /// so it does not look like the update went away.
    private func refreshUpdateItem() {
        menuBar.setUpdate(version: stagedUpdate, enabled: session == nil && !dictating)
    }

    /// What macOS is still withholding, and the tap that depends on it.
    ///
    /// Called at launch, whenever the menu opens, when the Accessibility list
    /// changes, and after a config reload — the Fn row depends on which key is
    /// bound. Idempotent: the tap is only created when it is not already up.
    private func evaluateSetup() {
        var needs: MenuBarController.SetupNeeds = []
        let granted = Permissions.accessibilityGranted
        if !granted { needs.insert(.accessibility) }

        switch Permissions.microphone {
        case .denied, .restricted:
            needs.insert(.microphone)
        case .notDetermined:
            // Asked once, in order: Accessibility is the one yap cannot work
            // without, and stacking two system prompts on a first launch reads
            // as an app demanding everything at once. `requestMicrophone` only
            // prompts while the status is undetermined, so this cannot loop.
            if granted, !micRequested {
                micRequested = true
                Permissions.requestMicrophone { [weak self] _ in
                    Task { @MainActor in self?.evaluateSetup() }
                }
            }
        default:
            break
        }

        let fnAction = hotkey.usesFn ? Permissions.fnKeyAction() : nil
        if fnAction != nil { needs.insert(.fnMapping) }
        menuBar.setSetupNeeds(needs, fnAction: fnAction)

        // The tap needs the grant, and the grant can arrive at any time. Start
        // it the moment it does — the whole reason this is event-driven is so
        // nobody has to relaunch yap after ticking a box.
        guard granted, !tapRunning else { return }
        do {
            try monitor.start { [weak self] event in
                // The tap callback has already hopped to the main queue.
                MainActor.assumeIsolated { self?.handle(event) }
            }
            tapRunning = true
            warn("listening on \(hotkey.serialized)")
        } catch {
            // Not fatal, and not an exit: the process stays up with the row
            // visible, so the menu can still say what is wrong. Exiting here
            // is what used to turn launch-at-login into a relaunch loop.
            warn("failed to register hotkey tap: \(error)")
        }
    }

    /// Finalize anything live before the process goes away. A session killed
    /// mid-write loses its meta.json and would never be picked up again;
    /// stopped cleanly it lands on disk with no transcript, which is exactly
    /// what `resumePending` looks for on the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        detector?.stop()
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        if let recordingObserver {
            NotificationCenter.default.removeObserver(recordingObserver)
        }
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
        // Nothing to transcribe into. Opening the mic anyway would record
        // audio the release edge then has to throw away, and the menu bar is
        // already saying why.
        guard modelReady else {
            warn("press ignored — model not loaded")
            return
        }
        // State bookkeeping must not re-run under a second press: capture.start
        // is idempotent, the generation bump below is not.
        guard !recording else { return }
        // Decided once per press. The file can be saved mid-press, and a pill
        // that appears halfway through — or a level pump feeding a window
        // nobody can see — is worse than honouring the answer we started on.
        if Config.overlayEnabled() {
            overlayShown = true
            // Fires on an audio thread; pushLevel is nonisolated for exactly
            // this reason.
            capture.onLevel = { [overlay] level in overlay.pushLevel(level) }
        } else {
            overlayShown = false
            capture.onLevel = nil
        }
        // Before `capture.start()`, not after. Opening the mic is 60-86 ms of
        // Core Audio bring-up, and a press that shows nothing for that long
        // reads as a press that did not register — measured, and the single
        // largest thing standing between key-down and feedback. Nothing here
        // depends on the mic actually opening, and the failure branch below
        // takes both back.
        if overlayShown { overlay.show(.recording) }
        menuBar.setDictating(true)
        do {
            try capture.start()
        } catch {
            warn("capture failed: \(error)")
            if overlayShown { overlay.hide() }
            overlayShown = false
            capture.onLevel = nil
            menuBar.setIdle()
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
        refreshUpdateItem()
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

        if overlayShown { overlay.show(.transcribing) }
        menuBar.setTranscribing()
        // Whose press this is. finishDictation refuses to clean up for anyone
        // else's, so a newer press starting while this one transcribes keeps
        // its indicator, its overlay and its capture.
        let generation = pressGeneration
        // Inherits this method's main-actor isolation, so injection and the
        // menu-bar reset need no hop; the await on the transcriber suspends
        // rather than blocks, leaving the main actor free the whole time.
        Task { [transcriber, echoTranscripts, generation, weak self] in
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
                        // Return key code. Read here, after injection and off
                        // the measured path, so it survives a save with no
                        // restart.
                        if Config.newlineAfterRelease() {
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
        overlay.hide()
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
        refreshUpdateItem()
    }

    // MARK: - sessions

    private func startSession(auto: Bool = false, title: String? = nil) {
        guard session == nil else { return }
        // Same gate as a press, different report: this one was asked for by a
        // click, so it owes an answer rather than a log line.
        guard modelReady else {
            warn("recording refused — model not loaded")
            notifyUser(title: "yap — model still loading", body: "Try again in a moment")
            return
        }
        do {
            let newSession = try RecordingSession(root: root)
            newSession.title = title
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
            refreshUpdateItem()
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
        detector?.releaseAcceptedMeeting()
        menuBar.setRecording(false, since: nil)
        refreshUpdateItem()

        let dir = session.dir
        Task { [coordinator] in await coordinator.enqueue(dir) }
    }

    /// End a session this app started by itself. For Ignore, which arrives
    /// from the auto-record toast after a session is already running and from
    /// the ask prompt before one exists.
    private func stopSessionIfAutoStarted() {
        guard session != nil, autoStarted else { return }
        stopSession()
    }

    /// Attach the daemon's handlers. Starting the detector is the caller's
    /// call: a manual session holds the mic, and detection must stay down
    /// until it ends.
    private func wire(_ detector: MeetingDetector) {
        detector.onMeetingStart = { [weak self, weak detector] pid, appName in
            guard let self else { return }

            // Before anything else, including the AX title lookup and the
            // back-to-back stop: an excluded app is invisible to every piece
            // of meeting logic, not merely unprompted. Read fresh at each
            // event, the same standing-consent pattern as auto-record below.
            let bundleID = MeetingTitle.bundleID(forPID: pid)
            if let bundleID, Config.meetingExcludedApps().contains(bundleID) {
                warn("◇ \(appName ?? bundleID) is excluded — ignoring")
                // Marks the pid, so the detector stops re-firing every poll;
                // its end-of-meeting path clears the mark on its own.
                detector?.declineCurrentMeeting()
                return
            }

            let title = MeetingTitle.capture(forCapturePID: pid)
            let who = appName ?? "Your microphone"
            warn("◆ \(who) is in use" + (title.map { " · \($0)" } ?? ""))
            if let session = self.session {
                // A quiet gap followed by the same capture pid can be a device
                // swap or a back-to-back call. Only a vanished meeting window
                // is evidence that the accepted call ended.
                guard self.autoStarted,
                      let oldTitle = session.title,
                      !MeetingTitle.windowExists(oldTitle, forCapturePID: pid)
                else { return }
                warn("◇ \(oldTitle) ended — a different call started")
                self.stopSession()
            }

            // "Never ask about this app again", offered from whichever surface
            // the user is looking at. Both need it to also end the recording
            // this event may have just started.
            let ignoreApp: @MainActor () -> Void = { [weak self, weak detector] in
                guard let bundleID else { return }
                Config.update { config in
                    var list = config["meeting_excluded_apps"] as? [String] ?? []
                    if !list.contains(bundleID) { list.append(bundleID) }
                    config["meeting_excluded_apps"] = list
                }
                warn("◇ \(appName ?? bundleID) added to the ignore list")
                detector?.declineCurrentMeeting()
                self?.stopSessionIfAutoStarted()
            }

            // Standing consent is read at each event so config saves take
            // effect without a restart. Recording is always announced.
            if Config.meetingAutoRecord() {
                self.startSession(auto: true, title: title)
                guard self.session != nil else { return }
                detector?.acceptCurrentMeeting()
                showToast(
                    title: appName.map { "Recording \($0) call" } ?? "Recording meeting",
                    body: title ?? "Stop from the menu bar or here",
                    button: "Stop",
                    secondaryButton: bundleID != nil ? "Ignore" : nil,
                    onSecondary: ignoreApp
                ) { [weak self, weak detector] in
                    detector?.declineCurrentMeeting()
                    self?.stopSession()
                }
                return
            }

            askUser(
                title: appName.map { "\($0) is in a call" } ?? "Your microphone is in use",
                body: title ?? "Record this meeting?",
                button: "Record",
                // Only when we have both a name to show and an identity to
                // store; a process with no app bundle gets Dismiss and no more.
                secondaryButton: appName.flatMap { bundleID != nil ? "Ignore \($0)" : nil },
                onSecondary: ignoreApp,
                onDismiss: { detector?.declineCurrentMeeting() }
            ) { [weak self] in
                guard let self, self.session == nil else { return }
                detector?.acceptCurrentMeeting()
                self.startSession(auto: true, title: title)
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

    /// The transcript toast's Name action: update metadata, heading and folder.
    private func promptForName(of dir: URL) {
        let existing = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("meta.json"))))
            .flatMap { ($0 as? [String: Any])?["title"] as? String }
        askForName(title: "Name this meeting", prefill: existing ?? "") { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let newDir = RecordingSession.applyTitle(trimmed, to: dir)
            showToast(title: "Saved", body: newDir.lastPathComponent, button: "Open") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [newDir.appendingPathComponent("transcript.md")])
            }
        }
    }

    /// The transcript toast's Delete action.
    ///
    /// The Trash, not `removeItem`: a recording is minutes of someone's
    /// meeting and a mis-click on a pill that appears by itself is easy. That
    /// is also why there is no confirmation — the Trash *is* the confirmation,
    /// and Undo puts it back without going near Finder.
    private func trashSession(_ dir: URL) {
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: &trashed)
        } catch {
            warn("delete failed: \(error)")
            notifyUser(title: "yap — couldn't delete", body: error.localizedDescription)
            return
        }
        warn("⌫ trashed \(dir.lastPathComponent)")
        guard let trashed = trashed as URL? else { return }
        showToast(title: "Deleted", body: dir.lastPathComponent, button: "Undo") {
            do {
                try FileManager.default.moveItem(at: trashed, to: dir)
            } catch {
                warn("undo failed: \(error)")
                notifyUser(title: "yap — couldn't undo", body: error.localizedDescription)
            }
        }
    }

    /// The config file was saved. Everything that can change without a
    /// restart is re-applied here; the rest is read at the point of use.
    private func reloadConfig() {
        hotkey = Resolve.hotkey()
        monitor.setBinding(hotkey)
        menuBar.setHotkeyName(hotkey.displayName)
        // The Fn row only applies while Fn is the key, so a rebind changes
        // whether it belongs on screen.
        evaluateSetup()
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
        if let configured = try? Resolve.model(), configured.id != model.id {
            warn("config: model changed to \(configured.id) — restart yap to load it")
        }

        // Same reasoning, different reason: a live session is writing into the
        // old root, and resumePending was handed it at boot. Moving the daemon
        // mid-flight would strand both.
        if Config.resolveRoot() != root {
            warn("config: recordings_dir changed — restart yap to use it")
        }

        // Only meaningful once the updater is subscribed, which happens after
        // the model warms; before that `startUpdater` reads the same setting.
        if updateObserver != nil {
            if Config.updatesAutomatic() {
                Updater.shared.startAutomaticChecks()
            } else {
                Updater.shared.stopAutomaticChecks()
            }
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
