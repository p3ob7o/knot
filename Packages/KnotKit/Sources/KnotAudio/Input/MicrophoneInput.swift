import AVFAudio
import Foundation
import KnotCore
import Synchronization

/// The device's microphone, through `AVAudioEngine` and a tap on its input node
/// (docs/architecture.md §8).
///
/// Before it touches the hardware it asks `HardwareInputPolicy`, and in a test, an agent's
/// thread or a simulator it refuses with `no_input_device`: no automated test and no agent
/// opens a microphone on the build Mac. Nothing here runs on this Mac's hardware, so what it
/// does on a device is checked at the owner's sittings.
///
/// Interruptions and route changes are WP-12's second pull request. Here, an engine that
/// changes its configuration ends the recording as `input_lost`, with everything written kept.
public struct MicrophoneInput: AudioInput {
    let hardware: any HardwareAudio
    let policy: @Sendable () -> HardwareInputPolicy.Refusal?

    public init() {
        self.init(hardware: SystemHardwareAudio(), policy: HardwareInputPolicy.refusalForThisProcess)
    }

    init(hardware: any HardwareAudio, policy: @escaping @Sendable () -> HardwareInputPolicy.Refusal?) {
        self.hardware = hardware
        self.policy = policy
    }

    public func prepare() async {}

    public func open() async throws(KnotError) -> any OpenAudioInput {
        // First, before anything reaches the hardware or asks for a permission.
        if policy() != nil { throw KnotError.noInputDevice }
        guard await hardware.recordPermission() else { throw KnotError.microphonePermissionRefused }
        try hardware.activateSession()
        let engine: any InputEngine
        do {
            engine = try hardware.makeEngine()
        } catch {
            hardware.deactivateSession()
            throw error
        }
        // The input node's input format is the hardware's: a rate or a channel count of zero
        // means no input is available, and the engine would throw, or raise an exception, at the
        // start (AVAudioEngine.h, inputNode). The working file takes the rate of what the tap
        // delivers, the node's output format.
        let hardwareShape = engine.hardware
        let tap = engine.tap
        guard hardwareShape.sampleRate > 0, hardwareShape.channels > 0, tap.sampleRate > 0, tap.channels > 0 else {
            hardware.deactivateSession()
            throw KnotError.noInputDevice
        }
        return OpenMicrophone(engine: engine, sampleRate: tap.sampleRate, hardware: hardware)
    }
}

/// The system's audio hardware, as the microphone input uses it. A test passes one that records
/// every use, to show that a refused input touches none of it.
protocol HardwareAudio: Sendable {
    /// Whether the app may record, asking the person the first time.
    func recordPermission() async -> Bool
    /// Makes the audio session ready to record, on iOS and watchOS.
    func activateSession() throws(KnotError)
    /// Gives the audio session back, on iOS and watchOS.
    func deactivateSession()
    func makeEngine() throws(KnotError) -> any InputEngine
}

/// A rate and a channel count, read from a format.
struct InputShape: Hashable, Sendable {
    var sampleRate: Double
    var channels: Int

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    init(_ format: AVAudioFormat) {
        self.init(sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }
}

/// The engine's input node, as the microphone uses it. A test passes one that opens nothing,
/// records each call, and lets the test deliver an ending at a point of its choosing.
protocol InputEngine: Sendable {
    /// What the tap delivers: the input node's output format.
    var tap: InputShape { get }
    /// What the hardware gives: the input node's input format.
    var hardware: InputShape { get }
    /// Installs the tap, which hands over each buffer the input delivers.
    func installTap(bufferSize: AVAudioFrameCount, _ tap: @escaping @Sendable (AVReadOnlyAudioPCMBuffer) -> Void)
        throws(KnotError)
    func removeTap()
    func start() throws(KnotError)
    func stop()
    /// One element each time the engine changes its configuration and stops itself, as when the
    /// hardware changes.
    func configurationChanges() -> AsyncStream<Void>
}

/// The real hardware.
struct SystemHardwareAudio: HardwareAudio {
    func recordPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    func activateSession() throws(KnotError) {
        #if os(iOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .default, options: [])
                try session.setActive(true)
            } catch {
                throw SessionError.knotError(code: (error as NSError).code)
            }
            // The session answers whether input hardware is there (AVAudioSession.h, inputAvailable).
            guard session.isInputAvailable else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                throw KnotError.noInputDevice
            }
        #endif
    }

    func deactivateSession() {
        #if os(iOS) || os(watchOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func makeEngine() throws(KnotError) -> any InputEngine {
        SystemInputEngine(engine: AVAudioEngine())
    }
}

