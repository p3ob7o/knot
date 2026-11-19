import AVFAudio
import Foundation
import Synchronization

enum RecorderError: Error {
    /// The Simulator's microphone is the build Mac's, which no agent opens (AGENTS.md).
    case hardwareInputRefused
    case noInputDevice
}

struct RecordingSummary: Sendable {
    let frames: Int64
    let sampleRate: Double
    let bytes: Int64
}

/// The smallest recorder that answers SP-1: an engine tap written to a CAF file. Format choice,
/// syncing and recovery belong to WP-12. In the Simulator it refuses before touching the audio
/// session, so the spike never opens the build Mac's microphone.
@MainActor
final class Recorder {
    private var engine: AVAudioEngine?
    private var sink: FileSink?
    private var url: URL?

    /// Starts recording into `url`. `firstBuffer` is called once, from the tap's thread, when
    /// the first captured buffer arrives: the "live microphone" moment of product spec §14.
    func start(url: URL, firstBuffer: @escaping @Sendable (Date) -> Void) throws {
        guard !SP1Process.isSimulator else { throw RecorderError.hardwareInputRefused }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: [])
        try session.setActive(true)
        SP1Log.record("recorder.session-active", [:])

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sink = FileSink(file: file, sampleRate: format.sampleRate, firstBuffer: firstBuffer)
        // OS 27 deprecates `installTap(onBus:bufferSize:format:block:)` for this throwing form,
        // whose Sendable provider receives a Sendable read-only buffer.
        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.write(buffer)
        }
        engine.prepare()
        try engine.start()
        SP1Log.record("recorder.engine-started", ["sampleRate": String(Int(format.sampleRate))])
        self.engine = engine
        self.sink = sink
        self.url = url
    }

    func stop() -> RecordingSummary {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        let summary = sink?.close() ?? RecordingSummary(frames: 0, sampleRate: 0, bytes: 0)
        let bytes = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        engine = nil
        sink = nil
        url = nil
        return RecordingSummary(frames: summary.frames, sampleRate: summary.sampleRate, bytes: bytes ?? 0)
    }

    var isRunning: Bool { engine != nil }
}

/// Owns the file the tap writes. The tap runs on its own thread, so the file sits behind a lock.
/// `AVAudioFile` is Sendable from OS 26.
private final class FileSink: Sendable {
    private struct State {
        var file: AVAudioFile?
        var frames: Int64 = 0
        var sawFirst = false
    }

    private let state: Mutex<State>
    private let sampleRate: Double
    private let firstBuffer: @Sendable (Date) -> Void

    init(file: AVAudioFile, sampleRate: Double, firstBuffer: @escaping @Sendable (Date) -> Void) {
        self.state = Mutex(State(file: file))
        self.sampleRate = sampleRate
        self.firstBuffer = firstBuffer
    }

    func write(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let first = state.withLock { state -> Bool in
            guard let file = state.file else { return false }
            do {
                try file.write(from: buffer)
                state.frames += Int64(buffer.frameLength)
            } catch {
                SP1Log.record("recorder.write-failed", ["error": SP1Log.code(error)])
            }
            defer { state.sawFirst = true }
            return !state.sawFirst
        }
        if first { firstBuffer(Date()) }
    }

    func close() -> RecordingSummary {
        state.withLock { state in
            state.file = nil
            return RecordingSummary(frames: state.frames, sampleRate: sampleRate, bytes: 0)
        }
    }
}
