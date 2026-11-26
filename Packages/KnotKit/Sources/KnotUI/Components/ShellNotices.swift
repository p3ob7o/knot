#if !os(watchOS)
    import KnotCore
    import SwiftUI

    /// The app shows a decision inline while iCloud sync is paused.
    public struct SyncPresentation: View {
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
                VStack(alignment: .leading) {
                    Button {
                        answer(.keepPaused)
                    } label: {
                        Text("Keep sync paused", bundle: .module)
                    }
                    Button {
                        answer(.upload)
                    } label: {
                        Text("Upload local notes", bundle: .module)
                    }
                }
                .modifier(NoticeActionStyle())
            }
        }
    }

    public struct SpeechDownloadNotice: View {
        public init() {}

        public var body: some View {
            ProgressView {
                Text("Downloading the speech model…", bundle: .module)
            }
        }
    }

    /// Rows that describe the export, separate from the app's folder chooser and file access.
    public struct ExportResultRows: View {
        public struct MissingFile: Identifiable, Sendable {
            public let id: AssetID
            public let kind: AssetKind

            public init(id: AssetID, kind: AssetKind) {
                self.id = id
                self.kind = kind
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
                            LabeledContent {
                                Text(file.id.description)
                            } label: {
                                Text(file.kind == .audio ? "Recording" : "Drawing", bundle: .module)
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
