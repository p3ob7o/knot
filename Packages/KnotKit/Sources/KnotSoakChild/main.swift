import Foundation

// KnotSoakChild: the child process of the capture ledger soak (docs/architecture.md §17,
// docs/plan/WP-06.md). Its parent, the soak in Tests/KnotSoak/, makes a store in a temporary
// folder, starts the child over it, kills it at a point the seed chooses from a named list, and
// relaunches it, until the script has run. Every line the child prints holds IDs, indexes,
// numbers, codes and hashes, never text: SoakLaunch.swift lists them.
//
//   KnotSoakChild                     prints that it is ready, and exits
//   KnotSoakChild run --root <folder> --seed <n> --launch <n> --from <index> --to <index>
//                     --count <n> [--kill <point> --after <n>] [--fault <name>]
//
// `run` opens the store under <folder>, recovers what earlier launches left, runs captures
// <from> up to <to> of the script that <seed> makes for <count> captures, and exits. With
// `--kill` it stops at the <n>th pass of <point> and waits there to be killed (KillPoints.swift).
// `--fault` injects one of the faults that the soak's own tests prove it catches
// (InjectedFaults.swift).
//
// The child runs the fakes, so it does its work only in a debug build or one that sets
// KNOT_FAKES. Any other build says so and exits.

#if DEBUG || KNOT_FAKES
    func arguments() -> [String: String] {
        var values: [String: String] = [:]
        var rest = Array(CommandLine.arguments.dropFirst(2))
        while rest.count >= 2, rest[0].hasPrefix("--") {
            values[String(rest[0].dropFirst(2))] = rest[1]
            rest.removeFirst(2)
        }
        guard rest.isEmpty else { Say.fail("usage") }
        return values
    }

    func runChild() async {
        let all = CommandLine.arguments.dropFirst()
        guard let command = all.first else {
            Say.line("KnotSoakChild: ready")
            return
        }
        guard command == "run" else { Say.fail("unknown command") }
        let watch = ParentWatch.start()
        defer { watch.cancel() }
        let values = arguments()
        guard let root = values["root"], let seed = values["seed"].flatMap(UInt64.init),
            let launch = values["launch"].flatMap(Int.init), let from = values["from"].flatMap(Int.init),
            let to = values["to"].flatMap(Int.init), let count = values["count"].flatMap(Int.init),
            0 <= from, from <= to, to <= count
        else { Say.fail("usage") }
        var fault: InjectedFault?
        if let name = values["fault"] {
            guard let known = InjectedFault(rawValue: name) else { Say.fail("unknown fault") }
            fault = known
        }
        let launchRun = SoakLaunch(
            SoakLaunch.Options(
                root: URL(fileURLWithPath: root, isDirectory: true), seed: seed, launch: launch, range: from..<to,
                count: count, killPoint: values["kill"], killAfter: values["after"].flatMap(Int.init) ?? 1,
                fault: fault))
        await launchRun.run()
    }

    await runChild()
#else
    FileHandle.standardError.write(
        Data("KnotSoakChild: this build has no fakes; build it in debug or with KNOT_FAKES\n".utf8))
    exit(3)
#endif
