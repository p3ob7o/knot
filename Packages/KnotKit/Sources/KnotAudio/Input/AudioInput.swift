import AVFAudio
import KnotCore

/// Where a recording's audio comes from: the microphone in the app, and injected audio under
/// test, where the hardware input is refused (docs/architecture.md §8).
///
/// The source is not part of the `Recorder` port. The live recorder takes one when it is made,
/// and opens it once for each recording.
public protocol AudioInput: Sendable {
    /// Gets ready without opening anything, so that a start soon after is fast. Calling it
    /// often is harmless.
    func prepare() async

    /// Releases resources still held by `prepare()`. An `open()` that takes prepared
    /// resources must transfer ownership so releasing preparation cannot affect that recording.
    /// Safe to call when nothing is prepared. This call opens no hardware.
    func releasePreparation() async

    /// Opens the input for one recording without delivering anything yet: the permission, the
    /// audio session and the format it will deliver. Nothing implies a recording yet.
    ///
    /// Errors: microphone permission refused, no input device, audio session busy.
    func open() async throws(KnotError) -> any OpenAudioInput
}

extension AudioInput {
    /// The default for inputs that retain no preparation.
    public func releasePreparation() async {}
}

/// An input opened for one recording.
public protocol OpenAudioInput: Sendable {
    /// The rate the input delivers at, which the working file keeps for its whole length.
    var sampleRate: Double { get }

    /// The sample format of the buffers it delivers: 16-bit integers or 32-bit floats.
    var commonFormat: AVAudioCommonFormat { get }

    /// Starts delivering. Every buffer is mono and in `format`, which the recorder makes from
    /// `sampleRate` and `commonFormat`. Deliveries come one at a time, in order, and
    /// `deliver` writes each buffer before it returns, so a delivery must not wait for anything
    /// the recorder does.
    func start(format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void) throws(KnotError)

    /// Stops delivering and closes what `open` opened. Returns once no delivery is under way
    /// and none will follow. Safe to call more than once, and before `start`.
    func stop() async
}

/// What an input hands the recorder.
public enum AudioDelivery: Sendable {
    /// The next stretch of audio, mono, in the format the recorder asked for.
    case audio(AVReadOnlyAudioPCMBuffer)
    /// The input stopped by itself and delivers nothing more.
    case ended(InputEnding)
}

/// Why an input stopped by itself.
public enum InputEnding: String, Hashable, Sendable {
    /// The input went away, or changed so that it can no longer feed the working file.
    case lost
    /// The system took the audio session: a call, Siri or an alarm.
    case interrupted

    /// The recording's ending this gives.
    var recordingEnding: RecordingEnding {
        switch self {
        case .lost: .inputLost
        case .interrupted: .interrupted
        }
    }
}
