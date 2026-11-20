import Foundation
import KnotCore
import KnotLink

// KnotLinkCrashHost: a process that KnotLink's kill tests start and kill
// (docs/architecture.md §17).
//
//   KnotLinkCrashHost
//       Reports that it is ready and exits.
//   KnotLinkCrashHost record --root <folder> --capture <uuid> --launch <uuid> [--kill-at <point>]
//       Runs the watch coordinator over a store in <folder>: launch, one recording of
//       synthetic audio, its stop, conversion and send. At <point>, one of the coordinator's
//       kill points or `converting`, halfway through writing the converted file, it kills
//       itself with SIGKILL.
//   KnotLinkCrashHost relaunch --root <folder> --launch <uuid> [--kill-at <point>]
//       A later launch: the coordinator finishes what the killed one left, and the host
//       prints one line per outbox entry and per file left in Recording/, then exits. With
//       --kill-at it is killed at that point of its own recovery instead.
//
// Each conversion prints "converting <capture>" as it starts, so a test counts them.
//
// The recorder here takes injected audio and has no microphone. The transport activates at
// once and delivers nothing, so the outbox keeps every capture.

let arguments = Array(CommandLine.arguments.dropFirst())

func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func say(_ line: String) {
    // Unbuffered, so that a line written just before a kill is not lost.
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func die() -> Never {
    kill(getpid(), SIGKILL)
    // The signal can land a moment after the call returns: wait for it, doing nothing more.
    while true { pause() }
}

guard let mode = arguments.first else {
    say("KnotLinkCrashHost: ready")
    exit(0)
}

guard let rootText = value("--root"), let launchText = value("--launch"), let launchID = LaunchID(launchText) else {
    say("KnotLinkCrashHost: --root and --launch are required")
    exit(2)
}
let killAt = value("--kill-at")
let locations = StoreLocations.testing(root: URL(fileURLWithPath: rootText, isDirectory: true))
let device: DeviceID = Identifier(uuid: UUID(uuidString: "00000000-0000-4000-8000-00000000d0e1")!)
let recorder = HostRecorder(locations: locations, killAt: killAt)
let link = OutboxLink(outbox: WatchOutbox(locations: locations), transport: HostTransport(), clock: SystemWallClock())

switch mode {
case "record":
    guard let captureText = value("--capture"), let capture = CaptureID(captureText) else {
        say("KnotLinkCrashHost: --capture is required")
        exit(2)
    }
    let coordinator = WatchCoordinator(
        recorder: recorder, link: link, ids: FixedIDs(capture: capture), clock: SystemWallClock(),
        launchID: launchID, device: device,
        killPoint: { point in if point.rawValue == killAt { die() } })
    await coordinator.launch()
    do {
        _ = try await coordinator.start()
    } catch {
        say("start failed \(error.code)")
        exit(1)
    }
    let outcome = await coordinator.stop()
    say("stopped \(String(describing: outcome))")
    exit(0)
case "relaunch":
    let coordinator = WatchCoordinator(
        recorder: recorder, link: link, ids: SystemIDGenerator(), clock: SystemWallClock(), launchID: launchID,
        device: device, killPoint: { point in if point.rawValue == killAt { die() } })
    await coordinator.launch()
    await link.resume()
    let outbox = WatchOutbox(locations: locations)
    for entry in (try? outbox.entries()) ?? [] {
        say("outbox \(entry.captureID) recording=\(entry.hasRecording) manifest=\(entry.manifest != nil)")
    }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: locations.recording.path)) ?? []
    for name in left.sorted() { say("recording-folder \(name)") }
    exit(0)
default:
    say("KnotLinkCrashHost: unknown mode")
    exit(2)
}

/// Every ID it makes is the one capture's.
struct FixedIDs: IDGenerator {
    let capture: CaptureID

    func make<Tag: IdentifierTag>(_ kind: Tag.Type) -> Identifier<Tag> { Identifier(capture) }
}

