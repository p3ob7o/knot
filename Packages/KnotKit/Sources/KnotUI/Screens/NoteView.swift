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
        @FocusState private var fieldFocused: Bool
        let model: NoteViewModel
        let player: PlayerViewModel
        @State private var restoreFieldFocus = false
        @State private var playing: SegmentID?

        public init(model: NoteViewModel, player: PlayerViewModel) {
            self.model = model
            self.player = player
        }

        public var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.betweenSegments) {
                    banners
                    page
                }
                .padding(theme.spacing.surfaceMargin)
                .animation(theme.motion.animation(for: .listChange, reduceMotion: reduceMotion), value: model.items)
            }
            #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { done }
                    ToolbarItemGroup(placement: .keyboard) {
                        newNote
                        Spacer()
                        recordingControls
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        newNote
                        Spacer()
                        recordingControls
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
                        done
                        recordingControls
                    }
                    .padding(theme.spacing.surfaceMargin)
                }
            #endif
            .onAppear { fieldFocused = true }
            .onChange(of: model.recording) { _, phase in
                if phase == .idle, restoreFieldFocus {
                    fieldFocused = true
                    restoreFieldFocus = false
                }
            }
            .onDisappear { model.endCapture() }
            .task { await model.refresh() }
            .task { await model.observeStore() }
            .task { await model.followWindow(every: .seconds(5)) }
            .task { await player.observe() }
        }

        @ViewBuilder private var page: some View {
            if model.mode == .capture, let note = model.record?.note {
                VStack(alignment: .leading, spacing: theme.spacing.tight) {
                    Text(
                        "Adding to the note from \(note.createdAt.formatted(date: .omitted, time: .shortened))",
                        bundle: .module
                    )
                    .font(theme.type[model.surface == .macPanel ? .rowPreview : .caption])
                    if model.surface != .macPanel {
                        ForEach(model.items) { item in
                            if item.id == model.lastRecording.map(SegmentID.init) {
                                segment(item)
                            } else if item.id != model.activeRecording.map(SegmentID.init) {
                                let text = model.displayedText(of: item)
                                Text(text.isEmpty ? item.kind.holding(duration: item.duration) : text)
                                    .font(theme.type[.body])
                            }
                        }
                    }
                }
                .foregroundStyle(theme.colors[.textSecondary])
                if model.surface == .macPanel, let last = model.lastRecording,
                    let item = model.items.first(where: { $0.id == SegmentID(last) })
                {
                    segment(item)
                }
            } else {
                if let title = model.title {
                    Text(title)
                        .font(theme.type[.noteTitle])
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(model.items) { item in
                    if item.id != model.activeRecording.map(SegmentID.init) {
                        segment(item)
                    }
                }
            }
            if model.recording.isRecording || model.recording == .stopping {
                LiveCaptureSegment(
                    transcript: model.liveTranscript, levels: model.surface == .macPanel ? [] : model.liveLevels)
            } else {
                CaptureField(
                    text: model.fieldText, acceptsTyping: model.fieldAcceptsTyping, isFocused: $fieldFocused,
                    typeRole: model.surface == .macPanel ? .noteTitle : .body,
                    onChange: model.fieldChanged, onSubmit: model.endCapture)
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
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.fieldAcceptsTyping || (model.typedCapture == nil && model.fieldText.isEmpty))
        }

        @ViewBuilder private var newNote: some View {
            if model.offersNewNote {
                Button {
                    model.newNote()
                    fieldFocused = true
                } label: {
                    Label {
                        Text("New note", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                    .labelStyle(.iconOnly)
                }
                .keyboardShortcut("n", modifiers: .command)
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
                        .font(theme.type[.body])
                        .foregroundStyle(theme.colors[.textPrimary])
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
                if model.recordingOutcome == .saved {
                    Text("Saved", bundle: .module).font(theme.type[.caption]).accessibilityHidden(true)
                }
                RecordButton(
                    phase: model.recording, elapsed: elapsed, outcome: model.recordingOutcome,
                    toolbar: model.surface == .app
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
                    role: .failed
                ) {
                    Button {
                        model.restoreDeletedNote()
                    } label: {
                        Text("Restore", bundle: .module)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if model.recordingOutcome == .discarded {
                Banner(
                    String(localized: "Too short. Nothing was kept.", bundle: .module), symbol: "mic",
                    role: .textSecondary)
            }
            if model.recordingOutcome == .saveFailed {
                Banner(
                    String(localized: "Knot couldn’t finish saving the recording.", bundle: .module),
                    symbol: "exclamationmark.triangle", role: .failed
                ) {
                    Button {
                        model.dismissRecordingOutcome()
                    } label: {
                        Text("Dismiss", bundle: .module)
                    }
                }
            }
            if let problem = model.problem {
                Banner(problem.message, symbol: "exclamationmark.triangle", role: .failed) {
                    #if os(iOS)
                        if problem == .couldNotStartRecording(KnotError.microphonePermissionRefused.code),
                            let settings = URL(string: UIApplication.openSettingsURLString)
                        {
                            Button {
                                openURL(settings)
                            } label: {
                                Text("Open Settings", bundle: .module)
                            }
                            .buttonStyle(.borderless)
                        }
                    #endif
                    Button {
                        model.dismissProblem()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Dismiss", bundle: .module))
                }
            }
            // Each conflict keeps its own draft until the person decides it. How this looks is
            // the design round's.
            ForEach(Array(model.editConflicts.values), id: \.target) { conflict in
                Banner(conflict.message, symbol: "arrow.triangle.2.circlepath", role: .failed) {
                    Button {
                        model.keepMyEdit(conflict.target)
                    } label: {
                        Text("Keep mine", bundle: .module)
                    }
                    Button {
                        model.dropMyEdit(conflict.target)
                    } label: {
                        Text("Keep the new text", bundle: .module)
                    }
                }
                .buttonStyle(.borderless)
            }
            if let offer = model.undoOffer {
                Banner(offer.label, symbol: "arrow.uturn.backward") {
                    Button {
                        model.undo()
                    } label: {
                        Text("Undo", bundle: .module)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("z", modifiers: .command)
                }
            }
        }

        private func segment(_ item: SegmentItem) -> some View {
            SegmentView(
                item,
                text: model.editConflict(for: .segment(item.id))?.draft ?? model.displayedText(of: item),
                isShowingOriginal: model.showingOriginal.contains(item.id),
                playback: playing == item.id ? player.state : .empty,
                handlers: handlers(for: item))
        }

        private func handlers(for item: SegmentItem) -> SegmentHandlers {
            SegmentHandlers(
                edit: { text in model.editText(of: item.id, to: text) },
                action: { action in model.perform(action, on: item.id) },
                togglePlay: {
                    Task {
                        guard let file = await model.file(of: item) else { return }
                        playing = item.id
                        await player.toggle(file)
                    }
                },
                seek: { position in Task { await player.seek(to: position) } },
                beginEdit: { model.beginEditing(item.id) },
                endEdit: { model.endEditing(item.id) },
                drawing: { scale throws(KnotError) in try await model.drawing(of: item, scale: scale) })
        }
    }
#endif
