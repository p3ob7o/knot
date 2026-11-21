import AVFAudio
import Foundation
import KnotCore
import Synchronization

/// The `AudioPlayer` on AVFAudio (docs/architecture.md §5): a stored recording played through
/// an `AVAudioEngine` and a player node, which plays, pauses and seeks it.
///
/// Every change runs on the player's own queue, one at a time, and a change of state is told to
/// every subscription under one lock with the state it changes, so that a subscriber that joins
/// sees the state current then and each later one, in order. While it plays, it tells where it
/// stands every 100 ms, when that has moved. The player node's completion, which comes on the
/// audio's thread or inside a stop, only hands its end to that queue.
///
/// On iOS and watchOS a play makes the audio session ready for playback; what a device plays,
/// through its speaker or headphones, is checked at the owner's sittings. Under test the engine
/// renders offline, by `AVAudioEngine`'s manual rendering, so that nothing plays aloud and the
/// test moves the audio on itself.
public final class LiveAudioPlayer: AudioPlayer {
    /// Where the audio goes.
    enum Output: Sendable {
        /// The device's output.
        case device
        /// Nowhere: the engine renders when a test asks it to, and never touches the output.
        case offline
    }

    private let output: Output
    private let log: KnotLog
    private let queue = DispatchQueue(label: "knot.audio.player", qos: .userInitiated)
    private let state = Mutex(State())

    private struct State {
        var engine: AVAudioEngine?
        var node: AVAudioPlayerNode?
        var file: AVAudioFile?
        /// The loaded recording's frames and rate, and its length.
        var frames: AVAudioFramePosition = 0
        var rate: Double = 0
        var length: Duration = .zero
        var playback: PlaybackState = .empty
        /// While playing, the frame its segment started from.
        var segmentStart: AVAudioFramePosition = 0
        /// Counts the segments scheduled, so that the end of one that was stopped is ignored.
        var segment = 0
        var subscribers: [UUID: AsyncStream<PlaybackState>.Continuation] = [:]
        /// Tells where a playing recording stands.
        var ticker: (any DispatchSourceTimer)?
        /// The asset the loaded file is, when its name gives one, for the log.
        var asset: AssetID?
    }

    public convenience init() {
        self.init(output: .device)
    }

    init(output: Output, log: KnotLog = KnotLog(.audio)) {
        self.output = output
        self.log = log
    }

    // MARK: The port

    public func load(_ file: URL) async throws(KnotError) -> Duration {
        let output = self.output
        let loaded: Result<Duration, KnotError> = await onQueue { [self] in
            let audio: AVAudioFile
            do {
                audio = try AVAudioFile(forReading: file)
            } catch {
                return .failure(KnotError.audioUnreadable.with(ErrorContext(engineCode: (error as NSError).code)))
            }
            let format = audio.processingFormat
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            do {
                // Before the engine's mixer is touched, so that it never configures the hardware.
                if output == .offline {
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
                }
                engine.attach(node)
                // From OS 27 a connection says why it failed (AVAudioEngine.h, connect:to:format:error:).
                try engine.connectNode(node, to: engine.mainMixerNode, format: format)
            } catch {
                return .failure(KnotError.audioUnreadable.with(ErrorContext(engineCode: (error as NSError).code)))
            }
            engine.prepare()
            let frames = audio.length
            let length = Duration.seconds(Double(frames) / format.sampleRate)
            // A stored recording is named by its asset's ID; any other name gives none.
            let asset = AssetID(file.deletingPathExtension().lastPathComponent)
            let previous = state.withLock { state in
                defer {
                    state.engine = engine
                    state.node = node
                    state.file = audio
                    state.frames = frames
                    state.rate = format.sampleRate
                    state.length = length
                    state.segment += 1
                    state.asset = asset
                }
                return (state.engine, state.node)
            }
            stopTicking()
            previous.1?.stop()
            previous.0?.stop()
            publish(.paused(at: .zero, of: length))
            return .success(length)
        }
        return try loaded.get()
    }

    public func play() async {
        await onQueue { [self] in
            switch state.withLock({ $0.playback }) {
            case .empty, .playing: return
            case .paused(let at, _): start(from: at)
            // From the end, it plays again from the start.
            case .ended: start(from: .zero)
            }
        }
    }

    public func pause() async {
        await onQueue { [self] in
            guard case .playing = state.withLock({ $0.playback }) else { return }
            let at = halt()
            state.withLock { $0.engine }?.pause()
            publish(.paused(at: at, of: state.withLock { $0.length }))
        }
    }

    public func seek(to position: Duration) async {
        await onQueue { [self] in
            let (playback, length) = state.withLock { ($0.playback, $0.length) }
            let held = min(max(position, .zero), length)
            switch playback {
            case .empty: return
            case .playing:
                _ = halt()
                start(from: held)
            case .paused, .ended:
                publish(.paused(at: held, of: length))
            }
        }
    }

    /// A play the engine refused, with the loaded file's asset when its name gives one.
    private func logNotStarted(_ error: any Error) {
        let failure = KnotError.audioUnreadable.with(ErrorContext(engineCode: (error as NSError).code))
        if let asset = state.withLock({ $0.asset }) {
            log.failure(failure, "player_not_started", .asset(asset))
        } else {
            log.failure(failure, "player_not_started")
        }
    }

