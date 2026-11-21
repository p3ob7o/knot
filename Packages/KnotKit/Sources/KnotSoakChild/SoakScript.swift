#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore

    /// A random generator that a seed fixes: SplitMix64. The parent has its own copy, so the
    /// child and the parent never share a sequence.
    struct SeededRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A generator for one capture of the script: the same whatever launch runs it.
        static func forCapture(_ index: Int, seed: UInt64) -> SeededRandom {
            var mixer = SeededRandom(seed: seed ^ (UInt64(index) &* 0xD6E8_FEB8_6659_FD93))
            return SeededRandom(seed: mixer.next())
        }
    }

    /// The soak's captures, all of them typed for now, as the seed makes them. Every launch of
    /// the child makes the same script from the same seed and runs the part its parent names, so
    /// a relaunch goes on where the killed launch stopped.
    ///
    /// The text is synthetic: a token that names the capture, `s<seed>c<index>`, then words of
    /// a made-up list. A save only ever adds to the text, so every save's text begins with the
    /// text of each save before it: the parent checks a stored text against an acknowledged
    /// save by the hash of the stored text's first bytes, and never sees the text itself.
    struct SoakScript {
        /// When the script's clock starts.
        static let base = Date(timeIntervalSince1970: 1_795_000_000)

        let seed: UInt64
        let captures: [Capture]

        struct Capture {
            let index: Int
            /// When it begins, after `base`.
            let startsAt: TimeInterval
            let surface: CaptureSurface
            let placement: CapturePlacement
            /// Whether its text is only spaces and line breaks: it ends discarded as empty.
            let blank: Bool
            /// The whole text after each save: the begin, then each update.
            let texts: [String]
            /// The seconds before each update, and before the end.
            let pauses: [TimeInterval]
            let ending: Ending
            /// What the store does to one save of this capture.
            let disturbance: Disturbance?

            /// How long the capture lasts.
            var length: TimeInterval { pauses.reduce(0, +) }
        }

        enum Ending {
            /// Ended by its surface.
            case end
            /// Discarded: the accidental press.
            case discard
            /// Left open: the next capture begins on the other surface, and rule 15 ends this one
            /// (docs/product-spec.md §3).
            case leftOpen
        }

        /// What the store does to the save at `save`: 0 is the begin, then each update, then
        /// the end.
        struct Disturbance {
            enum Kind: String {
                /// The store refuses the write as busy, and the capture takes `Inbox/`.
                case refused
                /// The store holds the write past the engine's deadline, and commits it late.
                case held
            }

            let kind: Kind
            let save: Int
        }

        private static let words = [
            "amber", "basil", "cedar", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper",
            "kelp", "lumen", "mosaic", "nectar", "orchid", "pebble", "quartz", "russet", "saffron", "tundra",
            "umber", "velvet", "willow", "xenon", "yarrow", "zephyr",
        ]

        init(seed: UInt64, count: Int) {
            self.seed = seed
            var captures: [Capture] = []
            var time: TimeInterval = 0
            var previous: Capture?
            for index in 0..<count {
                var random = SeededRandom.forCapture(index, seed: seed)
                if let previous {
                    time += previous.length
                    // Inside the window of five minutes, outside it, or right after a capture
                    // left open.
                    time +=
                        previous.ending == .leftOpen
                        ? 0.5 : [2, 20, 90, 240, 420, 1_800].randomElement(using: &random)!
                }
                // A capture that follows one left open is on the other surface, so that rule 15
                // ends that one and this one is the next segment of its note.
                let surface: CaptureSurface =
                    previous?.ending == .leftOpen
                    ? (previous?.surface == .app ? .macPanel : .app)
                    : (Int.random(in: 0..<4, using: &random) == 0 ? .macPanel : .app)
                let placement: CapturePlacement = Int.random(in: 0..<10, using: &random) == 0 ? .newNote : .window
                let blank = Int.random(in: 0..<14, using: &random) == 0
                let updates = Int.random(in: 0...6, using: &random)
                var texts: [String] = []
                var text = blank ? " " : "s\(seed)c\(index)"
                texts.append(text)
                for _ in 0..<updates {
                    text +=
                        blank
                        ? [" ", "\n"].randomElement(using: &random)! : " " + Self.words.randomElement(using: &random)!
                    texts.append(text)
                }
                let pauses = (0...updates).map { _ in [0.2, 0.6, 1.5, 4].randomElement(using: &random)! }
                let roll = Int.random(in: 0..<100, using: &random)
                let ending: Ending =
                    index == count - 1 ? .end : roll < 4 ? .discard : roll < 14 ? .leftOpen : .end
                let saves = texts.count + (ending == .leftOpen ? 0 : 1)
                let disturbanceRoll = Int.random(in: 0..<100, using: &random)
                let disturbance: Disturbance? =
                    disturbanceRoll < 10
                    ? Disturbance(kind: .refused, save: Int.random(in: 0..<saves, using: &random))
                    : disturbanceRoll < 16
                        ? Disturbance(kind: .held, save: Int.random(in: 0..<saves, using: &random)) : nil
                let capture = Capture(
                    index: index, startsAt: time, surface: surface, placement: placement, blank: blank, texts: texts,
                    pauses: pauses, ending: ending, disturbance: disturbance)
                captures.append(capture)
                previous = capture
            }
            self.captures = captures
        }
    }
#endif
