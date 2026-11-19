import KnotIntents
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotIntentsLive.self) == "KnotIntents.KnotIntentsLive")
}

@Test func placeholderIntentIsDeclared() {
    #expect(String(reflecting: KnotPlaceholderIntent.self) == "KnotIntents.KnotPlaceholderIntent")
}
