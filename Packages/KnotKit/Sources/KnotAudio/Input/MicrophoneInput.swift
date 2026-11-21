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
/// An interruption, a call, Siri or an alarm that takes the audio session, ends the recording
/// as `interrupted`, with everything written kept. A route change that changes the hardware, as
/// AirPods that connect, makes the engine change its configuration and stop itself: the input then
/// puts its tap back in the new format and starts again, and a new rate goes through a converter
/// into the working file's, which keeps its rate for its whole length (docs/architecture.md §8).
/// An engine that cannot start again, or media services that were reset, end the recording as
/// `input_lost`.
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
    /// What the audio session tells a recording, from the moment it is asked, on iOS and watchOS.
    /// The Mac has no audio session, and the stream ends at once.
    func sessionEvents() -> AsyncStream<SessionEvent>
}

/// What the audio session tells a recording.
enum SessionEvent: Hashable, Sendable {
    /// The system took the session: a call, Siri or an alarm.
    case interrupted
    /// The media services were reset, and every audio object with them.
    case servicesReset
    /// The route changed, for the session's reason. When the hardware changed, the engine's own
    /// configuration change follows, and the input starts again on it.
    case routeChanged(reason: UInt)
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
                // Haptics and system sounds are held back while the session takes input unless it
                // allows them, and by default it does not (AVAudioSession.h,
                // allowHapticsAndSystemSoundsDuringRecording): without this, the live cue's
                // haptic is never felt. The live cue's gap keeps its sound out of the recording.
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
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

