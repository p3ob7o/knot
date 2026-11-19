import Foundation
import KnotCore
import KnotInk

#if canImport(PencilKit)
    import PencilKit
#endif

// KnotInkCrashHost: a process that KnotInk's kill tests start and kill
// (docs/architecture.md §17). The package that owns KnotInk gives it its work and its
// kill points. Until then it reports that it is ready and exits.
//
// WP-18 proof step: `KnotInkCrashHost pencilkit-build` and `pencilkit-decode` check whether
// a bare executable, which has no bundle ID, can build or decode a PKDrawing
// (docs/notes/WP-18.md).

let arguments = CommandLine.arguments.dropFirst()

#if canImport(PencilKit)
    func probeStroke() -> PKStroke {
        let points = (0..<20).map { i in
            PKStrokePoint(
                location: CGPoint(x: Double(i) * 2, y: 10), timeOffset: Double(i) / 60,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(
            ink: PKInk(.pen),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0)))
    }

    switch arguments.first {
    case "pencilkit-build":
        print("KnotInkCrashHost: bundle ID \(Bundle.main.bundleIdentifier ?? "none"), building a drawing")
        let drawing = PKDrawing(strokes: [probeStroke()])
        print("KnotInkCrashHost: built a drawing with \(drawing.strokes.count) strokes")
    case "pencilkit-decode":
        // Decodes the drawing data in the file the second argument names.
        print("KnotInkCrashHost: bundle ID \(Bundle.main.bundleIdentifier ?? "none"), decoding a drawing")
        let data = FileManager.default.contents(atPath: arguments.dropFirst().first ?? "") ?? Data()
        let drawing = try PKDrawing(data: data)
        print("KnotInkCrashHost: decoded a drawing with \(drawing.strokes.count) strokes")
        print("KnotInkCrashHost: its data again, \(drawing.dataRepresentation().count) bytes")
    default:
        print("KnotInkCrashHost: ready")
    }
#else
    print("KnotInkCrashHost: ready")
#endif
