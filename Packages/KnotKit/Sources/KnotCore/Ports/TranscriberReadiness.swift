/// Whether the transcriber can turn speech into text on this device (docs/architecture.md
/// §5 and §9). Five states, read from the speech model on disk, never from the process's
/// own reservation.
public enum TranscriberReadiness: String, Hashable, Sendable, Codable, CaseIterable {
    /// The model for the chosen English variant is on the device.
    case ready
    /// The variant is supported, and its model is not on the device. The app asks for the
    /// install, and transcription waits: a deferral.
    case notInstalled = "not_installed"
    /// The model is downloading. Transcription waits: a deferral.
    case installing
    /// The chosen English variant is not supported here.
    case unsupportedLocale = "unsupported_locale"
    /// No speech recognition on this device, such as in the Simulator or on the Watch.
    case unavailable

    /// True when speech can never run on this device: it is unavailable, or the locale is
    /// unsupported. A recording whose work belongs here is then kept with no text, and its
    /// note does not wait for it. False while the model is only missing or installing,
    /// since that work is waiting, and the recording stays on its way.
    public var neverRunsHere: Bool {
        switch self {
        case .unavailable, .unsupportedLocale: true
        case .ready, .notInstalled, .installing: false
        }
    }
}
