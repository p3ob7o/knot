import AVFoundation
import AppKit
import Carbon
import KnotApp
import KnotCore
import KnotUI
import ServiceManagement
import SwiftUI

struct MacSettings: View {
    let shell: Shell
    @State private var model: SettingsViewModel
    @State private var destination: SettingsRow?
    @State private var permission = MacMicrophone.status

    init(shell: Shell) {
        self.shell = shell
        var environment = shell.environment
        if !shell.isTestLaunch {
            environment.settings = MacDeviceSettings(settings: environment.settings, gates: environment.gates)
        }
        _model = State(
            initialValue: SettingsViewModel(
                environment: environment, context: shell.composition.context, platform: .mac))
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsForm(model, open: { destination = $0 })
                .formStyle(.grouped)
            Divider()
            Form {
                LabeledContent("Microphone") {
                    switch permission {
                    case .authorized: Text("Allowed")
                    case .notDetermined:
                        Button("Allow Microphone…") {
                            Task { permission = await MacMicrophone.request() }
                        }
                    case .denied, .restricted:
                        Button("Open System Settings…", action: MacMicrophone.openPrivacySettings)
                    @unknown default: Text("Unavailable")
                    }
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items…", action: SMAppService.openSystemSettingsLoginItems)
                }
                if shell.environment.gates.isOpen(.commandLine) {
                    if model.settings.commandLineAccess {
                        CommandLineInstructions()
                    }
                } else {
                    Text("Command-line access is unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 540, height: 640)
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = MacMicrophone.status
            Task { await model.load() }
        }
        .sheet(item: $destination, onDismiss: reload) { row in
            switch row {
            case .hotkey:
                HotkeyPicker(recording: shell.recording)
            case .exportAll:
                MacNotesExport(environment: shell.environment)
            case .recentlyDeleted:
                RecentlyDeleted()
            case .about:
                MacAbout(app: shell.composition, flush: shell.flush)
            default:
                EmptyView()
            }
        }
    }

    private func reload() { Task { await model.load() } }
}

enum MacMicrophone {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func request() async -> AVAuthorizationStatus {
        if ProcessSigns.current.holding.isEmpty {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return status
    }

    @MainActor
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The shared form hands its settings save here. A failed registration leaves the previous
/// setting in place. The OS's status remains authoritative after System Settings changes.
@MainActor
private final class MacDeviceSettings: SettingsStore {
    let settings: any SettingsStore
    let gates: any FeatureGates

    init(settings: any SettingsStore, gates: any FeatureGates) {
        self.settings = settings
        self.gates = gates
    }

    func load() async throws(KnotError) -> KnotCore.Settings {
        var value = try await settings.load()
        let status = SMAppService.mainApp.status
        value.launchAtLogin = status == .enabled || status == .requiresApproval
        if !gates.isOpen(.commandLine) { value.commandLineAccess = false }
        return value
    }

    func save(_ next: KnotCore.Settings) async throws(KnotError) {
        guard !next.commandLineAccess || gates.isOpen(.commandLine) else { throw .accessOff }
        let earlier = try await load()
        let changesLogin = earlier.launchAtLogin != next.launchAtLogin
        if changesLogin { try setLogin(next.launchAtLogin) }
        do {
            var merged = next
            // The shortcut picker saves independently. The form has no shortcut editing row.
            merged.hotkey = (try await settings.load()).hotkey
            try await settings.save(merged)
        } catch {
            if changesLogin { try? setLogin(earlier.launchAtLogin) }
            throw error
        }
    }

    nonisolated func changes() -> AsyncStream<KnotCore.Settings> { settings.changes() }

    private func setLogin(_ enabled: Bool) throws(KnotError) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw .unexpected
        }
    }
}

private struct CommandLineInstructions: View {
    private var tool: URL? {
        let name = LiveConfiguration.currentFlavour() == .milestone ? "knot-cli" : "knot-dev"
        return Bundle.main.url(forAuxiliaryExecutable: name)
    }

    var body: some View {
        if let tool {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add the command to a directory on your PATH.")
                commandLine(shim(tool.path), label: "Copy shell command")
                Text("Use this executable path with the mcp argument. Sandboxed clients can’t start the tool.")
                commandLine(tool.path, label: "Copy executable path")
            }
            .font(.callout)
        }
    }

    private func shim(_ path: String) -> String {
        let command = LiveConfiguration.currentFlavour() == .milestone ? "knot" : "knot-dev"
        return "mkdir -p \"$HOME/.local/bin\" && printf '%s\\n' '#!/bin/sh' "
            + quoted("exec \(quoted(path)) \"$@\"")
            + " > \"$HOME/.local/bin/\(command)\" && chmod +x \"$HOME/.local/bin/\(command)\""
    }

    private func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func commandLine(_ line: String, label: String) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: line).font(.caption.monospaced()).textSelection(.enabled)
            Spacer()
            Button(label, systemImage: "document.on.document") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
            .labelStyle(.iconOnly)
            .help(label)
        }
    }
}

private struct HotkeyPicker: View {
    @Environment(\.dismiss) private var dismiss
    let recording: MacCaptureCoordinator
    @State private var listening = false
    @State private var saving = false
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hotkey").font(.headline)
            Text("Tap to type. Hold for 250 ms to record. Release to stop.")
            Text("Choose a function key or press a key with a modifier.")
                .foregroundStyle(.secondary)
            if invalid {
                Text("A shortcut needs a function key or a key with a modifier.")
            } else if let problem = recording.shortcutProblem {
                Text(problem)
            }
            if listening { Text("Press a shortcut now.").accessibilityAddTraits(.updatesFrequently) }
            HStack {
                Button(listening ? "Cancel Recording" : "Record Shortcut") { listening.toggle() }
                    .disabled(saving)
                if recording.shortcut != nil {
                    Button("Clear Shortcut") { save(nil) }.disabled(saving)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(HotkeyEventReader(listening: listening && !saving, onKey: keyPressed))
    }

    private func keyPressed(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape), Hotkey.Modifiers(eventFlags: event.modifierFlags).isEmpty {
            listening = false
            return
        }
        do {
            let shortcut = try Hotkey(event: event)
            invalid = false
            save(shortcut)
        } catch {
            invalid = true
        }
    }

    private func save(_ shortcut: Hotkey?) {
        saving = true
        Task {
            let saved = await recording.saveShortcut(shortcut)
            saving = false
            if saved { dismiss() }
        }
    }
}

private struct HotkeyEventReader: NSViewRepresentable {
    let listening: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyReader { KeyReader() }

    func updateNSView(_ view: KeyReader, context: Context) {
        view.listen(listening ? onKey : nil)
    }

    static func dismantleNSView(_ view: KeyReader, coordinator: ()) { view.listen(nil) }

    final class KeyReader: NSView {
        private var monitor: Any?
        private var action: ((NSEvent) -> Void)?

        func listen(_ action: ((NSEvent) -> Void)?) {
            self.action = action
            if action == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window, event.window === window else { return event }
                    self.action?(event)
                    return nil
                }
            }
        }
    }
}
