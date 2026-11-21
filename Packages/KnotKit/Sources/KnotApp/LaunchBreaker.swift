import Foundation
import KnotCore

/// The breaker of each launch step (docs/architecture.md §13): a step in which the last two
/// launches died is skipped, and the diagnostics say so.
///
/// It keeps, for each step, what the last launches did with it, in the named defaults suite of
/// the store's launch state (`LiveComposition.launchStateSuite`): it is there before the store
/// opens, and opening the store is itself a step. A mark is handed to the system's preferences
/// with `set(_:forKey:)` before the step runs, and survives the death of the process that wrote
/// it: no call to `synchronize()`, which the SDK's header calls unnecessary. A launch
/// writes "entered" before the step and "left" after it, so an "entered" that a later launch
/// finds is a launch that died inside the step. A skip is written too, so the launch after a
/// skip runs the step again. A step that dies at every run therefore goes entered, entered,
/// skipped: it runs at two launches in three, and is skipped at every third.
struct LaunchBreaker: Sendable {
    enum Mark: String {
        case entered, left, skipped
    }

    /// The marks kept for one step.
    static let kept = 4
    private static let entryName = "v1.launch.breaker"

    let suiteName: String

    /// True when the last two launches died inside `step`.
    func shouldSkip(_ step: LaunchStep) -> Bool {
        let marks = history(step)
        return marks.count >= 2 && marks.suffix(2).allSatisfy { $0 == .entered }
    }

    func enter(_ step: LaunchStep) { append(.entered, to: step) }

    func skip(_ step: LaunchStep) { append(.skipped, to: step) }

    func leave(_ step: LaunchStep) {
        update(step) { marks in
            if marks.last == .entered { marks[marks.count - 1] = .left } else { marks.append(.left) }
        }
    }

    func history(_ step: LaunchStep) -> [Mark] {
        let all = defaults?.dictionary(forKey: Self.entryName) as? [String: [String]] ?? [:]
        return (all[step.rawValue] ?? []).compactMap(Mark.init(rawValue:))
    }

    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    private func append(_ mark: Mark, to step: LaunchStep) {
        update(step) { $0.append(mark) }
    }

    private func update(_ step: LaunchStep, _ change: (inout [Mark]) -> Void) {
        guard let defaults else { return }
        var all = defaults.dictionary(forKey: Self.entryName) as? [String: [String]] ?? [:]
        var marks = (all[step.rawValue] ?? []).compactMap(Mark.init(rawValue:))
        change(&marks)
        all[step.rawValue] = marks.suffix(Self.kept).map(\.rawValue)
        defaults.set(all, forKey: Self.entryName)
    }
}

/// This device's ID, as the capture engine stamps it on the captures it makes before and after
/// the store opens.
///
/// The engine exists before the store opens, so its device ID cannot come from the store's
/// `store_meta`. It is kept in this device's named defaults suite, and a store the app creates
/// is created with it, so the two agree. When an existing store holds another ID, the store's
/// wins from the next launch on. The Keychain's install ID, which WP-10's second pull request
/// brings with `InstallIdentity`, takes this over.
struct DeviceIdentity: Sendable {
    private static let entryName = "v1.device.id"

    let suiteName: String

    /// The kept ID, or a new one, kept.
    func current(ids: any IDGenerator) -> DeviceID {
        let defaults = UserDefaults(suiteName: suiteName)
        if let text = defaults?.string(forKey: Self.entryName), let id = DeviceID(text) { return id }
        let id: DeviceID = ids.make()
        defaults?.set(id.description, forKey: Self.entryName)
        return id
    }

    /// Keeps the store's ID for the launches that follow.
    func adopt(_ id: DeviceID) {
        UserDefaults(suiteName: suiteName)?.set(id.description, forKey: Self.entryName)
    }
}
