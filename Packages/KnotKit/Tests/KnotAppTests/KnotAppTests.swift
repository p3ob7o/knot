import KnotApp
import KnotCore
import Testing

@Test func factoryAndLiveEnvironmentAreDeclared() {
    #expect(String(reflecting: type(of: EnvironmentFactory.make())) == "KnotCore.AppEnvironment")
    #expect(String(reflecting: type(of: EnvironmentFactory.live)) == "KnotCore.AppEnvironment")
}
