import AVFAudio
import Foundation
import KnotCore
import Synchronization

/// Audio that stands in for the microphone: 16-bit mono samples made in memory and handed to
/// the recorder in buffers, as a tap hands them over (docs/architecture.md §8). It opens no
/// hardware, so tests, the crash host and the proof runs record with it on any machine.
public struct InjectedAudio: AudioInput {
    /// How fast the buffers come.
    public enum Pace: Hashable, Sendable {
        /// One buffer for each buffer's length of audio, as a tap delivers them.
        case realTime
        /// One buffer each interval, whatever its length of audio.
        case every(Duration)
        /// As fast as the recorder takes them.
        case unpaced
    }

    /// What happens once `frames` have been delivered.
    public enum Ending: Hashable, Sendable {
        /// The input stays open and delivers nothing more, as a quiet input does not: the
        /// recording stays live until it is stopped.
        case runsDry
        /// The input ends by itself, as when it goes away or a call takes the session.
        case ends(InputEnding)
    }

    public var sampleRate: Double
    /// Frames in each buffer: 1,600 is 100 ms at 16 kHz, the smallest buffer a tap delivers.
    public var framesPerBuffer: Int
    public var pace: Pace
    /// How many frames are delivered, or `nil` for no end.
    public var frames: Int64?
    public var ending: Ending
    /// The sample at each frame of the recording, from its first.
    public var samples: @Sendable (Int64) -> Int16
    /// An error that `open` throws, as the microphone's can: the permission refused, no input
    /// device, the session busy.
    public var openFailure: KnotError?
    /// An error that `start` throws, after the recorder has written its manifest and file.
    public var startFailure: KnotError?
    /// Called after each buffer the recorder has taken, with the frames handed over so far. The
    /// recorder writes a buffer before it returns, so these frames have reached the system.
    public var delivered: (@Sendable (Int64) -> Void)?

    public init(
        sampleRate: Double = 16_000, framesPerBuffer: Int = 1_600, pace: Pace = .realTime, frames: Int64? = nil,
        ending: Ending = .runsDry, samples: @escaping @Sendable (Int64) -> Int16 = SyntheticAudio.sample(at:),
        openFailure: KnotError? = nil, startFailure: KnotError? = nil,
        delivered: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.sampleRate = sampleRate
        self.framesPerBuffer = framesPerBuffer
        self.pace = pace
        self.frames = frames
        self.ending = ending
        self.samples = samples
        self.openFailure = openFailure
        self.startFailure = startFailure
        self.delivered = delivered
    }

    public func prepare() async {}

    public func releasePreparation() async {}

    public func open() async throws(KnotError) -> any OpenAudioInput {
        if let openFailure { throw openFailure }
        return OpenInjectedAudio(self)
    }
}

/// Injected audio opened for one recording. Its buffers are delivered from a queue of its own,
/// as the hardware's tap delivers from the audio's thread, never from a thread of the
/// cooperative pool: the recorder writes and measures each buffer in the delivery, so an
/// injected recording does that where a real one does. Each buffer waits on the queue for its
/// pace, and a stop returns once no delivery is under way and none will follow.
final class OpenInjectedAudio: OpenAudioInput {
    let source: InjectedAudio
    let commonFormat = AVAudioCommonFormat.pcmFormatInt16
    private let queue = DispatchQueue(label: "knot.audio.injected", qos: .userInitiated)
    private let state = Mutex(Feed())

    private struct Feed {
        var started = false
        var stopped = false
        /// True once the feeder delivers nothing more: its source ran out or ended, or it stopped.
        var finished = false
        /// Stops waiting for the feeder to finish.
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    /// What one recording's feeder hands over, and since when.
    private struct Feeder: Sendable {
        let format: AVAudioFormat
        let deliver: @Sendable (AudioDelivery) -> Void
        let began: DispatchTime
    }

    var sampleRate: Double { source.sampleRate }

    init(_ source: InjectedAudio) {
        self.source = source
    }

