import AVFAudio
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// What the input tap has seen. The tap runs on the audio thread, so the state sits behind a
/// lock. The samples stay in memory, are capped at 60 s and are never written to disk.
final class CaptureBuffer: Sendable {
    struct State: Sendable {
        /// When the first sample of the first buffer was captured, from the buffer's host time.
        var firstSampleTime: Double?
        /// When the first buffer reached the tap.
        var firstDeliveredAt: Double?
        var buffers = 0
        var samples: [Float] = []
        var sampleRate: Double = 0
    }

    private let state = Mutex(State())
    static let cap: Double = 60

    func append(_ buffer: AVReadOnlyAudioPCMBuffer, _ when: AVAudioTime) {
        let delivered = Clock.now()
        let rate = buffer.format.sampleRate
        var copy: [Float] = []
        if case .float(let span) = buffer.channelData(0) {
            span.withUnsafeBufferPointer { copy = Array($0.prefix(buffer.frameLength)) }
        }
        let firstSample = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
        state.withLock { state in
            if state.buffers == 0 {
                state.firstDeliveredAt = delivered
                state.firstSampleTime = firstSample
                state.sampleRate = rate
            }
            state.buffers += 1
            guard Double(state.samples.count) < Self.cap * rate else { return }
            state.samples.append(contentsOf: copy)
        }
    }

    func snapshot() -> State { state.withLock { $0 } }
}

/// How the start of a recording sounds, from its levels in 10 ms windows.
struct Onset: Sendable {
    var firstDB: Double
    var peakDB: Double
    /// The first 30 ms are already loud: within 20 dB of the loudest window and above -45 dBFS.
    /// Speech was under way when the microphone opened, so its start is probably cut.
    var speechAtOpen: Bool
    var seconds: Double

    static func analyse(_ samples: [Float], sampleRate: Double) -> Onset? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        let window = max(1, Int(sampleRate * 0.010))
        var levels: [Double] = []
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + window)
            var sum: Double = 0
            for i in index..<end { sum += Double(samples[i]) * Double(samples[i]) }
            let rms = (sum / Double(end - index)).squareRoot()
            levels.append(20 * log10(max(rms, 1e-9)))
            index = end
        }
        let first = levels.prefix(3)
        let firstDB = 10 * log10(first.map { pow(10, $0 / 10) }.reduce(0, +) / Double(first.count))
        let peakDB = levels.max() ?? -180
        return Onset(
            firstDB: firstDB, peakDB: peakDB, speechAtOpen: firstDB > -45 && firstDB > peakDB - 20,
            seconds: Double(samples.count) / sampleRate)
    }
}

/// The default input device, read from Core Audio's properties. Reading them opens nothing.
enum InputDevice {
    struct Info: Sendable {
        var present: Bool
        var transport: String
    }

    static func current() -> Info {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return Info(present: false, transport: "none") }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return Info(present: true, transport: name(transport))
    }

    static func name(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth: "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired: "iPhone, wired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: "iPhone, wireless"
        default: "other"
        }
    }

    /// Built-in and wired inputs: the ones the failure rule allows to listen from key-down.
    static func isWired(_ transport: String) -> Bool {
        ["built-in", "USB", "Thunderbolt", "iPhone, wired"].contains(transport)
    }
}

enum MicrophoneError: Error, Sendable {
    case notAllowed(String)
    case noInput
    case startFailed(String)

    var text: String {
        switch self {
        case .notAllowed(let status): "the microphone is not allowed (\(status))"
        case .noInput: "no input device"
        case .startFailed(let code): "the engine did not start (\(code))"
        }
    }
}

/// The recorder's input side for the spike: an `AVAudioEngine` with a tap on its input node.
///
/// - `prepare()` at key-down: makes the engine, touches its input node, installs the tap and
///   calls `prepare()`. Per the SDK (AVAudioEngine.h) that preallocates what the engine needs to
///   start, and the microphone indicator appears only while the engine runs.
/// - `open()` at the mark: `start()`. The listening state shows when the first buffer arrives.
/// - `stop()` keeps what was captured; `discard()` drops the engine and the audio.
///
/// It never runs in the self-test, and it refuses to prepare unless the microphone is allowed,
/// so that a key press never brings up the system's microphone prompt.
@MainActor
final class Microphone {
    struct Prepared: Sendable {
        var duration: Double
        var sampleRate: Double
        var channels: UInt32
    }

    private var engine: AVAudioEngine?
    private var sink: CaptureBuffer?
    private(set) var running = false

    static var authorization: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    func prepare() -> Result<Prepared, MicrophoneError> {
        discard()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return .failure(.notAllowed(Self.authorization))
        }
        let start = Clock.now()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return .failure(.noInput) }
        let sink = CaptureBuffer()
        do {
            // macOS 27: the Sendable tap. The old installTap(onBus:bufferSize:format:block:) is
            // deprecated. The header gives buffers of 100 to 400 ms, so "live" is timed from the
            // first sample's host time, not from when the first buffer arrives.
            try input.installAudioTap(
                onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format,
                tapProvider: { buffer, when in sink.append(buffer, when) })
        } catch {
            let ns = error as NSError
            return .failure(.startFailed("tap \(ns.domain)#\(ns.code)"))
        }
        engine.prepare()
        self.engine = engine
        self.sink = sink
        return .success(
            Prepared(duration: Clock.now() - start, sampleRate: format.sampleRate, channels: format.channelCount))
    }

    /// Starts the engine. Returns how long `start()` took.
    func open() -> Result<Double, MicrophoneError> {
        guard let engine else { return .failure(.noInput) }
        let start = Clock.now()
        do {
            try engine.start()
        } catch {
            let ns = error as NSError
            return .failure(.startFailed("\(ns.domain)#\(ns.code)"))
        }
        running = true
        return .success(Clock.now() - start)
    }

    var buffer: CaptureBuffer? { sink }

    func stop() -> CaptureBuffer.State? {
        let state = sink?.snapshot()
        discard()
        return state
    }

    func discard() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        sink = nil
        running = false
    }
}

/// Plays the last hold back, from memory, on an engine of its own with no input node.
@MainActor
final class Playback {
    private var engine: AVAudioEngine?

    func play(_ samples: [Float], sampleRate: Double) {
        stop()
        guard sampleRate > 0, !samples.isEmpty,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, completionHandler: nil)
            try player.playAudio()
        } catch {
            return
        }
        self.engine = engine
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
