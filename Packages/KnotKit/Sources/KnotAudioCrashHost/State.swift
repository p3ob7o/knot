import Foundation
import KnotAudio
import KnotCore

/// `state`: reads or writes the recording state in the defaults suite `--suite` names, through
/// `DefaultsRecordingStateStore`, so that a test or `state-check` sees it shared across two
/// processes. The suite is a test's own, whose name says nothing of the machine or the account.
///
///     state --read --suite <name>
///     state --write --suite <name> --phase idle|starting|recording|stopping [--capture <id>]
///           [--launch <id>] [--started-s <seconds>] [--heartbeat-s <seconds>] [--pid <n>]
///     state --clear --suite <name>
///
/// Times are seconds since 1970. `--read` and `--write` print the state as it then stands, as
/// `state phase <phase> capture <id|none> launch <id|none> started <s|none> heartbeat <s|none>
/// pid <n|none>`; `--clear` removes the suite and prints `state cleared`.
func state(_ arguments: Arguments) throws(HostError) {
    let actions = ["read", "write", "clear"].filter { arguments.flag($0) }
    guard actions.count == 1, let action = actions.first else { throw .usage("state takes --read, --write or --clear") }
    let name = try arguments.required("suite")
    // Each use has an instance of the suite of its own: the store keeps the one it is given.
    func suite() throws(HostError) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: name) else { throw .usage("--suite cannot be used: \(name)") }
        return defaults
    }
    let store = DefaultsRecordingStateStore(defaults: try suite())
    switch action {
    case "read":
        print(describe(store.read()))
    case "write":
        let snapshot = try snapshot(arguments)
        store.write(snapshot)
        // Written to the preferences daemon before this process ends.
        try suite().synchronize()
        print(describe(store.read()))
    case "clear":
        removeSuite(named: name)
        print("state cleared")
    default:
        throw .usage("state takes --read, --write or --clear")
    }
}

/// Removes a test's defaults suite and what it holds. A suite named by an absolute path, as a
/// test on the Mac names it, keeps its file at that path with `.plist`, in the test's folder:
/// that file goes too. A suite named by a word, as in a simulator, keeps it in the Preferences
/// folder, where it goes as well, though the preferences daemon may write it again, empty.
func removeSuite(named name: String) {
    guard let defaults = UserDefaults(suiteName: name) else { return }
    defaults.removePersistentDomain(forName: name)
    defaults.synchronize()
    if name.hasPrefix("/") {
        try? FileManager.default.removeItem(atPath: name + ".plist")
    } else if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
        try? FileManager.default.removeItem(at: library.appending(path: "Preferences/\(name).plist"))
    }
}

/// The snapshot that `state write` is given.
private func snapshot(_ arguments: Arguments) throws(HostError) -> RecordingStateSnapshot {
    guard let phase = RecordingPhase(rawValue: try arguments.required("phase")) else {
        throw .usage("--phase is idle, starting, recording or stopping")
    }
    func identifier<Kind>(_ name: String) throws(HostError) -> Identifier<Kind>? {
        guard let text = arguments.string(name) else { return nil }
        guard let id = Identifier<Kind>(text) else { throw .usage("--\(name) takes an ID") }
        return id
    }
    func date(_ name: String) throws(HostError) -> Date? {
        guard let text = arguments.string(name) else { return nil }
        guard let seconds = Double(text) else { throw .usage("--\(name) takes seconds since 1970") }
        return Date(timeIntervalSince1970: seconds)
    }
    let pid = try arguments.string("pid").map { text throws(HostError) in
        guard let pid = Int32(text) else { throw .usage("--pid takes a whole number") }
        return pid
    }
    return RecordingStateSnapshot(
        phase: phase, captureID: try identifier("capture"), startedAt: try date("started-s"),
        heartbeat: try date("heartbeat-s"), ownerLaunch: try identifier("launch"), ownerPID: pid)
}

/// The one line that says a state.
func describe(_ snapshot: RecordingStateSnapshot) -> String {
    func seconds(_ date: Date?) -> String { date.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "none" }
    return "state phase \(snapshot.phase.rawValue) capture \(snapshot.captureID.map { "\($0)" } ?? "none") "
        + "launch \(snapshot.ownerLaunch.map { "\($0)" } ?? "none") started \(seconds(snapshot.startedAt)) "
        + "heartbeat \(seconds(snapshot.heartbeat)) pid \(snapshot.ownerPID.map(String.init) ?? "none")"
}
