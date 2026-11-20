import Foundation
import KnotCore
import Observation

/// Where the record control stands on a surface.
public enum RecordingPhase: Hashable, Sendable {
    case idle
    /// A press started a recording that is not live yet. Another press is ignored.
    case starting
    case recording(CaptureID)
    /// A press stopped the recording, which is not saved yet. Another press is ignored.
    case stopping

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// What can be undone at once (docs/product-spec.md §7): a delete, or a move to a note of its
/// own. The app's undo of a move is the store's return.
public enum UndoOffer: Hashable, Sendable {
    case deletedSegment(SegmentID)
    case deletedNote(NoteID)
    /// `segment` moved out of the open note into `newNote`.
    case moved(segment: SegmentID, newNote: NoteID)

    public var label: String {
        switch self {
        case .deletedSegment: localized("Segment deleted")
        case .deletedNote: localized("Note deleted")
        case .moved: localized("Moved to its own note")
        }
    }
}

/// The view model of a note and of the capture surface: one, because with the append window
/// open the capture surface is that note with its field focused (docs/product-spec.md §7,
/// assumption A27). A note is a stack of segments, each edited on its own, and new text enters
/// through the capture field, the last element of every open note.
///
/// It talks to ports only. It never applies the append rule: the note a capture surface shows
/// comes from `NoteStore.predictPlacement`, which calls the same rule as the store's
/// record-a-capture transaction, and the store decides where a capture lands
/// (docs/architecture.md §5).
@MainActor
@Observable
public final class NoteViewModel {
    public enum Mode: Hashable, Sendable {
        /// The capture surface: it shows the note a capture would join, following the window.
        case capture
        /// An open note: its field always appends to it (rule 5).
        case note(NoteID)
    }

    public private(set) var mode: Mode
    /// The surface captures start on: the app, the Mac panel or the Mac window.
    public let surface: CaptureSurface
    /// The note on screen, or `nil` for a blank capture surface.
    public private(set) var record: NoteRecord?
    /// The note's segments, without the one the field is typing.
    public private(set) var items: [SegmentItem] = []
    public private(set) var fieldText = ""
    /// "New note" was pressed: the surface shows a blank note until the next capture makes it.
    public private(set) var isNewNote = false
    public private(set) var recording: RecordingPhase = .idle
    /// Where the open capture's content is durable, once it began.
    public private(set) var capturePath: CapturePath?
    public private(set) var problem: SurfaceProblem?
    public private(set) var undoOffer: UndoOffer?
    /// The open note was deleted on another device: it says so and offers to restore it.
    public private(set) var isDeletedElsewhere = false
    /// The person deleted the open note here: the surface closes, with the undo offered.
    public private(set) var isClosed = false
    /// The voice segments that show their raw transcript.
    public private(set) var showingOriginal: Set<SegmentID> = []
    /// The typed capture the field is making, from its first keystroke to its end.
    public private(set) var typedCapture: CaptureID?

    /// A running recording blocks typing on every capture surface (rule 15).
    public var fieldAcceptsTyping: Bool { recording == .idle }

    public var noteID: NoteID? { record?.note.id }

    public var title: String? { record?.note.title }

    /// "New note" is one action away wherever the surface shows a note (rule 4). It waits
    /// while a recording runs, and has nothing to do on a surface that is already blank.
    public var offersNewNote: Bool {
        recording == .idle && (record != nil || typedCapture != nil || mode != .capture)
    }

    private let environment: AppEnvironment
    private let context: UIContext
    private let announcer: any Announcer
    private var speech: TranscriberReadiness = .ready
    private var assets: [AssetID: Asset] = [:]
    private var chain: Task<Void, Never>?
    private var sentText = ""
    private var recordingPress: Press?
    private var arrivalsCleared = false

    public init(
        environment: AppEnvironment, context: UIContext, surface: CaptureSurface = .app, opening note: NoteID? = nil,
        announcer: any Announcer
    ) {
        self.environment = environment
        self.context = context
        self.surface = surface
        self.announcer = announcer
        self.mode = note.map(Mode.note) ?? .capture
    }

