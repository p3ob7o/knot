#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore

    /// A random generator that a seed fixes: SplitMix64.
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
    /// the child makes the same script from the same seed and runs the part its parent names,
    /// so a relaunch goes on where the killed launch stopped. The parent makes the same script
    /// too, and knows every text the child sends at every save: it checks the store against it
    /// exactly, and never sees a text through the pipe.
    ///
    /// The text is synthetic. It begins with a token that names the capture,
    /// `s<seed>c<index>`, which no save changes. A save may add a word, replace the last word
    /// or one in the middle, or take the last word away. Some captures carry a body longer than
    /// one segment can hold (`Limits.segmentTextBytes`), which the store keeps as several
    /// pieces; capture `alwaysLong` always does, so that every script holds one.
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

            /// The token its text begins with, or none for a blank capture.
            var token: String? { blank ? nil : texts[0].split(separator: " ", maxSplits: 1).first.map(String.init) }
        }

        enum Ending: String {
            /// Ended by its surface.
            case end
            /// Discarded: the accidental press.
            case discard
            /// Left open: the next capture begins on the other surface, and rule 15 ends this one
            /// (docs/product-spec.md §3).
            case leftOpen = "left_open"
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

        /// The words the saves add and replace.
        static let words = [
            "amber", "basil", "cedar", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper",
            "kelp", "lumen", "mosaic", "nectar", "orchid", "pebble", "quartz", "russet", "saffron", "tundra",
            "umber", "velvet", "willow", "xenon", "yarrow", "zephyr",
        ]

        /// Every capture whose index this gives carries a body past one piece: so that even a
        /// short script holds one.
        static let alwaysLong = 2

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
                let blank = index != Self.alwaysLong && Int.random(in: 0..<14, using: &random) == 0
                let long = !blank && (index == Self.alwaysLong || Int.random(in: 0..<40, using: &random) == 0)
                let updates = Int.random(in: 0...6, using: &random)
                let texts =
                    blank
                    ? Self.blankTexts(updates: updates, random: &random)
                    : Self.texts(token: "s\(seed)c\(index)", long: long, updates: updates, random: &random)
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

        private static func blankTexts(updates: Int, random: inout SeededRandom) -> [String] {
            var text = " "
            var texts = [text]
            for _ in 0..<updates {
                text += [" ", "\n"].randomElement(using: &random)!
                texts.append(text)
            }
            return texts
        }

        /// The texts of a capture's saves: the token, a body for a long capture, then words
        /// that the saves add, replace and take away. The token is never touched.
        private static func texts(token: String, long: Bool, updates: Int, random: inout SeededRandom) -> [String] {
            var head = token
            if long {
                // Past one piece, or past two: lines of words, so that a piece can end at a line
                // break, as the store's split prefers.
                let target = Limits.segmentTextBytes * Int.random(in: 1...2, using: &random) + 4_096
                var body = ""
                var line = 0
                while body.utf8.count < target {
                    line += 1
                    body += (1...12).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
                    body += line % 7 == 0 ? "\n\n" : "\n"
                }
                head += "\n" + body
            }
            var tail: [String] = [words.randomElement(using: &random)!]
            func text() -> String { ([head] + tail).joined(separator: " ") }
            var texts = [text()]
            for _ in 0..<updates {
                switch Int.random(in: 0..<10, using: &random) {
                case 0..<5:
                    tail.append(words.randomElement(using: &random)!)
                case 5..<7 where !tail.isEmpty:
                    tail[tail.count - 1] = words.randomElement(using: &random)!
                case 7 where tail.count > 1:
                    tail[Int.random(in: 0..<tail.count, using: &random)] = words.randomElement(using: &random)!
                case 8..<10 where !tail.isEmpty:
                    tail.removeLast()
                default:
                    tail.append(words.randomElement(using: &random)!)
                }
                texts.append(text())
            }
            return texts
        }
    }
#endif
