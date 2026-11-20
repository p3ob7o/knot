import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct ScriptedSyncEngineTests {
    @Test(.tags(.contract)) func theContract() async throws {
        try await SyncEngineContract.run {
            let engine = ScriptedSyncEngine(clock: FakeClock())
            return SyncEngineSubject(
                engine: engine, setPending: { engine.setPending($0) }, pause: { engine.pause($0) },
                failNextSync: { engine.failNextSyncs(with: $0) },
                zoneMissingOnNextSend: { engine.zoneMissingOnNextSend($0) },
                pauseDuringNextSync: { engine.pauseDuringNextSync($0) }, deliverLateEvent: { engine.deliverLateEvent() }
            )
        }
    }
}
