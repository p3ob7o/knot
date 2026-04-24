import SwiftUI
import KnotKit
#if os(iOS)
import UIKit
#endif

/// First-launch flow. Single screen: explain what Knot does, then ask the
/// user to pick their vault folder. Once a folder is picked, we show a
/// confirmation and dismiss to the editor.
struct OnboardingView: View {
    @Bindable var model: EditorModel
    var onDone: () -> Void

    @State private var pickerPresented = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Knot")
                    .font(.title.bold())
                Text("Quick capture into your Obsidian vault.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("Pick your vault folder once.")
                bullet("Short notes append to today's daily file.")
                bullet("Longer notes go to your inbox.")
                bullet("Local-only — no servers, no accounts.")
            }
            .font(.callout)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button {
                pickerPresented = true
            } label: {
                Label("Pick vault folder…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .folderPicker(isPresented: $pickerPresented) { url in
            do {
                try model.setVault(url: url)
                onDone()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Folder picker, platform-conditional

extension View {
    /// Presents a native folder picker. On macOS this uses `NSOpenPanel`; on
    /// iOS it presents `UIDocumentPickerViewController` configured to pick a
    /// folder.
    func folderPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (URL) -> Void
    ) -> some View {
        modifier(FolderPickerModifier(isPresented: isPresented, onPick: onPick))
    }
}

private struct FolderPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: isPresented) { _, newValue in
            guard newValue else { return }
            isPresented = false
            // Defer to the next runloop tick so the popover (or any other
            // transient UI) finishes its dismiss before we present the
            // panel — otherwise the two fight for focus and the panel
            // never comes forward on an LSUIElement app.
            DispatchQueue.main.async {
                presentMacPanel(onPick: onPick)
            }
        }
        #else
        content.sheet(isPresented: $isPresented) {
            DocumentFolderPicker { url in
                isPresented = false
                onPick(url)
            } onCancel: {
                isPresented = false
            }
            .ignoresSafeArea()
        }
        #endif
    }
}

#if os(macOS)
@MainActor
private func presentMacPanel(onPick: @escaping (URL) -> Void) {
    // Temporarily switch to a regular activation policy so the panel can
    // become key and front. We restore the previous policy when the panel
    // closes.
    let previousPolicy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Vault"
    panel.title = "Pick your Obsidian vault"
    panel.message = "Pick the root folder of your Obsidian vault."
    panel.level = .modalPanel

    let response = panel.runModal()

    // Restore the prior policy so the app fades back into the menu bar.
    NSApp.setActivationPolicy(previousPolicy)

    if response == .OK, let url = panel.url {
        onPick(url)
    }
}
#endif

#if os(iOS)
private struct DocumentFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            // Persisting access requires startAccessing while we read it for
            // bookmarking; the EditorModel's setVault() will do the bookmark.
            _ = url.startAccessingSecurityScopedResource()
            onPick(url)
            url.stopAccessingSecurityScopedResource()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
#endif
