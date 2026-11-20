import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The order of late ends, from the re-check of findings 22 to 24 (review findings 26 and 27):
/// the memory of attempts the link gave up, every mix of three attempts' ends in every order of
/// arrival, and two captures at once. Synthetic content only.
@Suite struct LateEndOrderTests {
    enum End: String, CaseIterable, Sendable {
        case missing, deferral, failedDelivery, clean, unended

        var fate: FakeLinkSystem.Fate? {
            switch self {
            case .missing: .fails(.outboxFileMissing)
            case .deferral: .fails(.counterpartFull)
            case .failedDelivery: .fails(.deliveryFailed)
            case .clean: .neverArrives
            case .unended: nil
            }
        }

        var speaks: Bool { self == .missing || self == .clean }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var ends: [End]  // A, B, C
        var order: [Int]  // indices into the held ends, in the order they arrive
        var testDescription: String { "A=\(ends[0]) B=\(ends[1]) C=\(ends[2]) order=\(order)" }
    }

    static let permutations3 = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

    /// Every mix of A and B in {missing, deferral, clean} and of C in {missing, deferral, failed
    /// delivery, clean, unended}, in every order of arrival of the ends that happen.
    static let cases: [Case] = {
        var all: [Case] = []
        let ab: [End] = [.missing, .deferral, .clean]
        for a in ab {
            for b in ab {
                for c in [End.missing, .deferral, .failedDelivery, .clean, .unended] {
                    let orders = c == .unended ? [[0, 1], [1, 0]] : permutations3
                    for order in orders { all.append(Case(ends: [a, b, c], order: order)) }
                }
            }
        }
        return all
    }()

    /// Two resumes give up A then B; C is queued last. The ends arrive in every order. By
    /// settled point 3 the newest attempt whose end speaks of the file decides: failed when it
    /// says "missing", not failed when it read the file or when none spoke.
    @Test(arguments: cases)
    func recheckIThreeAttemptsInEveryOrderLeaveTheSameState(_ c: Case) async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        try #require(harness.system.finish(capture, as: c.ends[0].fate!))  // A
        await link.resume()
        await harness.settle(link)
        try #require(harness.outstanding(capture).count == 1)
        try #require(harness.system.finish(capture, as: c.ends[1].fate!))  // B
        await link.resume()
        await harness.settle(link)
        try #require(harness.outstanding(capture).count == 1)  // C
        if let fate = c.ends[2].fate { try #require(harness.system.finish(capture, as: fate)) }
        let ended = c.ends[2] == .unended ? 2 : 3
        try #require(harness.system.held().count == ended)

        harness.system.releaseHeld { events in c.order.map { events[$0] } }
        await harness.settle(link)

        let newestSpeaking = c.ends.prefix(ended).last(where: \.speaks)
        let shouldFail = newestSpeaking == .missing
        let state = await link.states()[capture]
        if shouldFail {
            #expect(state == .failed, "\(c.testDescription)")
            #expect(harness.outstanding(capture).isEmpty, "\(c.testDescription)")
        } else {
            #expect(state != .failed, "\(c.testDescription): a later attempt read the file, or none spoke")
            await link.resume()
            await harness.settle(link)
            #expect(harness.outstanding(capture).count == 1, "\(c.testDescription): it is sent again")
        }
    }

    /// The smallest form: A ends "missing", B read the file, C is still under way. A's end
    /// arrives first. B is newer than A and read the file, so the capture must not fail.
    @Test func recheckIALateMissingDoesNotForgetANewerAttemptThatReadTheFile() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        harness.system.finish(capture, as: .fails(.outboxFileMissing))  // A
        await link.resume()
        await harness.settle(link)
        harness.system.finish(capture, as: .neverArrives)  // B, which read the file
        await link.resume()
        await harness.settle(link)
        try #require(harness.outstanding(capture).count == 1)  // C, under way
        harness.system.releaseHeld()  // A's end, then B's
        await harness.settle(link)
        #expect(await link.states()[capture] != .failed, "B, newer than A, read the file.")
    }

    /// The order of attempts never rests on the wall clock. The Watch's clock is set back between
    /// two launches: X is queued by the first, adopted and given up by the second, which queues Y.
    /// Y read the file and X's late end says "missing". Y, made by this launch, is the newer.
    @Test(arguments: [false, true])
    func recheckIAnAttemptQueuedAfterTheClockWentBackIsStillTheNewer(_ reversed: Bool) async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (first, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: first)
        await harness.settle(first)
        try #require(harness.outstanding(capture).count == 1)  // X
        harness.clock.advance(by: -3_600)
        let (second, _) = harness.launchWatch()
        await second.resume()
        await harness.settle(second)
        harness.system.finish(capture, as: .fails(.outboxFileMissing))  // X
        await second.resume()
        await harness.settle(second)
        try #require(harness.outstanding(capture).count == 1)  // Y
        harness.system.finish(capture, as: .neverArrives)  // Y, which read the file
        harness.system.releaseHeld { reversed ? $0.reversed() : $0 }
        await harness.settle(second)
        #expect(await second.states()[capture] != .failed, "Y was queued after X and read the file.")
    }

    /// Two captures, each with given-up attempts: one's late "missing" leaves the other alone.
    @Test func recheckIOneCapturesLateEndLeavesTheOtherAlone() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let one = try await harness.sendNew(on: link)
        let two = try await harness.sendNew(on: link)
        await harness.settle(link)
        harness.system.finish(one, as: .fails(.outboxFileMissing))
        harness.system.finish(two, as: .fails(.counterpartFull))
        await link.resume()
        await harness.settle(link)
        harness.system.finish(two, as: .fails(.counterpartFull))
        await link.resume()
        await harness.settle(link)
        let standing = try #require(harness.outstanding(two).first)
        harness.system.releaseHeld()
        await harness.settle(link)
        #expect(await link.states()[one] == .failed)
        #expect(await link.states()[two] == .queued(attempt: standing.attempt))
        #expect(harness.outstanding(two) == [standing])
    }

    /// An end of a remembered attempt that says "missing", arriving after the capture's
    /// acknowledgement, changes nothing: the capture left the outbox and nothing is failed.
    @Test func recheckIARememberedEndAfterAnAcknowledgementChangesNothing() async throws {
        let harness = LinkHarness()
        harness.system.holdsEvents = true
        let (link, _) = harness.launchWatch()
        let capture = try await harness.sendNew(on: link)
        await harness.settle(link)
        harness.system.finish(capture, as: .fails(.outboxFileMissing))  // A, held
        await link.resume()
        await harness.settle(link)
        try #require(harness.outstanding(capture).count == 1)  // B
        harness.system.releaseHeld { [.message(.acknowledgement(capture))] + $0 }
        await harness.settle(link)
        #expect(harness.acknowledgementsSeen == [capture])
        #expect(await link.currentCounts() == (waiting: 0, failed: 0))
        #expect(harness.outstanding(capture).isEmpty)
    }
}
