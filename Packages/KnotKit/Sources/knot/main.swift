import Foundation
import KnotAgent
import KnotCore

// The `knot` command (docs/product-spec.md §10). KnotAgent holds the commands. This file
// reads the tool's name, flavour and version from the Info.plist embedded in its binary, and
// hands KnotAgent its ports.
//
// Until WP-34's second pull request wires the real store in, the ports are the unfilled ones
// of `AppEnvironment.unavailable`, so a command that needs the store fails with what they
// answer, and never with a result. The tool opens no store and reads nothing in the group
// container. Its gates are the build's own, from its milestone level.

let info = Bundle.main.infoDictionary ?? [:]
let arguments = Array(CommandLine.arguments.dropFirst())
let tool = ToolInfo(
    name: CommandLine.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "knot",
    version: info["CFBundleShortVersionString"] as? String ?? "unversioned",
    flavour: info["KnotFlavour"] as? String ?? "dev")
let output = StandardOutput()

// An agent never runs the milestone tool, so it cannot open the owner's notes by accident
// (docs/architecture.md §7).
if let refusal = Agent.refusal(flavour: tool.flavour, environment: ProcessInfo.processInfo.environment) {
    exit(Agent.refuse(refusal, arguments: arguments, tool: tool, output: output).rawValue)
}

let unfilled = AppEnvironment.unavailable
let context = AgentContext(
    tool: tool, notes: unfilled.notes, settings: unfilled.settings,
    gates: MilestoneGates(infoValue: info["KnotMilestoneLevel"] as? String), clock: unfilled.clock,
    ids: unfilled.ids, notifier: unfilled.notifier, launchID: unfilled.ids.make(), thisDevice: nil,
    speech: .unavailable, store: nil, input: StandardInput(), output: output)
exit(await Agent.run(arguments, in: context).rawValue)
