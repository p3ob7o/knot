import Foundation

// `knot-eval`: two local commands that score speech and cleanup, on the committed synthetic
// fixtures (`--set synthetic`) or on the owner's recordings in the folder that
// KNOT_LOCAL_FIXTURES names (`--set local`). They print numbers only. It never waits.
//
// This file only reads the options and chooses the command. `speech` is WP-13's and lives in
// Speech.swift, and `cleanup` is WP-14's and lives in Cleanup.swift. Each package edits its
// own files. This file and EvalOptions.swift are shared: a change goes through the orchestrator.

let arguments = Array(CommandLine.arguments.dropFirst())
let named = arguments.first.flatMap(EvalCommand.init(rawValue:))

// A first word that is neither a command nor an option is a mistyped command, not a run of both.
if named == nil, let first = arguments.first, !first.hasPrefix("--") {
    FileHandle.standardError.write(Data(EvalOptions.usage.utf8))
    exit(EvalExit.usage)
}

let options: EvalOptions
switch EvalOptions.parse(named == nil ? arguments : Array(arguments.dropFirst())) {
case .success(let parsed):
    options = parsed
case .failure(.usage):
    FileHandle.standardError.write(Data(EvalOptions.usage.utf8))
    exit(EvalExit.usage)
case .failure(.inputMissing(let what)):
    FileHandle.standardError.write(Data("knot-eval: \(what)\n".utf8))
    exit(EvalExit.inputMissing)
}

let status: Int32
switch named {
case .speech?:
    status = await SpeechCommand.run(options)
case .cleanup?:
    status = await CleanupCommand.run(options)
case nil:
    // No command named: both run, speech first. On the owner's recordings cleanup reads the
    // transcripts that speech writes, so there it runs only after a speech run that passed.
    let speech = await SpeechCommand.run(options)
    if options.set == .local, speech != EvalExit.ok {
        status = speech
    } else {
        status = EvalExit.ofBoth(speech: speech, cleanup: await CleanupCommand.run(options))
    }
}
exit(status)
