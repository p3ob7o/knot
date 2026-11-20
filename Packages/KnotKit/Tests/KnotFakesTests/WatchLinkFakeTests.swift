import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct ScriptedWatchLinkTests {
    @Test(.tags(.contract)) func theContract() async throws {
        try await WatchLinkContract.run {
            let link = ScriptedWatchLink()
            let missing = URL(fileURLWithPath: "/outbox/missing.m4a")
            link.markMissing(missing)
            return WatchLinkSubject(
                link: link, makeFile: { URL(fileURLWithPath: "/outbox/\($0).m4a") }, missingFile: missing,
                finishTransfer: { link.finishTransfer($0) }, acknowledge: { link.acknowledge($0) },
                failTransfer: { link.failTransfer($0, with: $1) }, queueCount: { link.queueCount($0) })
        }
    }

    /// The background task with work still pending ends at its limit, and says so.
    @Test func aBackgroundTaskEndsAtItsLimit() async throws {
        let link = ScriptedWatchLink()
        let capture: CaptureID = Identifier(uuid: UUID())
        try await link.send(WatchLinkContract.manifest(capture), file: URL(fileURLWithPath: "/outbox/a.m4a"))
        #expect(await link.runBackgroundTask(limit: .milliseconds(20)) == false)
        await link.resume(.launch)
        #expect(link.triggers == [.launch])
    }
}
