import AppKit
import SwiftUI

// MARK: - Panes

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            } footer: {
                Text("Starts yap automatically at your next login.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                LabeledContent("Version") { Text(model.version) }
                HStack(spacing: 8) {
                    Text(model.updateStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button("Check Now") { model.checkForUpdates() }
                }
            }
            Section {
                Button("Show Logs in Finder") { model.showLogs() }
            }
        }
        .formStyle(.grouped)
    }
}

struct DictationPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    HStack(spacing: 8) {
                        HotkeyRecorder(value: $model.hotkey)
                            .frame(width: 150, height: 24)
                        Button("Reset to Fn") { model.hotkey = HotkeyBinding.fn.serialized }
                            .buttonStyle(.link)
                    }
                }
                Toggle("Tap to toggle", isOn: $model.tapToToggle)
                Toggle("Show recording pill", isOn: $model.overlay)
                Toggle("Press Return after dictating", isOn: $model.newlineAfterRelease)
                Toggle("Mute speakers while dictating", isOn: $model.muteOutput)
            } footer: {
                Text("Click the field, then hold the key or chord you want.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Model", selection: $model.model) {
                    ForEach(ModelRegistry.shared, id: \.id) { entry in
                        Text("\(entry.displayName) · \(entry.sizeMB) MB").tag(entry.id)
                    }
                }
            } footer: {
                RestartNote()
            }
        }
        .formStyle(.grouped)
    }
}

struct RecordingPane: View {
    @ObservedObject var model: SettingsModel
    @State private var routeSelection: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(model.recordingsDir)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseRecordingsDir() }
                    }
                }
            }
            Section {
                AppList(
                    apps: model.routes,
                    selection: $routeSelection,
                    emptyText: "Calls from apps you add here are saved to their own folder.",
                    addHelp: "Route an app…",
                    removeHelp: "Stop routing the selected app",
                    onAdd: { model.addRoute() },
                    onRemove: {
                        guard let routeSelection else { return }
                        model.removeRoute(routeSelection)
                        self.routeSelection = nil
                    },
                    // Named by detection since launch: the only way to route
                    // a daemon, which has no .app for the picker to find.
                    addChoices: model.seenClients.map { app in
                        AppList.AddChoice(id: app.bundleID, label: app.name) {
                            model.addRoute(for: app)
                        }
                    },
                    onActivate: { model.changeRouteFolder($0) }
                )
            } header: {
                Text("Route by app")
            } footer: {
                Text("Calls detected from these apps are saved here instead of the folder above. Double-click a row to change its folder. Anything detection has named since yap started is listed under +, so a background process with no app can be routed too.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Transcribe recordings automatically", isOn: $model.transcriptionEnabled)
                Toggle("Voice processing on the mic", isOn: $model.micVoiceProcessing)
            }
            Section {
                LabeledContent("Run after each recording") {
                    TextField("shell command", text: $model.onStop)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
            } footer: {
                Text("Given the session folder as its argument.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct MeetingsPane: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Toggle("Detect meetings", isOn: $model.meetingDetection)
                Toggle("Record without asking", isOn: $model.meetingAutoRecord)
                    .disabled(!model.meetingDetection)
            }
            Section("Ignored apps") {
                AppList(
                    apps: model.excludedApps,
                    selection: $selection,
                    emptyText: "Apps you ignore never trigger a meeting prompt.",
                    addHelp: "Ignore an app…",
                    removeHelp: "Stop ignoring the selected app",
                    onAdd: { model.addExcludedApp() },
                    onRemove: {
                        guard let selection else { return }
                        model.removeExcludedApp(selection)
                        self.selection = nil
                    }
                )
                .disabled(!model.meetingDetection)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings that only the next launch reads. Said once, next to the control it
/// applies to, rather than as a line floating under a whole section.
private struct RestartNote: View {
    var body: some View {
        Label("Applies after yap restarts.", systemImage: "arrow.clockwise")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

// MARK: - App list

/// The bordered list with `+` and `−` under it that macOS uses everywhere an
/// editable set of things lives. Familiar beats invented here: anyone who has
/// added a login item already knows how to work this. Serves both the ignored
/// apps and the recording routes; only the words and the subtitle differ.
private struct AppList: View {
    let apps: [SettingsModel.AppRow]
    @Binding var selection: String?
    let emptyText: String
    let addHelp: String
    let removeHelp: String
    let onAdd: () -> Void
    let onRemove: () -> Void
    /// Entries offered beside the picker. Any at all turn `+` into a menu,
    /// with the picker first; none leaves it the plain button.
    var addChoices: [AddChoice] = []
    /// Double-click on a row, for lists where a row has something to edit.
    var onActivate: ((String) -> Void)? = nil

    struct AddChoice: Identifiable {
        let id: String
        let label: String
        let action: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Between rows, never after the last: a hairline floating
                    // in the empty space under the final row reads as content
                    // clipped off the bottom.
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 {
                            Divider().padding(.leading, 35)
                        }
                        row(app)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay {
                if apps.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }

            Divider()
            HStack(spacing: 0) {
                if addChoices.isEmpty {
                    stepper("plus", help: addHelp, action: onAdd)
                } else {
                    Menu {
                        Button("Choose Application…", action: onAdd)
                        Divider()
                        ForEach(addChoices) { choice in
                            Button(choice.label, action: choice.action)
                        }
                    } label: {
                        symbol("plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(addHelp)
                }
                Divider().frame(height: 16)
                stepper("minus", help: removeHelp, action: onRemove)
                    .disabled(selection == nil)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .background(.quaternary.opacity(0.35))
        }
        // Four rows before it scrolls; three fit without clipping the second
        // line of the last one, which 138 did.
        .frame(height: 168)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    private func row(_ app: SettingsModel.AppRow) -> some View {
        let selected = selection == app.id
        return HStack(spacing: 8) {
            icon(app)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                // An uninstalled app has no name to show, so the identifier
                // moves up and becomes the row. Printing it twice — once as a
                // stand-in name and once as the subtitle — read as a debug
                // dump rather than a list of apps.
                Text(app.installed ? app.name : app.id)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(
                        selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : .clear)
        .contentShape(Rectangle())
        // The double-tap sits inside the single so it gets first refusal;
        // the other way round the single tap eats both clicks.
        .onTapGesture(count: 2) { onActivate?(app.id) }
        .onTapGesture { selection = selected ? nil : app.id }
    }

    /// A drawn placeholder rather than the generic application icon: a blank
    /// squircle beside two real app icons reads as a failed image load, and
    /// the row is trying to say the app is gone.
    @ViewBuilder
    private func icon(_ app: SettingsModel.AppRow) -> some View {
        if let image = app.icon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 15))
                .foregroundStyle(selection == app.id ? AnyShapeStyle(.white.opacity(0.8))
                    : AnyShapeStyle(.secondary))
        }
    }

    private func stepper(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { self.symbol(symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 30, height: 24)
            .contentShape(Rectangle())
    }
}

// MARK: - Material

/// The sidebar's own material. `List(.sidebar)` draws its selection and
/// spacing correctly in a plain window but not its translucency, and a flat
/// gray rail beside a vibrant one is the tell that a window was assembled.
struct SidebarMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
