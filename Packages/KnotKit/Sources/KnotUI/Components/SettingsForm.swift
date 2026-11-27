#if !os(watchOS)
    import KnotCore
    import SwiftUI

    /// The settings forms (docs/product-spec.md §11). The Watch has no settings: it is a
    /// capture device only.
    public struct SettingsForm: View {
        @Environment(\.knotTheme) private var theme
        #if os(iOS)
            @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        #endif
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
                #if os(iOS)
                    Section {
                        if let actionButtonSetup {
                            navigationRow(
                                String(localized: "Action Button setup", bundle: .module),
                                action: actionButtonSetup)
                        }
                        ForEach(model.rows.filter { !isDestination($0) }) { row in
                            rowView(row)
                        }
                    } footer: {
                        if !model.isAvailable {
                            Text("Settings can’t be read right now.", bundle: .module)
                                .foregroundStyle(theme.colors[.textSecondary])
                        } else if let note = model.lockScreenNote {
                            Text(note)
                                .foregroundStyle(theme.colors[.textSecondary])
                        }
                    }
                    Section {
                        ForEach(model.rows.filter(isDestination)) { row in
                            rowView(row)
                        }
                    } footer: {
                        if model.saveProblem != nil {
                            Label {
                                Text("That change couldn’t be saved.", bundle: .module)
                                    .foregroundStyle(theme.colors[.textSecondary])
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(theme.colors[.attention])
                            }
                        }
                    }
                #else
                    if !model.isAvailable {
                        Text("Settings can't be read right now. They show their defaults.", bundle: .module)
                            .foregroundStyle(theme.colors[.textSecondary])
                    }
                    if model.saveProblem != nil {
                        Text("That change couldn't be saved.", bundle: .module)
                            .foregroundStyle(theme.colors[.failed])
                    }
                    if let actionButtonSetup {
                        Section {
                            Button(String(localized: "Action Button setup", bundle: .module), action: actionButtonSetup)
                                .tint(theme.colors[.textPrimary])
                        }
                    }
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                    if let note = model.lockScreenNote {
                        Text(note)
                            .font(theme.type[.caption])
                            .foregroundStyle(theme.colors[.textSecondary])
                    }
                #endif
            }
            #if os(iOS)
                .formStyle(.grouped)
            #endif
            .disabled(!model.isAvailable)
            .task { await model.observeSync() }
        }

        #if os(iOS)
            private func isDestination(_ row: SettingsRow) -> Bool {
                row == .about || row == .recentlyDeleted || row == .exportAll
            }

            private func navigationRow(
                _ title: String, showsDisclosure: Bool = true, action: @escaping () -> Void
            ) -> some View {
                Button(action: action) {
                    HStack {
                        Text(title)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if showsDisclosure {
                            Image(systemName: "chevron.right")
                                .font(theme.type[.stateLine])
                                .foregroundStyle(theme.colors[.textSecondary])
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(theme.colors[.textPrimary])
                    .frame(maxWidth: .infinity, minHeight: theme.sizes.hitTarget, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        #endif

        @ViewBuilder private func rowView(_ row: SettingsRow) -> some View {
            switch row {
            case .appendWindow:
                let minutes = Binding(
                    get: { model.settings.appendWindow.minutes },
                    set: { minutes in Task { await model.setAppendWindow(minutes: minutes) } })
                #if os(iOS)
                    HStack {
                        let layout =
                            dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                        layout {
                            Text(row.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(model.appendWindowText)
                        }
                        Stepper(row.title, value: minutes, in: 0...AppendWindow.maximumMinutes)
                            .labelsHidden()
                            .accessibilityValue(Text(model.appendWindowText))
                    }
                #else
                    Stepper(value: minutes, in: 0...AppendWindow.maximumMinutes) {
                        LabeledContent(row.title, value: model.appendWindowText)
                    }
                #endif
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
                #if os(iOS)
                    if dynamicTypeSize.isAccessibilitySize {
                        englishPicker(row.title).pickerStyle(.navigationLink)
                    } else {
                        englishPicker(row.title).pickerStyle(.menu)
                    }
                #else
                    englishPicker(row.title)
                #endif
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
                #if os(iOS)
                    navigationRow(row.title, showsDisclosure: row != .exportAll) { open(row) }
                #else
                    Button(row.title) { open(row) }
                #endif
            }
        }

        private func englishPicker(_ title: String) -> some View {
            Picker(
                title,
                selection: Binding(
                    get: { model.settings.englishVariant.rawValue },
                    set: { raw in Task { await model.setEnglishVariant(EnglishVariant(rawValue: raw)) } })
            ) {
                ForEach(SettingsViewModel.englishVariants, id: \.rawValue) { variant in
                    Text(SettingsViewModel.label(of: variant))
                        #if os(iOS)
                            .foregroundStyle(theme.colors[.textPrimary])
                        #endif
                        .tag(variant.rawValue)
                }
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
