import AppKit
import Foundation

/// Persists whether the editor surface should appear as a detached
/// window and, when detached, its last on-screen frame so it reopens at
/// the spot the user left it.
enum WindowStateStore {
    private static let detachedKey = "knot.windowDetached"
    private static let frameKey = "knot.windowFrame"

    static func isDetached(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: detachedKey)
    }

    static func setDetached(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: detachedKey)
    }

    static func savedFrame(in defaults: UserDefaults = .standard) -> NSRect? {
        guard
            let dict = defaults.dictionary(forKey: frameKey),
            let x = dict["x"] as? Double,
            let y = dict["y"] as? Double,
            let w = dict["w"] as? Double,
            let h = dict["h"] as? Double
        else {
            return nil
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    static func saveFrame(_ frame: NSRect, in defaults: UserDefaults = .standard) {
        let dict: [String: Double] = [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "w": Double(frame.size.width),
            "h": Double(frame.size.height)
        ]
        defaults.set(dict, forKey: frameKey)
    }
}
