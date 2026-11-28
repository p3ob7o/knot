#if !os(watchOS)
    import SwiftUI

    public struct RecentlyDeletedView: View {
        @Environment(\.knotTheme) private var theme
        let model: RecentlyDeletedViewModel

        public init(model: RecentlyDeletedViewModel) {
            self.model = model
        }

        public var body: some View {
            List {
                if let problem = model.problem {
                    Banner(problem.message, symbol: "exclamationmark.icloud", role: .failed)
                        .listRowSeparator(.hidden)
                }
                if let notice = model.notice {
                    feedbackBanner(notice)
                        .listRowSeparator(.hidden)
                }
                if !model.isLoaded {
                    ProgressView {
                        Text("Loading recently deleted items…", bundle: .module)
                            .font(theme.type[.body])
                            .foregroundStyle(theme.colors[.textPrimary])
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowSeparator(.hidden)
                } else if model.items.isEmpty, model.problem == nil {
                    ContentUnavailableView {
                        Label {
                            Text("No recently deleted notes", bundle: .module)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "trash")
                        }
                        .font(theme.type[.rowTitle])
                        .foregroundStyle(theme.colors[.textPrimary])
                    } description: {
                        Text("Deleted notes and segments stay here for 30 days.", bundle: .module)
                            .font(theme.type[.body])
                            .foregroundStyle(theme.colors[.textSecondary])
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(model.items) { row in
                        itemRow(row)
                    }
                }
            }
            #if os(iOS)
                .listStyle(.plain)
            #endif
            .task { await model.refresh() }
            .task { await model.observeStore() }
        }

        private func feedbackBanner(_ notice: RestoreNotice) -> some View {
            switch notice {
            case .restored:
                Banner(notice.announcement.text, symbol: "checkmark", dismiss: model.dismissNotice)
            case .failed:
                Banner(
                    notice.announcement.text, symbol: "exclamationmark.circle", role: .failed,
                    dismiss: model.dismissNotice)
            }
        }

        private func itemRow(_ row: DeletedItemRow) -> some View {
            VStack(alignment: .leading, spacing: theme.spacing.tight) {
                VStack(alignment: .leading, spacing: theme.spacing.tight) {
                    Text(row.title)
                        .font(theme.type[.rowTitle])
                        .foregroundStyle(theme.colors[.textPrimary])
                    VStack(alignment: .leading, spacing: theme.spacing.tight) {
                        switch row.kind {
                        case .note:
                            Text("Note", bundle: .module)
                        case .segment:
                            if let title = row.parentNoteTitle {
                                Text("Segment in “\(title)”", bundle: .module)
                            } else {
                                Text("Segment", bundle: .module)
                            }
                        }
                        Text(
                            "Deleted \(row.deletedAt, format: .dateTime.year().month().day().hour().minute())",
                            bundle: .module)
                        switch row.daysRemaining {
                        case 0:
                            Text("May be purged soon", bundle: .module)
                        case 1:
                            Text("1 day left", bundle: .module)
                        default:
                            Text("\(row.daysRemaining) days left", bundle: .module)
                        }
                    }
                    .font(theme.type[.metaLine])
                    .foregroundStyle(theme.colors[.textSecondary])
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)

                Button {
                    Task { await model.restore(row.id) }
                } label: {
                    Text("Restore", bundle: .module)
                        .font(theme.type[.body])
                        .fixedSize(horizontal: false, vertical: true)
                        #if os(iOS)
                            .frame(minWidth: theme.sizes.hitTarget, minHeight: theme.sizes.hitTarget)
                            .contentShape(.rect)
                        #endif
                }
                .buttonStyle(.bordered)
                .tint(theme.colors[.textPrimary])
                .accessibilityLabel(Text("Restore \(row.title)", bundle: .module))
                .disabled(model.restoring != nil)
            }
        }
    }
#endif