/// A session that activates at once and never delivers.
final class HostTransport: LinkTransport {
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    func activate() async -> LinkSessionState { .ready }
    var state: LinkSessionState { .ready }
    var receivedContext: LinkContext? { nil }
    func queueFile(_ url: URL, manifest: CaptureManifest, attempt: Int) {}
    func outstandingFiles() -> [OutstandingFile] { [] }
    func cancelFile(captureID: CaptureID, attempt: Int) {}
    func setFileReceiver(_ receive: @escaping @Sendable (ReceivedFile) -> LinkMessage?) {}
    func send(_ message: LinkMessage) {}
    func updateContext(_ context: LinkContext) throws(KnotError) {}
}

/// A recorder on injected audio: 16-bit synthetic samples, written whole when the recording
/// starts, as if it had already run. Its conversion prefixes the bytes with a marker, so a
/// test can tell a converted file from a working one, and writes the result in two halves at
/// `--kill-at converting`, dying between them as a converter killed mid-file would.
final class HostRecorder: Recorder {
    static let frames: Int64 = 8_000
    static let sampleRate: Double = 16_000
    static let marker = Data("CONVERTED".utf8)

    let locations: StoreLocations
    let killAt: String?
    private let files: StoreFiles
    private let layer = PosixFileLayer()

    init(locations: StoreLocations, killAt: String?) {
        self.locations = locations
        self.killAt = killAt
        self.files = locations.durableFiles(layer: PosixFileLayer())
    }

    static func samples() -> Data {
        Data((0..<Int(frames * 2)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    static func converted(_ working: Data) -> Data { marker + working }

    func prepare() async {}

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        try files.place(
            try request.manifest(startedAt: Date()).encoded(), at: locations.recordingManifest(request.captureID))
        let working = locations.recordingAudio(request.captureID, format: .caf)
        try files.place(Self.samples(), at: working)
        return HostSession(captureID: request.captureID, workingFile: working)
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        guard layer.entryKind(locations.recording) == .folder else { return [] }
        var recovered: [RecordedAudio] = []
        for name in try layer.contents(of: locations.recording) where name.hasSuffix(".json") {
            guard let data = try? layer.read(locations.recording.appending(path: name)),
                let manifest = try? CaptureManifest.decode(data), manifest.launchID != currentLaunch
            else { continue }
            let working = locations.recordingAudio(manifest.captureID, format: .caf)
            guard let audio = try? layer.read(working) else { continue }
            recovered.append(
                RecordedAudio(
                    captureID: manifest.captureID, frames: Int64(audio.count / 2), sampleRate: Self.sampleRate,
                    ending: .recovered, workingFile: working))
        }
        return recovered
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        guard let working = recording.workingFile, let data = try? layer.read(working) else {
            throw KnotError.audioUnreadable.about(capture: recording.captureID)
        }
        say("converting \(recording.captureID)")
        let output = Self.converted(data)
        let destination = locations.convertedRecording(recording.captureID)
        if killAt == "converting" {
            try? output.prefix(output.count / 2).write(to: destination)
            die()
        }
        try files.place(output, at: destination)
        return ConvertedRecording(captureID: recording.captureID, file: destination, duration: recording.duration)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        for url in [locations.recordingAudio(capture, format: .caf), locations.recordingManifest(capture)]
        where layer.entryKind(url) != nil {
            try files.remove(url)
        }
    }
}

/// A recording that already holds its audio.
final class HostSession: RecordingSession {
    let captureID: CaptureID
    let events: AsyncStream<RecordingEvent>
    let liveAudio: AsyncStream<AudioChunk>
    private let workingFile: URL

    init(captureID: CaptureID, workingFile: URL) {
        self.captureID = captureID
        self.workingFile = workingFile
        events = AsyncStream { $0.finish() }
        liveAudio = AsyncStream { $0.finish() }
    }

    func stop() async -> RecordedAudio {
        RecordedAudio(
            captureID: captureID, frames: HostRecorder.frames, sampleRate: HostRecorder.sampleRate, ending: .stopped,
            workingFile: workingFile)
    }

    func discard() async {}
}
