import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// `OutboxLink` passes the `WatchLink` contract suite over the fake transport, on the Mac
/// (docs/architecture.md §5).
@Suite struct WatchLinkContractTests {
    @Test(.tags(.contract)) func outboxLinkPassesTheWatchLinkContract() async throws {
        try await WatchLinkContract.run {
            let harness = LinkHarness()
            let (link, _) = harness.launchWatch()
            await link.resume(.launch)
            return WatchLinkSubject(
                link: link,
                makeFile: { capture in
                    let url = harness.locations.convertedRecording(capture)
                    try harness.files.place(Data("synthetic \(capture)".utf8), at: url)
                    return url
                },
                missingFile: harness.root.appending(path: "missing.m4a", directoryHint: .notDirectory),
                finishTransfer: { capture in
                    harness.system.finish(capture, as: .neverArrives)
                    await harness.settle(link)
                },
                acknowledge: { capture in
                    harness.phone.transport.send(.acknowledgement(capture))
                    await harness.settle(link)
                },
                failTransfer: { capture, error in
                    guard let failure = LinkFailure(rawValue: error.code.rawValue) else {
                        Issue.record("Not a case of the link: \(error.code).")
                        return
                    }
                    harness.system.finish(capture, as: .fails(failure))
                    await harness.settle(link)
                },
                queueCount: { capture in harness.system.timesQueued(capture) })
        }
    }

    @Test func aSendOfAFileThatIsNotThereFailsWithOutboxFileMissing() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        await link.resume(.launch)
        let (manifest, url) = try harness.convertedRecording()
        try FileManager.default.removeItem(at: url)
        let error = await #expect(throws: KnotError.self) { try await link.send(manifest, file: url) }
        #expect(error?.code == KnotError.outboxFileMissing.code)
        #expect(error?.context.captureID == manifest.captureID)
        #expect(harness.system.timesQueued(manifest.captureID) == 0)
        #expect(!harness.inOutbox(manifest.captureID))
    }

    @Test func aNewSendOfAFailedCaptureReplacesItsRecording() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        await link.resume(.launch)
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        harness.system.finish(capture, as: .fails(.outboxFileMissing))
        await harness.settle(link)
        #expect(await link.states()[capture] == .failed)

        let fresh = Data("a fresh copy".utf8)
        let (manifest, url) = try harness.convertedRecording(bytes: fresh)
        var again = manifest
        again.captureID = capture
        try harness.files.move(url, to: harness.locations.convertedRecording(capture))
        try await link.send(again, file: harness.locations.convertedRecording(capture))
        await harness.settle(link)
        #expect(try Data(contentsOf: harness.outbox.recordingURL(capture)) == fresh)
        #expect(harness.outbox.entry(capture)?.manifest?.payloadSHA256 == sha256(fresh))
        let state = await link.states()[capture]
        #expect(state != .failed && state != nil, "It waits again.")
    }
}

/// The live entry point: the iPhone keeps the unavailable link; the Watch's composition wires
/// an `OutboxLink` over its transport, and the coordinator over it.
@Suite struct KnotLinkLiveTests {
    @Test func wireLeavesTheUnavailableLinkAndTheWatchsOverloadWiresTheOutbox() async throws {
        let plain = KnotLinkLive.wire(.unavailable)
        #expect(plain.watchLink is UnavailableWatchLink)
        #expect(
            KnotLinkLive.coordinator(for: plain, launchID: Identifier(uuid: UUID()), device: Identifier(uuid: UUID()))
                == nil)

        let harness = LinkHarness()
        let wired = KnotLinkLive.wire(
            .unavailable, locations: harness.locations, transport: harness.system.launch(.watch))
        let link = try #require(wired.watchLink as? OutboxLink)
        #expect(link.outbox.locations == harness.locations)
        await link.resume(.launch)
        let (manifest, url) = try harness.convertedRecording()
        try await wired.watchLink.send(manifest, file: url)
        #expect(harness.inOutbox(manifest.captureID))
        #expect(
            KnotLinkLive.coordinator(for: wired, launchID: Identifier(uuid: UUID()), device: Identifier(uuid: UUID()))
                != nil)
    }
}
