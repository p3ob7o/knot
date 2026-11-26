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
        let isRestoring: Bool
        let openSetupRow: ((SetupRow) -> Void)?
        let open: (NoteID) -> Void

        public init(
            stream: StreamViewModel, search: SearchViewModel, showsInlineSearch: Bool = true,
            isRestoring: Bool = false, openSetupRow: ((SetupRow) -> Void)? = nil,
            open: @escaping (NoteID) -> Void
        ) {
            self.stream = stream
            self.search = search
            self.showsInlineSearch = showsInlineSearch
            self.isRestoring = isRestoring
            self.openSetupRow = openSetupRow
            self.open = open
        }

        public var body: some View {
            List {
                Section {
                    if showsInlineSearch {
                        SearchField(text: search.query, onChange: search.setQuery)
                    }
                    if let problem = search.displayedProblem(streamProblem: stream.problem) {
                        Banner(problem.message, symbol: "exclamationmark.icloud", role: .failed)
                            .listRowSeparator(.hidden)
                    }
                    if let arrival = stream.arrival {
                        Banner(arrival.message, symbol: "tray.and.arrow.down", role: .textPrimary) {
                            Button {
                                if let first = arrival.notes.first { open(first) }
                                stream.dismissArrivalNotice()
                            } label: {
                                Text("Show", bundle: .module)
                                    #if os(iOS)
                                        .foregroundStyle(theme.colors[.textPrimary])
                                    #endif
                            }
                            .modifier(NoticeActionStyle())
                            Button {
                                stream.dismissArrivalNotice()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(theme.type[.stateLine])
                                    .imageScale(.small)
                                    .foregroundStyle(theme.colors[.textSecondary])
                                    #if os(iOS)
                                        .frame(minWidth: theme.sizes.hitTarget, minHeight: theme.sizes.hitTarget)
                                        .contentShape(.rect)
                                    #endif
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Dismiss", bundle: .module))
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                if let results = search.results {
                    ForEach(results) { row in rowButton(row) }
                } else if isRestoring, stream.rows.isEmpty {
                    ProgressView {
                        Text("Syncing notes…", bundle: .module)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowSeparator(.hidden)
                } else if let firstRun = stream.firstRun {
                    FirstRunView(firstRun, onOpen: openSetupRow, onDismiss: stream.dismissSetupRow)
                } else {
                    #if os(iOS)
                        ForEach(stream.rows) { row in
                            rowButton(row)
                                .task(id: row.id == stream.rows.last?.id && stream.hasMore) {
                                    if row.id == stream.rows.last?.id, stream.hasMore {
                                        await stream.loadMore()
                                    }
                                }
                        }
                    #else
                        ForEach(stream.rows) { row in rowButton(row) }
                        if stream.hasMore {
                            ProgressView()
                                .task { await stream.loadMore() }
                        }
                    #endif
                }
            }
            #if os(iOS)
                .listStyle(.plain)
            #endif
            .overlay {
                if let query = search.emptyResultsQuery, !showsInlineSearch {
                    GeometryReader { geometry in
                        ScrollView {
                            ContentUnavailableView {
                                Label {
                                    Text("No Results for “\(query)”", bundle: .module)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "magnifyingglass")
                                }
                            }
                            .frame(minHeight: geometry.size.height)
                        }
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
