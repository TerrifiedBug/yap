import AppKit
import SwiftUI

/// Status bar item in the top-right of the menu bar. Shows what yap is doing
/// at a glance and provides the only persistent control surface (we run as
/// `.accessory` — no dock icon, no main window).
///
/// One status item serves both halves of the app. Push-to-talk dictation is
/// transient and drives the state line; a recording session is long-lived and
/// owns the toggle item plus its elapsed counter. They are tracked separately
/// because they overlap: you can dictate a note while a meeting records.
///
/// It is also where onboarding lives. There is no `yap setup` any more, so a
/// missing grant is a row you click rather than a line printed into a log
/// nobody reads. Those rows are hidden in the ordinary case, which is every
/// launch after the first.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Transient dictation state, resolved against the session state by
    /// `refresh()`. Dictation wins the state line while it lasts — it is the
    /// thing the user is doing right now — and the session line comes back
    /// underneath it.
    private enum Dictation {
        case idle
        case listening
        case transcribing
    }

    /// Where the model is. The status item now exists before the model does,
    /// so this is the difference between "yap is thinking" and "yap is broken"
    /// during the seconds — or, on a cold cache, minutes — before the first
    /// press can work.
    private enum Model {
        case loading(String)
        case failed
        case ready
    }

    /// What macOS is still withholding. An option set because they are
    /// independent and any combination can be true at once.
    struct SetupNeeds: OptionSet {
        let rawValue: Int
        static let accessibility = SetupNeeds(rawValue: 1 << 0)
        static let microphone = SetupNeeds(rawValue: 1 << 1)
        static let fnMapping = SetupNeeds(rawValue: 1 << 2)
    }

    /// Name of the push-to-talk key, as the state line spells it. Live: the
    /// config file can change the key while the daemon runs.
    private var hotkeyName: String
    /// Whether a tap latches the mic rather than a hold holding it. Only the
    /// idle line's verb depends on it; live the same way the key name is.
    private var tapToToggle: Bool

    private let statusItem: NSStatusItem
    private let toggleItem: NSMenuItem
    private let copyItem: NSMenuItem
    private let accessibilityItem: NSMenuItem
    private let microphoneItem: NSMenuItem
    private let fnItem: NSMenuItem
    private let retryItem: NSMenuItem
    private let updateItem: NSMenuItem
    /// Backs the header card. `refresh()` stays the single point of truth and
    /// pushes finished strings into it; SwiftUI does the redraw, so nothing
    /// here reaches into the view.
    private let state = MenuState()

    /// Fixed, so the menu keeps one width as the state line changes length.
    /// Wide enough for the longest of them and for the Fn row, which spells
    /// out whatever macOS has the key doing instead.
    private static let headerWidth: CGFloat = 300

    /// The last thing dictation produced. In process memory, one at a time,
    /// never written to disk or log by this feature — the log deliberately
    /// records a length and not the words, and a menu item is not the place
    /// to start keeping a transcript history.
    ///
    /// It exists because a transcript can miss: the clipboard route is one
    /// copy away from losing it, and injection can land in the wrong field.
    private var lastTranscript: String?

    private var dictation: Dictation = .idle
    private var model: Model = .ready
    private var needs: SetupNeeds = []
    private var recordingSince: Date?
    private var ticker: Timer?

    /// Clicked "Start recording". The menu does not flip itself: a session
    /// start can fail, so the title only changes once the caller confirms with
    /// `setRecording(true, since:)`.
    var onStartRecording: (() -> Void)?
    /// Clicked "Stop recording".
    var onStopRecording: (() -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var onGrantMicrophone: (() -> Void)?
    var onOpenKeyboardSettings: (() -> Void)?
    var onRetryModel: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    /// The menu is about to draw. The daemon re-reads the permission state
    /// here, so the rows are right at the moment someone looks at them
    /// without anything polling in between.
    var onMenuWillOpen: (() -> Void)?

    init(modelID: String, hotkeyName: String, tapToToggle: Bool) {
        self.hotkeyName = hotkeyName
        self.tapToToggle = tapToToggle
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        // Without this AppKit greys out every item whose target doesn't answer
        // a validation selector, which would disable the header *and* the
        // actions. We drive enablement ourselves instead.
        menu.autoenablesItems = false

        state.line = Self.idleTitle(hotkeyName, tapToToggle)

        // A hosting view inside a menu item, not a run of disabled text lines:
        // the mark, the state and the model read as one card. Fixed width so
        // the menu never resizes as the state line changes length; the height
        // comes from what SwiftUI lays out.
        let header = NSMenuItem()
        let hosting = NSHostingView(rootView: MenuHeaderView(state: state, modelID: modelID))
        hosting.frame.size = NSSize(
            width: Self.headerWidth,
            height: hosting.fittingSize.height
        )
        header.view = hosting
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // The onboarding rows, directly under the card so they are the first
        // thing read. All hidden by default — no separator of their own,
        // because an empty group would leave two rules stacked on every launch
        // after the first.
        accessibilityItem = Self.item(
            "Grant Accessibility…", symbol: "hand.raised",
            action: #selector(grantAccessibilityClicked))
        microphoneItem = Self.item(
            "Grant Microphone…", symbol: "mic.slash",
            action: #selector(grantMicrophoneClicked))
        fnItem = Self.item(
            "Open Keyboard Settings…", symbol: "keyboard",
            action: #selector(openKeyboardSettingsClicked))
        retryItem = Self.item(
            "Retry Model Download", symbol: "arrow.clockwise",
            action: #selector(retryModelClicked))
        for item in [accessibilityItem, microphoneItem, fnItem, retryItem] {
            item.isHidden = true
            menu.addItem(item)
        }

        toggleItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        toggleItem.image = NSImage(
            systemSymbolName: "record.circle", accessibilityDescription: nil)
        menu.addItem(toggleItem)

        copyItem = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyTranscriptClicked),
            keyEquivalent: ""
        )
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        // Nothing to copy until something has been dictated. That is the
        // whole of the empty state.
        copyItem.isEnabled = false
        menu.addItem(copyItem)

        menu.addItem(.separator())

        // Above Settings, because it is the more urgent of the two and it is
        // only ever there when there is something to do.
        updateItem = Self.item(
            "Update", symbol: "arrow.down.circle.fill",
            action: #selector(installUpdateClicked))
        updateItem.isHidden = true
        menu.addItem(updateItem)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(settingsClicked),
            keyEquivalent: ","
        )
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        // No symbol: the system's own Quit items don't carry one.
        let quit = NSMenuItem(
            title: "Quit yap",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        super.init()

        for item in [
            toggleItem, copyItem, settings, quit,
            accessibilityItem, microphoneItem, fnItem, retryItem, updateItem,
        ] {
            item.target = self
        }

        menu.delegate = self
        statusItem.menu = menu

        // Template image, never tinted. Colouring the icon while recording put
        // a second red dot next to the system's own recording indicator and
        // read as an error; the menu carries the state instead.
        statusItem.button?.image = StatusIcon.image(size: 16)
        statusItem.button?.imagePosition = .imageLeft
    }

    private static func item(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
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

    /// The model is on its way. `downloading` distinguishes a first run — which
    /// is a several-hundred-megabyte wait — from a warm cache, which is a
    /// third of a second.
    func setModelLoading(downloading: Bool, sizeMB: Int) {
        model = .loading(downloading ? "downloading model (~\(sizeMB) MB)…" : "loading model…")
        refresh()
    }

    /// Warm-up threw. Deliberately not fatal: the rest of the app still works,
    /// and the row below offers the only thing that can help.
    func setModelFailed() {
        model = .failed
        refresh()
    }

    func setModelReady() {
        model = .ready
        refresh()
    }

    /// A staged update, or nil for none. `enabled` is false while a recording
    /// or a press is live: restarting then would cost audio the user is
    /// relying on, and a greyed row says so better than a refusal would.
    func setUpdate(version: String?, enabled: Bool) {
        updateItem.isHidden = version == nil
        updateItem.isEnabled = enabled
        if let version {
            updateItem.title = "Update to \(version) · Restart"
        }
        // The only time the icon says anything on its own. A dot, not a
        // colour: a tinted mark next to the system's recording indicator
        // already read as an error once.
        statusItem.button?.image = StatusIcon.image(size: 16, badged: version != nil)
    }

    /// What is still missing, and what macOS has Fn doing instead when that is
    /// the thing missing.
    func setSetupNeeds(_ needs: SetupNeeds, fnAction: String?) {
        self.needs = needs
        if let fnAction {
            fnItem.title = "Fn key is set to \(fnAction) — Open Keyboard Settings…"
        }
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

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }

    /// Single point of truth for the toggle title, the onboarding rows and the
    /// header's state line. Called on every state change and once a second
    /// while a session records.
    private func refresh() {
        if let recordingSince {
            let elapsed = formatElapsed(Date().timeIntervalSince(recordingSince))
            toggleItem.title = "Stop Recording · \(elapsed)"
            toggleItem.image = NSImage(
                systemSymbolName: "stop.circle", accessibilityDescription: nil)
        } else {
            toggleItem.title = "Start Recording"
            toggleItem.image = NSImage(
                systemSymbolName: "record.circle", accessibilityDescription: nil)
        }

        accessibilityItem.isHidden = !needs.contains(.accessibility)
        microphoneItem.isHidden = !needs.contains(.microphone)
        fnItem.isHidden = !needs.contains(.fnMapping)
        if case .failed = model {
            retryItem.isHidden = false
        } else {
            retryItem.isHidden = true
        }

        // Precedence, most immediate first: what you are doing now, then what
        // is running, then what is stopping yap working at all, then the model,
        // then the resting line.
        switch dictation {
        case .listening:
            state.line = "● listening"
        case .transcribing:
            state.line = "transcribing…"
        case .idle:
            if let recordingSince {
                let elapsed = formatElapsed(Date().timeIntervalSince(recordingSince))
                state.line = "● recording · \(elapsed)"
            } else if !needs.isEmpty {
                state.line = "needs setup"
            } else {
                switch model {
                case .loading(let line): state.line = line
                case .failed: state.line = "model download failed"
                case .ready: state.line = Self.idleTitle(hotkeyName, tapToToggle)
                }
            }
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

    @objc private func grantAccessibilityClicked() { onGrantAccessibility?() }
    @objc private func grantMicrophoneClicked() { onGrantMicrophone?() }
    @objc private func openKeyboardSettingsClicked() { onOpenKeyboardSettings?() }
    @objc private func retryModelClicked() { onRetryModel?() }
    @objc private func installUpdateClicked() { onInstallUpdate?() }

    /// Copies the last transcript, for the press that landed somewhere wrong
    /// or on a clipboard that has since moved on.
    @objc private func copyTranscriptClicked() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    /// Opens the Settings window, building it on first click. "Open Config
    /// File" lives inside it, for anyone who would rather type.
    @objc private func settingsClicked() {
        SettingsWindow.show()
    }

    /// No callback: quitting is unconditional. Anything that has to run on the
    /// way out belongs in the app delegate's `applicationWillTerminate`, which
    /// also covers Cmd-Q and a launchd stop.
    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

// MARK: -

/// The one line of the header card that changes. Mutated by
/// `MenuBarController.refresh()`; the view redraws itself.
@MainActor
private final class MenuState: ObservableObject {
    @Published var line: String = ""
}

/// The card at the top of the dropdown: the yap mark, what it is doing, and
/// which model it will do it with.
private struct MenuHeaderView: View {
    @ObservedObject var state: MenuState
    /// Fixed for the life of the process — the model is chosen once, at launch.
    let modelID: String

    var body: some View {
        HStack(spacing: 10) {
            // Same treatment as the prompt pill's icon, so the two surfaces
            // read as one app.
            Image(nsImage: StatusIcon.image(size: 19) ?? NSImage())
                .renderingMode(.template)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("yap").font(.headline)
                Text(state.line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(modelID)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
