import KnotStore

/// A named point where the soak kills its child (docs/architecture.md §17). The seed chooses,
/// for each launch, one point of the run's list and how many times the child passes it first.
///
/// The child stops at three kinds of point by their names alone (KnotSoakChild's
/// KillPoints.swift), so a package adds kill points in a file of its own here, as an extension of
/// this type, without a change to the harness:
///
/// - `.store(_:)`: a `StoreKillPoint`, inside the store's transaction;
/// - `.log(_:)`: the moment a part of the child writes that log event, such as the engine's
///   `capture_fell_back`;
/// - `.step(_:)`: a step of the child's script: `after_begin`, `after_checkpoint`, `after_end`;
///
/// and the parent kills it at a fourth, `.anywhere`, after the child's nth acknowledgement in
/// the launch, wherever the child is then.
struct SoakKillPoint: Hashable, Sendable, CustomStringConvertible {
    enum Trigger: Hashable, Sendable {
        /// The child stops at this name and waits to be killed.
        case child(String)
        /// The parent kills the child once it has acknowledged this many saves in the launch.
        case anywhere
    }

    let trigger: Trigger
    /// How many passes before the kill: the seed draws one in this range for each launch.
    let passes: ClosedRange<Int>

    static func store(_ point: StoreKillPoint, passes: ClosedRange<Int>) -> SoakKillPoint {
        SoakKillPoint(trigger: .child("store:\(point.rawValue)"), passes: passes)
    }

    static func log(_ event: String, passes: ClosedRange<Int>) -> SoakKillPoint {
        SoakKillPoint(trigger: .child("log:\(event)"), passes: passes)
    }

    static func step(_ name: String, passes: ClosedRange<Int>) -> SoakKillPoint {
        SoakKillPoint(trigger: .child("step:\(name)"), passes: passes)
    }

    static func anywhere(passes: ClosedRange<Int>) -> SoakKillPoint {
        SoakKillPoint(trigger: .anywhere, passes: passes)
    }

    var description: String {
        switch trigger {
        case .child(let name): name
        case .anywhere: "anywhere"
        }
    }
}

extension SoakKillPoint {
    /// The kill points of typed captures, WP-06's: inside the store's two transactions of a
    /// capture, after each step of the script, at the engine's fall back to `Inbox/` and its
    /// late answers, inside ingest and recovery, and anywhere at all. A late answer is rare, and
    /// recovery finishes a capture only when the launch before left one open, so those two kill
    /// at their first pass.
    static let typedCaptures: [SoakKillPoint] = [
        .store(.insideRecord, passes: 1...12),
        .store(.insideSave, passes: 1...40),
        .step("after_begin", passes: 1...12),
        .step("after_checkpoint", passes: 1...40),
        .step("after_end", passes: 1...12),
        .log("capture_fell_back", passes: 1...2),
        .log("store_answered_late", passes: 1...1),
        .log("inbox_item_stored", passes: 1...3),
        .log("capture_recovered", passes: 1...1),
        .anywhere(passes: 1...60),
    ]
}
