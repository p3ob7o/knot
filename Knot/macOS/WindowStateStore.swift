import AppKit
import Foundation

enum WindowStateStore {
    private static let detachedKey = "knot.windowDetached"
    private static let frameKey = "knot.windowFrame"
    private static let minimumSize = NSSize(width: 360, height: 300)
    private static let maximumDimension: CGFloat = 8_192

    static func isDetached(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: detachedKey)
    }

    static func setDetached(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: detachedKey)
    }

    static func savedFrame(in defaults: UserDefaults = .standard) -> NSRect? {
        guard let dict = defaults.dictionary(forKey: frameKey),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              let width = dict["w"] as? Double, let height = dict["h"] as? Double else { return nil }
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite), abs(x) < 10_000_000, abs(y) < 10_000_000,
              width >= minimumSize.width, height >= minimumSize.height,
              width <= maximumDimension, height <= maximumDimension else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func saveFrame(_ frame: NSRect, in defaults: UserDefaults = .standard) {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= minimumSize.width, frame.height >= minimumSize.height,
              frame.width <= maximumDimension, frame.height <= maximumDimension else {
            defaults.removeObject(forKey: frameKey)
            return
        }
        defaults.set([
            "x": Double(frame.origin.x), "y": Double(frame.origin.y),
            "w": Double(frame.size.width), "h": Double(frame.size.height)
        ], forKey: frameKey)
    }

    static func constrainedFrame(
        _ proposed: NSRect,
        visibleFrames: [NSRect] = NSScreen.screens.map(\.visibleFrame),
        fallback: NSRect? = NSScreen.main?.visibleFrame
    ) -> NSRect {
        guard !visibleFrames.isEmpty else { return proposed }
        let screen = visibleFrames.max { intersectionArea(proposed, $0) < intersectionArea(proposed, $1) }
            ?? fallback ?? visibleFrames[0]
        let width = min(max(proposed.width, minimumSize.width), screen.width)
        let height = min(max(proposed.height, minimumSize.height), screen.height)
        let x = min(max(proposed.minX, screen.minX), screen.maxX - width)
        let y = min(max(proposed.minY, screen.minY), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: detachedKey)
        defaults.removeObject(forKey: frameKey)
    }

    private static func intersectionArea(_ left: NSRect, _ right: NSRect) -> CGFloat {
        let intersection = left.intersection(right)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
