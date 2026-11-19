import Foundation
import KnotAudio
import KnotCore

// KnotAudioCrashHost: the process that KnotAudio's kill tests start and kill
// (docs/architecture.md §17), and the tool of WP-12's proof step. It runs on the Mac and,
// through `xcrun simctl spawn`, in the iOS and watchOS simulators. It records injected audio
// only and never opens a hardware input.
//
//   record          records injected audio into a working file until done or killed
//   inspect         reads a working file back, as recovery would
//   render          writes the injected clip at another sample rate into a CAF file
//   measure-start   times the start of a recording, step by step
//   measure-size    measures the working file per minute, the cost of a sync, and the copy
//   kill-test       (Mac only) the parent of the kill test: starts, kills and inspects children
//
// With no command it reports that it is ready, which WP-01's test of the crash host checks.

setvbuf(stdout, nil, _IOLBF, 0)

let commandLine = Array(CommandLine.arguments.dropFirst())
if commandLine.isEmpty {
    print("KnotAudioCrashHost: ready")
    exit(0)
}

do {
    let arguments = try Arguments(commandLine)
    switch arguments.command {
    case "record": try await record(arguments)
    case "inspect": try await inspect(arguments)
    case "render": try await render(arguments)
    case "measure-start": try await measureStart(arguments)
    case "measure-size": try await measureSize(arguments)
    #if os(macOS)
        case "kill-test": exit(try await killTest(arguments) ? 0 : 1)
    #endif
    default: throw HostError.usage("unknown command \(arguments.command)")
    }
} catch {
    FileHandle.standardError.write(Data("KnotAudioCrashHost: \(error)\n".utf8))
    exit((error as? HostError)?.isUsage == true ? 2 : 1)
}

extension HostError {
    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }
}
