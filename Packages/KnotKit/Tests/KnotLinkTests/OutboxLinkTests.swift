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
        await harness.settle(link)
        #expect(harness.outstanding(capture).count == 1)

        // A transfer that finishes without arriving is not a delivery.
        harness.system.finish(capture, as: .neverArrives)
        await harness.settle(link)
        #expect(await link.states()[capture] == .waiting)
        #expect(harness.inOutbox(capture))

        await link.resume()
        await harness.settle(link)
        harness.system.finish(capture, as: .arrives)
        await harness.settle(link)
        #expect(!harness.inOutbox(capture), "The acknowledged capture is removed.")
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
        await harness.settle(link)
        #expect(harness.outstanding(capture).count == 1, "Queued once the session activated.")
    }

    @Test func afterActivationASendQueuesBeforeItReturns() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        await link.resume()
        let capture = try await harness.sendNew(on: link)
        let queued = try #require(harness.outstanding(capture).first, "Queued before the send returned.")
        #expect(await link.states()[capture] == .queued(attempt: queued.attempt))
        await link.resume()
        await harness.settle(link)
        #expect(harness.outstanding(capture) == [queued], "An outstanding capture is not queued twice.")
    }

    // MARK: Loss, duplication and reordering

    @Test func aLostAcknowledgementSendsTheCaptureAgain() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)

        harness.system.finish(capture, as: .arrives)
        #expect(harness.phone.acknowledged(capture))
        // The end arrives; the acknowledgement is lost.
        harness.system.releaseHeld { events in
            events.filter { if case .message = $0 { false } else { true } }
        }
        await harness.settle(link)
        #expect(await link.states()[capture] == .waiting)
        #expect(harness.inOutbox(capture), "Without its acknowledgement the capture stays.")

        await link.resume()
        await harness.settle(link)
        #expect(harness.outstanding(capture).count == 1, "Queued again on the next trigger.")
        harness.system.finish(capture, as: .arrives)
        harness.system.releaseHeld()
        await harness.settle(link)
        #expect(!harness.inOutbox(capture))
        #expect(harness.phone.intactArrivals(capture) == 2, "The duplicate is harmless: ingest is idempotent.")
    }

    @Test func aLostEndIsQueuedAgainOnTheNextTrigger() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        let first = try #require(harness.outstanding(capture).first)

        harness.system.finish(capture, as: .neverArrives)
        harness.system.releaseHeld { _ in [] }
        await link.resume()
        await harness.settle(link)
        let again = try #require(harness.outstanding(capture).first, "A transfer gone from the queue is queued again.")
        #expect(again.attempt != first.attempt)
        #expect(harness.inOutbox(capture))
    }

    @Test func repeatedEventsChangeNothing() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)

        harness.system.finish(capture, as: .arrives)
        harness.system.releaseHeld { events in events + events + events }
        await harness.settle(link)
        #expect(!harness.inOutbox(capture))
        await link.resume()
        await harness.settle(link)
        await SuiteWait.until("the acknowledgement reported") { !harness.acknowledgementsSeen.isEmpty }
        #expect(harness.acknowledgementsSeen == [capture], "One acknowledgement is reported, once.")
        #expect(harness.outstanding(capture).isEmpty, "An acknowledged capture is never queued again.")
    }

    @Test func reorderedEventsChangeNothing() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let first = try await harness.sendNew(on: link)
        let second = try await harness.sendNew(on: link)
        await harness.settle(link)
        #expect(harness.system.outstanding().count == 2)

        harness.system.finish(first, as: .arrives)
        harness.system.finish(second, as: .arrives)
        // Every acknowledgement before every end, the second capture's first.
        harness.system.releaseHeld { events in events.reversed() }
        await harness.settle(link)
        #expect(!harness.inOutbox(first) && !harness.inOutbox(second))
        await link.resume()
        await harness.settle(link)
        await SuiteWait.until("both acknowledgements reported") { harness.acknowledgementsSeen.count >= 2 }
        #expect(Set(harness.acknowledgementsSeen) == [first, second])
        #expect(harness.system.outstanding().isEmpty, "Neither is queued again.")
    }

    @Test func anAcknowledgementCancelsATransferStillUnderWay() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        harness.system.finish(capture, as: .arrives)
        harness.system.releaseHeld { events in events.filter { if case .message = $0 { false } else { true } } }
        await harness.settle(link)
        #expect(await link.states()[capture] == .waiting)
        await link.resume()
        await harness.settle(link)
        #expect(harness.outstanding(capture).count == 1)

        // The first acknowledgement arrives late, while the second transfer is under way.
        harness.phone.transport.send(.acknowledgement(capture))
        harness.system.releaseHeld()
        await harness.settle(link)
        #expect(!harness.inOutbox(capture))
        #expect(harness.outstanding(capture).isEmpty, "The transfer under way is cancelled.")
        #expect(harness.system.timesCancelled(capture) >= 1)
    }

    // MARK: Failures

    @Test(arguments: [LinkFailure.linkNotReady, .counterpartMissing, .counterpartFull])
    func aDeferralWaitsForTheNextTrigger(_ failure: LinkFailure) async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)

        harness.system.finish(capture, as: .fails(failure))
        await harness.settle(link)
        #expect(await link.states()[capture] == .waiting)
        #expect(harness.outstanding(capture).isEmpty, "A deferral is not queued again at once.")
        #expect(await link.currentCounts() == (waiting: 1, failed: 0), "A deferral shows as waiting.")

        await link.resume()
        await harness.settle(link)
        #expect(harness.outstanding(capture).count == 1, "Queued again on the next trigger.")
    }

    @Test func aFailedDeliveryIsQueuedAgainAtOnce() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        let first = try #require(harness.outstanding(capture).first)

        harness.system.finish(capture, as: .fails(.deliveryFailed))
        await harness.settle(link)
        let again = try #require(harness.outstanding(capture).first, "Queued again without a trigger.")
        #expect(again.attempt != first.attempt)
        #expect(await link.states()[capture] == .queued(attempt: again.attempt))
    }

    /// A transfer's end matches the attempt it names: the end of an earlier attempt, repeated
    /// by the network, never ends the attempt that replaced it.
    @Test func aRepeatedEndOfAnEarlierAttemptDoesNotEndTheCurrentOne() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        await link.resume()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        let first = try #require(harness.outstanding(capture).first)

        harness.system.finish(capture, attempt: first.attempt, as: .fails(.deliveryFailed))
        harness.system.releaseHeld { events in events + events + events }
        await harness.settle(link)
        let current = harness.outstanding(capture)
        #expect(current.count == 1, "One transfer of a capture at a time: \(current)")
        #expect(current.first?.attempt != first.attempt)
        #expect(await link.states()[capture] == .queued(attempt: current.first?.attempt ?? -1))
    }

    @Test func aMissingFileFailsTheCaptureAndKeepsItsManifest() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)

        try FileManager.default.removeItem(at: harness.outbox.recordingURL(capture))
        harness.system.finish(capture, as: .arrives)
        await harness.settle(link)
        #expect(await link.states()[capture] == .failed)
        #expect(FileManager.default.fileExists(atPath: harness.outbox.manifestURL(capture).path))
        #expect(await link.currentCounts() == (waiting: 0, failed: 1))
        await link.resume()
        await harness.settle(link)
        #expect(harness.outstanding(capture).isEmpty, "A capture with no file is never queued again.")
    }

    @Test func theTransportsReportOfAnUnreadableFileFailsTheCapture() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)

        harness.system.finish(capture, as: .fails(.outboxFileMissing))
        await harness.settle(link)
        #expect(await link.states()[capture] == .failed)
        await link.resume()
        await harness.settle(link)
        #expect(harness.outstanding(capture).isEmpty)
        #expect(harness.inOutbox(capture))
    }

    // MARK: Relaunch

    @Test func aRelaunchAdoptsOutstandingTransfersAndQueuesNoDuplicate() async throws {
        let harness = LinkHarness()
        let (first, _) = harness.launchWatch()
        var captures: [CaptureID] = []
        for _ in 0..<3 { captures.append(try await harness.sendNew(on: first)) }
        await harness.settle(first)
        let before = harness.system.outstanding()
        #expect(before.count == 3)

        let (relaunched, _) = harness.launchWatch()
        await relaunched.resume()
        await harness.settle(relaunched)
        #expect(harness.system.outstanding() == before, "A capture still outstanding is never queued again.")
        for file in before {
            #expect(await relaunched.states()[file.captureID] == .queued(attempt: file.attempt))
        }

        harness.system.finishAll(as: .arrives)
        await harness.settle(relaunched)
        #expect(captures.allSatisfy { !harness.inOutbox($0) })
    }

    @Test func endsThatCameWhileTheAppWasNotRunningArriveAfterActivation() async throws {
        let harness = LinkHarness()
        let (first, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: first)
        await harness.settle(first)

        harness.system.activatesByItself = false
        let (relaunched, _) = harness.launchWatch()
        // The transfer finishes while the new launch has not activated.
        harness.system.finish(capture, as: .arrives)
        #expect(harness.inOutbox(capture))
        let resumed = Task { await relaunched.resume() }
        harness.system.completeActivation(.watch)
        await resumed.value
        await harness.settle(relaunched)
        #expect(!harness.inOutbox(capture))
        #expect(harness.phone.intactArrivals(capture) == 1)
    }

    /// docs/notes/SP-2.md: the ends of transfers that finished while the app was not running
    /// arrive at the next launch, after activation. Such an end names an earlier launch's
    /// transfer, never the one this launch queued for the same capture.
    @Test(arguments: [LinkFailure.deliveryFailed, .outboxFileMissing])
    func anEndFromAnEarlierLaunchIsNotTakenForThisLaunchsTransfer(_ failure: LinkFailure) async throws {
        let harness = LinkHarness()
        let (first, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: first)
        await harness.settle(first)
        let earlier = try #require(harness.outstanding(capture).first)

        // The app dies; the transfer fails while it is not running, and its end waits.
        harness.system.holdsEvents = true
        let (second, _) = harness.launchWatch()
        harness.system.finish(capture, attempt: earlier.attempt, as: .fails(failure))
        await second.resume()
        await harness.settle(second)
        let current = try #require(harness.outstanding(capture).first, "This launch queued the capture again.")

        // The earlier launch's end arrives straight after activation.
        harness.system.releaseHeld()
        await harness.settle(second)
        #expect(harness.outstanding(capture) == [current], "One transfer of a capture at a time.")
        #expect(await second.states()[capture] == .queued(attempt: current.attempt))
        #expect(await second.currentCounts() == (waiting: 1, failed: 0))
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
        await harness.settle(relaunched)
        #expect(harness.outstanding(capture).count == 1)
    }

    // MARK: Stalls

    @Test func aStalledTransferIsCancelledAndQueuedAgain() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch(stallLimit: 60)
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        let first = try #require(harness.outstanding(capture).first)

        harness.clock.advance(by: 30)
        await link.resume()
        await harness.settle(link)
        #expect(harness.system.timesCancelled(capture) == 0, "Not yet stalled.")
        #expect(harness.outstanding(capture) == [first])

        harness.clock.advance(by: 31)
        await link.resume()
        await harness.settle(link)
        #expect(harness.system.timesCancelled(capture) >= 1)
        let again = try #require(harness.outstanding(capture).first)
        #expect(harness.outstanding(capture).count == 1 && again.attempt != first.attempt)
    }

    @Test func noTransferStallsWhileTheIPhoneIsOutOfReach() async throws {
        let harness = LinkHarness()
        let (link, _) = harness.launchWatch(stallLimit: 60)
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        let queued = try #require(harness.outstanding(capture).first)

        var away = LinkSessionState.ready
        away.isReachable = false
        harness.system.setState(away, of: .watch)
        // Quiet means the link has handled the change of reachability.
        await harness.settle(link)
        harness.clock.advance(by: 3_600)
        await link.resume()
        await harness.settle(link)
        #expect(harness.system.timesCancelled(capture) == 0)
        #expect(harness.outstanding(capture) == [queued])

        // Back in reach, the same transfer has stalled.
        harness.system.setState(.ready, of: .watch)
        await harness.settle(link)
        await link.resume()
        await harness.settle(link)
        #expect(harness.system.timesCancelled(capture) >= 1)
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

    /// The forecast follows the append rule's own window: a gap negative by less than the
    /// window, as when the two clocks are slightly apart, continues the note, as the iPhone
    /// will decide (docs/product-spec.md §3).
    @Test func theForecastFollowsTheWindowsOwnRule() {
        let ended = Date(timeIntervalSince1970: 1_795_000_000)
        let context = LinkContext(joinableCaptureEndedAt: ended, window: .default)
        for gap: TimeInterval in [-299, -60, -1, 0, 1, 60, 299, -300, 300, -301, 301, 3_600] {
            #expect(
                context.continuesNote(at: ended.addingTimeInterval(gap)) == AppendWindow.default.contains(gap: gap),
                "A gap of \(gap) seconds.")
        }
        #expect(!LinkContext(joinableCaptureEndedAt: ended, window: .off).continuesNote(at: ended))
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
            await harness.settle(link)
            #expect(harness.outstanding(capture).count == 1, "Round \(round): queued.")
            harness.system.finish(capture, as: .arrivesDamaged)
            await harness.settle(link)
            #expect(await link.states()[capture] == .waiting, "Round \(round): waiting.")
            #expect(harness.inOutbox(capture), "A mismatch is never acknowledged.")
            #expect(await link.currentCounts() == (waiting: 1, failed: 0), "It shows as not delivered.")
            await link.resume()
        }
        #expect(harness.phone.damagedArrivals(capture) == 3)

        await harness.settle(link)
        #expect(harness.outstanding(capture).count == 1)
        harness.system.finish(capture, as: .arrives)
        await harness.settle(link)
        #expect(!harness.inOutbox(capture), "The intact copy is acknowledged.")
        #expect(harness.phone.intactArrivals(capture) == 1)
    }
}
