import AppKit

/// Status bar item in the top-right of the menu bar. Shows what yap is doing
/// at a glance and provides the only persistent control surface (we run as
/// `.accessory` — no dock icon, no main window).
///
/// One status item serves both halves of the app. Push-to-talk dictation is
/// transient and drives the state line; a recording session is long-lived and
/// owns the toggle item plus its elapsed counter. They are tracked separately
/// because they overlap: you can dictate a note while a meeting records.
@MainActor
final class MenuBarController {
    /// Transient dictation state, resolved against the session state by
    /// `refresh()`. Dictation wins the state line while it lasts — it is the
    /// thing the user is doing right now — and the session line comes back
    /// underneath it.
    private enum Dictation {
        case idle
        case listening
        case transcribing
    }

    /// Name of the push-to-talk key, as the state line spells it. Live: the
    /// config file can change the key while the daemon runs.
    private var hotkeyName: String
    /// Whether a tap latches the mic rather than a hold holding it. Only the
    /// idle line's verb depends on it; live the same way the key name is.
    private var tapToToggle: Bool

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let copyItem: NSMenuItem

    /// The last thing dictation produced. In process memory, one at a time,
    /// never written to disk or log by this feature — the log deliberately
    /// records a length and not the words, and a menu item is not the place
    /// to start keeping a transcript history.
    ///
    /// It exists because a transcript can miss: the clipboard route is one
    /// copy away from losing it, and injection can land in the wrong field.
    private var lastTranscript: String?

    private var dictation: Dictation = .idle
    private var recordingSince: Date?
    private var ticker: Timer?

    /// Clicked "Start recording". The menu does not flip itself: a session
    /// start can fail, so the title only changes once the caller confirms with
    /// `setRecording(true, since:)`.
    var onStartRecording: (() -> Void)?
    /// Clicked "Stop recording".
    var onStopRecording: (() -> Void)?

    init(modelID: String, hotkeyName: String, tapToToggle: Bool) {
        self.hotkeyName = hotkeyName
        self.tapToToggle = tapToToggle
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        // Without this AppKit greys out every item whose target doesn't answer
        // a validation selector, which would disable the two status lines *and*
        // the actions. We drive enablement ourselves instead.
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(
            title: Self.idleTitle(hotkeyName, tapToToggle),
            action: nil,
            keyEquivalent: ""
        )
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        // Never changes: the model is chosen once, at launch.
        let modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let editConfig = NSMenuItem(
            title: "Edit config…",
            action: #selector(editConfigClicked),
            keyEquivalent: ","
        )
        menu.addItem(editConfig)

        copyItem = NSMenuItem(
            title: "Copy last transcript",
            action: #selector(copyTranscriptClicked),
            keyEquivalent: ""
        )
        // Nothing to copy until something has been dictated. That is the
        // whole of the empty state.
        copyItem.isEnabled = false
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit yap",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, editConfig, copyItem, quit] {
            item.target = self
        }

        statusItem.menu = menu

        // Template image, never tinted. Colouring the icon while recording put
        // a second red dot next to the system's own recording indicator and
        // read as an error; the menu carries the state instead.
        statusItem.button?.image = StatusIcon.image(size: 16)
        statusItem.button?.imagePosition = .imageLeft
    }

    /// The push-to-talk key is held and the mic is hot.
    func setDictating(_ active: Bool) {
        dictation = active ? .listening : .idle
        refresh()
    }

    /// Between key release and text injection, or while a finished session
    /// transcribes.
    func setTranscribing() {
        dictation = .transcribing
        refresh()
    }

    func setIdle() {
        dictation = .idle
        refresh()
    }

    /// The config file changed the push-to-talk key.
    func setHotkeyName(_ name: String) {
        guard name != hotkeyName else { return }
        hotkeyName = name
        refresh()
    }

    /// The config file flipped tap_to_toggle.
    func setTapToToggle(_ enabled: Bool) {
        guard enabled != tapToToggle else { return }
        tapToToggle = enabled
        refresh()
    }

    /// A dictation press produced text. See `lastTranscript` for why we keep
    /// it and how far that goes.
    func setLastTranscript(_ text: String) {
        lastTranscript = text
        copyItem.isEnabled = true
    }

    /// Session recording. `since` is the session's real start time and feeds
    /// the elapsed counter; a nil date clears the ticker.
    func setRecording(_ active: Bool, since: Date?) {
        // Invalidate before anything else. The run loop owns the timer, not
        // us, so a second start without this leaves the old one firing forever
        // against a controller that has moved on.
        ticker?.invalidate()
        ticker = nil

        recordingSince = active ? (since ?? Date()) : nil

        if recordingSince != nil {
            // The only timer in the app that ticks on a schedule, and it exists
            // for exactly as long as a session does — nothing runs while idle.
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        refresh()
    }

    /// Single point of truth for both titles. Called on every state change and
    /// once a second while a session records.
    private func refresh() {
        if let recordingSince {
            let elapsed = formatElapsed(Date().timeIntervalSince(recordingSince))
            toggleItem.title = "Stop recording · \(elapsed)"
        } else {
            toggleItem.title = "Start recording"
        }

        switch dictation {
        case .listening:
            stateLabel.title = "● listening"
        case .transcribing:
            stateLabel.title = "transcribing…"
        case .idle:
            stateLabel.title =
                recordingSince == nil ? Self.idleTitle(hotkeyName, tapToToggle) : "● recording"
        }
    }

    private static func idleTitle(_ hotkey: String, _ tapToToggle: Bool) -> String {
        "idle · \(tapToToggle ? "tap" : "hold") \(hotkey) to dictate"
    }

    @objc private func toggleClicked() {
        if recordingSince == nil {
            onStartRecording?()
        } else {
            onStopRecording?()
        }
    }

    /// Copies the last transcript, for the press that landed somewhere wrong
    /// or on a clipboard that has since moved on.
    @objc private func copyTranscriptClicked() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    /// Opens the config in whatever the user's editor for .json is. No
    /// callback into the daemon: the module is flat, and the watcher picks up
    /// the save on its own.
    @objc private func editConfigClicked() {
        Config.ensureFileExists()
        NSWorkspace.shared.open(Config.path)
    }

    /// No callback: quitting is unconditional. Anything that has to run on the
    /// way out belongs in the app delegate's `applicationWillTerminate`, which
    /// also covers Cmd-Q and a launchd stop.
    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
