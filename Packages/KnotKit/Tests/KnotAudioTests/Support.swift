import AVFAudio
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

/// Temporary folders for a test's stores, each removed when the test is done with them.
final class TemporaryFolders: Sendable {
    private let made = Mutex<[URL]>([])

    /// A new, empty folder under the system's temporary folder.
    func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KnotAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        made.withLock { $0.append(url) }
        return url
    }

    func removeAll() {
        for url in made.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
}

/// A count that one task sets and another reads.
final class Tally: Sendable {
    private let state = Mutex<Int64>(0)
    var value: Int64 { state.withLock { $0 } }
    func set(_ value: Int64) { state.withLock { $0 = value } }
}

/// One test's folder, removed when the test ends.
struct ScratchFolder: ~Copyable {
    let url: URL

    /// With `privateForm`, the folder is written with `/private` in front, as the system hands
    /// some containers over: the same folder, written another way.
    init(privateForm: Bool = false) throws {
        let temporary = FileManager.default.temporaryDirectory
        let base = privateForm ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true) : temporary
        url = base.appendingPathComponent("KnotAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    var locations: StoreLocations { StoreLocations.testing(root: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Injected audio for the recorder's tests: the synthetic signal at 16 kHz in 100 ms buffers,
/// faster than real time.
func injected(
    frames: Int64? = nil, rate: Double = 16_000, framesPerBuffer: Int = 1_600, every: Duration = .milliseconds(2),
    ending: InjectedAudio.Ending = .runsDry, openFailure: KnotError? = nil, startFailure: KnotError? = nil
) -> InjectedAudio {
    InjectedAudio(
        sampleRate: rate, framesPerBuffer: framesPerBuffer, pace: .every(every), frames: frames, ending: ending,
        openFailure: openFailure, startFailure: startFailure)
}

/// A live recorder over `locations` that syncs often, so that a test sees durable counts soon.
func recorder(_ locations: StoreLocations, input: any AudioInput) -> LiveRecorder {
    LiveRecorder(locations: locations, input: input, settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)))
}

/// A request for a new capture of `launch`, from a control, following the window.
func request(_ launch: LaunchID = LaunchID(uuid: UUID()), limit: Duration = .seconds(1800)) -> RecordingRequest {
    RecordingRequest(
        captureID: CaptureID(uuid: UUID()), launchID: launch,
        origin: CaptureOrigin(source: .device(DeviceID(uuid: UUID())), surface: .control), placement: .window,
        shownNote: NoteID(uuid: UUID()), limit: limit)
}

/// The cues that `cues` was handed, once the recorder has handed over every cue it gave before
/// this call. A start of `request`, a capture that is recording or whose files are there, is
/// refused, and the recorder hands its could-not-start cue over on its one cue queue after every
/// earlier cue: the wait for that cue rests on the queue's order, not on a time, and a recorder
/// that never gave an earlier cue is told at once. The refused start's own cue is left out.
func cuesHandedOver(
    by recorder: any Recorder, to cues: RecordingCueEmitter, refusing request: RecordingRequest,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> [Cue] {
    let refusals = cues.cues.filter { $0 == .couldNotStart }.count
    await #expect(
        throws: KnotError.self, "A start of a capture that is there is refused.", sourceLocation: sourceLocation
    ) {
        _ = try await recorder.start(request)
    }
    await SuiteWait.until("the refused start's cue", sourceLocation: sourceLocation) {
        cues.cues.filter { $0 == .couldNotStart }.count > refusals
    }
    var handed = cues.cues
    if let last = handed.lastIndex(of: .couldNotStart) { handed.remove(at: last) }
    return handed
}

/// Every event of a session until its end, bounded by `SuiteWait`.
func allEvents(of session: any RecordingSession) async -> [RecordingEvent] {
    await SuiteWait.value("the events to end") {
        var events: [RecordingEvent] = []
        for await event in session.events { events.append(event) }
        return events
    } ?? []
}

/// Waits for a durable count of at least `frames`, and returns the counts seen on the way.
@discardableResult
func durable(atLeast frames: Int64, of session: any RecordingSession) async -> [Int64] {
    await SuiteWait.value("\(frames) durable frames") {
        var seen: [Int64] = []
        for await event in session.events {
            if case .durable(let count) = event {
                seen.append(count)
                if count >= frames { break }
            }
        }
        return seen
    } ?? []
}

/// The samples the synthetic signal gives from frame 0.
func synthetic(_ count: Int) -> [Int16] {
    (0..<count).map { SyntheticAudio.sample(at: Int64($0)) }
}

/// The manifest the recorder wrote for `capture`.
func manifest(_ locations: StoreLocations, _ capture: CaptureID) throws -> CaptureManifest {
    try CaptureManifest.decode(try Data(contentsOf: locations.recordingManifest(capture)))
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// The names in `Recording/`, the hidden ones included.
func recordingFolder(_ locations: StoreLocations) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: locations.recording.path)) ?? []).sorted()
}

/// Writes a working file holding `frames` of the synthetic signal, closed, as a stop leaves it.
func writeWorkingFile(at url: URL, frames: Int, rate: Double = 16_000, close: Bool = true) throws -> AVAudioFile {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let file = try AVAudioFile(
        forWriting: url, settings: WorkingFile.settings(sampleRate: rate), commonFormat: .pcmFormatInt16,
        interleaved: false)
    if frames > 0,
        let buffer = SyntheticAudio.buffer(
            format: file.processingFormat, from: 0, count: frames, SyntheticAudio.sample(at:))
    {
        try file.write(from: buffer)
    }
    if close { file.close() }
    return file
}

/// Writes a recorder's manifest for a capture of `launch`, as a start does.
func writeManifest(_ locations: StoreLocations, _ request: RecordingRequest, endedAt: Date? = nil) throws {
    var manifest = request.manifest(startedAt: Date())
    manifest.endedAt = endedAt
    try FileManager.default.createDirectory(at: locations.recording, withIntermediateDirectories: true)
    try manifest.encoded().write(to: locations.recordingManifest(request.captureID))
}

/// Cuts the closed working file at `url` inside frame `frame`, counted from 1, as a power cut
/// between its close and its final sync can leave it: its header still gives every frame it was
/// closed with, and the drive holds `frame` - 1 of them and half of the next.
func cut(_ url: URL, insideFrame frame: Int64) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
    let reading = CAFHeader.read(descriptor)
    close(descriptor)
    guard case .whole(let dataStart, let dataBytes, _) = reading, dataBytes != nil else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(dataStart + (frame - 1) * 2 + 1))
    try handle.close()
}
