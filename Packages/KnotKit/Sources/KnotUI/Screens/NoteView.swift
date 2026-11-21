#if !os(watchOS)
    import KnotCore
    import SwiftUI

    /// An open note, and the capture surface, which is that note with its field focused while
    /// the window is open (docs/product-spec.md §7). A thin view over `NoteViewModel`: its
    /// segments, then the capture field as the last element, the record control, and "New note"
    /// one action away.
    public struct NoteView: View {
        @Environment(\.knotTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @FocusState private var fieldFocused: Bool
        let model: NoteViewModel
        let player: PlayerViewModel
        @State private var playing: SegmentID?

        public init(model: NoteViewModel, player: PlayerViewModel) {
            self.model = model
            self.player = player
        }

        public var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.betweenSegments) {
                    banners
                    if let title = model.title {
                        Text(title)
                            .font(theme.type[.noteTitle])
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(model.items) { item in
                        SegmentView(
                            item,
                            text: model.editConflict(for: .segment(item.id))?.draft ?? model.displayedText(of: item),
                            isShowingOriginal: model.showingOriginal.contains(item.id),
                            playback: playing == item.id ? player.state : .empty,
                            handlers: handlers(for: item))
                    }
                    CaptureField(
                        text: model.fieldText, acceptsTyping: model.fieldAcceptsTyping, isFocused: $fieldFocused,
                        onChange: model.fieldChanged, onSubmit: model.endCapture)
                }
                .padding(theme.spacing.surfaceMargin)
                .animation(theme.motion.animation(for: .listChange, reduceMotion: reduceMotion), value: model.items)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
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
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    }
                    Spacer()
                    RecordButton(phase: model.recording, action: model.toggleRecording)
                }
                .padding(theme.spacing.surfaceMargin)
            }
            .onAppear { fieldFocused = true }
            .onDisappear { model.endCapture() }
            .task { await model.refresh() }
            .task { await model.observeStore() }
            .task { await model.followWindow(every: .seconds(5)) }
            .task { await player.observe() }
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
            if let problem = model.problem {
                Banner(problem.message, symbol: "exclamationmark.triangle", role: .failed) {
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
                endEdit: { model.endEditing(item.id) })
        }
    }
#endif
