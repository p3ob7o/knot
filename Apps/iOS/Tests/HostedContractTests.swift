import KnotTestSupport
import Testing

/// The dummy port's contract suite, run hosted in the app in the iOS Simulator. It proves
/// the arrangement for the suites that can run only there (docs/architecture.md §5).
actor HostedCounter: DummyCounter {
    private var count = 0

    func value() -> Int { count }

    func increment() -> Int {
        count += 1
        return count
    }

    func reset() { count = 0 }
}

@Test(.tags(.contract))
func dummyContractRunsHostedInTheApp() async {
    await DummyCounterContract.run { HostedCounter() }
}
