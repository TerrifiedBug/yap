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
///
/// Laid out the way macOS lays settings out: a source list on the left, one
/// short pane on the right. Three panes that each fit on screen beat one
/// column you scroll, and the rail doubles as the map — you can see everything
/// yap can be told to do without touching anything.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    /// Rail plus pane, sized to the tallest pane — Meetings, whose app list
    /// is the only thing here that grows. The shorter panes carry a little
    /// slack, which beats one pane scrolling on open.
    private static let contentSize = NSSize(width: 660, height: 420)

    static func show() {
        let window = self.window ?? make()
        // A fresh view on every open, so the form reflects the file as it is
        // now — including hand edits made since the last time it was open.
        let controller = NSHostingController(rootView: SettingsView())
        // The window owns its size, not the form. Both halves of that matter:
        // `sizingOptions = []` stops the controller pushing a preferred size,
        // and restoring the size around the swap stops AppKit collapsing the
        // window onto the content's *minimum* height, which would also throw
        // away a size the user chose.
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
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "yap Settings"
        // NSWindow defaults to release-on-close, which over-releases under ARC
        // — and we keep this one around between opens.
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 380)
        window.center()
        self.window = window
        return window
    }
}

// MARK: - Panes

/// The four things yap can be told about, in the order you meet them: how it
/// runs, the key you hold, what happens to a recording, and when to offer one.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case dictation
    case recording
    case meetings

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .recording: return "Recording"
        case .meetings: return "Meetings"
        }
    }

    /// One line under the title. Says what the pane is for, so nobody has to
    /// infer it from the controls.
    var summary: String {
        switch self {
        case .general: return "Login, updates, logs."
        case .dictation: return "The key you hold, and what happens when you let go."
        case .recording: return "Where sessions land, and what runs after one."
        case .meetings: return "Whether yap offers to record when something else takes the mic."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .dictation: return "waveform"
        case .recording: return "recordingtape"
        case .meetings: return "person.wave.2.fill"
        }
    }

    /// Rail chips only, for scanning. Red goes to Recording deliberately: it
    /// is the record light, the same thing it means everywhere else in yap.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .dictation: return .accentColor
        case .recording: return .red
        case .meetings: return .indigo
        }
    }
}

// MARK: - View

private struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @State private var pane: SettingsPane = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                rail
                Divider()
                detail
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rail: some View {
        List(SettingsPane.allCases, selection: $pane) { item in
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(item.tint, in: RoundedRectangle(cornerRadius: 5))
            }
            .tag(item)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .background(SidebarMaterial(material: .sidebar))
        .frame(width: 186)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(pane.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            switch pane {
            case .general: GeneralPane(model: model)
            case .dictation: DictationPane(model: model)
            case .recording: RecordingPane(model: model)
            case .meetings: MeetingsPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The file every control above writes to, named rather than hidden — the
    /// window is a GUI over it, and saying so is what makes hand-editing and
    /// clicking feel like the same act.
    private var footer: some View {
        HStack(spacing: 10) {
            Text((Config.path.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Button("Open Config File") { model.openConfigFile() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

