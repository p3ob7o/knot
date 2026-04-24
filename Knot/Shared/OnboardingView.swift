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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Knot")
                    .font(.system(size: 28, weight: .bold))
                Text("A faster way to get notes into your Obsidian vault.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                bullet("Pick your Obsidian vault folder once.")
                bullet("Short notes append to today's daily file under \"## Quick notes\".")
                bullet("Longer notes become new files in your inbox.")
                bullet("No servers. No accounts. Files land in your vault on this device.")
            }
            .font(.body)

            Spacer(minLength: 12)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button {
                pickerPresented = true
            } label: {
                Label("Pick vault folder…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            presentMacPanel()
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

    #if os(macOS)
    private func presentMacPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Vault"
        panel.message = "Pick the root folder of your Obsidian vault."
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
    #endif
}

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
