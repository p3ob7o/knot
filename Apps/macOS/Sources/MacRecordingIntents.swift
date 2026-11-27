import AppIntents

struct MacStartRecording: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Recording"

    @Dependency private var recording: MacCaptureCoordinator

    @MainActor
    func perform() async throws -> some IntentResult {
        recording.start(held: false)
        return .result()
    }
}

struct MacStopRecording: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Stop Recording"

    @Dependency private var recording: MacCaptureCoordinator

    @MainActor
    func perform() async throws -> some IntentResult {
        recording.stop()
        return .result()
    }
}
