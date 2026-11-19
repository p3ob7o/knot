import KnotSpeech
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotSpeechLive.self) == "KnotSpeech.KnotSpeechLive")
}
