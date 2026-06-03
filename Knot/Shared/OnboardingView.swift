import SwiftUI
import KnotKit
#if os(iOS)
import UIKit
#endif

/// First-launch flow. The user first picks a vault, then answers the folder
/// questions that depend on that vault's structure.
struct OnboardingView: View {
    @Bindable var model: EditorModel
    var onDone: () -> Void

    @State private var step: OnboardingStep = .vault
    @State private var pickerPresented = false
    @State private var errorMessage: String?
    @State private var selectedVaultURL: URL?
    @State private var folderChildren: [String: [VaultFolder]] = [:]
    @State private var loadingFolderPaths: Set<String> = []
    @State private var inboxFolder = ""
    @State private var inboxBrowserPath = ""
    @State private var dailyFolder = ""
    @State private var dailyBrowserPath = ""
    @State private var dailyHeading = ""
    @State private var headings: [MarkdownHeading] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            stepContent
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            footer
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: seedFromModel)
        .onChange(of: step) { _, newStep in
            guard newStep != .vault else { return }
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
        .folderPicker(isPresented: $pickerPresented) { url in
            handlePickedVault(url)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Knot")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(.primary)

            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .vault:
            VStack(alignment: .leading, spacing: 10) {
                question(
                    "Locate your Obsidian vault",
                    "Pick the vault root folder. Knot will inspect it before asking where notes should land."
                )

                if let name = model.vaultUnavailableName {
                    Label("Could not find \(name). Pick the vault again to reconnect it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.851, green: 0.416, blue: 0.416))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .inbox:
            folderQuestion(
                title: "Choose the Inbox folder",
                detail: "New standalone notes are saved here. Leave it empty to use the vault root.",
                text: $inboxFolder,
                browserPath: $inboxBrowserPath
            )

        case .dailyFolder:
            folderQuestion(
                title: "Choose the Daily Notes folder",
                detail: "Short quick notes append to today's daily file in this folder.",
                text: $dailyFolder,
                browserPath: $dailyBrowserPath
            )

        case .dailyHeading:
            VStack(alignment: .leading, spacing: 10) {
                question(
                    "Choose the Daily Note heading",
                    "Today's daily note already has headings. Pick the section for quick notes, or type a new heading."
                )

                TextField("## Quick notes", text: $dailyHeading)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(continueTapped)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(headings) { heading in
                            folderRow(
                                title: heading.raw,
                                systemImage: heading.raw == dailyHeading ? "checkmark.circle.fill" : "number",
                                isSelected: heading.raw == dailyHeading,
                                showsDisclosure: false
                            ) {
                                dailyHeading = heading.raw
                                fieldFocused = true
                            }
                        }
                    }
                }
                .frame(height: Self.folderListHeight)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.851, green: 0.416, blue: 0.416))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == .vault {
                Button {
                    pickerPresented = true
                } label: {
                    Label("Pick vault folder...", systemImage: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                HStack(spacing: 10) {
                    Button {
                        goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .frame(minHeight: 22)
                    }
                    .controlSize(.large)

                    Spacer(minLength: 0)

                    Button {
                        continueTapped()
                    } label: {
                        Label(step == .dailyHeading ? "Done" : "Continue", systemImage: step == .dailyHeading ? "checkmark" : "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 128, minHeight: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            #if os(macOS)
            if step == .vault {
                Text("Right-click the menu bar icon for settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            #endif
        }
    }

    private func question(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func folderQuestion(
        title: String,
        detail: String,
        text: Binding<String>,
        browserPath: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            question(title, detail)

            TextField("Vault root", text: text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(continueTapped)
                .onChange(of: text.wrappedValue) { _, newValue in
                    browserPath.wrappedValue = closestKnownFolder(
                        to: VaultStructure.normalizeFolderPath(newValue)
                    )
                }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    folderRow(
                        title: currentFolderTitle(browserPath.wrappedValue),
                        systemImage: browserPath.wrappedValue.isEmpty ? "house" : "checkmark.circle.fill",
                        isSelected: browserPath.wrappedValue == VaultStructure.normalizeFolderPath(text.wrappedValue),
                        showsDisclosure: false
                    ) {
                        text.wrappedValue = browserPath.wrappedValue
                        fieldFocused = true
                    }

                    if !browserPath.wrappedValue.isEmpty {
                        folderRow(
                            title: "Back to \(currentFolderTitle(parentFolderPath(of: browserPath.wrappedValue)))",
                            systemImage: "chevron.left",
                        isSelected: false,
                        showsDisclosure: false
                    ) {
                        let parent = parentFolderPath(of: browserPath.wrappedValue)
                        browserPath.wrappedValue = parent
                        loadFolderLevel(parent)
                        fieldFocused = true
                    }
                }

                    ForEach(childFolders(of: browserPath.wrappedValue)) { folder in
                        folderRow(
                            title: folderName(for: folder.path),
                            systemImage: "folder",
                            isSelected: folder.path == VaultStructure.normalizeFolderPath(text.wrappedValue),
                            showsDisclosure: true
                        ) {
                            text.wrappedValue = folder.path
                            browserPath.wrappedValue = folder.path
                            loadFolderLevel(folder.path)
                            fieldFocused = true
                        }
                    }

                    if loadingFolderPaths.contains(browserPath.wrappedValue) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: Self.folderListHeight)
        }
    }

    private func folderRow(
        title: String,
        systemImage: String,
        isSelected: Bool,
        showsDisclosure: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Flow

    private static let folderListHeight: CGFloat = 170

    private var headerSubtitle: String {
        if model.vaultUnavailableName != nil {
            return "Reconnect your Obsidian vault and confirm where notes should go."
        }
        return "Quick capture into your Obsidian vault."
    }

    private func seedFromModel() {
        inboxFolder = model.settings.inboxFolder
        dailyFolder = model.settings.dailyFolder
        dailyHeading = model.settings.dailyHeading
        inboxBrowserPath = closestKnownFolder(to: VaultStructure.normalizeFolderPath(inboxFolder))
        dailyBrowserPath = closestKnownFolder(to: VaultStructure.normalizeFolderPath(dailyFolder))

        guard model.hasVault,
              let url = try? model.resolveVaultURL() else {
            step = .vault
            return
        }

        selectedVaultURL = url
        resetFolderBrowser()
        inboxBrowserPath = closestKnownFolder(to: VaultStructure.normalizeFolderPath(inboxFolder))
        dailyBrowserPath = closestKnownFolder(to: VaultStructure.normalizeFolderPath(dailyFolder))
        if step == .vault {
            step = .inbox
        }
    }

    private func handlePickedVault(_ url: URL) {
        do {
            try model.setVault(url: url)
            selectedVaultURL = url
            resetFolderBrowser()
            inboxFolder = model.settings.inboxFolder
            dailyFolder = model.settings.dailyFolder
            dailyHeading = model.settings.dailyHeading
            inboxBrowserPath = closestKnownFolder(to: VaultStructure.normalizeFolderPath(inboxFolder))
            dailyBrowserPath = closestKnownFolder(to: VaultStructure.normalizeFolderPath(dailyFolder))
            errorMessage = nil
            step = .inbox
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func continueTapped() {
        errorMessage = nil

        switch step {
        case .vault:
            pickerPresented = true

        case .inbox:
            var updated = model.settings
            updated.inboxFolder = VaultStructure.normalizeFolderPath(inboxFolder)
            inboxFolder = updated.inboxFolder
            inboxBrowserPath = closestKnownFolder(to: updated.inboxFolder)
            model.updateSettings(updated)
            step = .dailyFolder

        case .dailyFolder:
            var updated = model.settings
            updated.dailyFolder = VaultStructure.normalizeFolderPath(dailyFolder)
            if updated.dailyFolder != model.settings.dailyFolder {
                model.lastImport = nil
            }
            dailyFolder = updated.dailyFolder
            dailyBrowserPath = closestKnownFolder(to: updated.dailyFolder)
            model.updateSettings(updated)
            advanceAfterDailyFolder()

        case .dailyHeading:
            var updated = model.settings
            updated.dailyHeading = normalizedHeading(dailyHeading)
            dailyHeading = updated.dailyHeading
            model.updateSettings(updated)
            finishOnboarding()
        }
    }

    private func goBack() {
        errorMessage = nil
        switch step {
        case .vault:
            break
        case .inbox:
            step = .vault
        case .dailyFolder:
            step = .inbox
        case .dailyHeading:
            step = .dailyFolder
        }
    }

    private func advanceAfterDailyFolder() {
        guard let vaultURL = selectedVaultURL ?? (try? model.resolveVaultURL()) else {
            finishOnboarding()
            return
        }

        headings = VaultStructure.dailyNoteHeadings(in: vaultURL, settings: model.settings)

        guard !headings.isEmpty else {
            finishOnboarding()
            return
        }

        if headings.contains(where: { $0.raw == model.settings.dailyHeading }) {
            dailyHeading = model.settings.dailyHeading
        } else if let first = headings.first {
            dailyHeading = first.raw
        }
        step = .dailyHeading
    }

    private func finishOnboarding() {
        guard model.hasVault else {
            step = .vault
            return
        }
        model.completeOnboarding()
        onDone()
    }

    private func childFolders(of parentPath: String) -> [VaultFolder] {
        let parent = VaultStructure.normalizeFolderPath(parentPath)
        return folderChildren[parent] ?? []
    }

    private func closestKnownFolder(to path: String) -> String {
        var candidate = VaultStructure.normalizeFolderPath(path)
        while !candidate.isEmpty {
            if knownFolderPaths.contains(candidate) {
                return candidate
            }
            candidate = parentFolderPath(of: candidate)
        }
        return ""
    }

    private var knownFolderPaths: Set<String> {
        var paths = Set([""])
        for children in folderChildren.values {
            for child in children {
                paths.insert(child.path)
            }
        }
        return paths
    }

    private func resetFolderBrowser() {
        folderChildren = [:]
        loadingFolderPaths = []
        inboxBrowserPath = ""
        dailyBrowserPath = ""
        loadFolderLevel("")
    }

    private func loadFolderLevel(_ path: String) {
        let normalized = VaultStructure.normalizeFolderPath(path)
        guard folderChildren[normalized] == nil,
              !loadingFolderPaths.contains(normalized),
              let vaultURL = selectedVaultURL else {
            return
        }

        loadingFolderPaths.insert(normalized)
        Task {
            let children = await Task.detached(priority: .userInitiated) {
                VaultStructure.childFolders(in: vaultURL, parentPath: normalized)
            }.value

            await MainActor.run {
                folderChildren[normalized] = children
                loadingFolderPaths.remove(normalized)
            }
        }
    }

    private func parentFolderPath(of path: String) -> String {
        let parts = VaultStructure.normalizeFolderPath(path)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    private func folderName(for path: String) -> String {
        let normalized = VaultStructure.normalizeFolderPath(path)
        return normalized.split(separator: "/").last.map(String.init) ?? "Vault root"
    }

    private func currentFolderTitle(_ path: String) -> String {
        let normalized = VaultStructure.normalizeFolderPath(path)
        return normalized.isEmpty ? "Vault root" : normalized
    }

    private func normalizedHeading(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if markdownHeadingLevel(of: trimmed) != nil {
            return trimmed
        }
        if trimmed.isEmpty {
            return AppSettings().dailyHeading
        }
        return "## \(trimmed)"
    }

    private func markdownHeadingLevel(of line: String) -> Int? {
        guard line.first == "#" else { return nil }
        var hashes = 0
        for character in line {
            if character == "#" {
                hashes += 1
            } else {
                break
            }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let remainder = line.dropFirst(hashes)
        guard remainder.first == " ",
              !remainder.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return hashes
    }
}

private enum OnboardingStep {
    case vault
    case inbox
    case dailyFolder
    case dailyHeading
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
