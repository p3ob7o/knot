import Foundation
import KnotAudio
import KnotCore

// KnotAudioCrashHost: the process that KnotAudio's kill tests start and kill
// (docs/architecture.md §17). It runs the live recorder on injected audio only, and never opens
// a hardware input. It runs on the Mac and, through `xcrun simctl spawn`, in the iOS and watchOS
// simulators.
//
//   record          records injected audio with the live recorder until done or killed
//   recover         runs recovery from a launch of its own and checks what it finds
//   measure-start   times the live recorder's start
//   policy          prints whether this process may open a hardware input, and opens nothing
//   kill-test       (Mac only) the parent of the kill test: starts, kills and recovers children
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
    case "recover": try await recover(arguments)
    case "measure-start": try await measureStart(arguments)
    case "policy": policy()
    #if os(macOS)
        case "kill-test": exit(try await killTest(arguments) ? 0 : 1)
    #endif
    default: throw HostError.usage("unknown command \(arguments.command)")
    }
} catch {
    FileHandle.standardError.write(Data("KnotAudioCrashHost: \(error)\n".utf8))
    exit((error as? HostError)?.isUsage == true ? 2 : 1)
}

/// `policy`: whether this process may open a hardware input, by `HardwareInputPolicy` alone. It
/// asks and touches nothing of the audio system. Prints `policy allowed`, or `policy refused
/// <reason>`.
func policy() {
    if let refusal = HardwareInputPolicy.refusalForThisProcess() {
        print("policy refused \(refusal.rawValue)")
    } else {
        print("policy allowed")
    }
}

extension HostError {
    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }
}
