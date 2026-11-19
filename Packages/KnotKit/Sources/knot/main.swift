import Foundation
import KnotAgent
import KnotCore
import KnotExport
import KnotStore

// The `knot` command (docs/product-spec.md §10). WP-34 builds its commands. WP-01 makes it
// a tool that knows its name, its flavour and its version, which it reads from the
// Info.plist embedded in its binary, so that the packaging proof can run it.

let info = Bundle.main.infoDictionary ?? [:]
let name = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "knot"
let flavour = info["KnotFlavour"] as? String ?? "dev"
let version = info["CFBundleShortVersionString"] as? String ?? "unversioned"

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("\(name): \(message)\n".utf8))
    exit(code)
}

// An agent never runs the milestone tool, so it cannot open the owner's notes by accident
// (docs/architecture.md §7).
if flavour == "milestone", ProcessInfo.processInfo.environment["KNOT_AGENT"] == "1" {
    fail("this is the milestone build and KNOT_AGENT is set. Agents use knot-dev.", code: 7)
}

switch CommandLine.arguments.dropFirst().first {
case "--version":
    print("\(name) \(version) (\(flavour))")
default:
    fail("no commands yet. WP-34 builds them.", code: 2)
}
