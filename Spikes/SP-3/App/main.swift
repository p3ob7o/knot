import AppKit
import Darwin
import Foundation
import GRDB
import notify

// The spike app. Two ways to run it:
//
//   "Knot Dev.app/Contents/MacOS/Knot Dev" --self-test [--seconds N] [--spawn]
//       Headless. No NSApplication, so no Dock icon, no window and no focus. It opens the
//       synthetic store, prints {"event":"ready"}, waits for a write by the tool (the
//       Darwin notification, or the counter seen by polling), then with --spawn starts each
//       packaging of the tool as a sandboxed parent would, as an MCP client stands in, and
//       quits. It never runs longer than N seconds (8 by default).
//
//   Opened from Finder, as the owner does for the distribution-signed check.
//       One small window that shows what the app sees in the store, refreshed when the
//       tool writes, and the commands to run in Terminal.

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst().filter { $0 != "--team-group" }

func emit(_ object: [String: Any]) { print(Spike.json(object)) }

/// The packagings of the tool that the app carries, by where they sit in its bundle.
let toolPaths: [(name: String, path: String)] = {
    let contents = Bundle.main.bundleURL.appending(path: "Contents")
    return [
        ("bare", contents.appending(path: "MacOS/knot-dev").path),
        ("helper", contents.appending(path: "Helpers/knot-dev.app/Contents/MacOS/knot-dev").path),
        ("inherit", contents.appending(path: "Helpers/variants/knot-dev-inherit").path),
        ("noplist", contents.appending(path: "Helpers/variants/knot-dev-noplist").path),
    ]
}()

/// Starts one tool as an MCP client would, over standard input and output, sends one
/// request, closes its input, and waits at most `seconds` for it to end.
func spawn(_ name: String, _ path: String, seconds: Double) -> [String: Any] {
    var result: [String: Any] = ["event": "spawn", "tool": name]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["mcp"]
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        result["launched"] = false
        result["error"] = Spike.describe(error)
        return result
    }
    result["launched"] = true
    input.fileHandleForWriting.write(Data("{\"id\":1,\"method\":\"probe\"}\n".utf8))
    try? input.fileHandleForWriting.close()
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    if process.isRunning {
        process.terminate()
        result["timedOut"] = true
    }
    process.waitUntilExit()
    result["status"] = Int(process.terminationStatus)
    result["reason"] = process.terminationReason == .exit ? "exit" : "signal"
    let reply = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if let data = reply.split(separator: "\n").first.map({ Data($0.utf8) }),
        let object = try? JSONSerialization.jsonObject(with: data)
    {
        result["reply"] = object
    } else {
        result["stdout"] = String(reply.prefix(400))
    }
    if !stderr.isEmpty { result["stderr"] = String(Spike.tilde(stderr).prefix(400)) }
    return result
}

// MARK: - Headless self-test

@MainActor
final class SelfTest {
    let seconds: Double
    let spawnTools: Bool
    var pool: DatabasePool?
    var start = 0
    var token: Int32 = 0
    var finished = false

    init(seconds: Double, spawnTools: Bool) {
        self.seconds = seconds
        self.spawnTools = spawnTools
    }

    func run() {
        var ready = Spike.probe(origin: "app", write: false)
        ready["event"] = "ready"
        do {
            let pool = try Spike.openStore()
            self.pool = pool
            start = try Spike.read(pool).counter
        } catch {
            ready["error"] = Spike.describe(error)
            emit(ready)
            finish(seen: nil)
            return
        }
        let status = notify_register_dispatch(Spike.changed, &token, .main) { _ in
            MainActor.assumeIsolated { SelfTest.current?.check(by: "notification") }
        }
        ready["registered"] = status == UInt32(NOTIFY_STATUS_OK)
        emit(ready)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { SelfTest.current?.check(by: "polling") }
        }
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { SelfTest.current?.finish(seen: nil) }
        }
    }

    func check(by how: String) {
        guard !finished, let pool, let state = try? Spike.read(pool), state.counter > start else { return }
        var seen = state.json
        seen["event"] = "seen"
        seen["by"] = how
        seen["countersSeen"] = state.counter - start
        finish(seen: seen)
    }

    func finish(seen: [String: Any]?) {
        guard !finished else { return }
        finished = true
        emit(seen ?? ["event": "timeout", "seconds": seconds])
        if spawnTools {
            for tool in toolPaths { emit(spawn(tool.name, tool.path, seconds: 3)) }
        }
        notify_cancel(token)
        emit(["event": "done"])
        exit(0)
    }

    static var current: SelfTest?
}

// MARK: - The window, for the owner's check

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let text = NSTextView()
    var token: Int32 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Knot Dev: SP-3 check"
        let scroll = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        _ = notify_register_dispatch(Spike.changed, &token, .main) { _ in
            MainActor.assumeIsolated { Controller.current?.refresh(reason: "the tool wrote") }
        }
        refresh(reason: "launch")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The counter each form showed at the last refresh, so the window says which moved.
    var last: [String: Int] = [:]

    func refresh(reason: String) {
        var lines: [String] = []
        for team in [false, true] {
            let form = Spike.groupForm(team: team)
            let probe = Spike.probe(origin: "app", write: false, team: team)
            let counter = (probe["before"] as? [String: Any])?["counter"] as? Int
            let moved = counter.map { c in last[form].map { c > $0 ? "moved" : "unchanged" } ?? "first read" } ?? "-"
            if let counter { last[form] = counter }
            lines.append(
                "\(form) form: store \(probe["store"] ?? "?"), counter \(counter.map(String.init) ?? "-") (\(moved))"
                    + ((probe["error"] as? String).map { "\n  error: \($0)" } ?? ""))
        }
        let tool = "\"" + Spike.tilde(Bundle.main.bundleURL.appending(path: "Contents/MacOS/knot-dev").path) + "\""
        text.string = """
            Refreshed: \(reason), \(Date().formatted(date: .omitted, time: .standard))

            What the app sees, in each form of the group:
            \(lines.joined(separator: "\n"))

            In Terminal, run each line. After an add, the form it names reads "moved":
              \(tool) probe
              \(tool) add synthetic
              \(tool) probe --team-group
              \(tool) add synthetic --team-group
              \(tool) cleanup
              \(tool) cleanup --team-group
            """
    }

    static var current: Controller?
}

if arguments.first == "--self-test" {
    let seconds = arguments.firstIndex(of: "--seconds").flatMap { Double(arguments[safe: $0 + 1] ?? "") } ?? 8
    let test = SelfTest(seconds: min(seconds, 20), spawnTools: arguments.contains("--spawn"))
    SelfTest.current = test
    test.run()
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let controller = Controller()
    Controller.current = controller
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
