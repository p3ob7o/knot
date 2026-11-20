import Foundation
import KnotCore

/// One capture surface: what the person asked for, the note it shows, and its typed capture as
/// the person types (docs/product-spec.md §3, rules 4, 5 and 13, and §4.1).
///
/// The session tracker. It holds intent only: follow the window, "New note", or a note the
/// person has open. The append rule has one owner, the store's record-a-capture transaction,
/// and the session passes the engine only the placement asked for and the note it showed.
///
/// What the surface shows comes from the store's prediction, `NoteStore.predictPlacement`,
/// which calls the same rule as the store's decision. While the field is empty the display
/// follows the window: the surface asks `destination()` again as time passes. At the first
/// keystroke the destination is fixed: the capture begins then (rule 13), with the note shown
/// at that moment, asked again first when what the surface showed is more than
/// `freshFor` old.
///
/// Typing. `type(_:)` takes the whole text of the field at each keystroke and returns at once.
/// The session saves it through the engine, one call at a time: while a save is in flight the
/// keystrokes that follow are folded into the next save, so the text on the drive is never more
/// than one save behind the last keystroke (§4.1's 150 ms, with the engine's 100 ms deadline).
/// `flush()` returns once the latest text is durable, for the surface hiding, the app going to
/// the background and the app quitting; `end()` flushes and ends.
public actor CaptureSession {
    /// Where the next capture of the surface goes, as the surface shows it.
    public enum Destination: Hashable, Sendable {
        /// The next segment of this note.
        case note(NoteID)
        /// A new note.
        case newNote
        /// Typing does not start: a recording runs (rule 15).
        case refused(ErrorCode)
        /// The store did not answer in time; the store or ingest decides when the capture lands.
        case unknown
    }

    /// How long what the surface showed stands for the first keystroke without asking again.
    public static let freshFor: TimeInterval = 1

    public nonisolated let surface: CaptureSurface
    private let engine: any CaptureEngine
    private let notes: any NoteStore
    private let clock: any WallClock
    private let deviceID: DeviceID
    private let deadline: StoreDeadline

    /// What the person asked for.
    public private(set) var intent: CapturePlacement = .window
    /// What the surface showed last, and when.
    private var shown: (destination: Destination, at: Date)?
    /// The typed capture the session holds, once a call began it.
    private var capture: CaptureID?
    /// The destination fixed at the first keystroke.
    private var fixed: Destination?
    /// The newest text of the field, and the newest text the engine answered as durable.
    private var latest: String?
    private var saved: String?
    private var pump: Task<Void, Never>?
    private var lastError: KnotError?
    /// Why the capture ended under the session, said once by the next flush.
    private var endedUnder: KnotError?
    /// The capture's state as the engine last answered it.
    public private(set) var state: CaptureState?

    public init(
        surface: CaptureSurface, engine: any CaptureEngine, notes: any NoteStore, clock: any WallClock,
        deviceID: DeviceID, deadline: StoreDeadline = .standard
    ) {
        self.surface = surface
        self.engine = engine
        self.notes = notes
        self.clock = clock
        self.deviceID = deviceID
        self.deadline = deadline
    }

    // MARK: Intent

    /// "New note": the next capture starts a new note, inside the window too (rule 4). A typed
    /// capture in progress ends first, as it stands.
    @discardableResult
    public func newNote() async throws(KnotError) -> CaptureState? {
        let ended = try await end()
        intent = .newNote
        shown = nil
        return ended
    }

    /// Capturing from inside an open note always appends to it (rule 5).
    public func open(_ note: NoteID) {
        intent = .named(note)
        shown = nil
    }

    /// Back to the window, as the stream's capture surface follows it.
    public func followWindow() {
        intent = .window
        shown = nil
    }

    /// Where the next capture goes, as the surface shows it: fixed once the capture has begun,
    /// and otherwise asked of the store now.
    public func destination() async -> Destination {
        if let fixed { return fixed }
        let now = clock.now()
        let destination: Destination
        switch intent {
        case .newNote:
            destination = .newNote
        case .named(let note):
            destination = .note(note)
        case .window:
            let request = AppendRequest(startedAt: now, placement: .window, source: .device(deviceID))
            let answer = await deadline.race { [notes, surface] () async throws(KnotError) in
                try await notes.predictPlacement(request, kind: .typed, surface: surface)
            }
            switch answer {
            case .answered(.join(let note, _)): destination = .note(note)
            case .answered(.newNote): destination = .newNote
            case .answered(.refused(let error)): destination = .refused(error.code)
            case .refused, .timedOut: destination = .unknown
            }
        }
        shown = (destination, now)
        return destination
    }

    // MARK: Typing

    /// The field's whole text, at each keystroke. The first keystroke begins the capture, and
    /// each later one is saved, folded into the save in flight's successor.
    public func type(_ text: String) {
        latest = text
        startPump()
    }

    /// Returns once the latest text is durable, with the capture's state, or throws what kept it
    /// from the drive: the surface then keeps the text and says that it could not save (§4.4),
    /// and the next keystroke or flush tries again with the whole text.
    @discardableResult
    public func flush() async throws(KnotError) -> CaptureState? {
        startPump()
        while let running = pump { await running.value }
        if let endedUnder {
            self.endedUnder = nil
            throw endedUnder
        }
        if let latest, latest != saved, capture != nil || !latest.isEmpty {
            throw lastError ?? KnotError.writeFailed
        }
        return state
    }

    /// Ends the typed capture, with its latest text, and returns its final state, or `nil` when
    /// nothing was typed. A capture whose text never reached the drive throws, and the surface
    /// keeps its text (§4.4).
    @discardableResult
    public func end() async throws(KnotError) -> CaptureState? {
        do throws(KnotError) {
            try await flush()
        } catch {
            // A capture that began ends with the text the engine holds, which is the latest: the
            // engine saves it with the end. One that never began has nothing on the drive.
            if capture == nil { throw error }
        }
        guard let capture else {
            reset()
            return nil
        }
        let ended = try await engine.end(capture)
        reset()
        return ended
    }

    /// Ends the typed capture keeping nothing.
    @discardableResult
    public func discard() async throws(KnotError) -> CaptureState? {
        while let running = pump { await running.value }
        guard let capture else {
            reset()
            return nil
        }
        let discarded = try await engine.discard(capture)
        reset()
        return discarded
    }

    private func reset() {
        capture = nil
        fixed = nil
        latest = nil
        saved = nil
        lastError = nil
        shown = nil
        if case .newNote = intent { intent = .window }
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { await self.drain() }
    }

    /// Saves until the engine holds the latest text, one call at a time, and stops at the first
    /// save that does not reach the drive.
    private func drain() async {
        defer { pump = nil }
        while let text = latest, text != saved {
            if let capture {
                do throws(KnotError) {
                    state = try await engine.update(capture, with: .text(text))
                    saved = text
                    lastError = nil
                } catch {
                    lastError = error
                    if error.code == KnotError.illegalTransition.code {
                        // Another surface's start ended the capture (rule 15): what was saved
                        // stays, the next flush says so, and the next keystroke begins a
                        // capture of its own.
                        reset()
                        endedUnder = error
                    }
                    return
                }
            } else {
                guard !text.isEmpty else { return }
                do throws(KnotError) {
                    let begun = try await engine.begin(await firstKeystroke(text))
                    capture = begun.captureID
                    state = begun
                    saved = text
                    lastError = nil
                    fixed = begun.noteID.map(Destination.note) ?? fixedFromShown()
                    // "New note" is spent on the capture it started: the next one follows the
                    // window, and so joins that note while the window is open (rule 4).
                    if case .newNote = intent { intent = .window }
                } catch {
                    lastError = error
                    return
                }
            }
        }
    }

    /// The request of the first keystroke: the placement asked for and the note shown now,
    /// asked of the store again when what the surface showed is stale.
    private func firstKeystroke(_ text: String) async -> CaptureRequest {
        if intent == .window, shown == nil || clock.now().timeIntervalSince(shown?.at ?? .distantPast) > Self.freshFor {
            _ = await destination()
        }
        var shownNote: NoteID?
        if case .note(let note)? = shown?.destination { shownNote = note }
        if case .named(let note) = intent { shownNote = note }
        return CaptureRequest(kind: .typed, surface: surface, placement: intent, shownNote: shownNote, text: text)
    }

    private func fixedFromShown() -> Destination {
        switch intent {
        case .newNote: .newNote
        case .named(let note): .note(note)
        case .window: shown?.destination ?? .unknown
        }
    }
}
