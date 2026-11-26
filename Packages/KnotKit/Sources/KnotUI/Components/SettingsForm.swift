#if !os(watchOS)
    import KnotCore
    import SwiftUI

    /// The settings forms (docs/product-spec.md §11). The Watch has no settings: it is a
    /// capture device only.
    public struct SettingsForm: View {
        @Environment(\.knotTheme) private var theme
        let model: SettingsViewModel
        let open: (SettingsRow) -> Void
        let actionButtonSetup: (() -> Void)?

        /// - Parameter open: opens a row that leads elsewhere: export, recently deleted, about,
        ///   and the Mac's hotkey chooser, which the app shell owns.
        public init(
            _ model: SettingsViewModel, actionButtonSetup: (() -> Void)? = nil,
            open: @escaping (SettingsRow) -> Void = { _ in }
        ) {
            self.model = model
            self.open = open
            self.actionButtonSetup = actionButtonSetup
        }

        public var body: some View {
            Form {
                if !model.isAvailable {
                    Text("Settings can't be read right now. They show their defaults.", bundle: .module)
                        .foregroundStyle(theme.colors[.textSecondary])
                }
                if model.saveProblem != nil {
                    Text("That change couldn't be saved.", bundle: .module)
                        .foregroundStyle(theme.colors[.failed])
                }
                ForEach(model.rows) { row in
                    rowView(row)
                }
                if let actionButtonSetup {
                    Button(SetupRow.actionButton.title, action: actionButtonSetup)
                        .accessibilityLabel(Text("Set up Action Button recording", bundle: .module))
                }
                if let note = model.lockScreenNote {
                    Text(note)
                        .font(theme.type[.caption])
                        .foregroundStyle(theme.colors[.textSecondary])
                }
            }
            .disabled(!model.isAvailable)
            .task { await model.observeSync() }
        }

        @ViewBuilder private func rowView(_ row: SettingsRow) -> some View {
            switch row {
            case .appendWindow:
                Stepper(
                    value: Binding(
                        get: { model.settings.appendWindow.minutes },
                        set: { minutes in Task { await model.setAppendWindow(minutes: minutes) } }),
                    in: 0...AppendWindow.maximumMinutes
                ) {
                    LabeledContent(row.title, value: model.appendWindowText)
                }
            case .cleanup:
                VStack(alignment: .leading) {
                    Toggle(
                        row.title,
                        isOn: Binding(
                            get: { model.settings.cleanupEnabled },
                            set: { on in Task { await model.setCleanupEnabled(on) } }))
                    if let note = model.cleanupNote {
                        Text(note).font(theme.type[.caption]).foregroundStyle(theme.colors[.textSecondary])
                    }
                }
            case .englishVariant:
                Picker(
                    row.title,
                    selection: Binding(
                        get: { model.settings.englishVariant.rawValue },
                        set: { raw in Task { await model.setEnglishVariant(EnglishVariant(rawValue: raw)) } })
                ) {
                    ForEach(SettingsViewModel.englishVariants, id: \.rawValue) { variant in
                        Text(SettingsViewModel.label(of: variant)).tag(variant.rawValue)
                    }
                }
            case .sync:
                VStack(alignment: .leading) {
                    Toggle(
                        row.title,
                        isOn: Binding(
                            get: { model.settings.syncEnabled ?? false },
                            set: { on in Task { await model.setSyncEnabled(on) } }))
                    SettingsSyncStatusView(model.syncState)
                }
            case .hotkey:
                Button {
                    open(row)
                } label: {
                    LabeledContent(row.title, value: model.hotkeyText)
                }
            case .launchAtLogin:
                Toggle(
                    row.title,
                    isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { on in Task { await model.setLaunchAtLogin(on) } }))
            case .commandLineAccess:
                Toggle(
                    row.title,
                    isOn: Binding(
                        get: { model.settings.commandLineAccess },
                        set: { on in Task { await model.setCommandLineAccess(on) } }))
            case .exportAll, .recentlyDeleted, .about:
                Button(row.title) { open(row) }
            }
        }
    }

    /// The status below the iCloud sync toggle.
    public struct SettingsSyncStatusView: View {
        @Environment(\.knotTheme) private var theme
        let state: SettingsSyncState

        public init(_ state: SettingsSyncState) {
            self.state = state
        }

        public var body: some View {
            Text(state.label)
                .font(theme.type[.caption])
                .foregroundStyle(theme.colors[.textSecondary])
        }
    }
#endif
