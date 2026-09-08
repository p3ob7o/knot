import KnotKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: EditorModel
    @State private var working = AppSettings()
    @State private var base = AppSettings()
    @State private var baseRevision: Revision?
    @State private var pickerPresented = false
    @State private var errorMessage: String?
    @State private var applying = false
    @State private var resetConfirmation = false
    @State private var eraseConfirmation = false
    @State private var localDataMessage: String?
    #if os(macOS)
    @State private var shortcut = ShortcutStore.load()
    @State private var baseShortcut = ShortcutStore.load()
    @State private var hotkeyError: String?
    @State private var legacyBareApproved = false
    @State private var baseLegacyBareApproved = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Form {
                vaultSection
                #if os(macOS)
                shortcutSection
                #endif
                dailySection
                inboxSection
                attachmentSection
                routingSection
                localDataSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("Settings")
        .onAppear { reload() }
        .folderPicker(isPresented: $pickerPresented) { url in
            Task {
                do { try await model.selectVault(url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("Reset configuration?", isPresented: $resetConfirmation) {
            Button("Reset", role: .destructive) { model.resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Drafts and pending captures remain in local recovery. Vault files are not deleted.")
        }
        .alert("Erase local drafts?", isPresented: $eraseConfirmation) {
            Button("Erase Drafts", role: .destructive) { Task { await eraseDrafts() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases active and parked local drafts. Pending captures and every vault file remain unchanged.")
        }
    }

    private var vaultSection: some View {
        Section("Vault") {
            LabeledContent("Connected") {
                Label(model.vaultName ?? "None", systemImage: model.hasVault ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.exclamationmark")
            }
            HStack {
                Button("Change", systemImage: "folder") { pickerPresented = true }
                Button("Reimport", systemImage: "arrow.clockwise") {
                    Task { await reimport() }
                }
                .disabled(!model.hasVault)
            }
            if let count = model.configurationDiff?.entries.count, count > 0 {
                HStack {
                    Label("\(count) imported values", systemImage: "arrow.down.doc")
                    Spacer()
                    Button("Undo Import") { Task { await undoImport() } }
                }
            }
        }
    }

    #if os(macOS)
    private var shortcutSection: some View {
        Section("Global Shortcut") {
            ShortcutPickerView(shortcut: $shortcut)
            if let shortcut, shortcut.isLegacyBare {
                Toggle("Enable imported bare key", isOn: $legacyBareApproved)
                Label("A bare shortcut can intercept normal typing. Confirm it here before Knot enables it.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let hotkeyError {
                Label(hotkeyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }
    #endif

    private var dailySection: some View {
        Section("Daily Note") {
            LabeledContent("Folder") { field(TextField("Daily", text: $working.dailyFolder)) }
            LabeledContent("Filename") { field(TextField("YYYY-MM-DD", text: $working.dailyFilenameFormat)) }
            LabeledContent("Heading") { field(TextField("## Quick notes", text: $working.dailyHeading)) }
            LabeledContent("Bullet") { field(TextField("- {{HH:mm}} {{content}}", text: $working.dailyBulletFormat)) }
            LabeledContent("Preview") {
                Text(dailyPreview).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private var inboxSection: some View {
        Section("Inbox") {
            LabeledContent("Folder") { field(TextField("Inbox", text: $working.inboxFolder)) }
            LabeledContent("Filename") { field(TextField("YYYY-MM-DD HHmm", text: $working.inboxFilenameFormat)) }
        }
    }

    private var attachmentSection: some View {
        Section("Attachments") {
            LabeledContent("Destination") { field(TextField("Vault root", text: $working.attachmentFolderPath)) }
        }
    }

    private var routingSection: some View {
        Section("Automatic Routing") {
            LabeledContent("Daily limit") {
                TextField("280", value: $working.routingMaxChars, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            Toggle("Multiline captures go to Inbox", isOn: $working.routingRequiresSingleLine)
        }
    }

    private var localDataSection: some View {
        Group {
            Section("Local Data") {
            Button("Erase Local Drafts", systemImage: "trash", role: .destructive) {
                eraseConfirmation = true
            }
            if let localDataMessage {
                Text(localDataMessage).font(.callout).foregroundStyle(.secondary)
            }
        }
            Section("Configuration") {
                Button("Reset Configuration", systemImage: "arrow.counterclockwise", role: .destructive) {
                    resetConfirmation = true
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { reload() }.disabled(!isDirty || applying)
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Apply") { Task { await apply() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || applying)
            }
        }
        .padding(16)
    }

    private func field<V: View>(_ value: V) -> some View {
        value.textFieldStyle(.roundedBorder).frame(width: 260)
    }

    private var dailyPreview: String {
        guard let pattern = try? CompiledDatePattern(working.dailyFilenameFormat) else { return "Invalid format" }
        return ([working.dailyFolder, pattern.render(date: Date(), timeZone: .current) + ".md"]
            .filter { !$0.isEmpty }).joined(separator: "/")
    }

    private var isDirty: Bool {
        #if os(macOS)
        working != base || shortcut != baseShortcut || legacyBareApproved != baseLegacyBareApproved
        #else
        working != base
        #endif
    }

    private func reload() {
        working = model.settings
        base = model.settings
        baseRevision = model.settingsRevision
        errorMessage = nil
        #if os(macOS)
        shortcut = ShortcutStore.load()
        baseShortcut = shortcut
        legacyBareApproved = shortcut.map { ShortcutStore.isLegacyBareApproved($0) } ?? false
        baseLegacyBareApproved = legacyBareApproved
        hotkeyError = HotkeyManager.shared.lastRegistrationError
        #endif
    }

    private func apply() async {
        applying = true
        errorMessage = nil
        do {
            _ = try working.validated()
            #if os(macOS)
            if let shortcut, shortcut.isLegacyBare, !legacyBareApproved {
                throw HotkeyRegistrationError.legacyApprovalRequired
            }
            try HotkeyManager.shared.replace(
                current: baseShortcut, with: shortcut, allowLegacyBare: legacyBareApproved
            )
            do {
                try await model.applySettings(working, expectedRevision: baseRevision)
            } catch {
                try? HotkeyManager.shared.replace(
                    current: shortcut, with: baseShortcut, allowLegacyBare: baseLegacyBareApproved
                )
                throw error
            }
            ShortcutStore.save(shortcut, approvingLegacyBare: legacyBareApproved)
            baseShortcut = shortcut
            baseLegacyBareApproved = legacyBareApproved
            #else
            try await model.applySettings(working, expectedRevision: baseRevision)
            #endif
            baseRevision = model.settingsRevision
            base = working
        } catch { errorMessage = error.localizedDescription }
        applying = false
    }

    private func eraseDrafts() async {
        do {
            let count = try await model.eraseLocalDrafts()
            localDataMessage = count == 1 ? "Erased 1 local draft." : "Erased \(count) local drafts."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reimport() async {
        do {
            try await model.reimportConfiguration()
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func undoImport() async {
        do {
            try await model.undoConfigurationImport()
            reload()
        } catch { errorMessage = error.localizedDescription }
    }
}
