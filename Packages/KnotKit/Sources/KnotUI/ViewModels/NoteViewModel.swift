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

/// A recording outcome is separate from the phase so typing can resume as soon as it ends.
public enum RecordingOutcome: Hashable, Sendable {
    case saved
    case discarded
    case couldNotStart
    case saveFailed
}

/// The typed field owns one sequence of saves. A refused save can still change what the engine
/// will try to write on end, so only an answered save lets the field ask for an end.
private struct TypedDraft {
    let placement: CapturePlacement
    let shownNote: NoteID?
    var acknowledged: (text: String, revision: Int64)?
    var submitted: String?
    var needsSave = false
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

/// An edit that the store refused because the text changed elsewhere after the edit began
/// (docs/architecture.md §6). Nothing was written: the person's draft is kept, and they decide.
public struct EditConflict: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case segment(SegmentID)
        case title
    }

    public var target: Target
    /// What the person wrote, kept. `nil` for a title they cleared.
    public var draft: String?
    /// What the store holds now, which arrived while they edited.
    public var arrived: String?

    public init(target: Target, draft: String?, arrived: String?) {
        self.target = target
        self.draft = draft
        self.arrived = arrived
    }

    public var message: String { localized("This text changed elsewhere while you edited it.") }

    /// The draft of `segment`, while this conflict is about it.
    public func draft(of segment: SegmentID) -> String? {
        target == .segment(segment) ? draft : nil
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
    public private(set) var recordingOutcome: RecordingOutcome?
    public private(set) var liveTranscript = LiveTranscript(final: "", volatile: "")
    public private(set) var liveLevels: [Float] = []
    public private(set) var lastRecording: CaptureID?
    public private(set) var activeRecording: CaptureID?
    public private(set) var isHeldRecording = false

    public var recordingElapsed: Duration? {
        if recording == .stopping { return frozenElapsed }
        guard recording.isRecording else { return nil }
        return recordingStartedAt.map { recordingClock.now() - $0 }
    }
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
    /// An edit refused as stale, waiting for the person to keep it or drop it.
    /// The edits refused as stale, each waiting for the person to keep it or drop it. A conflict
    /// belongs to its segment, and a title's to its note: each keeps its own draft.
    public private(set) var editConflicts: [EditConflict.Target: EditConflict] = [:]

    /// The conflict of `target`, if it has one.
    public func editConflict(for target: EditConflict.Target) -> EditConflict? { editConflicts[target] }

    /// A running recording blocks typing on every capture surface (rule 15).
    /// From the moment an end is asked until it answers, the field takes no typing either, so
    /// nothing can be typed that the capture will not hold. If the end fails, the field takes
    /// typing again with its text.
    public var fieldAcceptsTyping: Bool { recording == .idle && endsAsked == 0 }

    /// True while an end of the typed capture is asked and has not answered.
    public var isEnding: Bool { endsAsked > 0 }

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
    private var draft: TypedDraft?
    private var typedWatch: Task<Void, Never>?
    private var pressInFlight = false
    private let recordingClock: RecordingClock
    private var recordingStartedAt: Duration?
    private var frozenElapsed: Duration?
    private var recordingLive: Task<Void, Never>?
    private var recordingOutcomeExpiry: Task<Void, Never>?
    /// The ends of the typed capture asked and not yet answered.
    private var endsAsked = 0
    /// The revision of each segment when the person began editing it, which the edit carries.
    private var editBases: [SegmentID: StampedRevision] = [:]
    /// The revision of what each conflict showed as arrived. Committing again carries it, so a
    /// change that arrives after the conflict was shown is never replaced unseen.
    private var conflictBases: [EditConflict.Target: StampedRevision] = [:]
    /// The note's revision when the person began editing its title.
    private var titleBase: (note: NoteID, revision: StampedRevision)?
    private var conflictTitleNote: NoteID?
    /// Follows the running recording's capture, which can end by itself.
    private var recordingWatch: Task<Void, Never>?
    private var arrivalsCleared = false

    public init(
        environment: AppEnvironment, context: UIContext, surface: CaptureSurface = .app, opening note: NoteID? = nil,
        announcer: any Announcer, recordingClock: RecordingClock = .continuous
    ) {
        self.environment = environment
        self.context = context
        self.surface = surface
        self.announcer = announcer
        self.recordingClock = recordingClock
        self.mode = note.map(Mode.note) ?? .capture
    }

    isolated deinit {
        typedWatch?.cancel()
        recordingWatch?.cancel()
        recordingLive?.cancel()
        recordingOutcomeExpiry?.cancel()
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
            if draft != nil || !fieldText.isEmpty || recording != .idle {
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
            if draft == nil, fieldText.isEmpty, recording == .idle, mode == .capture { await refresh() }
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
            if canFollowWindow { clearNote() }
            return
        }
        guard canFollowWindow else { return }
        if let id = decision.joinedNote { await show(id, followingWindow: true) } else { clearNote() }
    }

    private var canFollowWindow: Bool {
        mode == .capture && draft == nil && fieldText.isEmpty && !isNewNote && recording == .idle
    }

    private func show(_ id: NoteID, followingWindow: Bool = false) async {
        let read: NoteRecord?
        do { read = try await environment.notes.note(id) } catch { return }
        guard !followingWindow || canFollowWindow else { return }
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
        guard !followingWindow || canFollowWindow else { return }
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
        if draft == nil, !text.isEmpty {
            draft = TypedDraft(placement: placement, shownNote: record?.note.id)
        }
        fieldText = text
        enqueue { model in await model.saveField() }
    }

    /// Ends the typed capture: Done, ⌘↩, or the surface hiding (docs/product-spec.md §4.1).
    /// Empty text leaves nothing in the stream.
    public func endCapture() {
        endsAsked += 1
        enqueue { model in
            _ = await model.endTypedCapture()
            model.endsAsked -= 1
        }
    }

    /// "New note": forces a new note inside the window (rule 4). The text typed so far stays in
    /// its own note, and the surface shows a blank note until the next capture makes it.
    public func newNote() {
        guard recording == .idle else { return }
        endsAsked += 1
        enqueue { model in
            let ended = await model.endTypedCapture()
            model.endsAsked -= 1
            guard ended else { return }
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

    @discardableResult
    private func saveField() async -> Bool {
        let text = fieldText
        if draft == nil, !text.isEmpty {
            draft = TypedDraft(placement: placement, shownNote: record?.note.id)
        }
        guard let draft else { return true }
        if !draft.needsSave, draft.acknowledged?.text == text { return true }
        if let id = typedCapture {
            self.draft?.submitted = text
            do {
                let state = try await environment.engine.update(id, with: .text(text))
                await acknowledgeTyped(state, text: text)
                return true
            } catch {
                self.draft?.needsSave = true
                problem = .couldNotSave(error.code)
                return false
            }
        }
        guard !text.isEmpty else {
            self.draft = nil
            clearSaveProblem()
            return true
        }
        let request = CaptureRequest(
            kind: .typed, surface: surface, placement: draft.placement, shownNote: draft.shownNote, text: text)
        let states = environment.engine.states()
        self.draft?.submitted = text
        do {
            let state = try await environment.engine.begin(request)
            typedCapture = state.captureID
            watchTyped(state.captureID, in: states)
            await acknowledgeTyped(state, text: text)
            return true
        } catch {
            if error.code != KnotError.segmentCaptureOpen.code,
                error.code != KnotError.captureBlockedByRecording.code,
                let id = error.context.captureID
            {
                typedCapture = id
                watchTyped(id, in: states)
            }
            self.draft?.needsSave = true
            problem = .couldNotSave(error.code)
            return false
        }
    }

    private func acknowledgeTyped(_ state: CaptureState, text: String) async {
        draft?.acknowledged = (text, state.durableRevision)
        draft?.needsSave = false
        capturePath = state.path
        isNewNote = false
        clearSaveProblem()
        if let note = state.noteID, record?.note.id != note { await show(note) }
    }

    private func watchTyped(_ id: CaptureID, in states: AsyncStream<CaptureState>) {
        typedWatch?.cancel()
        typedWatch = Task { [weak self] in
            for await state in states where state.captureID == id && state.outcome != .open {
                self?.enqueue { model in await model.acceptTypedEnd(state) }
                return
            }
        }
    }

    private func acceptTypedEnd(_ state: CaptureState) async {
        guard typedCapture == state.captureID, let draft else { return }
        let endedText: String?
        switch state.outcome {
        case .stored:
            if let saved = draft.acknowledged, saved.revision == state.durableRevision {
                endedText = saved.text
            } else if state.path == .store,
                let stored = try? await environment.notes.segment(SegmentID(state.captureID))
            {
                endedText = stored.text
            } else {
                // Only the field sends updates. An end can make its last refused save durable.
                endedText = state.durableRevision > (draft.acknowledged?.revision ?? 0) ? draft.submitted : nil
            }
        case .discardedEmpty:
            let emptyText =
                draft.acknowledged?.revision == state.durableRevision
                ? draft.acknowledged?.text : draft.submitted
            endedText = emptyText.flatMap { CaptureText.isEmpty($0) ? $0 : nil }
        default:
            endedText = nil
        }
        if let endedText, fieldText.hasPrefix(endedText) {
            fieldText = String(fieldText.dropFirst(endedText.count))
        }
        typedWatch?.cancel()
        typedWatch = nil
        typedCapture = nil
        self.draft = nil
        capturePath = state.path
        if fieldText.isEmpty { clearSaveProblem() }
        if let note = state.noteID, !recording.isRecording { await show(note) }
    }

    /// End follows an acknowledged write of exactly the field's current text.
    @discardableResult
    private func endTypedCapture() async -> Bool {
        guard await saveField() else { return false }
        guard let id = typedCapture else { return fieldText.isEmpty }
        do {
            let state = try await environment.engine.end(id)
            await acceptTypedEnd(state)
            await refresh()
            return fieldText.isEmpty
        } catch {
            problem = .couldNotSave(error.code)
            return false
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
        guard !pressInFlight else { return }
        pressInFlight = true
        let press = Press(kind, at: environment.clock.now())
        let before = recording
        if before.isRecording {
            if kind != .holdStart {
                frozenElapsed = recordingElapsed
                recording = .stopping
            }
        } else if kind != .holdRelease {
            recording = .starting
        }
        enqueue { model in await model.sendPress(press, before: before) }
    }

    private func sendPress(_ press: Press, before: RecordingPhase) async {
        defer { pressInFlight = false }
        if recording == .starting, !(await saveField()) {
            recording = before
            environment.cues.emit(.couldNotStart)
            announcer.announce(.recordingCouldNotStart)
            return
        }
        let request = CaptureRequest(kind: .voice, surface: surface, placement: placement, shownNote: record?.note.id)
        let states = environment.engine.states()
        do {
            switch try await environment.engine.press(press, recording: request) {
            case .ignored:
                recording = before
            case .started(let state):
                watchRecordingEnd(state.captureID, in: states)
                await adoptRecording(state, startedHere: press.kind)
            case .stopped(let state):
                await finishRecording(state)
            }
        } catch {
            recording = before
            if !before.isRecording, error.code != KnotError.captureBlockedByRecording.code,
                error.code != KnotError.segmentCaptureOpen.code
            {
                showRecordingOutcome(.couldNotStart)
                problem = .couldNotStartRecording(error.code)
                announcer.announce(.recordingCouldNotStart)
            } else if before.isRecording {
                announceFailedStop()
            }
        }
    }

    /// A surface learns about recordings started by another entry point at the next engine state.
    public func observeRecordings() async {
        for await state in environment.engine.states() where state.kind == .voice {
            if state.outcome == .open {
                guard recording == .idle, !pressInFlight else { continue }
                await adoptRecording(state, startedHere: nil)
            } else {
                acceptRecordingEnd(state)
            }
        }
    }

    private func adoptRecording(_ state: CaptureState, startedHere: PressKind?) async {
        guard state.outcome == .open else {
            await finishRecording(state)
            return
        }
        showRecordingOutcome(nil)
        activeRecording = state.captureID
        isHeldRecording = startedHere == .holdStart
        recording = .recording(state.captureID)
        recordingStartedAt = startedHere == nil ? nil : recordingClock.now()
        liveTranscript = LiveTranscript(final: "", volatile: "")
        liveLevels = []
        capturePath = state.path
        isNewNote = false
        if case .couldNotStartRecording = problem { problem = nil }
        followLiveRecording(state.captureID)
        announcer.announce(.recordingStarted)
        if mode == .capture, let id = state.noteID { await show(id) }
    }

    private func acceptRecordingEnd(_ state: CaptureState) {
        guard activeRecording == state.captureID else { return }
        enqueue { model in
            guard model.activeRecording == state.captureID else { return }
            await model.finishRecording(state)
        }
    }

    private func watchRecordingEnd(_ id: CaptureID, in states: AsyncStream<CaptureState>) {
        recordingWatch?.cancel()
        recordingWatch = Task { [weak self] in
            for await state in states where state.captureID == id && state.outcome != .open {
                self?.acceptRecordingEnd(state)
                return
            }
        }
    }

    private func followLiveRecording(_ id: CaptureID) {
        recordingLive?.cancel()
        let live = environment.engine.live(id)
        recordingLive = Task { [weak self] in
            for await event in live {
                guard let self, recording == .recording(id) else { return }
                switch event {
                case .level(let peak, _):
                    liveLevels.append(peak)
                    if liveLevels.count > 30 { liveLevels.removeFirst() }
                case .transcript(let transcript):
                    liveTranscript = transcript
                case .transcriptUnavailable:
                    break
                }
            }
        }
    }

    private func finishRecording(_ state: CaptureState) async {
        recordingWatch?.cancel()
        recordingWatch = nil
        recordingLive?.cancel()
        recordingLive = nil
        activeRecording = nil
        isHeldRecording = false
        recording = .idle
        capturePath = state.path
        switch state.outcome {
        case .stored:
            lastRecording = state.captureID
            showRecordingOutcome(.saved)
            announcer.announce(.recordingStopped)
            if mode == .capture, let note = state.noteID { await show(note) }
        case .discardedEmpty:
            showRecordingOutcome(.discarded)
            announcer.announce(.recordingDiscarded)
        case .failed:
            announceFailedStop()
        case .open:
            break
        }
        await refresh()
    }

    private func announceFailedStop() {
        showRecordingOutcome(.saveFailed)
        announcer.announce(.recordingSaveFailed)
    }

    private func showRecordingOutcome(_ outcome: RecordingOutcome?) {
        recordingOutcomeExpiry?.cancel()
        recordingOutcome = outcome
        guard outcome == .saved || outcome == .discarded else { return }
        let clock = recordingClock
        let deadline = clock.now() + (outcome == .saved ? .seconds(1) : .seconds(3))
        recordingOutcomeExpiry = Task { [weak self] in
            do {
                try await clock.sleepUntil(deadline)
                try Task.checkCancellation()
                self?.recordingOutcome = nil
            } catch {}
        }
    }

    // MARK: Segments and the note

    /// The person began editing a segment: the edit carries the revision they read now. Each
    /// focus begins a new edit, so it replaces any base an earlier focus left.
    public func beginEditing(_ segment: SegmentID) {
        editBases[segment] = record?.revision(of: segment)
    }

    /// The person left a segment's field without changing it: no edit is sent, and the base
    /// ends with it, so no later edit meets a conflict with text the person already saw.
    public func endEditing(_ segment: SegmentID) {
        editBases[segment] = nil
    }

    /// The person began editing the title: it carries the note's revision they read now.
    public func beginEditingTitle() {
        titleBase = record.map { ($0.note.id, $0.revision) }
    }

    /// The person left the title without changing it.
    public func endEditingTitle() {
        titleBase = nil
    }

    /// Replaces a segment's text with the person's edit. Edits beat cleaned and raw text. The edit
    /// carries the revision read when it began (`beginEditing`), so text that changed elsewhere
    /// meanwhile is never replaced unseen: the store refuses it, nothing is written, and
    /// `editConflicts` keeps the draft for the person to decide.
    public func editText(of segment: SegmentID, to text: String) {
        guard let base = editBases.removeValue(forKey: segment) ?? record?.revision(of: segment) else { return }
        enqueue { model in
            await model.replace(segment, with: text, ifRevision: base)
        }
    }

    /// Sets or clears the title on the note and revision the edit showed.
    public func setTitle(_ title: String?) {
        let base = titleBase ?? record.map { ($0.note.id, $0.revision) }
        titleBase = nil
        guard let base else { return }
        enqueue { model in
            await model.retitle(base.note, to: title, ifRevision: base.revision)
        }
    }

    public func canKeepEdit(_ target: EditConflict.Target) -> Bool { conflictBases[target] != nil }

    /// Commits the kept draft of `target` over what arrived.
    public func keepMyEdit(_ target: EditConflict.Target) {
        guard let conflict = editConflicts[target] else { return }
        enqueue { model in
            guard model.editConflicts[target] == conflict else { return }
            // The revision of what the conflict showed. If it is stale by now, nothing is written
            // and the conflict shows the newer arrival.
            guard let shown = model.conflictBases[target] else { return }
            model.editConflicts[target] = nil
            model.conflictBases[target] = nil
            switch conflict.target {
            case .segment(let segment):
                await model.replace(segment, with: conflict.draft ?? "", ifRevision: shown)
            case .title:
                if let id = model.conflictTitleNote {
                    await model.retitle(id, to: conflict.draft, ifRevision: shown)
                }
            }
        }
    }

    /// Drops the draft of `target`: the text that arrived stays.
    public func dropMyEdit(_ target: EditConflict.Target) {
        editConflicts[target] = nil
        conflictBases[target] = nil
    }

    private func replace(_ segment: SegmentID, with text: String, ifRevision: StampedRevision) async {
        let replacement = TextReplacement(
            segment: segment, text: text, origin: .edited, writer: .app, ifRevision: ifRevision)
        do {
            _ = try await environment.notes.replaceText(replacement)
            // A write that succeeds ends the segment's conflict: the person decided by writing.
            editConflicts[.segment(segment)] = nil
            conflictBases[.segment(segment)] = nil
        } catch  where error.code == KnotError.revisionStale.code {
            await refresh()
            let arrived = try? await environment.notes.segment(segment)
            conflictBases[.segment(segment)] = arrived?.revision
            editConflicts[.segment(segment)] = EditConflict(
                target: .segment(segment), draft: text, arrived: arrived?.text)
            return
        } catch {
            problem = .actionRefused(error.code)
        }
        await refresh()
    }

    private func retitle(_ id: NoteID, to title: String?, ifRevision: StampedRevision) async {
        let value = title.flatMap { CaptureText.isEmpty($0) ? nil : $0 }
        do {
            _ = try await environment.notes.setTitle(value, of: id, ifRevision: ifRevision)
            editConflicts[.title] = nil
            conflictBases[.title] = nil
        } catch  where error.code == KnotError.revisionStale.code {
            await refresh()
            let arrived = try? await environment.notes.note(id)
            conflictTitleNote = id
            conflictBases[.title] = arrived?.revision
            editConflicts[.title] = EditConflict(target: .title, draft: value, arrived: arrived?.note.title)
            return
        } catch {
            problem = .actionRefused(error.code)
        }
        await refresh()
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

    /// Reads the stored drawing through the asset and rendering ports.
    public func drawing(of item: SegmentItem, scale: Double) async throws(KnotError) -> RenderedDrawing? {
        guard item.kind == .ink, let file = await file(of: item) else { return nil }
        let bytes: Data
        do {
            bytes = try await Task.detached { try Data(contentsOf: file, options: .mappedIfSafe) }.value
        } catch {
            throw .drawingUnreadable
        }
        return try await environment.drawingImages.image(of: InkDrawingData(bytes: bytes), scale: scale)
    }

    public func dismissRecordingOutcome() { showRecordingOutcome(nil) }

    public func dismissProblem() {
        if recordingOutcome == .couldNotStart { showRecordingOutcome(nil) }
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
    ///
    /// Each queued action holds the view model until it has run. A surface that goes away right
    /// after `endCapture()`, as a panel does when it closes, still has its last keystrokes
    /// saved and its capture ended: a capture reaches disk before anything else happens to it.
    /// Once the queue has run, nothing holds the model any longer.
    private func enqueue(_ work: @escaping @MainActor @Sendable (NoteViewModel) async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await work(self)
        }
    }
}
