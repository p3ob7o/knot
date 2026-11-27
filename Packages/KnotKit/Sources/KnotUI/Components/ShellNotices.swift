#if !os(watchOS)
    import KnotCore
    import SwiftUI

    /// The app shows a decision inline while iCloud sync is paused.
    public struct SyncPresentation: View {
        @Environment(\.knotTheme) private var theme
        let question: SyncQuestion
        let answer: (SyncAnswer) -> Void

        public init(question: SyncQuestion, answer: @escaping (SyncAnswer) -> Void) {
            self.question = question
            self.answer = answer
        }

        public var body: some View {
            let accountChanged = question == .accountChanged
            Banner(
                accountChanged
                    ? localized("The iCloud account changed.") : localized("Notes were removed from iCloud."),
                symbol: accountChanged ? "person.crop.circle" : "icloud.slash"
            ) {
                if !Self.prefersKeepingSyncPaused(for: question) {
                    keepPaused.modifier(NoticeActionStyle())
                } else {
                    keepPaused
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(theme.colors[.accent])
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Button {
                    answer(.upload)
                } label: {
                    Text("Upload local notes", bundle: .module)
                }
                .modifier(NoticeActionStyle())
            }
            #if os(iOS)
                .padding(.horizontal)
            #endif
        }

        static func prefersKeepingSyncPaused(for question: SyncQuestion) -> Bool {
            question == .zoneRemoved(.purged) || question == .zoneRemoved(.encryptedDataReset)
        }

        private var keepPaused: some View {
            Button {
                answer(.keepPaused)
            } label: {
                Text("Keep sync paused", bundle: .module)
                    .foregroundStyle(
                        theme.colors[Self.prefersKeepingSyncPaused(for: question) ? .onAccent : .textPrimary])
            }
        }
    }

    public struct SpeechDownloadNotice: View {
        public init() {}

        public var body: some View {
            ProgressView {
                Text("Downloading the speech model…", bundle: .module)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Rows that describe the export, separate from the app's folder chooser and file access.
    public struct ExportResultRows: View {
        public struct MissingFile: Identifiable, Sendable {
            public let id: AssetID
            public let kind: AssetKind
            public let noteLabel: String?

            public init(id: AssetID, kind: AssetKind, noteLabel: String? = nil) {
                self.id = id
                self.kind = kind
                self.noteLabel = noteLabel
            }
        }

        public enum State: Sendable {
            case idle
            case exporting
            case failed
            case complete(notes: Int, missing: [MissingFile])
        }

        let state: State

        public init(_ state: State) { self.state = state }

        public var body: some View {
            switch state {
            case .idle:
                EmptyView()
            case .exporting:
                ProgressView {
                    Text("Exporting notes…", bundle: .module)
                }
            case .failed:
                Text("Couldn’t complete the export.", bundle: .module)
            case .complete(let notes, let missing):
                Section {
                    Text("\(notes) notes exported.", bundle: .module)
                } header: {
                    Text("Export complete", bundle: .module)
                }
                if !missing.isEmpty {
                    Section {
                        ForEach(missing) { file in
                            let kind =
                                switch file.kind {
                                case .audio: localized("Recording")
                                case .ink: localized("Drawing")
                                case .unknown: localized("Attachment")
                                }
                            if let noteLabel = file.noteLabel {
                                Text("\(kind) in \(noteLabel)", bundle: .module)
                            } else {
                                Text(kind)
                            }
                        }
                    } header: {
                        Text("Files that couldn’t be exported", bundle: .module)
                    }
                }
            }
        }
    }
#endif
