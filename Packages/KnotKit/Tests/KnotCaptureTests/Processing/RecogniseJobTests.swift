import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// Recognise jobs: a queue given a recogniser reads a stored drawing's handwriting into its text,
/// and a queue without one leaves the job as it is.
@Suite struct RecogniseJobTests {
    static let drawing = Data([7, 1, 7, 1])

    /// A stored drawing with its recognise job.
    static func storedDrawing(_ rig: Rig) async throws -> SegmentID {
        let id: CaptureID = rig.ids.make()
        let file = try await rig.assets.place(drawing, as: AssetID(id), kind: .ink)
        let asset = Asset(
            id: AssetID(id), segmentID: SegmentID(id), kind: .ink, byteCount: file.byteCount, sha256: file.sha256)
        _ = try await rig.notes.record(
            NewCapture(
                id: id, kind: .ink, origin: CaptureOrigin(source: .device(rig.deviceID), surface: .app),
                launchID: rig.launchID, placement: .newNote, startedAt: rig.clock.now(), endedAt: rig.clock.now(),
                body: .file(asset, duration: nil), revision: 1))
        let segment = SegmentID(id)
        try await rig.notes.saveJob(Job(id: .recognise(of: segment), segmentID: segment, kind: .recognise))
        return segment
    }

    static func queue(_ rig: Rig, _ recogniser: ScriptedInkRecogniser?) -> StandardProcessingQueue {
        StandardProcessingQueue(
            notes: rig.notes, assets: rig.assets, transcriber: rig.transcriber, cleaner: rig.cleaner,
            clock: rig.clock, ids: rig.ids, recogniser: recogniser, layer: rig.layer)
    }

    static func job(_ rig: Rig, _ segment: SegmentID) async throws -> Job {
        try #require(try await rig.notes.jobs(for: segment).first { $0.kind == .recognise })
    }

    @Test func aStoredDrawingIsRecognised() async throws {
        let rig = Rig()
        let segment = try await Self.storedDrawing(rig)
        let recogniser = ScriptedInkRecogniser()
        recogniser.script(InkDrawingData(bytes: Self.drawing), text: "buy milk")

        #expect(await LaunchQueueTests.drain(Self.queue(rig, nil)) == .idle)
        #expect(try await Self.job(rig, segment).state == .queued, "No recogniser: the job waits.")

        #expect(await LaunchQueueTests.drain(Self.queue(rig, recogniser)) == .idle)
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.text == "buy milk" && read.textOrigin == .recognised)
        #expect(read.state == .ink(.ready))
        #expect(try await Self.job(rig, segment).state == .done)
        #expect(recogniser.recognitionCount == 1)
    }

    /// A language the recogniser does not read is final: the job ends at once, and the drawing is
    /// kept with no text.
    @Test func anUnsupportedLanguageEndsTheJob() async throws {
        let rig = Rig()
        let segment = try await Self.storedDrawing(rig)
        let recogniser = ScriptedInkRecogniser()
        recogniser.setLanguages([])
        #expect(await LaunchQueueTests.drain(Self.queue(rig, recogniser)) == .idle)
        let job = try await Self.job(rig, segment)
        #expect(job.state == .done && job.lastErrorCode == KnotError.handwritingLanguageUnsupported.code)
        #expect(job.attempts == 0)
        let read = try #require(try await rig.notes.segment(segment))
        #expect(read.state == .ink(.ready) && read.text.isEmpty)
    }

    /// Recognition outside the foreground is a deferral: not counted, and the job runs later.
    @Test func recognitionOutsideTheForegroundIsDeferred() async throws {
        let rig = Rig()
        let segment = try await Self.storedDrawing(rig)
        let recogniser = ScriptedInkRecogniser()
        recogniser.script(InkDrawingData(bytes: Self.drawing), text: "later")
        recogniser.setInForeground(false)
        let queue = Self.queue(rig, recogniser)
        #expect(await LaunchQueueTests.drain(queue) == .idle)
        let waiting = try await Self.job(rig, segment)
        #expect(waiting.state == .queued && waiting.attempts == 0)
        #expect(try await rig.notes.segment(segment)?.state == .ink(.recognising))
        recogniser.setInForeground(true)
        #expect(await LaunchQueueTests.drain(queue) == .idle)
        #expect(try await rig.notes.segment(segment)?.text == "later")
    }
}
