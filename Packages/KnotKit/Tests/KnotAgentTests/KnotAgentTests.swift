import KnotAgent
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotAgentLive.self) == "KnotAgent.KnotAgentLive")
}
