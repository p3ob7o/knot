import KnotCore
import KnotUIPreviews
import Testing

@Test func previewsRunOnThePreviewEnvironment() {
    #expect(String(reflecting: type(of: KnotUIPreviews.environment)) == "KnotCore.AppEnvironment")
}
