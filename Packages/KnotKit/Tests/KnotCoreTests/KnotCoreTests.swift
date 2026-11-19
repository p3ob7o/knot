import KnotCore
import Testing

@Test func unavailableEnvironmentIsDeclared() {
    #expect(String(reflecting: type(of: AppEnvironment.unavailable)) == "KnotCore.AppEnvironment")
}