/// The taxonomy's case for an error of the audio session, by what its code says
/// (CoreAudioTypes, AudioSessionTypes.h, `AVAudioSessionErrorCode`).
enum SessionError {
    /// `AVAudioSessionErrorCodeResourceNotAvailable`, '!res': "the device has no audio input
    /// available".
    static let resourceNotAvailable = 0x2172_6573

    /// `no_input_device` when the session says there is no input hardware; `audio_session_busy`
    /// for the rest, such as `AVAudioSessionErrorCodeInsufficientPriority` when a call holds the
    /// audio. The session's code is kept, never its text.
    static func knotError(code: Int) -> KnotError {
        let base = code == resourceNotAvailable ? KnotError.noInputDevice : KnotError.audioSessionBusy
        return base.with(ErrorContext(engineCode: code))
    }
}

/// `AVAudioEngine`'s input node.
struct SystemInputEngine: InputEngine {
    let engine: AVAudioEngine

    var tap: InputShape { InputShape(engine.inputNode.outputFormat(forBus: 0)) }
    var hardware: InputShape { InputShape(engine.inputNode.inputFormat(forBus: 0)) }

    func installTap(bufferSize: AVAudioFrameCount, _ tap: @escaping @Sendable (AVReadOnlyAudioPCMBuffer) -> Void)
        throws(KnotError)
    {
        do {
            try engine.inputNode.installAudioTap(onBus: 0, bufferSize: bufferSize, format: nil) { buffer, _ in
                tap(buffer)
            }
        } catch {
            throw KnotError.noInputDevice.with(ErrorContext(engineCode: (error as NSError).code))
        }
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }

    func start() throws(KnotError) {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw KnotError.audioSessionBusy.with(ErrorContext(engineCode: (error as NSError).code))
        }
    }

    func stop() {
        engine.stop()
    }

    func configurationChanges() -> AsyncStream<Void> {
        let engine = self.engine
        return AsyncStream { continuation in
            let watching = Task {
                for await _ in NotificationCenter.default.notifications(
                    named: .AVAudioEngineConfigurationChange, object: engine)
                {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in watching.cancel() }
        }
    }
}

/// The microphone opened for one recording.
///
/// The engine is touched in two places only, never at once: inside the start, and inside the one
/// stop that finishes the input, which no start runs beside. A stop asked for while the start
/// runs, its own undoing included, waits for it, and the start then takes away what it put
/// there. One stop finishes the input and every other waits until it has. Every delivery, of the
/// tap or of the configuration change, is counted while it runs, and none begins once the input
/// is finishing. So every stop, during the start, after it or at once with another, returns only
/// once the tap is gone, the engine stopped, every delivery under way ended and the session given
/// back: no delivery follows it.
final class OpenMicrophone: OpenAudioInput {
    let sampleRate: Double
    let commonFormat = AVAudioCommonFormat.pcmFormatFloat32
    private let engine: any InputEngine
    private let hardware: any HardwareAudio
    private let state = Mutex(State())
    /// Where a configuration change is delivered: a queue of the input's own, never a thread of
    /// the cooperative pool, so that a handler that holds its delivery holds no thread a task
    /// needs.
    private let changeQueue = DispatchQueue(label: "knot.microphone.configuration-change")

    private struct State {
        /// True while the start runs.
        var starting = false
        /// True once a stop has been asked for.
        var stopped = false
        var tapInstalled = false
        var engineStarted = false
        var sessionReleased = false
        /// Watches for the engine's configuration change.
        var watcher: Task<Void, Never>?
        /// Stops asked for while the start runs, waiting for it.
        var waiting: [CheckedContinuation<Void, Never>] = []
        /// True once a stop has begun to finish the input, and once it has finished it.
        var finishing = false
        var finished = false
        /// Stops waiting for the one that finishes the input.
        var finishWaiters: [CheckedContinuation<Void, Never>] = []
        /// How many stops are waiting, for the start, for the one that finishes the input, or for
        /// the deliveries under way.
        var suspended = 0
        /// True once the input is finishing: no delivery begins after.
        var closed = false
        /// Deliveries under way, and the stop waiting for them to end.
        var delivering = 0
        var deliveryWaiters: [CheckedContinuation<Void, Never>] = []
    }

