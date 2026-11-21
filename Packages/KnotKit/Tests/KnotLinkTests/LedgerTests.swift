import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The Watch's half of the capture ledger (docs/architecture.md §6, rule 6): every manifest is
/// still on the Watch, or an iPhone acknowledged its capture. A seeded run sends captures over
/// a network that loses, repeats, reorders and damages, with relaunches, stalls and triggers in
/// between, and checks the rule after every step. Then the network heals, and every capture
/// must leave the outbox, each on its own acknowledgement.
@Suite struct LedgerTests {
    @Test("watch-manifest-on-watch-or-acknowledged", .tags(.named), arguments: [UInt64](1...6))
    func watchManifestOnWatchOrAcknowledged(seed: UInt64) async throws {
        let harness = LinkHarness(seed: seed)
        var random = SeededRandom(seed: seed)
        harness.system.holdsEvents = true
        var (link, _) = harness.launchWatch(stallLimit: 120)
        var sent: [CaptureID] = []

        func check(_ step: Int) {
            for capture in sent where !harness.inOutbox(capture) {
                #expect(harness.phone.acknowledged(capture), "Step \(step): a manifest left with no acknowledgement.")
            }
        }

        for step in 0..<160 {
            switch random.next(below: 9) {
            case 0, 1:
                sent.append(try await harness.sendNew(on: link))
            case 2, 3:
                let outstanding = harness.system.outstanding()
                if !outstanding.isEmpty {
                    let file = outstanding[random.next(below: outstanding.count)]
                    let fates: [FakeLinkSystem.Fate] = [
                        .arrives, .arrives, .arrivesDamaged, .neverArrives, .fails(.deliveryFailed),
                        .fails(.linkNotReady), .fails(.counterpartMissing), .fails(.counterpartFull),
                    ]
                    harness.system.finish(
                        file.captureID, attempt: file.attempt, as: fates[random.next(below: fates.count)])
                }
            case 4, 5:
                // The network gives what it holds, some lost, some twice, out of order.
                var chooser = random
                harness.system.releaseHeld { events in
                    var out: [LinkEvent] = []
                    for event in events {
                        switch chooser.next(below: 6) {
                        case 0: break
                        case 1: out.append(contentsOf: [event, event])
                        default: out.append(event)
                        }
                    }
                    if chooser.next(below: 2) == 0 { out.reverse() }
                    return out
                }
                random = chooser
            case 6:
                await link.resume()
            case 7:
                harness.clock.advance(by: TimeInterval(random.next(below: 200)))
            default:
                if random.next(below: 3) == 0 { (link, _) = harness.launchWatch(stallLimit: 120) }
            }
            check(step)
        }

        // The network heals: nothing is held, everything arrives.
        harness.system.holdsEvents = false
        harness.system.releaseHeld()
        (link, _) = harness.launchWatch(stallLimit: 120)
        let healed = link
        let everyone = sent
        let emptied = await eventually("every capture acknowledged and removed") {
            await healed.resume()
            harness.system.finishAll(as: .arrives)
            return everyone.allSatisfy { !harness.inOutbox($0) }
        }
        #expect(emptied)
        check(-1)
        #expect(try harness.outbox.entries().isEmpty)
        for capture in sent {
            #expect(harness.phone.acknowledged(capture))
        }
    }
}

/// A small seeded generator, so a run can be repeated.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next(below bound: Int) -> Int {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Int((state &* 0x2545_F491_4F6C_DD1D) % UInt64(bound))
    }
}
