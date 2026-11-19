import AVFAudio
import Foundation
import Observation
import WatchKit
import os

/// Receives the microphone's buffers on the audio thread, writes them, and counts what it
/// needs to answer "does recording continue with the wrist down": frames, frames while the
/// app was not active, and the largest gap in the sample clock.
final class RecordingSink: Sendable {
    private struct State {
        var file: AVAudioFile?
        var frames: Int64 = 0
        var framesWhileInactive: Int64 = 0
        var inactive = false
        var inactiveSince: Date?
        var inactiveSeconds: Double = 0
        var nextSampleTime: Int64?
        var largestGap: Double = 0
        var firstSampleAt: Date?
        var writeError: String?
    }

    struct Totals: Sendable {
        var frames: Int64
        var framesWhileInactive: Int64
        var inactiveSeconds: Double
        var largestGap: Double
        var firstSampleAt: Date?
        var writeError: String?
    }

    let sampleRate: Double
    private let state: OSAllocatedUnfairLock<State>
    private let onFirstSample: @Sendable (Date) -> Void

    init(file: AVAudioFile, sampleRate: Double, onFirstSample: @escaping @Sendable (Date) -> Void) {
        self.sampleRate = sampleRate
        self.onFirstSample = onFirstSample
        state = OSAllocatedUnfairLock(uncheckedState: State(file: file))
    }

    func write(_ buffer: AVReadOnlyAudioPCMBuffer, at time: AVAudioTime) {
        let first: Date? = state.withLockUnchecked { state in
            var first: Date?
            if state.firstSampleAt == nil {
                state.firstSampleAt = .now
                first = state.firstSampleAt
            }
            let length = Int64(buffer.frameLength)
            if time.isSampleTimeValid {
                if let expected = state.nextSampleTime {
                    state.largestGap = max(state.largestGap, Double(time.sampleTime - expected) / sampleRate)
                }
                state.nextSampleTime = time.sampleTime + length
            }
            state.frames += length
            if state.inactive { state.framesWhileInactive += length }
            do {
                try state.file?.write(from: buffer)
            } catch {
                state.writeError = describe(error)
            }
            return first
        }
        if let first { onFirstSample(first) }
    }

    func setInactive(_ inactive: Bool) {
        state.withLockUnchecked { state in
            guard state.inactive != inactive else { return }
            state.inactive = inactive
            if inactive {
                state.inactiveSince = .now
            } else if let since = state.inactiveSince {
                state.inactiveSeconds += Date().timeIntervalSince(since)
                state.inactiveSince = nil
            }
        }
    }

    /// Closes the file and returns the counts.
    func finish() -> Totals {
        state.withLockUnchecked { state in
            if let since = state.inactiveSince {
                state.inactiveSeconds += Date().timeIntervalSince(since)
                state.inactiveSince = nil
            }
            state.file?.close()
            state.file = nil
            return Totals(
                frames: state.frames, framesWhileInactive: state.framesWhileInactive,
                inactiveSeconds: state.inactiveSeconds, largestGap: state.largestGap,
                firstSampleAt: state.firstSampleAt, writeError: state.writeError)
        }
    }
}

