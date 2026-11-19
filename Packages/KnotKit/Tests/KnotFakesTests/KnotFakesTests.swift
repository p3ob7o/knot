import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@Test func moduleNameIsTheOneTheReleaseCheckLooksFor() {
    #expect(String(reflecting: KnotFakes.self) == "\(KnotFakes.moduleName).KnotFakes")
}

/// A second implementation of the dummy port, so that the contract suite runs from two
/// test targets (named test `contract-suite-dummy-port-two-test-targets`).
final class LockedCounter: DummyCounter {
    private let count = Mutex(0)

    func value() -> Int { count.withLock { $0 } }

    func increment() -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }

    func reset() { count.withLock { $0 = 0 } }
}

@Test("contract-suite-dummy-port-two-test-targets", .tags(.named, .contract))
func contractSuiteDummyPortTwoTestTargets() async {
    await DummyCounterContract.run { LockedCounter() }
}