    func start(format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void) throws(KnotError) {
        if let failure = source.startFailure { throw failure }
        // A stop that came first leaves nothing to start.
        let begins = state.withLock { state in
            guard !state.stopped, !state.started else { return false }
            state.started = true
            return true
        }
        guard begins else { return }
        let feeder = Feeder(format: format, deliver: deliver, began: .now())
        queue.async { [self] in next(feeder, index: 0, position: 0) }
    }

    func stop() async {
        let started = state.withLock { state in
            state.stopped = true
            return state.started
        }
        guard started else { return }
        // After the delivery under way, if any: the feeder's queue is serial.
        queue.async { [self] in finish() }
        await withCheckedContinuation { (stop: CheckedContinuation<Void, Never>) in
            let finished = state.withLock { state in
                if !state.finished { state.waiting.append(stop) }
                return state.finished
            }
            if finished { stop.resume() }
        }
    }

    /// Ends the source or waits for the next buffer's pace, on the queue. Buffer n arrives once
    /// n + 1 buffers' worth of audio has passed, as from a tap, in real time; one interval after
    /// the last, at a set interval; and as soon as the queue comes to it, unpaced.
    private func next(_ feeder: Feeder, index: Int, position: Int64) {
        guard !state.withLock({ $0.stopped }) else { return finish() }
        if let total = source.frames, position >= total {
            if case .ends(let why) = source.ending { feeder.deliver(.ended(why)) }
            return finish()
        }
        let deliver: @Sendable () -> Void = { [self] in hand(feeder, index: index, position: position) }
        switch source.pace {
        case .realTime:
            let length = Double(source.framesPerBuffer) / source.sampleRate
            let due = feeder.began.uptimeNanoseconds + UInt64(length * Double(index + 1) * 1e9)
            queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due), execute: deliver)
        case .every(let interval) where index > 0:
            queue.asyncAfter(deadline: .now() + Self.dispatch(interval), execute: deliver)
        case .every, .unpaced:
            queue.async(execute: deliver)
        }
    }

    /// Hands the buffer at `position` over, unless the input stopped meanwhile, on the queue.
    private func hand(_ feeder: Feeder, index: Int, position: Int64) {
        guard !state.withLock({ $0.stopped }) else { return finish() }
        let count = Int(min(Int64(source.framesPerBuffer), (source.frames ?? .max) - position))
        guard let buffer = SyntheticAudio.buffer(format: feeder.format, from: position, count: count, source.samples)
        else { return finish() }
        feeder.deliver(.audio(buffer))
        let reached = position + Int64(count)
        source.delivered?(reached)
        next(feeder, index: index + 1, position: reached)
    }

    /// The feeder delivers nothing more; the stops waiting for it go on. Once or more.
    private func finish() {
        let waiting = state.withLock { state in
            state.finished = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for stop in waiting { stop.resume() }
    }

    private static func dispatch(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}

/// The synthetic signal that injected audio uses by default: noise made from each frame's
/// index alone, in integer arithmetic, so that every platform makes the same samples and a
/// reader can check each frame of a file against it. It holds no speech.
public enum SyntheticAudio {
    /// The sample at `frame`, from -8,192 to 8,191: a quarter of full scale.
    public static func sample(at frame: Int64) -> Int16 {
        var z = UInt64(bitPattern: frame) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int16(truncatingIfNeeded: Int64(z >> 50) - 8_192)
    }

    /// `count` frames from `position` in `format`, which is mono, 16-bit integers or 32-bit
    /// floats. `nil` for a count below one or another format.
    static func buffer(
        format: AVAudioFormat, from position: Int64, count: Int, _ samples: (Int64) -> Int16
    ) -> AVReadOnlyAudioPCMBuffer? {
        guard count > 0, format.channelCount == 1,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        if let destination = buffer.int16ChannelData?[0] {
            for index in 0..<count { destination[index] = samples(position + Int64(index)) }
        } else if let destination = buffer.floatChannelData?[0] {
            for index in 0..<count { destination[index] = Float(samples(position + Int64(index))) / 32_768 }
        } else {
            return nil
        }
        return AVReadOnlyAudioPCMBuffer(copying: buffer)
    }
}