    init(engine: any InputEngine, sampleRate: Double, hardware: any HardwareAudio) {
        self.engine = engine
        self.sampleRate = sampleRate
        self.hardware = hardware
    }

    /// True once a stop has been asked for, which a test reads to order a stop inside a start.
    var stopRequested: Bool { state.withLock { $0.stopped } }

    /// How many stops are waiting, which a test reads to see that a stop waits.
    var suspendedStops: Int { state.withLock { $0.suspended } }

    func start(format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void) throws(KnotError) {
        // A stop that came first leaves nothing to start.
        let proceed = state.withLock { state in
            guard !state.stopped, !state.starting, !state.tapInstalled else { return false }
            state.starting = true
            return true
        }
        guard proceed else { return }
        let deliver = counted(deliver)
        var failure: KnotError?
        do throws(KnotError) {
            // The tap delivers the hardware's format, every 100 ms or more; each buffer is mixed
            // down to one channel in the working file's format before it is written.
            try engine.installTap(bufferSize: AVAudioFrameCount(sampleRate / 10)) { buffer in
                // An empty buffer holds nothing to write and says nothing about the input.
                guard buffer.frameLength > 0 else { return }
                guard let mono = Downmix.mono(buffer, into: format) else {
                    // Another rate or a sample format the file cannot take: the input changed.
                    deliver(.ended(.lost))
                    return
                }
                deliver(.audio(mono))
            }
            state.withLock { $0.tapInstalled = true }
            let changes = engine.configurationChanges()
            let changeQueue = self.changeQueue
            let watcher = Task {
                // The engine stopped itself because the hardware changed. WP-12's second pull
                // request restarts it into the file's rate; until then the recording ends, kept.
                for await _ in changes {
                    changeQueue.async { deliver(.ended(.lost)) }
                    return
                }
            }
            state.withLock { $0.watcher = watcher }
            // A stop asked for meanwhile: the engine is not started, and the microphone never opens.
            if !state.withLock({ $0.stopped }) {
                try engine.start()
                state.withLock { $0.engineStarted = true }
            }
        } catch {
            failure = error
        }
        // A stop asked for while it ran, or a failure, takes away what it put there. The start is
        // over only then: a stop asked for meanwhile waits for that too, and the stops that
        // waited for it go on.
        if state.withLock({ $0.stopped }) || failure != nil { tearDown() }
        let waiting = state.withLock { state in
            state.starting = false
            state.suspended -= state.waiting.count
            defer { state.waiting = [] }
            return state.waiting
        }
        for stop in waiting { stop.resume() }
        if let failure { throw failure }
    }