/// The Watch's record control. Every way of starting a recording ends here: the button and
/// Double Tap, the complication's URL, the intents, the controls and the Smart Stack widget.
///
/// It never opens a microphone in the Simulator, whose microphone is the Mac's (AGENTS.md).
@MainActor @Observable
final class WatchRecorder {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case saved
        case refused(String)
        case failed(String)
    }

    static let shared = WatchRecorder()
    /// docs/product-spec.md §4.2: a recording stops after 30 minutes.
    static let limit: Duration = .seconds(30 * 60)

    private(set) var phase: Phase = .idle
    private(set) var source = ""
    private(set) var triggeredAt: Date?
    private(set) var firstSampleAt: Date?
    private(set) var last: RecordingInfo?

    var startLatency: Double? {
        guard let triggeredAt, let firstSampleAt else { return nil }
        return firstSampleAt.timeIntervalSince(triggeredAt)
    }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var sink: RecordingSink?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var uptimeAtTrigger: Double = 0
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var appActive = true
    private let log = EventLog.shared

    private init() {}

    var isRecording: Bool { phase == .starting || phase == .recording }

    func toggle(source: String) async {
        switch phase {
        case .starting, .stopping: log.append("record.press-ignored", ["source": source])
        case .recording: stop(reason: "pressed")
        default: await start(source: source)
        }
    }

    /// The complication opens `sp2://record?source=complication`.
    func handle(_ url: URL) async {
        let source =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "source" })?.value ?? "url"
        log.append("record.url", ["source": source, "uptime": String(format: "%.3f", ProcessClock.uptime)])
        if !isRecording { await start(source: source) }
    }

    /// Called from the scene's phase: active, or not (wrist down, screen off, another app).
    func setAppActive(_ active: Bool) {
        appActive = active
        sink?.setInactive(!active)
        if isRecording { log.append("record.app-active", ["active": "\(active)"]) }
    }

    func start(source: String) async {
        let triggered = Date()
        self.source = source
        triggeredAt = triggered
        firstSampleAt = nil
        uptimeAtTrigger = ProcessClock.uptime
        log.append("record.trigger", ["source": source, "uptime": String(format: "%.3f", uptimeAtTrigger)])

        if SP2.isSimulator {
            phase = .refused("Not in the Simulator: its microphone is the Mac's.")
            log.append("record.refused", ["reason": "simulator"])
            return
        }
        phase = .starting

        if AVAudioApplication.shared.recordPermission != .granted {
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { return fail("Microphone permission refused") }
        }

        let id = UUID().uuidString
        let url = Folders.folder("Outbox").appending(path: "\(id).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 64_000,
            ]
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
            let sink = RecordingSink(file: file, sampleRate: format.sampleRate) { first in
                Task { @MainActor in WatchRecorder.shared.firstSample(at: first) }
            }
            sink.setInactive(!appActive)
            try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                sink.write(buffer, at: time)
            }
            try engine.start()
            self.engine = engine
            self.sink = sink
            fileURL = url
            log.append(
                "record.engine-started",
                [
                    "id": id, "rate": "\(format.sampleRate)", "channels": "\(format.channelCount)",
                    "after": String(format: "%.3f", Date().timeIntervalSince(triggered)),
                ])
        } catch {
            return fail("Could not start: \(describe(error) ?? "unknown")")
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                WatchRecorder.shared.log.append("record.interrupted", [:])
                WatchRecorder.shared.stop(reason: "interrupted")
            }
        }
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.stop(reason: "limit")
        }
    }

    private func firstSample(at date: Date) {
        firstSampleAt = date
        if phase == .starting { phase = .recording }
        WKInterfaceDevice.current().play(.start)
        log.append(
            "record.first-sample",
            [
                "source": source,
                "trigger-to-sample": String(format: "%.3f", date.timeIntervalSince(triggeredAt ?? date)),
                "process-to-sample": String(format: "%.3f", uptimeAtTrigger + date.timeIntervalSince(triggeredAt ?? date)),
            ])
    }

    func stop(reason: String) {
        guard isRecording, let engine, let sink, let fileURL, let triggeredAt else { return }
        phase = .stopping
        limitTask?.cancel()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let totals = sink.finish()
        try? AVAudioSession.sharedInstance().setActive(false)
        self.engine = nil
        self.sink = nil
        self.fileURL = nil

        let stopped = Date()
        let info = RecordingInfo(
            source: source, triggeredAt: triggeredAt, processUptimeAtTrigger: uptimeAtTrigger,
            firstSampleAt: totals.firstSampleAt, stoppedAt: stopped, endReason: reason,
            duration: stopped.timeIntervalSince(totals.firstSampleAt ?? triggeredAt),
            sampleRate: sink.sampleRate, frames: totals.frames, framesWhileInactive: totals.framesWhileInactive,
            inactiveSeconds: totals.inactiveSeconds, largestGap: totals.largestGap)
        last = info
        log.append(
            "record.stopped",
            [
                "id": fileURL.deletingPathExtension().lastPathComponent, "reason": reason,
                "duration": String(format: "%.1f", info.duration),
                "audio-seconds": String(format: "%.1f", Double(totals.frames) / sink.sampleRate),
                "inactive-seconds": String(format: "%.1f", totals.inactiveSeconds),
                "audio-seconds-while-inactive": String(format: "%.1f", Double(totals.framesWhileInactive) / sink.sampleRate),
                "largest-gap": String(format: "%.3f", totals.largestGap), "write-error": totals.writeError ?? "",
            ])
        WKInterfaceDevice.current().play(.stop)
        phase = .saved
        WatchLink.shared.sendRecording(fileURL, info: info)
    }

    private func fail(_ reason: String) {
        phase = .failed(reason)
        log.append("record.failed", ["reason": reason])
        WKInterfaceDevice.current().play(.failure)
    }
}
