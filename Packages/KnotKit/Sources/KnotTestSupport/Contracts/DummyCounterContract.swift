import Testing

/// A port that exists only to prove how contract suites are arranged
/// (docs/architecture.md §17): a suite in KnotTestSupport takes a factory, and each
/// implementation's test target calls it. WP-02's ports follow the same shape.
public protocol DummyCounter: Sendable {
    func value() async -> Int
    func increment() async -> Int
    func reset() async
}

/// The contract suite of `DummyCounter`.
public enum DummyCounterContract {
    /// Runs every check of the contract against counters made by `makeCounter`.
    public static func run(
        _ makeCounter: @Sendable () -> any DummyCounter,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let counter = makeCounter()
        #expect(await counter.value() == 0, "A new counter starts at zero.", sourceLocation: sourceLocation)
        #expect(await counter.increment() == 1, sourceLocation: sourceLocation)
        #expect(await counter.increment() == 2, sourceLocation: sourceLocation)
        #expect(await counter.value() == 2, sourceLocation: sourceLocation)
        await counter.reset()
        #expect(await counter.value() == 0, "Reset returns the counter to zero.", sourceLocation: sourceLocation)

        let other = makeCounter()
        _ = await counter.increment()
        #expect(await other.value() == 0, "Each counter the factory makes is its own.", sourceLocation: sourceLocation)
    }
}