    // MARK: Loading

    /// Reads what the surface shows. On the capture surface with nothing typed, it asks the
    /// store which note a capture would join now, so that when the window runs out while the
    /// field is still empty, the earlier note leaves the surface (docs/product-spec.md §4.1).
    /// Once the first keystroke has fixed the destination, it only reads that note again.
    public func refresh() async {
        speech = await environment.transcriber.readiness()
        switch mode {
        case .note(let id):
            await show(id)
            if !arrivalsCleared, record != nil {
                // Opening a note clears its arrival marks, which changes no revision.
                arrivalsCleared = (try? await environment.notes.clearArrivalMarks(in: id)) != nil
                await show(id)
            }
        case .capture:
            if typedCapture != nil || recording != .idle {
                if let id = record?.note.id { await show(id) }
            } else if isNewNote {
                clearNote()
            } else {
                await followWindow()
            }
        }
    }

    /// Reads the surface again after each change the store publishes, such as text that
    /// arrived, a late capture or a delete on another device. New text never moves focus:
    /// this only changes the model, and the view keeps its focus.
    public func observeStore() async {
        for await _ in environment.notes.changeSignals() {
            await settle()
            await refresh()
        }
    }

    /// Asks the store again every `interval` while the field is empty, so the surface follows
    /// the window as time passes.
    public func followWindow(every interval: Duration) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            if typedCapture == nil, recording == .idle, mode == .capture { await refresh() }
        }
    }

    /// Waits until every action sent so far has run, in order.
    public func settle() async {
        while let running = chain {
            await running.value
            if chain == running { chain = nil }
        }
    }

    private func followWindow() async {
        let request = AppendRequest(
            startedAt: environment.clock.now(), placement: .window, source: .device(context.thisDevice))
        let decision: AppendDecision
        do {
            decision = try await environment.notes.predictPlacement(request, kind: .typed, surface: surface)
        } catch {
            clearNote()
            return
        }
        if let id = decision.joinedNote { await show(id) } else { clearNote() }
    }

    private func show(_ id: NoteID) async {
        let read: NoteRecord?
        do { read = try await environment.notes.note(id) } catch { return }
        guard let read else {
            // Purged: gone everywhere.
            if case .note = mode, !isClosed { isDeletedElsewhere = true }
            record = nil
            items = []
            return
        }
        if case .note = mode {
            isDeletedElsewhere = read.note.deletedAt != nil && !isClosed
        }
        var found: [AssetID: Asset] = [:]
        for assetID in read.liveSegments.compactMap(\.assetID) {
            if let asset = try? await environment.notes.asset(assetID) { found[assetID] = asset }
        }
        assets = found
        record = read
        items = SegmentPresenter.items(
            for: read, assets: found, thisDevice: context.thisDevice, speech: speech,
            excluding: typedCapture.map(SegmentID.init))
    }

    private func clearNote() {
        record = nil
        items = []
    }

    // MARK: The capture field

    /// The field's text changed. The first keystroke begins a typed capture, which fixes where
    /// it lands; each later change saves the text again. Saves go to the engine from one task,
    /// in order, and the latest text wins when several wait.
    public func fieldChanged(_ text: String) {
        guard fieldAcceptsTyping else { return }
        fieldText = text
        enqueue { model in await model.saveField() }
    }

    /// Ends the typed capture: Done, ⌘↩, or the surface hiding (docs/product-spec.md §4.1).
    /// Empty text leaves nothing in the stream.
    public func endCapture() {
        enqueue { model in await model.endTypedCapture() }
    }

    /// "New note": forces a new note inside the window (rule 4). The text typed so far stays in
    /// its own note, and the surface shows a blank note until the next capture makes it.
    public func newNote() {
        guard recording == .idle else { return }
        enqueue { model in
            await model.endTypedCapture()
            guard model.typedCapture == nil else { return }
            model.mode = .capture
            model.isNewNote = true
            model.isDeletedElsewhere = false
            model.undoOffer = nil
            model.clearNote()
        }
    }

    private var placement: CapturePlacement {
        switch mode {
        case .note(let id): .named(id)
        case .capture: isNewNote ? .newNote : .window
        }
    }

    private func saveField() async {
        let text = fieldText
        guard text != sentText else { return }
        if let id = typedCapture {
            do {
                let state = try await environment.engine.update(id, with: .text(text))
                sentText = text
                capturePath = state.path
                clearSaveProblem()
            } catch {
                problem = .couldNotSave(error.code)
            }
            return
        }
        guard !text.isEmpty else { return }
        let request = CaptureRequest(
            kind: .typed, surface: surface, placement: placement, shownNote: record?.note.id, text: text)
        do {
            let state = try await environment.engine.begin(request)
            typedCapture = state.captureID
            sentText = text
            capturePath = state.path
            isNewNote = false
            clearSaveProblem()
            // The destination is fixed now: the surface shows the note the capture is in.
            if let id = state.noteID { await show(id) } else { clearNote() }
        } catch {
            problem = .couldNotSave(error.code)
        }
    }

    private func endTypedCapture() async {
        guard let id = typedCapture else {
            if fieldText.isEmpty { return }
            // Text that could not begin a capture stays in the field: try once more.
            await saveField()
            guard typedCapture != nil else { return }
            return await endTypedCapture()
        }
        if fieldText != sentText { await saveField() }
        do {
            let state = try await environment.engine.end(id)
            capturePath = state.path
            typedCapture = nil
            fieldText = ""
            sentText = ""
            clearSaveProblem()
            if let note = state.noteID, case .capture = mode, state.outcome == .stored { await show(note) }
            await refresh()
        } catch {
            // The surface stays open with the text in it and says it could not save (§4.4).
            problem = .couldNotSave(error.code)
        }
    }

    private func clearSaveProblem() {
        if case .couldNotSave = problem { problem = nil }
    }

    // MARK: Recording

    /// A tap on the record control. It starts a recording when none runs and stops the one that
    /// runs. A press while a recording is starting or stopping is ignored, and a tap-started
    /// recording stopped within a second of its tap is discarded (docs/product-spec.md §4.2).
    public func toggleRecording() {
        press(.tap)
    }

    /// A press of the record control, or of the Mac hotkey's hold.
    public func press(_ kind: PressKind) {
        let now = environment.clock.now()
        let activity: RecorderActivity =
            switch recording {
            case .idle: .idle
            case .starting: .starting
            case .stopping: .stopping
            case .recording: .recording(startedBy: recordingPress ?? Press(.tap, at: .distantPast))
            }
        let decision = RecordingPressRule.decide(Press(kind, at: now), recorder: activity, saved: nil)
        switch decision {
        case .ignore:
            return
        case .start, .recoverOrphanThenStart:
            recording = .starting
            recordingPress = Press(kind, at: now)
            enqueue { model in await model.startRecording() }
        case .stopAndKeep, .stopAndDiscard:
            guard case .recording(let id) = recording else { return }
            recording = .stopping
            let discard = decision == .stopAndDiscard
            enqueue { model in await model.stopRecording(id, discard: discard) }
        }
    }

    private func startRecording() async {
        // Starting a recording ends the typed capture: its text is saved as it stands, and the
        // recording becomes the next segment of the same note (rule 15).
        await endTypedCapture()
        let request = CaptureRequest(kind: .voice, surface: surface, placement: placement, shownNote: record?.note.id)
        do {
            let state = try await environment.engine.begin(request)
            recording = .recording(state.captureID)
            capturePath = state.path
            isNewNote = false
            if problem != nil, case .couldNotStartRecording = problem { problem = nil }
            announcer.announce(.recordingStarted)
            if let id = state.noteID { await show(id) }
        } catch {
            recording = .idle
            recordingPress = nil
            problem = .couldNotStartRecording(error.code)
            announcer.announce(.recordingCouldNotStart)
        }
    }

    private func stopRecording(_ id: CaptureID, discard: Bool) async {
        let state: CaptureState?
        if discard {
            state = try? await environment.engine.discard(id)
        } else {
            state = try? await environment.engine.end(id)
        }
        recording = .idle
        recordingPress = nil
        announcer.announce(discard || state?.outcome == .discardedEmpty ? .recordingDiscarded : .recordingStopped)
        if let note = state?.noteID, state?.outcome == .stored { await show(note) }
        await refresh()
    }

    // MARK: Segments and the note

    /// Replaces a segment's text with the person's edit. Edits beat cleaned and raw text, and the
    /// store refuses a stale revision.
    public func editText(of segment: SegmentID, to text: String) {
        enqueue { model in
            guard let record = model.record else { return }
            let replacement = TextReplacement(
                segment: segment, text: text, origin: .edited, writer: .app, ifRevision: record.revision(of: segment))
            await model.storeAction { notes in _ = try await notes.replaceText(replacement) }
        }
    }

    /// Sets the note's title, or clears it with `nil` or blank text.
    public func setTitle(_ title: String?) {
        enqueue { model in
            guard let record = model.record else { return }
            let value = title.flatMap { CaptureText.isEmpty($0) ? nil : $0 }
            await model.storeAction { notes in _ = try await notes.setTitle(value, of: record.note.id, ifRevision: nil)
            }
        }
    }

    /// Runs a segment's action.
    public func perform(_ action: SegmentAction, on segment: SegmentID) {
        switch action {
        case .delete: delete(segment)
        case .moveToOwnNote: moveToOwnNote(segment)
        case .removeRecording: removeRecording(of: segment)
        case .showOriginal: toggleOriginal(segment)
        case .retry: retry(segment)
        case .moveWorkHere: problem = .notAvailableYet
        case .play, .shareFile:
            // The view plays and shares the file itself, through the player and the system.
            break
        }
    }

    public func delete(_ segment: SegmentID) {
        enqueue { model in
            if await model.storeAction({ notes in _ = try await notes.delete(.segment(segment)) }) {
                model.undoOffer = .deletedSegment(segment)
            }
        }
    }

    public func deleteNote() {
        enqueue { model in
            guard let id = model.record?.note.id else { return }
            // Deleted here, not elsewhere: the surface closes before it reads the note again.
            let closes = model.mode == .note(id)
            if closes { model.isClosed = true }
            if await model.storeAction({ notes in _ = try await notes.delete(.note(id)) }) {
                model.undoOffer = .deletedNote(id)
            } else if closes {
                model.isClosed = false
            }
        }
    }

    /// "Move to its own note": the segment leaves this note for a new note of its own, and this
    /// note stays in front of the person. The move can be undone at once.
    public func moveToOwnNote(_ segment: SegmentID) {
        enqueue { model in
            guard let from = model.record?.note.id else { return }
            do throws(KnotError) {
                switch try await model.environment.notes.move(segment, from: from) {
                case .moved(let outcome):
                    model.undoOffer = .moved(segment: segment, newNote: outcome.to.note.id)
                case .notInThatNote:
                    model.undoOffer = nil
                }
            } catch {
                model.problem = .actionRefused(error.code)
            }
            await model.refresh()
        }
    }

    /// Undoes the last delete or move. The undo of a move is the store's return, refused when
    /// the note it left has changed since or is gone: it then changes nothing, and the segment
    /// stays in its new note.
    public func undo() {
        guard let offer = undoOffer else { return }
        enqueue { model in
            model.undoOffer = nil
            switch offer {
            case .deletedSegment(let id):
                await model.storeAction { notes in _ = try await notes.restore(.segment(id)) }
            case .deletedNote(let id):
                if await model.storeAction({ notes in _ = try await notes.restore(.note(id)) }) {
                    model.isClosed = false
                }
            case .moved(let segment, let newNote):
                do throws(KnotError) {
                    _ = try await model.environment.notes.returnToFormerNote(segment, from: newNote)
                } catch {
                    model.problem = .undoRefused(error.code)
                }
                await model.refresh()
            }
        }
    }

    /// Lets the undo offer go.
    public func dismissUndo() {
        undoOffer = nil
    }

    /// Restores the open note that was deleted on another device.
    public func restoreDeletedNote() {
        enqueue { model in
            guard case .note(let id) = model.mode else { return }
            if await model.storeAction({ notes in _ = try await notes.restore(.note(id)) }) {
                model.isDeletedElsewhere = false
            }
        }
    }

    /// "Remove recording": keeps the text and deletes the audio.
    public func removeRecording(of segment: SegmentID) {
        enqueue { model in
            await model.storeAction { notes in
                let asset = try await notes.removeRecording(of: segment)
                try await model.environment.assets.remove(asset.id, kind: asset.kind)
            }
        }
    }

    /// "Show original": switches a voice segment between its cleaned and its raw text.
    public func toggleOriginal(_ segment: SegmentID) {
        if showingOriginal.contains(segment) {
            showingOriginal.remove(segment)
        } else {
            showingOriginal.insert(segment)
        }
    }

    /// The text a segment shows now: its raw transcript while "Show original" is on.
    public func displayedText(of item: SegmentItem) -> String {
        showingOriginal.contains(item.id) ? item.rawTranscript ?? item.text : item.text
    }

    /// Retries the failed step of a recording or a drawing: its failed jobs go back to the
    /// queue, the segment returns to waiting, and the queue wakes for it.
    public func retry(_ segment: SegmentID) {
        enqueue { model in
            await model.storeAction { notes in
                guard let read = try await notes.segment(segment) else { throw KnotError.notFound }
                for job in try await notes.jobs(for: segment) {
                    guard case .failed = job.state else { continue }
                    guard let retried = try? JobMachine.reduce(job, .retry) else { throw KnotError.illegalTransition }
                    try await notes.saveJob(retried)
                }
                let next: SegmentState
                switch read.state {
                case .voice(let state):
                    guard let moved = try? VoiceMachine.reduce(state, .retry) else { throw KnotError.illegalTransition }
                    next = .voice(moved)
                case .ink(let state):
                    guard let moved = try? InkMachine.reduce(state, .retry) else { throw KnotError.illegalTransition }
                    next = .ink(moved)
                default:
                    throw KnotError.illegalTransition
                }
                _ = try await notes.setState(next, of: segment)
                try await model.environment.queue.enqueue(segment)
            }
        }
    }

    /// The whole note as text: Copy note is one action (docs/product-spec.md §7).
    public var noteText: String {
        var parts: [String] = []
        if let title = record?.note.title, !CaptureText.isEmpty(title) { parts.append(title) }
        parts += items.map { displayedText(of: $0) }.filter { !CaptureText.isEmpty($0) }
        return parts.joined(separator: "\n\n")
    }

    /// The file of a segment's recording or drawing on this device, for the player and Share.
    public func file(of item: SegmentItem) async -> URL? {
        guard case .here(let asset) = item.attachment else { return nil }
        return try? await environment.assets.find(asset.id, kind: asset.kind)?.url
    }

    public func dismissProblem() {
        problem = nil
    }

    // MARK: Plumbing

    /// Runs a store action, then reads the surface again. A refusal changes nothing and says so.
    @discardableResult
    private func storeAction(_ body: (any NoteStore) async throws -> Void) async -> Bool {
        do {
            try await body(environment.notes)
            await refresh()
            return true
        } catch {
            problem = .actionRefused((error as? KnotError)?.code ?? KnotError.unexpected.code)
            await refresh()
            return false
        }
    }

    /// Runs `work` after everything sent before it, so that saves reach the engine in order.
    private func enqueue(_ work: @escaping @MainActor @Sendable (NoteViewModel) async -> Void) {
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }
}
