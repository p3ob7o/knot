import SwiftUI
import KnotKit

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

            Section("Daily note") {
                LabeledContent("Filename pattern") {
                    TextField("yyyy-MM-dd", text: settingsBinding(\.dailyFilenameFormat))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
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
                Text("Placeholders: {{HH:mm}}, {{content}}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Inbox") {
                LabeledContent("Filename prefix") {
                    TextField("yyyy-MM-dd HHmm", text: settingsBinding(\.inboxFilenameFormat))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
                }
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
