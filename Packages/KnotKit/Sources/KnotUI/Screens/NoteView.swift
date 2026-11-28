#if !os(watchOS)
    import KnotCore
    import SwiftUI
    #if os(iOS)
        import UIKit
    #endif

    /// An open note, and the capture surface, which is that note with its field focused while
    /// the window is open (docs/product-spec.md §7). A thin view over `NoteViewModel`: its
    /// segments, then the capture field as the last element, the record control, and "New note"
    /// one action away.
    public struct NoteView: View {
        @Environment(\.knotTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.openURL) private var openURL
        @Environment(\.calendar) private var calendar
        @Environment(\.locale) private var locale
        @FocusState private var fieldFocused: Bool
        let model: NoteViewModel
        let player: PlayerViewModel
        @State private var restoreFieldFocus = false
        @State private var titleFocused = false
        @State private var focusedSegments: Set<SegmentID> = []

        public static var captureFieldScrollID: String { "capture-field" }

        public enum InitialFocus: Equatable, Sendable {
            case capture
            case none
            case title
            case segment(SegmentID)
        }

        private let initialFocus: InitialFocus?
        private let shareSegment: ((SegmentID) -> Void)?
        private let observesRecordings: Bool

        private var showsLiveControls: Bool { model.recording.isRecording || model.recording == .stopping }
        private var showsInsetControls: Bool {
            #if os(iOS)
                showsLiveControls || (fieldFocused && !editsExistingText)
            #else
                showsLiveControls
            #endif
        }
        private var editsExistingText: Bool { titleFocused || !focusedSegments.isEmpty }
        private var focusOnAppear: InitialFocus {
            initialFocus ?? (model.mode == .capture || model.surface != .app ? .capture : .none)
        }
        private var showsDone: Bool {
            model.mode == .capture || showsLiveControls || model.typedCapture != nil || !model.fieldText.isEmpty
        }
        public init(
            model: NoteViewModel, player: PlayerViewModel, initialFocus: InitialFocus? = nil,
            shareSegment: ((SegmentID) -> Void)? = nil, observesRecordings: Bool = true
        ) {
            self.model = model
            self.player = player
            self.initialFocus = initialFocus
            self.shareSegment = shareSegment
            self.observesRecordings = observesRecordings
        }

        public var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.betweenSegments) {
                    #if os(iOS)
                        if model.mode == .capture, model.speechDownloading {
                            SpeechDownloadNotice()
                        }
                    #endif
                    banners
                    page
                }
                #if os(iOS)
                    .padding(.horizontal)
                    .padding(.top, theme.spacing.space8)
                    .padding(.bottom, theme.spacing.space6)
                #else
                    .padding(theme.spacing.surfaceMargin)
                #endif
                .animation(theme.motion.animation(for: .listChange, reduceMotion: reduceMotion), value: model.items)
            }
            #if os(iOS)
                .defaultFocus($fieldFocused, focusOnAppear == .capture, priority: .userInitiated)
                .toolbar {
                    if showsDone {
                        ToolbarItem(placement: .topBarTrailing) { done }
                    }
                    if !showsInsetControls, !editsExistingText {
                        ToolbarItemGroup(placement: .bottomBar) { captureActions }
                    }
                }
                .toolbarVisibility(editsExistingText || showsInsetControls ? .hidden : .automatic, for: .bottomBar)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: theme.spacing.space2) {
                        if let offer = model.undoOffer {
                            UndoCapsule(offer, undo: model.undo)
                        }
                        if showsInsetControls {
                            // The scroll view's bottom inset follows the keyboard's own safe area.
                            HStack { captureActions }
                            .buttonStyle(.glass)
                            .padding(.horizontal)
                            .padding(.vertical, theme.spacing.space2)
                        }
                    }
                }
            #else
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        if model.surface == .macPanel {
                            Text(
                                model.isHeldRecording
                                    ? "Release the hotkey to stop" : "⌘↩ Done, ⌘N New note, esc Close",
                                bundle: .module
                            )
                            .font(theme.type[.rowPreview])
                            .foregroundStyle(theme.colors[.textSecondary])
                        }
                        newNote
                        Spacer()
                        recordingControls
                    }
                    .padding(theme.spacing.surfaceMargin)
                }
            #endif
            .onAppear { fieldFocused = focusOnAppear == .capture }
            .onChange(of: model.recording) { _, phase in
                if phase == .idle, restoreFieldFocus {
                    fieldFocused = true
                    restoreFieldFocus = false
                }
            }
            .onDisappear { model.endCapture() }
            #if os(iOS)
                .task(id: model.mode) { await model.observeSpeechReadiness() }
            #endif
            .task { await model.refresh() }
            .task { await model.observeStore() }
            .task {
                if observesRecordings { await model.observeRecordings() }
            }
            .task { await model.followWindow(every: .seconds(5)) }
            .task { await player.observe() }
        }

        @ViewBuilder private var captureActions: some View {
            newNote
            Spacer()
            recordingControls
        }

        @ViewBuilder private var page: some View {
            if model.mode == .capture {
                let current = model.activeRecording.map(SegmentID.init)
                let justSaved = model.lastRecording.map(SegmentID.init)
                let earlier = model.items.filter { $0.id != current && $0.id != justSaved }
                if let note = model.record?.note, !earlier.isEmpty {
                    VStack(alignment: .leading, spacing: theme.spacing.space2) {
                        Text(
                            "Adding to the note from \(appendCaptionTime(note.createdAt, calendar: calendar, locale: locale))",
                            bundle: .module
                        )
                        .font(theme.type[.appendCaption])
                        .foregroundStyle(theme.colors[.textSecondary])
                        if model.surface != .macPanel {
                            VStack(alignment: .leading, spacing: theme.spacing.betweenSegments) {
                                ForEach(earlier) { item in
                                    segment(item, secondaryText: true)
                                }
                            }
                        }
                    }
                }
                if let item = model.items.first(where: { $0.id == justSaved }) {
                    segment(item)
                }
            } else {
                NoteTitleEditor(model: model, initiallyEditing: focusOnAppear == .title) {
                    titleFocused = $0
                }
                ForEach(model.items) { item in
                    if item.id != model.activeRecording.map(SegmentID.init) {
                        segment(item)
                    }
                }
            }
            if model.recording.isRecording || model.recording == .stopping {
                LiveCaptureSegment(
                    transcript: model.liveTranscript, levels: model.surface == .macPanel ? [] : model.liveLevels,
                    isLive: model.recording.isRecording)
            } else {
                CaptureField(
                    text: model.fieldText, acceptsTyping: model.fieldAcceptsTyping, isFocused: $fieldFocused,
                    typeRole: model.surface == .macPanel || model.surface == .app ? .captureField : .body,
                    onChange: model.fieldChanged, onSubmit: model.endCapture
                )
                .id(Self.captureFieldScrollID)
            }
        }

        private var done: some View {
            Button(action: model.endCapture) {
                Label {
                    Text("Done", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark")
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.glassProminent)
            .tint(theme.colors[.textPrimary])
            .accessibilityShowsLargeContentViewer {
                Label {
                    Text("Done", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.fieldAcceptsTyping || (model.typedCapture == nil && model.fieldText.isEmpty))
        }

        @ViewBuilder private var newNote: some View {
            #if os(iOS)
                let showsNewNote = model.offersNewNote || showsLiveControls
                let labelSize = showsInsetControls ? theme.sizes.insetGlassLabel : theme.sizes.hitTarget
            #else
                let showsNewNote = model.offersNewNote
            #endif
            if showsNewNote {
                Button {
                    model.newNote()
                    fieldFocused = true
                } label: {
                    Label {
                        Text("New note", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                    #if os(iOS)
                        .labelStyle(.iconOnly)
                        .font(theme.type[.rowTitle])
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: labelSize, height: labelSize)
                        .contentShape(.rect)
                    #endif
                }
                #if os(iOS)
                    .buttonBorderShape(.circle)
                    .buttonSizing(.flexible)
                    .frame(width: theme.sizes.hitTarget, height: theme.sizes.hitTarget)
                    .accessibilityShowsLargeContentViewer {
                        Label {
                            Text("New note", bundle: .module)
                        } icon: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                #endif
                .keyboardShortcut("n", modifiers: .command)
                #if os(iOS)
                    .disabled(showsLiveControls)
                #endif
            }
        }

        @ViewBuilder private var recordingControls: some View {
            if model.recording.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in recordControl(elapsed: model.recordingElapsed) }
            } else {
                recordControl(elapsed: model.recordingElapsed)
            }
        }

        private func recordControl(elapsed: Duration?) -> some View {
            HStack(spacing: theme.spacing.regular) {
                if let elapsed {
                    Text(ClockText.of(elapsed))
                        .font(theme.type[.recordingTime])
                        .foregroundStyle(theme.colors[.textPrimary])
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
                if model.recordingOutcome == .saved {
                    Text("Saved", bundle: .module)
                        .font(theme.type[.body])
                        .foregroundStyle(theme.colors[.textPrimary])
                        .accessibilityHidden(true)
                }
                RecordButton(
                    phase: model.recording, elapsed: elapsed, outcome: model.recordingOutcome,
                    toolbar: model.surface == .app && !showsInsetControls
                ) {
                    if model.recording == .idle { restoreFieldFocus = fieldFocused }
                    model.toggleRecording()
                }
            }
        }

        @ViewBuilder private var banners: some View {
            if model.isDeletedElsewhere {
                Banner(
                    String(localized: "This note was deleted on another device.", bundle: .module), symbol: "trash",
                    role: .textPrimary
                ) {
                    Button {
                        model.restoreDeletedNote()
                    } label: {
                        Text("Restore", bundle: .module)
                    }
                    .modifier(NoticeActionStyle())
                }
            }
            if model.recordingOutcome == .discarded {
                Banner(
                    String(localized: "Too short. Nothing was kept.", bundle: .module), symbol: "mic")
            }
            if model.recordingOutcome == .saveFailed {
                Banner(
                    Announcement.recordingSaveFailed.text,
                    symbol: "exclamationmark.triangle", role: .failed, dismiss: model.dismissRecordingOutcome)
            }
            if let problem = model.problem {
                let permission = problem == .couldNotStartRecording(KnotError.microphonePermissionRefused.code)
                Banner(
                    problem.message, symbol: permission ? "mic.slash" : "exclamationmark.triangle",
                    role: .failed, dismiss: model.dismissProblem
                ) {
                    #if os(iOS)
                        if permission,
                            let settings = URL(string: UIApplication.openSettingsURLString)
                        {
                            Button {
                                openURL(settings)
                            } label: {
                                Text("Open Settings", bundle: .module)
                            }
                            .modifier(NoticeActionStyle())
                        }
                    #endif

                }
            }
            // Each conflict keeps its own draft until the person decides it. How this looks is
            // the design round's.
            ForEach(Array(model.editConflicts.values), id: \.target) { conflict in
                Banner(conflictMessage(conflict), symbol: "arrow.triangle.2.circlepath", role: .textPrimary) {
                    Button {
                        model.keepMyEdit(conflict.target)
                    } label: {
                        Text("Keep mine", bundle: .module)
                    }
                    .modifier(NoticeActionStyle())
                    .disabled(!model.canKeepEdit(conflict.target))
                    Button {
                        model.dropMyEdit(conflict.target)
                    } label: {
                        Text("Keep the new text", bundle: .module)
                    }
                    .modifier(NoticeActionStyle())
                }
            }
            #if !os(iOS)
                if let offer = model.undoOffer {
                    Banner(offer.label, symbol: "arrow.uturn.backward") {
                        Button {
                            model.undo()
                        } label: {
                            Text("Undo", bundle: .module)
                        }
                        .modifier(NoticeActionStyle())
                        .keyboardShortcut("z", modifiers: .command)
                    }
                }
            #endif
        }

        private func conflictMessage(_ conflict: EditConflict) -> String {
            guard let arrived = conflict.arrived, !arrived.isEmpty else { return conflict.message }
            let comparison = String(localized: "Changed to: \(arrived)", bundle: .module)
            return "\(conflict.message)\n\(comparison)"
        }

        private func segment(_ item: SegmentItem, secondaryText: Bool = false) -> some View {
            SegmentView(
                item,
                text: model.editConflict(for: .segment(item.id))?.draft ?? model.displayedText(of: item),
                isShowingOriginal: model.showingOriginal.contains(item.id),
                playback: player.segment == item.id ? player.state : .empty,
                secondaryText: secondaryText, initiallyEditing: focusOnAppear == .segment(item.id),
                playbackAllowed: model.recording == .idle,
                handlers: handlers(for: item))
        }

        private func handlers(for item: SegmentItem) -> SegmentHandlers {
            SegmentHandlers(
                edit: { text in model.editText(of: item.id, to: text) },
                action: { action in
                    if action == .shareFile { shareSegment?(item.id) } else { model.perform(action, on: item.id) }
                },
                togglePlay: {
                    Task {
                        guard model.recording == .idle, let file = await model.file(of: item),
                            model.recording == .idle
                        else { return }
                        await player.toggle(file, segment: item.id)
                    }
                },
                seek: { position in
                    Task {
                        guard player.segment == item.id, model.recording == .idle else { return }
                        await player.seek(to: position)
                    }
                },
                beginEdit: { model.beginEditing(item.id) },
                endEdit: { model.endEditing(item.id) },
                editingChanged: { editing in
                    if editing { focusedSegments.insert(item.id) } else { focusedSegments.remove(item.id) }
                },
                recordingPeaks: { await model.recordingPeaks(of: item) },
                drawing: { scale throws(KnotError) in try await model.drawing(of: item, scale: scale) })
        }
    }

    /// Edits the title in place and keeps its original revision until focus leaves the field.
    private struct NoteTitleEditor: View {
        @Environment(\.knotTheme) private var theme
        @FocusState private var editing: Bool
        @State private var draft = ""
        @State private var original = ""
        let model: NoteViewModel
        let initiallyEditing: Bool
        let editingChanged: (Bool) -> Void

        private var title: String { model.title ?? "" }

        var body: some View {
            TextField(text: $draft) {
                Text("Title", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(theme.type[.noteTitle])
            .focused($editing)
            .accessibilityLabel(Text("Title", bundle: .module))
            .accessibilityAddTraits(.isHeader)
            .onAppear {
                draft = title
                editing = initiallyEditing
            }
            .onChange(of: title) { _, new in
                if !editing { draft = new }
            }
            .onChange(of: editing) { _, focused in
                editingChanged(focused)
                if focused {
                    original = draft
                    model.beginEditingTitle()
                } else {
                    finishEdit()
                }
            }
            .onSubmit { editing = false }
            .onDisappear {
                if editing {
                    editingChanged(false)
                    finishEdit()
                }
            }
        }

        private func finishEdit() {
            if draft != original {
                model.setTitle(draft)
            } else {
                model.endEditingTitle()
                draft = title
            }
        }
    }
#endif
