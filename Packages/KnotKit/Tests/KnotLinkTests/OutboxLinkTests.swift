import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The Watch's link over the fake transport (docs/architecture.md §12): a capture leaves the
/// outbox only on its acknowledgement, whatever the network loses, repeats or reorders.
@Suite struct OutboxLinkTests {
    // MARK: Delivery

    @Test func aCaptureLeavesTheOutboxOnlyOnItsAcknowledgement() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        #expect(harness.inOutbox(capture), "Sending returns once the capture is in the outbox.")
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        // A transfer that finishes without arriving is not a delivery.
        harness.system.finish(capture, as: .neverArrives)
        await eventually("the capture waiting again") { await link.states()[capture] == .waiting }
        #expect(harness.inOutbox(capture))

        await link.resume()
        harness.system.finish(capture, as: .arrives)
        await SuiteWait.until("the acknowledged capture removed") { !harness.inOutbox(capture) }
        #expect(harness.phone.acknowledged(capture))
        await SuiteWait.until("the acknowledgement reported") { harness.acknowledgementsSeen == [capture] }
        #expect(await link.currentCounts() == (waiting: 0, failed: 0))
    }

    @Test func sendingDoesNotWaitForTheSession() async throws {
        let harness = LinkHarness()
        harness.system.activatesByItself = false
        let (link, _) = harness.launchWatch()
        let capture = try #require(
            await SuiteWait.value("the send") { try? await harness.sendNew(on: link) }.flatMap { $0 })
        #expect(harness.inOutbox(capture))
        #expect(harness.system.timesQueued(capture) == 0, "Nothing is queued before the activation callback.")
        #expect(await link.currentCounts() == (waiting: 1, failed: 0))

        harness.system.completeActivation(.watch)
        await SuiteWait.until("the capture queued after activation") { harness.system.timesQueued(capture) == 1 }
    }

    @Test func afterActivationASendQueuesBeforeItReturns() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        await link.resume()
        let capture = try await harness.sendNew(on: link)
        #expect(harness.system.timesQueued(capture) == 1)
        #expect(await link.states()[capture] == .queued(attempt: 1))
        await link.resume()
        #expect(harness.system.timesQueued(capture) == 1, "An outstanding capture is not queued twice.")
    }

    // MARK: Loss, duplication and reordering

    @Test func aLostAcknowledgementSendsTheCaptureAgain() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.system.finish(capture, as: .arrives)
        #expect(harness.phone.acknowledged(capture))
        // The end arrives; the acknowledgement is lost.
        harness.system.releaseHeld { events in
            events.filter { if case .message = $0 { false } else { true } }
        }
        await eventually("the capture waiting") { await link.states()[capture] == .waiting }
        #expect(harness.inOutbox(capture), "Without its acknowledgement the capture stays.")

        await link.resume()
        await SuiteWait.until("the capture queued again") { harness.system.timesQueued(capture) == 2 }
        harness.system.finish(capture, as: .arrives)
        harness.system.releaseHeld()
        await SuiteWait.until("the capture removed") { !harness.inOutbox(capture) }
        #expect(harness.phone.intactArrivals(capture) == 2, "The duplicate is harmless: ingest is idempotent.")
    }

    @Test func aLostEndIsQueuedAgainOnTheNextTrigger() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.system.finish(capture, as: .neverArrives)
        harness.system.releaseHeld { _ in [] }
        await link.resume()
        #expect(harness.system.timesQueued(capture) == 2, "A transfer gone from the session's queue is queued again.")
        #expect(harness.inOutbox(capture))
    }

    @Test func repeatedEventsChangeNothing() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.system.finish(capture, as: .arrives)
        harness.system.releaseHeld { events in events + events + events }
        await SuiteWait.until("the capture removed") { !harness.inOutbox(capture) }
        await link.resume()
        await SuiteWait.until("the acknowledgement reported") { !harness.acknowledgementsSeen.isEmpty }
        #expect(harness.acknowledgementsSeen == [capture], "One acknowledgement is reported, once.")
        #expect(harness.system.timesQueued(capture) == 1, "An acknowledged capture is never queued again.")
    }

    @Test func reorderedEventsChangeNothing() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let first = try await harness.sendNew(on: link)
        let second = try await harness.sendNew(on: link)
        await SuiteWait.until("both queued") { harness.system.outstanding().count == 2 }

        harness.system.finish(first, as: .arrives)
        harness.system.finish(second, as: .arrives)
        // Every acknowledgement before every end, the second capture's first.
        harness.system.releaseHeld { events in events.reversed() }
        await SuiteWait.until("both removed") { !harness.inOutbox(first) && !harness.inOutbox(second) }
        await link.resume()
        await SuiteWait.until("both acknowledgements reported") { harness.acknowledgementsSeen.count >= 2 }
        #expect(Set(harness.acknowledgementsSeen) == [first, second])
        #expect(harness.system.timesQueued(first) == 1 && harness.system.timesQueued(second) == 1)
    }

    @Test func anAcknowledgementCancelsATransferStillUnderWay() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }
        harness.system.finish(capture, as: .arrives)
        harness.system.releaseHeld { events in events.filter { if case .message = $0 { false } else { true } } }
        await eventually("the capture waiting") { await link.states()[capture] == .waiting }
        await link.resume()
        await SuiteWait.until("the capture queued again") { harness.system.outstanding().count == 1 }

        // The first acknowledgement arrives late, while the second transfer is under way.
        harness.phone.transport.send(.acknowledgement(capture))
        harness.system.releaseHeld()
        await SuiteWait.until("the capture removed") { !harness.inOutbox(capture) }
        await SuiteWait.until("the transfer cancelled") { harness.system.outstanding().isEmpty }
        #expect(harness.system.timesCancelled(capture) == 1)
    }

    // MARK: Failures

    @Test(arguments: [LinkFailure.linkNotReady, .counterpartMissing, .counterpartFull])
    func aDeferralWaitsForTheNextTrigger(_ failure: LinkFailure) async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.system.finish(capture, as: .fails(failure))
        await eventually("the capture waiting") { await link.states()[capture] == .waiting }
        #expect(harness.system.timesQueued(capture) == 1, "A deferral is not queued again at once.")
        #expect(await link.currentCounts() == (waiting: 1, failed: 0), "A deferral shows as waiting.")

        await link.resume()
        #expect(harness.system.timesQueued(capture) == 2)
    }

    @Test func aFailedDeliveryIsQueuedAgainAtOnce() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.system.finish(capture, as: .fails(.deliveryFailed))
        await SuiteWait.until("the capture queued again") { harness.system.timesQueued(capture) == 2 }
        #expect(await link.states()[capture] == .queued(attempt: 2))
    }

    @Test func aMissingFileFailsTheCaptureAndKeepsItsManifest() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        try FileManager.default.removeItem(at: harness.outbox.recordingURL(capture))
        harness.system.finish(capture, as: .arrives)
        await eventually("the capture failed") { await link.states()[capture] == .failed }
        #expect(FileManager.default.fileExists(atPath: harness.outbox.manifestURL(capture).path))
        #expect(await link.currentCounts() == (waiting: 0, failed: 1))
        await link.resume()
        #expect(harness.system.timesQueued(capture) == 1, "A capture with no file is never queued again.")
    }

    @Test func theTransportsReportOfAnUnreadableFileFailsTheCapture() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.system.finish(capture, as: .fails(.outboxFileMissing))
        await eventually("the capture failed") { await link.states()[capture] == .failed }
        await link.resume()
        #expect(harness.system.timesQueued(capture) == 1)
        #expect(harness.inOutbox(capture))
    }

    // MARK: Relaunch

    @Test func aRelaunchAdoptsOutstandingTransfersAndQueuesNoDuplicate() async throws {
        let harness = LinkHarness()
        let (first, _) = harness.launchWatch()
        var captures: [CaptureID] = []
        for _ in 0..<3 { captures.append(try await harness.sendNew(on: first)) }
        await SuiteWait.until("all queued") { harness.system.outstanding().count == 3 }

        let (relaunched, _) = harness.launchWatch()
        await relaunched.resume()
        for capture in captures {
            #expect(harness.system.timesQueued(capture) == 1, "A capture still outstanding is never queued again.")
            #expect(await relaunched.states()[capture] == .queued(attempt: 1))
        }

        harness.system.finishAll(as: .arrives)
        let sent = captures
        await SuiteWait.until("all removed") { sent.allSatisfy { !harness.inOutbox($0) } }
    }

    @Test func endsThatCameWhileTheAppWasNotRunningArriveAfterActivation() async throws {
        let harness = LinkHarness()
        let (first, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: first)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.system.activatesByItself = false
        let (relaunched, _) = harness.launchWatch()
        // The transfer finishes while the new launch has not activated.
        harness.system.finish(capture, as: .arrives)
        #expect(harness.inOutbox(capture))
        let resumed = Task { await relaunched.resume() }
        harness.system.completeActivation(.watch)
        await resumed.value
        await SuiteWait.until("the capture removed") { !harness.inOutbox(capture) }
        #expect(harness.phone.intactArrivals(capture) == 1)
    }

    @Test func aRelaunchQueuesWhatWasNeverQueued() async throws {
        let harness = LinkHarness()
        harness.system.activatesByItself = false
        let (first, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: first)
        // The app died before the session activated.
        harness.system.activatesByItself = true
        let (relaunched, _) = harness.launchWatch()
        await relaunched.resume()
        #expect(harness.system.timesQueued(capture) == 1)
    }

    // MARK: Stalls

    @Test func aStalledTransferIsCancelledAndQueuedAgain() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch(stallLimit: 60)
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        harness.clock.advance(by: 30)
        await link.resume()
        #expect(harness.system.timesCancelled(capture) == 0, "Not yet stalled.")

        harness.clock.advance(by: 31)
        await link.resume()
        #expect(harness.system.timesCancelled(capture) == 1)
        #expect(harness.system.timesQueued(capture) == 2)
        #expect(harness.system.outstanding().map(\.attempt) == [2])
    }

    @Test func noTransferStallsWhileTheIPhoneIsOutOfReach() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch(stallLimit: 60)
        let capture = try await harness.sendNew(on: link)
        await SuiteWait.until("the capture queued") { harness.system.outstanding().count == 1 }

        var away = LinkSessionState.ready
        away.isReachable = false
        harness.system.setState(away, of: .watch)
        harness.clock.advance(by: 3_600)
        await eventually("the state seen") { await link.states()[capture] != nil }
        await link.resume()
        #expect(harness.system.timesCancelled(capture) == 0)
    }

    // MARK: Background task and context

    @Test func theBackgroundTaskEndsWhenNothingIsPending() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let done = await SuiteWait.value("the background task") { await link.runBackgroundTask(limit: SuiteWait.limit) }
        #expect(done == true)
    }

    @Test func theBackgroundTaskStopsAtItsLimitWhileContentIsPending() async throws {
        let harness = LinkHarness()
        var pending = LinkSessionState.ready
        pending.hasContentPending = true
        harness.system.setState(pending, of: .watch)
        let (link, _) = harness.launchWatch()
        let done = await SuiteWait.value("the background task") {
            await link.runBackgroundTask(limit: .milliseconds(100))
        }
        #expect(done == false)
    }

    @Test func theContextIsReadAtActivationAndFollowsUpdates() async throws {
        let harness = LinkHarness()
        let ended = harness.clock.now()
        harness.system.pushContext(LinkContext(joinableCaptureEndedAt: ended, window: .default))
        let (link, _) = harness.launchWatch()
        await link.resume()
        let context = try #require(await link.latestContext())
        #expect(context.continuesNote(at: ended.addingTimeInterval(60)))
        #expect(!context.continuesNote(at: ended.addingTimeInterval(301)))

        harness.system.pushContext(LinkContext(joinableCaptureEndedAt: nil, window: .default))
        await eventually("the new context") { await link.latestContext()?.joinableCaptureEndedAt == nil }
        #expect(await link.latestContext()?.continuesNote(at: ended) == false, "A note closed by New note gives none.")
    }

    // MARK: Named

    /// docs/architecture.md §12, "Checksums", the Watch's half: a file that arrives damaged is
    /// not acknowledged, so it stays in the outbox, shown as waiting and not as failed, and is
    /// sent again on the next trigger until an intact copy is acknowledged.
    @Test("checksum-mismatch-from-the-watch", .tags(.named))
    func checksumMismatchFromTheWatch() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)

        for round in 1...3 {
            await SuiteWait.until("attempt \(round) queued") { harness.system.timesQueued(capture) == round }
            harness.system.finish(capture, as: .arrivesDamaged)
            await eventually("the capture waiting after mismatch \(round)") {
                await link.states()[capture] == .waiting
            }
            #expect(harness.inOutbox(capture), "A mismatch is never acknowledged.")
            #expect(await link.currentCounts() == (waiting: 1, failed: 0), "It shows as not delivered.")
            await link.resume()
        }
        #expect(harness.phone.damagedArrivals(capture) == 3)

        await SuiteWait.until("attempt 4 queued") { harness.system.timesQueued(capture) == 4 }
        harness.system.finish(capture, as: .arrives)
        await SuiteWait.until("the intact copy acknowledged") { !harness.inOutbox(capture) }
        #expect(harness.phone.intactArrivals(capture) == 1)
    }
}
