import Foundation

// `knot-eval`: two local commands that score speech and cleanup, on the committed synthetic
// fixtures (`--set synthetic`) or on the owner's recordings in the folder that
// KNOT_LOCAL_FIXTURES names (`--set local`). They print numbers only. It never waits.
//
// This file only chooses the command. `speech` is WP-13's and lives in Speech.swift, and
// `cleanup` is WP-14's and lives in Cleanup.swift. Each package edits its own file, and
// neither edits the other's or this one.

let arguments = Array(CommandLine.arguments.dropFirst())
let status: Int32
switch arguments.first {
case "speech":
    status = await SpeechCommand.run(Array(arguments.dropFirst()))
case "cleanup":
    status = await CleanupCommand.run(Array(arguments.dropFirst()))
default:
    FileHandle.standardError.write(Data("usage: knot-eval speech|cleanup --set synthetic|local\n".utf8))
    status = 2
}
exit(status)
