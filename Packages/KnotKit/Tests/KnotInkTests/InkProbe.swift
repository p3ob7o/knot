#if canImport(PencilKit)
    import Foundation
    import PencilKit

    /// WP-18 proof step: what PKStrokeRecognizer does with the ink fixtures, and how its
    /// streaming, cancellation and failures behave. Each probe reports lines that start with
    /// "ink-proof", and docs/notes/WP-18.md reports them.
    ///
    /// The probes import no test framework, so that the same code runs in three hosts: the
    /// package tests (`InkProofTests`), and the probe app and the tests hosted in it
    /// (`ProbeApp/ProbeApp.swift`). Run them one at a time, so that the times are not
    /// measured against each other.
    enum InkProbe {
        typealias Report = @Sendable (String) -> Void

        static let english = [Locale.Language(identifier: "en-US")]

        static var place: String {
            #if targetEnvironment(simulator)
                "ios-simulator"
            #elseif os(iOS)
                "ios-device"
            #else
                "macos"
            #endif
        }

        static func milliseconds(_ duration: Duration) -> Double {
            let (seconds, attoseconds) = duration.components
            return Double(seconds) * 1000 + Double(attoseconds) / 1e15
        }

        static func ms(_ duration: Duration) -> String { String(format: "%.1f ms", milliseconds(duration)) }

        static func shown(_ text: String?) -> String {
            guard let text else { return "nil" }
            return "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
        }

        static func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }

        /// Every probe, in order.
        static func all(host: String, report: @escaping Report) async throws {
            let say: Report = { report("ink-proof [\(place), \(host)] \($0)") }
            await engineFacts(say)
            for name in InkFixture.names { try await recognise(name, say) }
            try await listLines(say)
            try await strokeByStroke(say)
            try await waitsForAnalysis(say)
            try await cancellation(say)
            try await edgeCases(say)
            try await concurrent(say)
        }

        static func engineFacts(_ say: Report) async {
            let supported = PKStrokeRecognizer.supportedLanguages.map(\.maximalIdentifier).sorted()
            say("recognitionVersion \(PKStrokeRecognizer.recognitionVersion)")
            say("supportedLanguages \(supported.count): \(supported.joined(separator: " "))")
            say("languages, system default: \(await PKStrokeRecognizer().languages.map(\.maximalIdentifier))")
            say(
                "languages, en-US asked: \(await PKStrokeRecognizer(preferredLanguages: english).languages.map(\.maximalIdentifier))"
            )
            let klingon = PKStrokeRecognizer(preferredLanguages: [Locale.Language(identifier: "tlh")])
            say("languages, tlh asked: \(await klingon.languages.map(\.maximalIdentifier))")
        }

        /// Accuracy and latency. The first run in a process is cold. Each later run uses a
        /// new recogniser, as a recognise job would.
        static func recognise(_ name: String, _ say: Report) async throws {
            let fixture = try InkFixture.load(name)
            let drawing = fixture.drawing()
            var totals: [Double] = []
            var texts: [String?] = []
            let clock = ContinuousClock()
            for run in 0..<6 {
                let recogniser = PKStrokeRecognizer(preferredLanguages: english)
                let t0 = clock.now
                await recogniser.updateDrawing(drawing)
                let t1 = clock.now
                let text = await recogniser.recognizedText()
                let t2 = clock.now
                texts.append(text)
                totals.append(milliseconds(t2 - t0))
                if run == 0 {
                    say("\(name) first run: update \(ms(t1 - t0)), text \(ms(t2 - t1)), result \(shown(text))")
                }
            }
            let warm = Array(totals.dropFirst())
            let reference = scoringWords(fixture.expectedText)
            let got = texts.last ?? nil
            let errors = wordErrors(reference: reference, hypothesis: scoringWords(got ?? ""))
            say(
                "\(name) summary: expected \(shown(fixture.expectedText)), got \(shown(got)), "
                    + "word errors \(errors) of \(reference.count), first run \(String(format: "%.1f", totals[0])) ms, "
                    + "warm median \(String(format: "%.1f", percentile(warm, 0.5))) ms, "
                    + "warm max \(String(format: "%.1f", warm.max()!)) ms, "
                    + "runs agree: \(Set(texts.map { $0 ?? "<nil>" }).count == 1)")

            let restored = try PKDrawing(data: drawing.dataRepresentation())
            let again = PKStrokeRecognizer(preferredLanguages: english)
            await again.updateDrawing(restored)
            say("\(name) after a dataRepresentation round trip: \(shown(await again.recognizedText()))")
            let t3 = clock.now
            let indexable = await again.indexableContent
            say("\(name) indexableContent \(ms(clock.now - t3)): \(shown(indexable))")
        }

        /// Why `list` loses words: its second line's descenders end 3 points above the third
        /// line's ascenders. Each line alone, then the third line moved 30 points down.
        static func listLines(_ say: Report) async throws {
            let fixture = try InkFixture.load("list")
            let full = fixture.drawing()
            let recogniser = PKStrokeRecognizer(preferredLanguages: english)
            await recogniser.updateDrawing(full)
            for (label, range) in [("line 1", 0..<7), ("line 2", 7..<14), ("line 3", 14..<22)] {
                let ids = Set(full.strokes[range].map(\.id))
                say("list \(label) alone, by stroke ID: \(shown(await recogniser.recognizedText(strokeIDs: ids)))")
            }
            for gap in [15.0, 30.0] {
                var strokes = fixture.pkStrokes()
                for index in 14..<strokes.count {
                    strokes[index].transform = CGAffineTransform(translationX: 0, y: gap)
                }
                let spaced = PKStrokeRecognizer(preferredLanguages: english)
                await spaced.updateDrawing(PKDrawing(strokes: strokes))
                say("list with line 3 moved \(Int(gap)) pt down: \(shown(await spaced.recognizedText()))")
            }
            var apart = fixture.pkStrokes()
            for index in 7..<apart.count {
                apart[index].transform = CGAffineTransform(translationX: 0, y: index < 14 ? 20 : 50)
            }
            let spread = PKStrokeRecognizer(preferredLanguages: english)
            await spread.updateDrawing(PKDrawing(strokes: apart))
            say("list with lines 2 and 3 moved 20 and 50 pt down: \(shown(await spread.recognizedText()))")
        }

        /// Streaming: the API has no stream. The nearest thing is to give the recogniser the
        /// drawing again after each stroke and ask again.
        static func strokeByStroke(_ say: Report) async throws {
            let fixture = try InkFixture.load("line")
            let strokes = fixture.pkStrokes()
            let recogniser = PKStrokeRecognizer(preferredLanguages: english)
            let clock = ContinuousClock()
            var times: [Double] = []
            var seen: [String] = []
            for count in 1...strokes.count {
                let t0 = clock.now
                await recogniser.updateDrawing(PKDrawing(strokes: strokes.prefix(count)))
                let text = shown(await recogniser.recognizedText())
                times.append(milliseconds(clock.now - t0))
                if seen.last != text { seen.append(text) }
            }
            say(
                "line stroke by stroke: \(strokes.count) updates, median \(String(format: "%.1f", percentile(times, 0.5))) ms, "
                    + "max \(String(format: "%.1f", times.max()!)) ms, total \(String(format: "%.1f", times.reduce(0, +))) ms"
            )
            say("line stroke by stroke, distinct results in order: \(seen.joined(separator: " → "))")
            let full = PKDrawing(strokes: strokes)
            await recogniser.updateDrawing(full)
            let ids = Set(full.strokes.prefix(4).map(\.id))
            say("line, first four strokes by ID: \(shown(await recogniser.recognizedText(strokeIDs: ids)))")
            say("line, an empty set of IDs: \(shown(await recogniser.recognizedText(strokeIDs: [])))")
            say("line, an unknown ID: \(shown(await recogniser.recognizedText(strokeIDs: [UUID()])))")
        }

        /// Whether analysis finishes some time after `updateDrawing` returns: ask again until
        /// an answer comes or five seconds pass. Also with the drawing flipped, in case the
        /// platform reads y as pointing up.
        static func waitsForAnalysis(_ say: Report) async throws {
            let fixture = try InkFixture.load("line")
            for flipped in [false, true] {
                var drawing = fixture.drawing()
                if flipped {
                    drawing.transform(
                        using: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: fixture.canvas.height))
                }
                let recogniser = PKStrokeRecognizer(preferredLanguages: english)
                await recogniser.updateDrawing(drawing)
                let clock = ContinuousClock()
                let t0 = clock.now
                var text: String?
                var asks = 0
                while clock.now - t0 < .seconds(5) {
                    asks += 1
                    text = await recogniser.recognizedText()
                    if text != nil { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                say(
                    "line \(flipped ? "flipped" : "upright"), asked \(asks) times over \(ms(clock.now - t0)): \(shown(text))"
                )
            }
        }

        /// Cancellation: what a cancelled task gets back, and how soon.
        static func cancellation(_ say: Report) async throws {
            let fixture = try InkFixture.load("list")
            let drawing = fixture.drawing()
            let clock = ContinuousClock()

            let early = Task {
                let recogniser = PKStrokeRecognizer(preferredLanguages: english)
                await recogniser.updateDrawing(drawing)
                return await recogniser.recognizedText()
            }
            early.cancel()
            let t0 = clock.now
            let earlyResult = await early.value
            say("cancelled before it starts: returned after \(ms(clock.now - t0)) with \(shown(earlyResult))")

            // Called from a task that is certainly cancelled already.
            let ready = PKStrokeRecognizer(preferredLanguages: english)
            await ready.updateDrawing(fixture.drawing(scale: 1.005))
            let precancelled = Task {
                while !Task.isCancelled { await Task.yield() }
                let t = ContinuousClock.now
                let text = await ready.recognizedText()
                return (text, ContinuousClock.now - t)
            }
            precancelled.cancel()
            let (preText, preTime) = await precancelled.value
            say("called from a cancelled task: returned after \(ms(preTime)) with \(shown(preText))")
            let afterwards = await ready.recognizedText()
            say("the same recogniser asked again, not cancelled: \(shown(afterwards))")

            for delay in [1, 5, 20] {
                let recogniser = PKStrokeRecognizer(preferredLanguages: english)
                await recogniser.updateDrawing(fixture.drawing(scale: 1 + Double(delay) / 1000))
                let started = clock.now
                let late = Task { await recogniser.recognizedText() }
                try await Task.sleep(for: .milliseconds(delay))
                late.cancel()
                let t1 = clock.now
                let lateResult = await late.value
                say(
                    "cancelled \(delay) ms into the query: returned \(ms(clock.now - t1)) after the cancel, "
                        + "\(ms(clock.now - started)) after the start, with \(shown(lateResult))")
            }

            let other = PKStrokeRecognizer(preferredLanguages: english)
            await other.updateDrawing(fixture.drawing(scale: 1.03))
            async let indexing = other.indexableContent
            async let interactive = other.recognizedText()
            let (indexed, asked) = await (indexing, interactive)
            say("indexing and interactive at once: indexable \(shown(indexed)), interactive \(shown(asked))")

            let replaced = PKStrokeRecognizer(preferredLanguages: english)
            await replaced.updateDrawing(fixture.drawing(scale: 1.04))
            async let first = replaced.recognizedText()
            await replaced.updateDrawing(try InkFixture.load("line").drawing())
            let second = await replaced.recognizedText()
            say("drawing replaced during a query: first \(shown(await first)), second \(shown(second))")
        }

        /// What failure looks like: none of these calls throws, so each case shows what comes back.
        static func edgeCases(_ say: Report) async throws {
            let empty = PKStrokeRecognizer(preferredLanguages: english)
            say("never given a drawing: \(shown(await empty.recognizedText()))")
            await empty.updateDrawing(PKDrawing())
            say("empty drawing: \(shown(await empty.recognizedText()))")

            let line = try InkFixture.load("line")
            for scale in [0.05, 0.25, 4.0, 20.0] {
                let recogniser = PKStrokeRecognizer(preferredLanguages: english)
                await recogniser.updateDrawing(line.drawing(scale: scale))
                say("line at scale \(scale): \(shown(await recogniser.recognizedText()))")
            }

            let dot = PKStroke(
                ink: PKInk(.pen),
                path: PKStrokePath(
                    controlPoints: [
                        PKStrokePoint(
                            location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 3, height: 3),
                            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                    ],
                    creationDate: Date(timeIntervalSinceReferenceDate: 0)))
            let single = PKStrokeRecognizer(preferredLanguages: english)
            await single.updateDrawing(PKDrawing(strokes: [dot]))
            say("one dot: \(shown(await single.recognizedText()))")

            let klingon = PKStrokeRecognizer(preferredLanguages: [Locale.Language(identifier: "tlh")])
            await klingon.updateDrawing(line.drawing())
            say("line with tlh asked: \(shown(await klingon.recognizedText()))")

            for (label, data) in [
                ("garbage data", Data("not a drawing".utf8)),
                ("truncated data", Data(line.drawing().dataRepresentation().prefix(64))),
            ] {
                do {
                    let decoded = try PKDrawing(data: data)
                    say("\(label): decoded with \(decoded.strokes.count) strokes")
                } catch {
                    let ns = error as NSError
                    say("\(label): throws \(type(of: error)) domain \(ns.domain) code \(ns.code)")
                }
            }
            // `search(_:)` is not probed: its `[SearchResult]` is not Sendable, so Swift 6 with
            // strict concurrency refuses to return it from the actor. Knot searches the
            // recognised text in its own index instead.
        }

        /// Three recognisers at once, as a queue that runs jobs side by side would.
        static func concurrent(_ say: Report) async throws {
            let drawings = try InkFixture.names.map { try InkFixture.load($0).drawing(scale: 1.02) }
            let clock = ContinuousClock()
            let t0 = clock.now
            let results = await withTaskGroup(of: (Int, String?).self) { group in
                for (index, drawing) in drawings.enumerated() {
                    group.addTask {
                        let recogniser = PKStrokeRecognizer(preferredLanguages: english)
                        await recogniser.updateDrawing(drawing)
                        return (index, await recogniser.recognizedText())
                    }
                }
                var all: [(Int, String?)] = []
                for await result in group { all.append(result) }
                return all.sorted { $0.0 < $1.0 }.map { shown($0.1) }
            }
            say("three at once: \(ms(clock.now - t0)), results \(results)")
        }

        /// One recognition of `line`, for the probe app's background run.
        static func once(_ say: Report) async throws -> String? {
            let recogniser = PKStrokeRecognizer(preferredLanguages: english)
            await recogniser.updateDrawing(try InkFixture.load("line").drawing(scale: 0.99))
            let clock = ContinuousClock()
            let t0 = clock.now
            let text = await recogniser.recognizedText()
            say("line once: \(ms(clock.now - t0)), \(shown(text))")
            return text
        }
    }
#endif