    /// The session's interruptions, resets and route changes. From OS 27 an interruption is a
    /// deactivation by the system, which `AVAudioSession.DidBecomeInactiveMessage` gives with
    /// `.systemInterruption`; the interruption notification is deprecated (AVAudioSessionTypes.h).
    func sessionEvents() -> AsyncStream<SessionEvent> {
        #if os(iOS) || os(watchOS)
            AsyncStream { continuation in
                let session = AVAudioSession.sharedInstance()
                let center = NotificationCenter.default
                let inactive = center.addObserver(of: session, for: .didBecomeInactive) { message in
                    if case .systemInterruption = message.deactivationResult { continuation.yield(.interrupted) }
                }
                let resets = Task {
                    for await _ in center.notifications(named: AVAudioSession.mediaServicesWereResetNotification) {
                        continuation.yield(.servicesReset)
                    }
                }
                let routes = Task {
                    for await notification in center.notifications(named: AVAudioSession.routeChangeNotification) {
                        let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                        continuation.yield(.routeChanged(reason: reason))
                    }
                }
                continuation.onTermination = { _ in
                    center.removeObserver(inactive)
                    resets.cancel()
                    routes.cancel()
                }
            }
        #else
            AsyncStream { $0.finish() }
        #endif
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
/// The engine is touched in three places only, never at once: inside the start, inside a restart
/// after the engine changed its configuration, and inside the one stop that finishes the input,
/// which no start or restart runs beside. A stop asked for while a start or a restart runs, its
/// own undoing included, waits for it, and the start then takes away what it put there. One stop
/// finishes the input and every other waits until it has. Every delivery, of the tap, of a
/// configuration change or of the session, is counted while it runs, and none begins once the
/// input is finishing. So every stop, during the start, after it or at once with another, returns
/// only once the tap is gone, the engine stopped, every delivery under way ended and the session
/// given back: no delivery follows it.
final class OpenMicrophone: OpenAudioInput {
    let sampleRate: Double
    let commonFormat = AVAudioCommonFormat.pcmFormatFloat32
    private let engine: any InputEngine
    private let hardware: any HardwareAudio
    private let state = Mutex(State())
    /// Where a configuration change and the session's events are handled: a queue of the input's
    /// own, never a thread of the cooperative pool, so that a restart, which starts the engine,
    /// and a handler that holds its delivery hold no thread a task needs.
    private let changeQueue = DispatchQueue(label: "knot.microphone.configuration-change")

    private struct State {
        /// True while the start or a restart runs.
        var starting = false
        /// True once a stop has been asked for.
        var stopped = false
        var tapInstalled = false
        var engineStarted = false
        var sessionReleased = false
        /// The working file's format and the counted delivery, which a restart takes again.
        var format: AVAudioFormat?
        var deliver: (@Sendable (AudioDelivery) -> Void)?
        /// How many times the engine was started again after a configuration change.
        var restarts = 0
        /// Watch for the engine's configuration changes and for the session's events.
        var watchers: [Task<Void, Never>] = []
        /// Stops asked for while the start or a restart runs, waiting for it.
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

    /// How many times the engine started again after a configuration change, for a test.
    var restarts: Int { state.withLock { $0.restarts } }

    func start(format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void) throws(KnotError) {
        // A stop that came first leaves nothing to start.
        let proceed = state.withLock { state in
            guard !state.stopped, !state.starting, !state.tapInstalled else { return false }
            state.starting = true
            return true
        }
        guard proceed else { return }
        let deliver = counted(deliver)
        state.withLock {
            $0.format = format
            $0.deliver = deliver
        }
        var failure: KnotError?
        do throws(KnotError) {
            try attach(format: format, deliver: deliver)
            watch(deliver)
            // A stop asked for meanwhile: the engine is not started, and the microphone never opens.
            if !state.withLock({ $0.stopped }) {
                try engine.start()
                state.withLock { $0.engineStarted = true }
            }
        } catch {
            failure = error
        }
        endStart(undo: state.withLock { $0.stopped } || failure != nil)
        if let failure { throw failure }
    }

    /// Installs the tap in the input's present format. Each buffer is mixed down to one channel
    /// and carried into the working file's format, at the file's rate, before it is delivered.
    private func attach(format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void)
        throws(KnotError)
    {
        let shape = engine.tap
        guard shape.sampleRate > 0, shape.channels > 0, let carrier = Carrier(tapRate: shape.sampleRate, into: format)
        else { throw KnotError.noInputDevice }
        // The tap delivers the hardware's format, every 100 ms or more.
        try engine.installTap(bufferSize: AVAudioFrameCount(shape.sampleRate / 10)) { buffer in
            // An empty buffer holds nothing to write and says nothing about the input.
            guard buffer.frameLength > 0 else { return }
            guard let carried = carrier.carry(buffer) else {
                // A sample format the file cannot take, or a rate the tap did not promise.
                deliver(.ended(.lost))
                return
            }
            if carried.frameLength > 0 { deliver(.audio(carried)) }
        }
        state.withLock { $0.tapInstalled = true }
    }

    /// Watches, once, for the engine's configuration changes, which start it again, and for the
    /// session's events: an interruption ends the recording as `interrupted`, a reset of the media
    /// services as `input_lost`, and a route change alone changes nothing.
    private func watch(_ deliver: @escaping @Sendable (AudioDelivery) -> Void) {
        let changes = engine.configurationChanges()
        let events = hardware.sessionEvents()
        let changeQueue = self.changeQueue
        let configuration = Task { [weak self] in
            for await _ in changes {
                guard let input = self else { return }
                changeQueue.async { input.restart() }
            }
        }
        let session = Task {
            for await event in events {
                switch event {
                case .interrupted:
                    changeQueue.async { deliver(.ended(.interrupted)) }
                    return
                case .servicesReset:
                    changeQueue.async { deliver(.ended(.lost)) }
                    return
                case .routeChanged:
                    continue
                }
            }
        }
        state.withLock { $0.watchers = [configuration, session] }
    }

    /// Starts the engine again after it changed its configuration and stopped itself: its tap is
    /// put back in the new format, carried into the file's rate. A stop asked for meanwhile waits
    /// for it, as for a start. An engine that cannot start again ends the recording as
    /// `input_lost`, with everything written kept. On the input's own queue.
    private func restart() {
        let taken = state.withLock { state -> (AVAudioFormat, @Sendable (AudioDelivery) -> Void)? in
            guard !state.stopped, !state.starting, !state.closed, let format = state.format,
                let deliver = state.deliver
            else { return nil }
            state.starting = true
            return (format, deliver)
        }
        guard let (format, deliver) = taken else { return }
        detach()
        var failure: KnotError?
        do throws(KnotError) {
            if !state.withLock({ $0.stopped }) {
                try attach(format: format, deliver: deliver)
                if !state.withLock({ $0.stopped }) {
                    try engine.start()
                    state.withLock {
                        $0.engineStarted = true
                        $0.restarts += 1
                    }
                }
            }
        } catch {
            failure = error
        }
        if failure != nil { deliver(.ended(.lost)) }
        endStart(undo: state.withLock { $0.stopped } || failure != nil)
    }

    /// Ends a start or a restart. A stop asked for while it ran, or a failure, takes away what it
    /// put there. The start is over only then: a stop asked for meanwhile waits for that too, and
    /// the stops that waited for it go on.
    private func endStart(undo: Bool) {
        if undo { tearDown() }
        let waiting = state.withLock { state in
            state.starting = false
            state.suspended -= state.waiting.count
            defer { state.waiting = [] }
            return state.waiting
        }
        for stop in waiting { stop.resume() }
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

    /// Stops the engine and takes the tap away, if they are there, for a restart.
    private func detach() {
        let (engineStarted, tapInstalled) = state.withLock { state in
            defer {
                state.engineStarted = false
                state.tapInstalled = false
            }
            return (state.engineStarted, state.tapInstalled)
        }
        if engineStarted { engine.stop() }
        if tapInstalled { engine.removeTap() }
    }

    /// Stops the engine and takes the tap away, if they are there, once, and stops watching. No
    /// delivery begins after.
    private func tearDown() {
        let watchers = state.withLock { state in
            state.closed = true
            defer { state.watchers = [] }
            return state.watchers
        }
        for watcher in watchers { watcher.cancel() }
        detach()
    }
}

/// Carries a tap's buffers into the working file's format: mixed down to one channel and, when
/// the tap's rate is not the file's, converted into the file's rate (docs/architecture.md §8). One
/// carrier for each tap, used on the tap's thread only, so that its converter's state runs from
/// one buffer to the next. What the converter still holds when its tap is taken away, at most
/// 20 ms, is not written.
final class Carrier: Sendable {
    /// The working file's format.
    private let format: AVAudioFormat
    /// One channel at the tap's rate.
    private let mono: AVAudioFormat
    private let converter: AVAudioConverter?

    /// `nil` when no converter can be made between the two rates.
    init?(tapRate: Double, into format: AVAudioFormat) {
        self.format = format
        guard tapRate != format.sampleRate else {
            mono = format
            converter = nil
            return
        }
        guard
            let mono = AVAudioFormat(
                commonFormat: format.commonFormat, sampleRate: tapRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: mono, to: format)
        else { return nil }
        self.mono = mono
        self.converter = converter
    }

    /// `buffer` in the file's format, perhaps with no frame while the converter fills; `nil`
    /// when it cannot be mixed or converted.
    func carry(_ buffer: AVReadOnlyAudioPCMBuffer) -> AVReadOnlyAudioPCMBuffer? {
        guard let mixed = Downmix.mono(buffer, into: mono) else { return nil }
        guard let converter else { return mixed }
        let ratio = format.sampleRate / mono.sampleRate
        let capacity = AVAudioFrameCount((Double(mixed.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // The converter asks for input until it has none for now: the one buffer, then no data,
        // which keeps its state for the next buffer. The block runs inside the call only
        // (AVAudioConverter.h, convertToBuffer:error:withInputFromBlock:).
        var pending: AVAudioPCMBuffer? = AVAudioPCMBuffer(copying: mixed)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let next = pending
            pending = nil
            inputStatus.pointee = next == nil ? .noDataNow : .haveData
            return next
        }
        guard status != .error, error == nil else { return nil }
        return AVReadOnlyAudioPCMBuffer(copying: output)
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
