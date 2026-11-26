#if !os(watchOS)
    import KnotCore
    import SwiftUI

    /// The stream, with search above it. A thin view: the behaviour is in `StreamViewModel` and
    /// `SearchViewModel`. The Watch shows no stream (docs/product-spec.md §6).
    public struct StreamView: View {
        @Environment(\.knotTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let stream: StreamViewModel
        let search: SearchViewModel
        let showsInlineSearch: Bool
        let openSetupRow: ((SetupRow) -> Void)?
        let open: (NoteID) -> Void

        public init(
            stream: StreamViewModel, search: SearchViewModel, showsInlineSearch: Bool = true,
            openSetupRow: ((SetupRow) -> Void)? = nil,
            open: @escaping (NoteID) -> Void
        ) {
            self.stream = stream
            self.search = search
            self.showsInlineSearch = showsInlineSearch
            self.openSetupRow = openSetupRow
            self.open = open
        }

        public var body: some View {
            List {
                Section {
                    if showsInlineSearch {
                        SearchField(text: search.query, onChange: search.setQuery)
                    }
                    if let problem = stream.problem {
                        Banner(problem.message, symbol: "exclamationmark.icloud", role: .failed)
                    }
                    if let arrival = stream.arrival {
                        Banner(arrival.message, symbol: "tray.and.arrow.down", role: .arrived) {
                            Button {
                                if let first = arrival.notes.first { open(first) }
                                stream.dismissArrivalNotice()
                            } label: {
                                Text("Show", bundle: .module)
                            }
                            Button {
                                stream.dismissArrivalNotice()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel(Text("Dismiss", bundle: .module))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let results = search.results {
                    if results.isEmpty, !showsInlineSearch {
                        ContentUnavailableView.search(text: search.query)
                    } else {
                        ForEach(results) { row in rowButton(row) }
                    }
                } else if let firstRun = stream.firstRun {
                    FirstRunView(firstRun, onOpen: openSetupRow, onDismiss: stream.dismissSetupRow)
                } else {
                    ForEach(stream.rows) { row in rowButton(row) }
                    if stream.hasMore {
                        ProgressView()
                            .task { await stream.loadMore() }
                    }
                }
            }
            .animation(theme.motion.animation(for: .listChange, reduceMotion: reduceMotion), value: stream.rows)
            .task { await stream.load() }
            .task { await stream.observeChanges() }
        }

        private func rowButton(_ row: StreamRowModel) -> some View {
            Button {
                open(row.id)
            } label: {
                StreamRowView(row)
            }
            .buttonStyle(.plain)
        }
    }
#endif
