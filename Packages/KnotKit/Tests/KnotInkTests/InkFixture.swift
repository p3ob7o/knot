#if canImport(PencilKit)
    import CryptoKit
    import Foundation
    import PencilKit

    /// One drawing of `Fixtures/ink`, read as `Fixtures/README.md` describes it, and turned
    /// into a `PKDrawing` (WP-18 proof step).
    ///
    /// The lookup here is local to the proof. Fixtures/README.md asks for one shared helper
    /// in KnotTestSupport, which this package does not own.
    struct InkFixture: Sendable {
        let name: String
        let expectedText: String
        let canvas: CGSize
        let inkWidth: Double
        /// Per stroke, per point: x, y, t, size, opacity, force, azimuth, altitude.
        let strokes: [[[Double]]]

        enum LoadError: Error, CustomStringConvertible {
            case fixtureMissing(String)
            case fixtureChanged(String)

            var description: String {
                switch self {
                case .fixtureMissing(let path):
                    "fixture_missing: Fixtures/\(path) is not in this checkout. Restore it with `git checkout -- Fixtures`."
                case .fixtureChanged(let path):
                    "fixture_changed: Fixtures/\(path) does not match Fixtures/manifest.json."
                }
            }
        }

        private struct File: Decodable {
            struct Canvas: Decodable {
                let width: Double
                let height: Double
            }
            struct Ink: Decodable { let width: Double }
            struct Stroke: Decodable { let points: [[Double]] }
            let name: String
            let expectedText: String
            let canvas: Canvas
            let ink: Ink
            let pointFields: [String]
            let strokes: [Stroke]
        }

        private struct Manifest: Decodable {
            struct Entry: Decodable {
                let name: String
                let file: String
                let sha256: String
            }
            let ink: [Entry]
        }

        static let names = ["line", "list", "sketch"]

        /// The folder that holds `Fixtures/manifest.json`, found by walking up from this file.
        static func fixturesFolder(from file: String = #filePath) throws -> URL {
            var folder = URL(fileURLWithPath: file).deletingLastPathComponent()
            while folder.path != "/" {
                let candidate = folder.appendingPathComponent("Fixtures")
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate
                }
                folder.deleteLastPathComponent()
            }
            throw LoadError.fixtureMissing("manifest.json")
        }

        static func load(_ name: String) throws -> InkFixture {
            let folder = try fixturesFolder()
            let manifest = try JSONDecoder().decode(
                Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            guard let entry = manifest.ink.first(where: { $0.name == name }) else {
                throw LoadError.fixtureMissing("ink/\(name).json")
            }
            let url = folder.appendingPathComponent(entry.file)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw LoadError.fixtureMissing(entry.file)
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.sha256 else { throw LoadError.fixtureChanged(entry.file) }
            let file = try JSONDecoder().decode(File.self, from: data)
            precondition(file.pointFields == ["x", "y", "t", "size", "opacity", "force", "azimuth", "altitude"])
            return InkFixture(
                name: file.name,
                expectedText: file.expectedText,
                canvas: CGSize(width: file.canvas.width, height: file.canvas.height),
                inkWidth: file.ink.width,
                strokes: file.strokes.map(\.points)
            )
        }

        /// The fixture's strokes as PencilKit strokes: a black pen, each point as the file
        /// gives it. A stroke's creation date is the drawing's start plus its first point's
        /// time, and each point's time offset counts from there.
        func pkStrokes(scale: Double = 1, start: Date = Date(timeIntervalSinceReferenceDate: 0)) -> [PKStroke] {
            strokes.map { points in
                let t0 = points.first?[2] ?? 0
                let path = PKStrokePath(
                    controlPoints: points.map { p in
                        PKStrokePoint(
                            location: CGPoint(x: p[0] * scale, y: p[1] * scale),
                            timeOffset: p[2] - t0,
                            size: CGSize(width: p[3] * scale, height: p[3] * scale),
                            opacity: p[4],
                            force: p[5],
                            azimuth: p[6],
                            altitude: p[7]
                        )
                    },
                    creationDate: start.addingTimeInterval(t0)
                )
                return PKStroke(ink: PKInk(.pen), path: path)
            }
        }

        func drawing(scale: Double = 1) -> PKDrawing {
            PKDrawing(strokes: pkStrokes(scale: scale))
        }
    }

    /// Words for scoring: lower case, letters and digits only. A list's dashes and the line
    /// breaks are not words.
    func scoringWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Word edit distance between a reference and a hypothesis.
    func wordErrors(reference: [String], hypothesis: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        var previous = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, other) in hypothesis.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (word == other ? 0 : 1))
            }
            previous = current
        }
        return previous[hypothesis.count]
    }
#endif
