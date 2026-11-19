import KnotTestSupport
import Testing

/// The first implementation of the dummy port. KnotFakesTests holds the second.
actor ActorCounter: DummyCounter {
    private var count = 0

    func value() -> Int { count }

    func increment() -> Int {
        count += 1
        return count
    }

    func reset() { count = 0 }
}

@Test("contract-suite-dummy-port-two-test-targets", .tags(.named, .contract))
func contractSuiteDummyPortTwoTestTargets() async {
    await DummyCounterContract.run { ActorCounter() }
}
