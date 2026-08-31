import AppKit
import SwiftUI

// MARK: - Panes

struct DictationPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $model.hotkey) {
                    ForEach(HotkeyMonitor.Key.allCases, id: \.self) { key in
                        Text(SettingsModel.label(for: key)).tag(key.rawValue)
                    }
                }
                Toggle("Tap to toggle", isOn: $model.tapToToggle)
                Toggle("Show recording pill", isOn: $model.overlay)
                Toggle("Press Return after dictating", isOn: $model.newlineAfterRelease)
                Toggle("Mute speakers while dictating", isOn: $model.muteOutput)
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
            } footer: {
                RestartNote()
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
                IgnoredAppList(
                    apps: model.excludedApps,
                    selection: $selection,
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

// MARK: - Ignored apps

/// The bordered list with `+` and `−` under it that macOS uses everywhere an
/// editable set of things lives. Familiar beats invented here: anyone who has
/// added a login item already knows how to work this.
private struct IgnoredAppList: View {
    let apps: [SettingsModel.ExcludedApp]
    @Binding var selection: String?
    let onAdd: () -> Void
    let onRemove: () -> Void

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
                    Text("Apps you ignore never trigger a meeting prompt.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }

            Divider()
            HStack(spacing: 0) {
                stepper("plus", help: "Ignore an app…", action: onAdd)
                Divider().frame(height: 16)
                stepper("minus", help: "Stop ignoring the selected app", action: onRemove)
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

    private func row(_ app: SettingsModel.ExcludedApp) -> some View {
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
                Text(app.installed ? app.id : "Not installed")
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
        .onTapGesture { selection = selected ? nil : app.id }
    }

    /// A drawn placeholder rather than the generic application icon: a blank
    /// squircle beside two real app icons reads as a failed image load, and
    /// the row is trying to say the app is gone.
    @ViewBuilder
    private func icon(_ app: SettingsModel.ExcludedApp) -> some View {
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
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
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
