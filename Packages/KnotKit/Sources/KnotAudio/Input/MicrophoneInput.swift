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
        let engine: AVAudioEngine
        do {
            engine = try hardware.makeEngine()
        } catch {
            hardware.deactivateSession()
            throw error
        }
        // The hardware's format: a rate or a channel count of zero means no input is available,
        // and the engine would throw, or raise an exception, at the start.
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            hardware.deactivateSession()
            throw KnotError.noInputDevice
        }
        return OpenMicrophone(engine: engine, sampleRate: format.sampleRate, hardware: hardware)
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
    func makeEngine() throws(KnotError) -> AVAudioEngine
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
                // Another app or a call holds the audio (AVAudioSessionErrorCodeInsufficientPriority),
                // or the session cannot record now.
                throw KnotError.audioSessionBusy.with(ErrorContext(engineCode: (error as NSError).code))
            }
        #endif
    }

    func deactivateSession() {
        #if os(iOS) || os(watchOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func makeEngine() throws(KnotError) -> AVAudioEngine {
        AVAudioEngine()
    }
}

/// The microphone opened for one recording.
final class OpenMicrophone: OpenAudioInput {
    let sampleRate: Double
    let commonFormat = AVAudioCommonFormat.pcmFormatFloat32
    private let engine: AVAudioEngine
    private let hardware: any HardwareAudio
    private let state = Mutex(State())

    private struct State {
        var running = false
        var closed = false
        /// Watches for the engine's configuration change.
        var watcher: Task<Void, Never>?
    }

    init(engine: AVAudioEngine, sampleRate: Double, hardware: any HardwareAudio) {
        self.engine = engine
        self.sampleRate = sampleRate
        self.hardware = hardware
    }

    func start(format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void) throws(KnotError) {
        let input = engine.inputNode
        do {
            // The tap delivers the hardware's format, every 100 ms or more; each buffer is mixed
            // down to one channel in the working file's format before it is written.
            try input.installAudioTap(onBus: 0, bufferSize: AVAudioFrameCount(sampleRate / 10), format: nil) {
                buffer, _ in
                // An empty buffer holds nothing to write and says nothing about the input.
                guard buffer.frameLength > 0 else { return }
                guard let mono = Downmix.mono(buffer, into: format) else {
                    // Another rate or a sample format the file cannot take: the input changed.
                    deliver(.ended(.lost))
                    return
                }
                deliver(.audio(mono))
            }
        } catch {
            throw KnotError.noInputDevice.with(ErrorContext(engineCode: (error as NSError).code))
        }
        let changes = NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: engine)
        let watcher = Task {
            // The engine stopped itself because the hardware changed. WP-12's second pull request
            // restarts it into the file's rate; until then the recording ends here, kept.
            for await _ in changes {
                deliver(.ended(.lost))
                return
            }
        }
        state.withLock { $0.watcher = watcher }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state.withLock { $0.watcher?.cancel() }
            throw KnotError.audioSessionBusy.with(ErrorContext(engineCode: (error as NSError).code))
        }
        state.withLock { $0.running = true }
    }

    func stop() async {
        let (wasRunning, first) = state.withLock { state in
            defer {
                state.running = false
                state.closed = true
                state.watcher?.cancel()
                state.watcher = nil
            }
            return (state.running, !state.closed)
        }
        guard first else { return }
        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        hardware.deactivateSession()
    }
}

/// Mixes a tap's buffer down to one channel.
enum Downmix {
    /// `buffer` as one channel in `format`, or `nil` when its rate differs from the format's or
    /// its samples are neither 32-bit floats nor 16-bit integers.
    static func mono(_ buffer: AVReadOnlyAudioPCMBuffer, into format: AVAudioFormat) -> AVReadOnlyAudioPCMBuffer? {
        let frames = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        guard buffer.format.sampleRate == format.sampleRate, channels > 0, frames > 0,
            let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let destination = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        let interleaved = buffer.format.isInterleaved
        let scale = 1 / Float(channels)
        let mixed: Bool = buffer.withUnsafeAudioBufferList { list in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            for frame in 0..<frames { destination[frame] = 0 }
            for channel in 0..<channels {
                let source = interleaved ? buffers.first : (channel < buffers.count ? buffers[channel] : nil)
                guard let data = source?.mData else { return false }
                let stride = interleaved ? channels : 1
                let offset = interleaved ? channel : 0
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { destination[frame] += samples[frame * stride + offset] * scale }
                case .pcmFormatInt16:
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frames {
                        destination[frame] += Float(samples[frame * stride + offset]) / 32_768 * scale
                    }
                default:
                    return false
                }
            }
            return true
        }
        return mixed ? AVReadOnlyAudioPCMBuffer(copying: mono) : nil
    }
}
