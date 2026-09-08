import KnotKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct OnboardingView: View {
    @Bindable var model: EditorModel
    var onDone: () -> Void

    @State private var session: OnboardingSession?
    @State private var browser: VaultBrowser?
    @State private var listing: FolderListing?
    @State private var loadState: LoadState = .idle
    @State private var pickerPresented = false
    @State private var browserPath = VaultRelativePath.root
    @State private var selectedPath: VaultRelativePath?
    @State private var typedPath = ""
    @State private var highlightedPath: VaultRelativePath?
    @State private var createCandidate: VaultRelativePath?
    @State private var confirmCreate = false
    @State private var dailyFormat = "YYYY-MM-DD"
    @State private var headings: [DiscoveredHeading] = []
    @State private var selectedHeading: HeadingSelector?
    @State private var endOfNote = false
    @State private var createMissingHeading = true
    @State private var dailySource = "Today's note"
    @State private var dailyRecoveryMessage: String?
    @State private var canAnalyzeLargeDaily = false
    @State private var analysisUsesTemplate = false
    @State private var samplePickerPresented = false
    @State private var manualHeadingTitle = "Quick notes"
    @State private var manualHeadingLevel = 2
    @State private var errorMessage: String?
    @State private var working = false

    private enum LoadState: Equatable { case idle, loading, empty, noMatches, loaded, denied, unavailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                stepContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 640)
        .onAppear { adopt(model.onboardingSession) }
        .onChange(of: model.onboardingSession) { _, value in adopt(value) }
        .folderPicker(isPresented: $pickerPresented) { url in
            Task { await chooseVault(url) }
        }
        .fileImporter(
            isPresented: $samplePickerPresented,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await loadSample(url) }
        }
        .alert("Create folder?", isPresented: $confirmCreate) {
            Button("Create") { confirmFolderCreation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder will be created inside the vault when setup finishes or on the first capture.")
        }
    }

    private var currentStep: OnboardingStep { session?.step ?? .vault }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Knot").font(.title2.bold())
                Text(stepTitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(stepIndex) of 5")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Step \(stepIndex) of 5")
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch currentStep {
        case .vault:
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the folder that contains your notes.")
                if let name = model.vaultUnavailableName {
                    Label("Reconnect \(name)", systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                Button { pickerPresented = true } label: {
                    Label(model.vaultName ?? "Choose Vault", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                if working { ProgressView("Inspecting configuration") }
            }
        case .inbox:
            folderStep(title: "Inbox folder", detail: "Standalone notes are created in this folder.")
        case .dailyFolder:
            VStack(alignment: .leading, spacing: 16) {
                folderStep(title: "Daily folder", detail: "Short captures append to today's note.")
                DisclosureGroup("Filename format") {
                    TextField("YYYY-MM-DD", text: $dailyFormat)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await persistDailyFormat() } }
                    Text(dailyPreview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .heading:
            headingStep
        case .summary:
            summaryStep
        }
    }

    private func folderStep(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detail).foregroundStyle(.secondary)
            TextField("Vault-relative path", text: $typedPath)
                .textFieldStyle(.roundedBorder)
                .onChange(of: typedPath) { _, value in Task { await updateSuggestions(value) } }
                .onSubmit { commitTypedPath() }
                .accessibilityLabel("\(title) path")
            if let createCandidate {
                Button { confirmCreate = true } label: {
                    Label("Create \(createCandidate.string)", systemImage: "folder.badge.plus")
                }
                .accessibilityHint("Records explicit permission to create this folder inside the vault")
            }
            HStack {
                Button { navigate(to: browserPath.parent) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(browserPath.isRoot)
                .help("Back")
                breadcrumb
                Spacer()
                Button(useCurrentTitle) { selectCurrentFolder() }
                    .buttonStyle(.borderedProminent)
            }
            .accessibilityElement(children: .contain)
            folderListing
                .frame(minHeight: 240)
            if let selectedPath {
                Label(selectedPath.isRoot ? "Vault root selected" : "Selected: \(selectedPath.string)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(selectedPath.string)
            } else {
                Text("Choose the current folder before continuing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Vault") { navigate(to: .root) }.buttonStyle(.plain)
                ForEach(Array(browserPath.components.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    Button(component) {
                        let parts = Array(browserPath.components.prefix(index + 1))
                        if let path = try? VaultRelativePath(components: parts) { navigate(to: path) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityLabel(browserPath.isRoot ? "Vault root" : browserPath.string)
        .help(browserPath.string)
    }

    @ViewBuilder private var folderListing: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView("Loading folders").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        case .noMatches:
            ContentUnavailableView("No Matching Folders", systemImage: "magnifyingglass")
        case .denied:
            recoveryState("Permission Required", image: "lock.trianglebadge.exclamationmark")
        case .unavailable:
            recoveryState("Folder Unavailable", image: "externaldrive.badge.exclamationmark")
        case .loaded:
            List(listing?.children ?? [], selection: $highlightedPath) { entry in
                Button { navigate(to: entry.path) } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(entry.path)
                .help(entry.path.string)
                .accessibilityLabel("Open \(entry.path.string)")
                .accessibilityHint("Browses this folder without selecting it")
            }
            .listStyle(.inset)
        }
    }

    private func recoveryState(_ title: String, image: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: image)
        } actions: {
            Button("Retry") { load(path: browserPath) }
        }
    }

    private var headingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Destination in \(dailySource)").foregroundStyle(.secondary)
            if let dailyRecoveryMessage {
                Label(dailyRecoveryMessage, systemImage: "doc.badge.ellipsis")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    if canAnalyzeLargeDaily {
                        Button("Analyze up to 64 MiB", systemImage: "doc.text.magnifyingglass") {
                            Task { await analyzeLargeDaily() }
                        }
                    }
                    Button("Choose Sample", systemImage: "doc") { samplePickerPresented = true }
                }
            }
            Toggle("Append at end of note", isOn: $endOfNote)
            if !endOfNote {
                Picker("Heading", selection: $selectedHeading) {
                    Text("Quick notes").tag(Optional(try! HeadingSelector(title: "Quick notes", level: 2)))
                    ForEach(headings) { heading in
                        Text(headingLabel(heading)).tag(Optional(heading.selector))
                    }
                }
                Toggle("Create the heading when missing", isOn: $createMissingHeading)
                DisclosureGroup("Manual target") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Heading", text: $manualHeadingTitle)
                            .textFieldStyle(.roundedBorder)
                        Stepper("Level \(manualHeadingLevel)", value: $manualHeadingLevel, in: 1...6)
                        Button("Use Manual Heading") { useManualHeading() }
                            .disabled(manualHeadingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 6)
                }
            }
            if headings.isEmpty {
                Label("No headings discovered. Quick notes is selected unless you choose another target.", systemImage: "text.badge.plus")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryRow("Vault", value: model.vaultName ?? "Selected vault", image: "externaldrive")
            summaryRow("Inbox", value: session?.workingSettings.inboxFolder.string ?? "", image: "tray")
            summaryRow("Daily", value: dailyPreview, image: "calendar")
            summaryRow("Target", value: targetSummary, image: "number")
            if let count = session?.importDiff?.entries.count, count > 0 {
                Label("\(count) setting values imported from Obsidian", systemImage: "arrow.down.doc")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(_ name: String, value: String, image: String) -> some View {
        LabeledContent(name) { Label(value, systemImage: image).lineLimit(2) }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if currentStep != .vault {
                    Button("Back", systemImage: "chevron.left") { Task { await back() } }
                }
                Spacer()
                if currentStep != .vault {
                    Button(currentStep == .summary ? "Finish" : "Continue") {
                        Task { await advance() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance || working)
                }
            }
        }
    }

    private var stepTitle: String {
        switch currentStep {
        case .vault: "Connect Vault"
        case .inbox: "Choose Inbox"
        case .dailyFolder: "Choose Daily Notes"
        case .heading: "Choose Daily Target"
        case .summary: "Review Destinations"
        }
    }
    private var stepIndex: Int { (OnboardingStep.allCases.firstIndex(of: currentStep) ?? 0) + 1 }
    private var useCurrentTitle: String { browserPath.isRoot ? "Use Vault Root" : "Use \(browserPath.lastComponent ?? "Folder")" }
    private var canAdvance: Bool {
        switch currentStep {
        case .vault: false
        case .inbox, .dailyFolder: selectedPath != nil
        case .heading, .summary: true
        }
    }
    private var dailyPreview: String {
        guard let settings = session?.workingSettings,
              let pattern = try? CompiledDatePattern(dailyFormat) else { return "Invalid filename format" }
        let value = pattern.render(date: Date(), timeZone: .current) + ".md"
        return ([settings.dailyFolder.string, value].filter { !$0.isEmpty }).joined(separator: "/")
    }
    private var targetSummary: String {
        guard let settings = session?.workingSettings else { return "" }
        switch settings.dailyTarget {
        case .endOfNote: return "End of note"
        case .heading(let selector, let policy):
            return String(repeating: "#", count: selector.level) + " " + selector.title + (policy == .ask ? " (ask if missing)" : "")
        }
    }

    private func adopt(_ value: OnboardingSession?) {
        guard let value else { return }
        session = value
        dailyFormat = value.workingSettings.dailyFilenameFormat
        let path = value.browserState.browserPath
        browserPath = path
        selectedPath = value.browserState.selectedPath
        typedPath = value.browserState.query
        browser = model.makeFolderBrowser()
        if value.step == .inbox || value.step == .dailyFolder { load(path: path) }
    }

    private func chooseVault(_ url: URL) async {
        working = true
        errorMessage = nil
        do {
            try await model.selectVault(url)
            adopt(model.onboardingSession)
        } catch { errorMessage = error.localizedDescription }
        working = false
    }

    private func navigate(to path: VaultRelativePath) {
        createCandidate = nil
        browserPath = path
        typedPath = ""
        highlightedPath = nil
        load(path: path)
        Task { await saveBrowserState() }
    }

    private func load(path: VaultRelativePath) {
        guard let browser, let session else { return }
        loadState = .loading
        let requestID = UUID()
        Task {
            do {
                let result = try await browser.load(
                    path: path,
                    generation: session.generation,
                    requestID: requestID
                )
                guard self.browserPath == result.path else { return }
                listing = result
                loadState = result.children.isEmpty ? .empty : .loaded
            } catch FolderListingFailure.denied { loadState = .denied }
            catch ConfigurationError.staleResult { }
            catch { loadState = .unavailable }
        }
    }

    private func updateSuggestions(_ value: String) async {
        guard let browser, let session else { return }
        guard !value.isEmpty else {
            createCandidate = nil
            load(path: browserPath)
            return
        }
        createCandidate = try? VaultRelativePath(value, kind: .folder)
        do {
            let result = try await browser.suggestions(
                typedPath: value, generation: session.generation, requestID: UUID()
            )
            browserPath = result.parent
            listing = FolderListing(
                path: result.parent, identity: DirectoryIdentity(device: 0, inode: 0),
                children: result.matches
            )
            highlightedPath = result.exactMatch?.path ?? result.matches.first?.path
            if result.exactMatch != nil { createCandidate = nil }
            loadState = result.matches.isEmpty ? .noMatches : .loaded
        } catch FolderListingFailure.denied {
            loadState = .denied
        } catch FolderListingFailure.missing {
            listing = nil
            loadState = .noMatches
        } catch ConfigurationError.staleResult {
        } catch {
            loadState = .unavailable
        }
    }

    private func commitTypedPath() {
        if selectExactTypedPath() { return }
        if createCandidate != nil { confirmCreate = true }
    }


    private func selectExactTypedPath() -> Bool {
        guard let exact = listing?.children.first(where: {
            $0.path.string.compare(typedPath, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return false }
        selectedPath = exact.path
        createCandidate = nil
        Task { await saveSelection() }
        return true
    }

    private func confirmFolderCreation() {
        guard let path = createCandidate else { return }
        selectedPath = path
        browserPath = path.parent
        typedPath = path.string
        createCandidate = nil
        Task { await saveSelection(creationIntent: path) }
    }

    private func selectCurrentFolder() {
        selectedPath = browserPath
        typedPath = browserPath.string
        createCandidate = nil
        Task { await saveSelection() }
    }

    private func saveBrowserState() async {
        guard var session else { return }
        session.browserState = FolderBrowserState(
            browserPath: browserPath, selectedPath: selectedPath, query: typedPath,
            highlightedPath: highlightedPath
        )
        session.updatedAt = Date()
        do { try await model.persistOnboarding(session); self.session = session }
        catch { errorMessage = error.localizedDescription }
    }

    private func saveSelection(creationIntent: VaultRelativePath? = nil) async {
        guard var session, let selectedPath else { return }
        do {
            let old = session.workingSettings
            session.workingSettings = try ValidatedSettings(
                dailyFolder: currentStep == .dailyFolder ? selectedPath.string : old.dailyFolder.string,
                inboxFolder: currentStep == .inbox ? selectedPath.string : old.inboxFolder.string,
                dailyFilenameFormat: dailyFormat,
                inboxFilenameFormat: old.inboxFilenameFormat,
                dailyTarget: old.dailyTarget, dailyBulletFormat: old.dailyBulletFormat,
                routingMaxChars: old.routingMaxChars,
                routingRequiresSingleLine: old.routingRequiresSingleLine,
                attachmentFolderPath: old.attachmentFolderPath
            )
            if let creationIntent, !session.folderCreationIntents.contains(creationIntent) {
                session.folderCreationIntents.append(creationIntent)
            }
            session.browserState = FolderBrowserState(
                browserPath: browserPath, selectedPath: selectedPath, query: typedPath,
                highlightedPath: highlightedPath
            )
            session.updatedAt = Date()
            try await model.persistOnboarding(session)
            self.session = session
        } catch { errorMessage = error.localizedDescription }
    }

    private func persistDailyFormat() async {
        guard var session else { return }
        do {
            let old = session.workingSettings
            session.workingSettings = try ValidatedSettings(
                dailyFolder: old.dailyFolder.string, inboxFolder: old.inboxFolder.string,
                dailyFilenameFormat: dailyFormat, inboxFilenameFormat: old.inboxFilenameFormat,
                dailyTarget: old.dailyTarget, dailyBulletFormat: old.dailyBulletFormat,
                routingMaxChars: old.routingMaxChars,
                routingRequiresSingleLine: old.routingRequiresSingleLine,
                attachmentFolderPath: old.attachmentFolderPath
            )
            try await model.persistOnboarding(session)
            self.session = session
        } catch { errorMessage = error.localizedDescription }
    }

    private func advance() async {
        guard var session else { return }
        working = true
        errorMessage = nil
        do {
            switch session.step {
            case .vault: break
            case .inbox:
                session.step = .dailyFolder
                selectedPath = session.workingSettings.dailyFolder
                browserPath = .root
                typedPath = session.workingSettings.dailyFolder.string
            case .dailyFolder:
                await persistDailyFormat()
                guard let latest = self.session else { throw ConfigurationError.sessionMissing }
                session = latest
                await loadDailySources(settings: session.workingSettings)
                let defaultHeading = try HeadingSelector(title: "Quick notes", level: 2)
                selectedHeading = resolvedConfiguredHeading(in: headings, settings: session.workingSettings)
                    ?? defaultHeading
                session.step = .heading
            case .heading:
                let old = session.workingSettings
                let defaultHeading = try HeadingSelector(title: "Quick notes", level: 2)
                let target: DailyTarget = endOfNote ? .endOfNote : .heading(
                    selectedHeading ?? defaultHeading,
                    missing: createMissingHeading ? .createAtEnd : .ask
                )
                session.workingSettings = try ValidatedSettings(
                    dailyFolder: old.dailyFolder.string, inboxFolder: old.inboxFolder.string,
                    dailyFilenameFormat: old.dailyFilenameFormat, inboxFilenameFormat: old.inboxFilenameFormat,
                    dailyTarget: target, dailyBulletFormat: old.dailyBulletFormat,
                    routingMaxChars: old.routingMaxChars,
                    routingRequiresSingleLine: old.routingRequiresSingleLine,
                    attachmentFolderPath: old.attachmentFolderPath
                )
                session.step = .summary
            case .summary:
                try await model.completeOnboarding(session: session)
                onDone()
                working = false
                return
            }
            session.updatedAt = Date()
            session.browserState = FolderBrowserState()
            try await model.persistOnboarding(session)
            self.session = session
            if session.step == .dailyFolder {
                selectedPath = session.workingSettings.dailyFolder
                load(path: .root)
            }
        } catch { errorMessage = error.localizedDescription }
        working = false
    }

    private func back() async {
        guard var session else { return }
        switch session.step {
        case .vault: return
        case .inbox: session.step = .vault
        case .dailyFolder: session.step = .inbox
        case .heading: session.step = .dailyFolder
        case .summary: session.step = .heading
        }
        session.updatedAt = Date()
        do {
            try await model.persistOnboarding(session)
            self.session = session
            if session.step == .inbox || session.step == .dailyFolder {
                selectedPath = session.step == .inbox ? session.workingSettings.inboxFolder : session.workingSettings.dailyFolder
                load(path: browserPath)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadDailySources(settings: ValidatedSettings) async {
        headings = []
        dailyRecoveryMessage = nil
        canAnalyzeLargeDaily = false
        analysisUsesTemplate = false
        guard let discovery = await model.discoverDaily(settings: settings) else {
            dailyRecoveryMessage = "The daily note could not be inspected."
            return
        }
        switch discovery {
        case .found(let path, let found):
            dailySource = path.string
            headings = found
        case .absent(let path):
            dailySource = path.string
            if let template = await model.discoverDailyTemplate() {
                switch template {
                case .found(let templatePath, let found):
                    dailySource = "Template: \(templatePath.string)"
                    headings = found
                case .tooLarge(let templatePath):
                    dailySource = "Template: \(templatePath.string)"
                    dailyRecoveryMessage = "The configured template is larger than the automatic analysis limit."
                    canAnalyzeLargeDaily = true
                    analysisUsesTemplate = true
                case .unreadable(let templatePath, let message):
                    dailySource = "Template: \(templatePath.string)"
                    dailyRecoveryMessage = "The configured template could not be read: \(message)"
                case .absent:
                    dailyRecoveryMessage = "Today's note and the configured template do not exist. Choose a sample or set a manual target."
                }
            } else {
                dailyRecoveryMessage = "Today's note does not exist. Choose a sample or set a manual target."
            }
        case .tooLarge(let path):
            dailySource = path.string
            dailyRecoveryMessage = "Today's note is larger than the automatic 8 MiB analysis limit."
            canAnalyzeLargeDaily = true
        case .unreadable(let path, let message):
            dailySource = path.string
            dailyRecoveryMessage = "The daily note could not be read: \(message)"
        }
    }

    private func analyzeLargeDaily() async {
        working = true
        let result: DailyDiscoveryResult?
        if analysisUsesTemplate {
            result = await model.discoverDailyTemplate(explicitLargeFileAnalysis: true)
        } else if let settings = session?.workingSettings {
            result = await model.discoverDaily(settings: settings, explicitLargeFileAnalysis: true)
        } else {
            result = nil
        }
        if let result { applyExplicitDiscovery(result) }
        working = false
    }

    private func applyExplicitDiscovery(_ result: DailyDiscoveryResult) {
        switch result {
        case .found(let path, let found):
            dailySource = analysisUsesTemplate ? "Template: \(path.string)" : path.string
            headings = found
            dailyRecoveryMessage = nil
            canAnalyzeLargeDaily = false
        case .tooLarge:
            dailyRecoveryMessage = "This file is larger than the explicit 64 MiB analysis limit. Choose a sample or set a manual target."
            canAnalyzeLargeDaily = false
        case .absent:
            dailyRecoveryMessage = "The selected source no longer exists. Choose a sample or set a manual target."
            canAnalyzeLargeDaily = false
        case .unreadable(_, let message):
            dailyRecoveryMessage = "The selected source could not be read: \(message)"
            canAnalyzeLargeDaily = false
        }
    }

    private func loadSample(_ url: URL) async {
        working = true
        do {
            headings = try await model.discoverSampleDaily(url)
            dailySource = "Sample: \(url.lastPathComponent)"
            dailyRecoveryMessage = nil
            canAnalyzeLargeDaily = false
            if let configured = session?.workingSettings {
                selectedHeading = resolvedConfiguredHeading(in: headings, settings: configured)
                    ?? selectedHeading
            }
        } catch {
            dailyRecoveryMessage = "The sample could not be analyzed: \(error.localizedDescription)"
        }
        working = false
    }

    private func useManualHeading() {
        let title = manualHeadingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selector = try? HeadingSelector(title: title, level: manualHeadingLevel) else { return }
        selectedHeading = selector
        endOfNote = false
        dailySource = "Manual target"
    }

    private func resolvedConfiguredHeading(in values: [DiscoveredHeading], settings: ValidatedSettings) -> HeadingSelector? {
        guard case .heading(let target, _) = settings.dailyTarget else { endOfNote = true; return nil }
        let matches = values.filter {
            $0.selector.title.localizedCaseInsensitiveCompare(target.title) == .orderedSame &&
                $0.selector.level == target.level && $0.selector.ancestorPath == target.ancestorPath
        }
        return matches.count == 1 ? matches[0].selector : nil
    }

    private func headingLabel(_ heading: DiscoveredHeading) -> String {
        (heading.selector.ancestorPath + [heading.selector.title]).joined(separator: " / ")
    }
}

extension View {
    func folderPicker(isPresented: Binding<Bool>, onPick: @escaping (URL) -> Void) -> some View {
        modifier(FolderPickerModifier(isPresented: isPresented, onPick: onPick))
    }
}

private struct FolderPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: isPresented) { _, value in
            guard value else { return }
            isPresented = false
            presentMacPanel(onPick: onPick)
        }
        #else
        content.sheet(isPresented: $isPresented) {
            DocumentFolderPicker(onPick: { url in isPresented = false; onPick(url) }, onCancel: { isPresented = false })
                .ignoresSafeArea()
        }
        #endif
    }
}

#if os(macOS)
@MainActor private func presentMacPanel(onPick: @escaping (URL) -> Void) {
    let previousPolicy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Vault"
    panel.title = "Choose Vault"
    panel.begin { response in
        NSApp.setActivationPolicy(previousPolicy)
        if response == .OK, let url = panel.url { onPick(url) }
    }
}
#endif

#if os(iOS)
private struct DocumentFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            let accessed = url.startAccessingSecurityScopedResource()
            onPick(url)
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}
#endif
