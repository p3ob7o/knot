import Foundation
import KnotCore
import Testing

/// The contract of `IDGenerator` (docs/architecture.md §4): every fresh ID is version 7,
/// carries its clock's time in milliseconds, and is never repeated.
public enum IDGeneratorContract {
    public static func run(_ generator: any IDGenerator, clock: any WallClock, count: Int = 2_000) {
        var seen: Set<UUID> = []
        for _ in 0..<count {
            let before = UInt64((clock.now().timeIntervalSince1970 * 1000).rounded(.down))
            let id: NoteID = generator.make()
            let after = UInt64((clock.now().timeIntervalSince1970 * 1000).rounded(.down))
            #expect(id.version == .fresh, "A fresh ID is version 7.")
            #expect(!id.isDerived)
            let stamp = UUIDv7.milliseconds(of: id.uuid)
            #expect(stamp >= before && stamp <= after, "A fresh ID carries the clock's time.")
            #expect(seen.insert(id.uuid).inserted, "A fresh ID is never repeated.")
        }
    }
}

/// The contract of `WallClock`: it tells the time, and two readings in a row never come out
/// more than a little apart when nothing moves it.
public enum WallClockContract {
    public static func run(_ clock: any WallClock) {
        let first = clock.now()
        let second = clock.now()
        #expect(abs(second.timeIntervalSince(first)) < 1, "Two readings in a row agree.")
        #expect(first.timeIntervalSince1970 > 0)
    }
}
