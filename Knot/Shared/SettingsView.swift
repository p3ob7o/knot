import SwiftUI
import KnotKit

/// Reveals the configurable knobs: vault folder, paths, daily-note format,
/// and routing thresholds. Live-binds to the model's settings so changes
/// take effect immediately.
struct SettingsView: View {
    @Bindable var model: EditorModel
    @State private var pickerPresented = false
    @State private var pickerError: String?
    @State private var resetConfirmation = false
    #if os(macOS)
    @State private var shortcut: Shortcut = ShortcutStore.load()
    @State private var hotkeyError: String?
    #endif

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
                ShortcutPickerView(shortcut: $shortcut)
                    .onChange(of: shortcut) { _, newValue in
                        ShortcutStore.save(newValue)
                        NotificationCenter.default.post(name: .knotShortcutChanged, object: nil)
                    }
                if let hotkeyError {
                    Label(hotkeyError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Toggle Knot")
            } footer: {
                Text("Click the field, then press any single character with any combination of ⌃⌥⇧⌘. Backspace clears; Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onReceive(NotificationCenter.default.publisher(for: .knotHotkeyStatusChanged)) { _ in
                hotkeyError = HotkeyManager.shared.lastRegistrationError
            }
            .task {
                hotkeyError = HotkeyManager.shared.lastRegistrationError
            }
            #endif

            Section("Folders") {
                LabeledContent("Daily folder") {
                    settingsField(
                        TextField("Daily", text: settingsBinding(\.dailyFolder))
                    )
                }
                LabeledContent("Inbox folder") {
                    settingsField(
                        TextField("Inbox", text: settingsBinding(\.inboxFolder))
                    )
                }
            }

            Section {
                LabeledContent("Filename pattern") {
                    settingsField(
                        TextField("YYYY-MM-DD", text: settingsBinding(\.dailyFilenameFormat))
                    )
                }
                LabeledContent("Heading") {
                    settingsField(
                        TextField("## Quick notes", text: settingsBinding(\.dailyHeading))
                    )
                }
                LabeledContent("Bullet format") {
                    settingsField(
                        TextField("- {{HH:mm}} {{content}}", text: settingsBinding(\.dailyBulletFormat))
                    )
                }
            } header: {
                Text("Daily note")
            } footer: {
                formatHelp
            }

            Section {
                LabeledContent("Filename") {
                    settingsField(
                        TextField("YYYY-MM-DD HHmm", text: settingsBinding(\.inboxFilenameFormat))
                    )
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

            Section {
                Button(role: .destructive) {
                    resetConfirmation = true
                } label: {
                    Label("Reset settings to defaults", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Clears your vault, shortcut, and every preference on this page. The next time you open Knot you'll start from the onboarding screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .alert("Reset all settings?", isPresented: $resetConfirmation) {
            Button("Reset", role: .destructive) {
                model.resetAllSettings()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This forgets your vault, the global shortcut, and every preference on this page. You'll need to pick the vault folder again.")
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .knotSettingsReset)) { _ in
            // The hotkey field reads from @State, so reload it explicitly
            // when the platform layer has cleared the persisted shortcut.
            shortcut = ShortcutStore.load()
        }
        #endif
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

    /// Fixed width for the editable column. `LabeledContent` inside a
    /// grouped Form silently expands flexible content (like a bare
    /// `TextField`) back to fill the row, so we use a hard
    /// `.frame(width:)` plus a leading `Spacer()` to right-align the
    /// field and leave breathing room before the scroller.
    private static let fieldWidth: CGFloat = 240

    @ViewBuilder
    private func settingsField<Field: View>(_ field: Field) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            field
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.fieldWidth)
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