    public func states() -> AsyncStream<PlaybackState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackState.self)
        let id = UUID()
        // The current state and the subscription under one lock: no change falls between them.
        state.withLock { state in
            continuation.yield(state.playback)
            state.subscribers[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Playing

    /// Plays from `position`, on the queue. At the end, there is nothing to play: it ended.
    private func start(from position: Duration) {
        let taken = state.withLock {
            state -> (AVAudioEngine, AVAudioPlayerNode, AVAudioFile, Int, Duration, AVAudioFramePosition)? in
            guard let engine = state.engine, let node = state.node, let file = state.file else { return nil }
            let frame = min(AVAudioFramePosition((Self.seconds(position) * state.rate).rounded(.down)), state.frames)
            state.segment += 1
            state.segmentStart = frame
            return (engine, node, file, state.segment, state.length, frame)
        }
        guard let (engine, node, file, segment, length, frame) = taken else { return }
        let remaining = file.length - frame
        guard remaining > 0 else {
            publish(.ended(length))
            return
        }
        Self.activateSession()
        // A node that played to its end is still playing, on a timeline from its first play:
        // stopped, its timeline starts again with this segment, so its position is this one's.
        node.stop()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            logNotStarted(error)
            publish(.paused(at: position, of: length))
            return
        }
        // The end is when the device has played it out; offline, where no device plays, when it is
        // rendered (AVAudioPlayerNode.h, AVAudioPlayerNodeCompletionCallbackType).
        node.scheduleSegment(
            file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
            completionCallbackType: output == .device ? .dataPlayedBack : .dataRendered
        ) { [weak self] _ in
            // On the audio's thread, or inside a stop: only handed to the queue.
            guard let player = self else { return }
            player.queue.async { player.segmentPlayed(segment) }
        }
        do {
            // From OS 27 a play says why it failed (AVAudioPlayerNode.h, playAndReturnError:).
            try node.playAudio()
        } catch {
            _ = halt()
            logNotStarted(error)
            publish(.paused(at: position, of: length))
            return
        }
        publish(.playing(at: position, of: length))
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now() + 0.1, repeating: 0.1)
        ticker.setEventHandler { [weak self] in self?.tick() }
        ticker.resume()
        state.withLock { $0.ticker = ticker }
    }

    /// Where a playing recording stands, told when it has moved. On the queue.
    private func tick() {
        guard case .playing(let told, let length) = state.withLock({ $0.playback }) else { return }
        let at = position()
        if at != told { publish(.playing(at: at, of: length)) }
    }

    /// Stops telling where the recording stands. On the queue.
    private func stopTicking() {
        state.withLock { state in
            defer { state.ticker = nil }
            return state.ticker
        }?.cancel()
    }

    /// Stops the segment that plays and returns where it stood, on the queue.
    private func halt() -> Duration {
        stopTicking()
        let at = position()
        let node = state.withLock { state -> AVAudioPlayerNode? in
            // The stopped segment's end is not the recording's.
            state.segment += 1
            return state.node
        }
        node?.stop()
        return at
    }

    /// Where the playing segment stands: its start, and what the node has played of it.
    private func position() -> Duration {
        state.withLock { state in
            guard case .playing = state.playback, let node = state.node, state.rate > 0 else {
                return Self.at(state.playback)
            }
            var frame = state.segmentStart
            // A render time with neither a sample time nor a host time cannot be asked about
            // (AVAudioPlayerNode.h, playerTimeForNodeTime:): nothing has been rendered yet.
            if let render = node.lastRenderTime, render.isSampleTimeValid || render.isHostTimeValid,
                let played = node.playerTime(forNodeTime: render), played.isSampleTimeValid
            {
                frame += max(played.sampleTime, 0)
            }
            return min(Duration.seconds(Double(frame) / state.rate), state.length)
        }
    }

    /// A segment played to its end: the recording ended, unless that segment was stopped.
    private func segmentPlayed(_ segment: Int) {
        let (current, length, engine) = state.withLock { ($0.segment == segment, $0.length, $0.engine) }
        guard current, case .playing = state.withLock({ $0.playback }) else { return }
        stopTicking()
        engine?.pause()
        publish(.ended(length))
    }

    /// Sets the state and tells every subscription, under one lock.
    private func publish(_ playback: PlaybackState) {
        state.withLock { state in
            state.playback = playback
            for subscriber in state.subscribers.values { subscriber.yield(playback) }
        }
    }

    /// For a test: renders `frames` frames offline, as the device would play them, and returns
    /// how many it rendered. Nothing is heard.
    func renderOffline(_ frames: AVAudioFrameCount) async -> AVAudioFrameCount {
        await onQueue { [self] in
            guard output == .offline, let engine = state.withLock({ $0.engine }), engine.isRunning,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)
            else { return 0 }
            var rendered: AVAudioFrameCount = 0
            while rendered < frames {
                let step = min(frames - rendered, buffer.frameCapacity)
                guard (try? engine.renderOffline(step, to: buffer)) == .success else { break }
                rendered += buffer.frameLength
            }
            return rendered
        }
    }

    /// The state it holds now, for a test.
    var currentState: PlaybackState { state.withLock { $0.playback } }

    // MARK: Helpers

    private static func at(_ playback: PlaybackState) -> Duration {
        switch playback {
        case .empty: .zero
        case .paused(let at, _), .playing(let at, _): at
        case .ended(let length): length
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Makes the audio session ready to play, on iOS and watchOS.
    private static func activateSession() {
        #if os(iOS) || os(watchOS)
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try? session.setCategory(.playback, mode: .default, options: [])
            }
            try? session.setActive(true)
        #endif
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
