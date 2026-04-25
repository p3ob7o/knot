import SwiftUI
import KnotKit
#if os(macOS)
import KeyboardShortcuts
#endif

/// Reveals the configurable knobs: vault folder, paths, daily-note format,
/// and routing thresholds. Live-binds to the model's settings so changes
/// take effect immediately.
struct SettingsView: View {
    @Bindable var model: EditorModel
    @State private var pickerPresented = false
    @State private var pickerError: String?

    var body: some View {
        Form {
            Section("Vault") {
                HStack {
                    Image(systemName: "folder")
                    Text(model.vaultName ?? "No vault selected")
                        .font(.body.weight(.medium))
                    Spacer()
                    Button("Change…") { pickerPresented = true }
                }
                if let pickerError {
                    Text(pickerError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button(role: .destructive) {
                    model.clearVault()
                } label: {
                    Text("Disconnect vault")
                }
                .disabled(!model.hasVault)
            }

            #if os(macOS)
            Section {
                LabeledContent("Toggle Knot") {
                    KeyboardShortcuts.Recorder(for: .toggleKnot)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Press the shortcut anywhere on macOS to open or dismiss the Knot popover. Click the recorder, press the keys you want, then release. Click the × to clear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("Folders") {
                LabeledContent("Daily folder") {
                    TextField("Daily", text: settingsBinding(\.dailyFolder))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
                }
                LabeledContent("Inbox folder") {
                    TextField("Inbox", text: settingsBinding(\.inboxFolder))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
                }
            }

            Section {
                LabeledContent("Filename pattern") {
                    TextField("YYYY-MM-DD", text: settingsBinding(\.dailyFilenameFormat))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                }
                LabeledContent("Heading") {
                    TextField("## Quick notes", text: settingsBinding(\.dailyHeading))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                }
                LabeledContent("Bullet format") {
                    TextField("- {{HH:mm}} {{content}}", text: settingsBinding(\.dailyBulletFormat))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                }
            } header: {
                Text("Daily note")
            } footer: {
                formatHelp
            }

            Section {
                LabeledContent("Filename") {
                    TextField("YYYY-MM-DD HHmm", text: settingsBinding(\.inboxFilenameFormat))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                }
            } header: {
                Text("Inbox")
            } footer: {
                Text("Slashes create subfolders. Wrap literal text in [brackets] — e.g. [Notes]/YYYY-MM-DD produces Notes/2026-04-25. The Inbox folder above is already literal, so prefer putting fixed parent names there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Routing") {
                LabeledContent("Max characters for daily") {
                    TextField("280", value: settingsBinding(\.routingMaxChars), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Toggle(
                    "Force inbox when note has multiple lines",
                    isOn: settingsBinding(\.routingRequiresSingleLine)
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .folderPicker(isPresented: $pickerPresented) { url in
            do {
                try model.setVault(url: url)
            } catch {
                pickerError = error.localizedDescription
            }
        }
    }

    private var formatHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Filename and bullet patterns use Moment.js display format — the same conventions as Obsidian's Daily Notes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Slashes in the filename pattern create subfolders. Wrap literal text in [brackets] (otherwise letters like Q, k, and s are interpreted as date tokens). In the bullet, use {{...}} for date placeholders plus {{content}} for the note text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(
                "Open the Moment.js format reference",
                destination: URL(string: "https://momentjs.com/docs/#/displaying/format/")!
            )
            .font(.caption)
        }
    }

    private func settingsBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = model.settings
                updated[keyPath: keyPath] = newValue
                model.updateSettings(updated)
            }
        )
    }
}