    func stop() async {
        let starting = state.withLock { state in
            state.stopped = true
            return state.starting
        }
        if starting {
            await wait { state, stop in
                guard state.starting else { return false }
                state.waiting.append(stop)
                return true
            }
        }
        // One stop finishes the input; every other waits until it has.
        let finishes = state.withLock { state in
            defer { state.finishing = true }
            return !state.finishing
        }
        guard finishes else {
            await wait { state, stop in
                guard !state.finished else { return false }
                state.finishWaiters.append(stop)
                return true
            }
            return
        }
        tearDown()
        // A delivery under way, of the tap or of the configuration change, ends before this stop
        // returns; none begins after the teardown.
        await wait { state, stop in
            guard state.delivering > 0 else { return false }
            state.deliveryWaiters.append(stop)
            return true
        }
        let release = state.withLock { state in
            defer { state.sessionReleased = true }
            return !state.sessionReleased
        }
        if release { hardware.deactivateSession() }
        let waiters = state.withLock { state in
            state.finished = true
            state.suspended -= state.finishWaiters.count
            defer { state.finishWaiters = [] }
            return state.finishWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends this stop when `waits`, under the lock, puts it on a list and says so, until it
    /// is resumed from there; goes on at once when `waits` says there is nothing to wait for.
    private func wait(_ waits: (inout State, CheckedContinuation<Void, Never>) -> Bool) async {
        await withCheckedContinuation { (stop: CheckedContinuation<Void, Never>) in
            let waiting = state.withLock { state in
                let waiting = waits(&state, stop)
                if waiting { state.suspended += 1 }
                return waiting
            }
            if !waiting { stop.resume() }
        }
    }

    /// `deliver`, counted while it runs, and dropped once the input is finishing.
    private func counted(_ deliver: @escaping @Sendable (AudioDelivery) -> Void) -> @Sendable (AudioDelivery) -> Void {
        { [self] delivery in
            let begins = state.withLock { state in
                guard !state.closed else { return false }
                state.delivering += 1
                return true
            }
            guard begins else { return }
            deliver(delivery)
            let waiters = state.withLock { state in
                state.delivering -= 1
                guard state.delivering == 0 else { return [CheckedContinuation<Void, Never>]() }
                state.suspended -= state.deliveryWaiters.count
                defer { state.deliveryWaiters = [] }
                return state.deliveryWaiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Stops the engine and takes the tap away, if they are there, once. No delivery begins after.
    private func tearDown() {
        let (engineStarted, tapInstalled, watcher) = state.withLock { state in
            state.closed = true
            defer {
                state.engineStarted = false
                state.tapInstalled = false
                state.watcher = nil
            }
            return (state.engineStarted, state.tapInstalled, state.watcher)
        }
        watcher?.cancel()
        if engineStarted { engine.stop() }
        if tapInstalled { engine.removeTap() }
    }
}

/// Mixes a tap's buffer down to one channel.
enum Downmix {
    /// `buffer` as one channel in `format`, or `nil` when its rate differs from the format's,
    /// its samples are neither 32-bit floats nor 16-bit integers, or its buffers do not hold
    /// its channels and frames.
    static func mono(_ buffer: AVReadOnlyAudioPCMBuffer, into format: AVAudioFormat) -> AVReadOnlyAudioPCMBuffer? {
        let frames = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let commonFormat = buffer.format.commonFormat
        guard buffer.format.sampleRate == format.sampleRate, channels > 0, frames > 0,
            let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let destination = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        let mixed = buffer.withUnsafeAudioBufferList { list in
            mix(list, frames: frames, channels: channels, commonFormat: commonFormat, into: destination)
        }
        return mixed ? AVReadOnlyAudioPCMBuffer(copying: mono) : nil
    }

    /// Writes the mean of the `channels` channels that `list` holds, `frames` each, into
    /// `destination`, from -1 to 1. False when the list does not hold them, or its samples are
    /// neither 32-bit floats nor 16-bit integers, and then nothing is read.
    ///
    /// Where each channel's samples are is read from the list itself: one buffer per channel,
    /// or buffers that each interleave some of them. Each buffer is checked to hold every frame
    /// of its channels before it is read.
    static func mix(
        _ list: UnsafePointer<AudioBufferList>, frames: Int, channels: Int, commonFormat: AVAudioCommonFormat,
        into destination: UnsafeMutablePointer<Float>
    ) -> Bool {
        let sampleSize: Int
        switch commonFormat {
        case .pcmFormatFloat32: sampleSize = MemoryLayout<Float>.size
        case .pcmFormatInt16: sampleSize = MemoryLayout<Int16>.size
        default: return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        // Each channel: the data that holds it, how many channels that data interleaves, and
        // the channel's place among them.
        var sources: [(data: UnsafeMutableRawPointer, stride: Int, offset: Int)] = []
        for audio in buffers {
            let stride = Int(audio.mNumberChannels)
            guard let data = audio.mData, stride > 0, Int(audio.mDataByteSize) >= frames * stride * sampleSize
            else { return false }
            for offset in 0..<stride { sources.append((data, stride, offset)) }
        }
        guard channels > 0, sources.count == channels else { return false }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { destination[frame] = 0 }
        for source in sources {
            if commonFormat == .pcmFormatFloat32 {
                let samples = source.data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { destination[frame] += samples[frame * source.stride + source.offset] * scale }
            } else {
                let samples = source.data.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frames {
                    destination[frame] += Float(samples[frame * source.stride + source.offset]) / 32_768 * scale
                }
            }
        }
        return true
    }
}
