import KnotExport
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotExportLive.self) == "KnotExport.KnotExportLive")
}
