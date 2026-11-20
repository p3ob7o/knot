#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A wall clock that a test sets and moves, backwards too.
    public final class FakeClock: WallClock {
        private let time: Mutex<Date>

        public init(_ start: Date = Date(timeIntervalSince1970: 1_795_000_000)) {
            time = Mutex(start)
        }

        public func now() -> Date { time.withLock { $0 } }

        public func set(_ date: Date) { time.withLock { $0 = date } }

        public func advance(by seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    /// An ID generator whose IDs follow from a seed: version 7, with the clock's time and
    /// bits from a seeded generator and a running count, so no two of one generator are equal.
    public final class SeededIDGenerator: IDGenerator {
        private struct State {
            var random: UInt64
            var count: UInt16 = 0
        }

        private let clock: any WallClock
        private let state: Mutex<State>

        public init(seed: UInt64 = 1, clock: any WallClock) {
            self.clock = clock
            self.state = Mutex(State(random: seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed))
        }

        public func make<Tag: IdentifierTag>(_ kind: Tag.Type) -> Identifier<Tag> {
            let bytes: [UInt8] = state.withLock { state in
                state.count &+= 1
                // xorshift64*
                state.random ^= state.random >> 12
                state.random ^= state.random << 25
                state.random ^= state.random >> 27
                let value = state.random &* 0x2545_F491_4F6C_DD1D
                let count = state.count
                return [UInt8(count >> 8), UInt8(truncatingIfNeeded: count)]
                    + (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
            }
            let milliseconds = UInt64(max(0, (clock.now().timeIntervalSince1970 * 1000).rounded(.down)))
            return Identifier(uuid: UUIDv7.make(milliseconds: milliseconds, random: bytes))
        }
    }
#endif
