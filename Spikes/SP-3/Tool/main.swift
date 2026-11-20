import Darwin
import Foundation

// The spike's tool. Every packaging the spike compares compiles this file: the bare
// executable, the one with no Info.plist, the one with only `inherit`, and the helper
// bundle. Each command prints one JSON object on standard output.
//
//   knot-dev --version
//   knot-dev probe [--write]     who am I, can I reach the group container and the store
//   knot-dev add <text>          writes a synthetic note and posts the Darwin notification
//   knot-dev export <folder>     tries to write a file into a folder named on the command line
//   knot-dev export -            writes the export to standard output, for the shell to place
//   knot-dev export-group        writes the export into the group container and names it
//   knot-dev mcp                 one JSON request per line on standard input, one reply per line
//   knot-dev cleanup             removes the spike's files from the group container, by name

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func emit(_ object: [String: Any]) { print(Spike.json(object)) }

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("knot-dev: \(message)\n".utf8))
    exit(code)
}

let exportText = "# Synthetic SP-3 export\n\nOne synthetic note, written by the spike.\n"

func tryExport(to folderPath: String) -> [String: Any] {
    var result = Spike.identity()
    let target = URL(fileURLWithPath: folderPath, isDirectory: true).appending(path: "knot-sp3-export.md")
    result["target"] = Spike.tilde(target.path)
    do {
        try Data(exportText.utf8).write(to: target, options: .atomic)
        result["written"] = true
    } catch {
        result["written"] = false
        result["error"] = Spike.describe(error)
    }
    return result
}

func handle(request line: String) -> [String: Any] {
    guard
        let data = line.data(using: .utf8),
        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return ["error": "not a JSON object"] }
    let id = request["id"] ?? NSNull()
    switch request["method"] as? String {
    case "probe":
        return ["id": id, "result": Spike.probe(origin: "mcp", write: false)]
    case "add":
        return ["id": id, "result": Spike.probe(origin: "mcp", write: true)]
    default:
        return ["id": id, "error": "unknown method"]
    }
}

switch arguments.first {
case "--version":
    print("knot-dev \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (sp3)")
case "probe":
    emit(Spike.probe(origin: "cli", write: arguments.contains("--write")))
case "add":
    guard arguments.count >= 2 else { fail("add needs text", code: 2) }
    emit(Spike.probe(origin: "cli", write: true))
case "export":
    guard arguments.count >= 2 else { fail("export needs a folder, or - for standard output", code: 2) }
    if arguments[1] == "-" {
        FileHandle.standardOutput.write(Data(exportText.utf8))
    } else {
        emit(tryExport(to: arguments[1]))
    }
case "export-group":
    do {
        let url = try Spike.spikeFolder().appending(path: "group-export.md")
        try Data(exportText.utf8).write(to: url, options: .atomic)
        emit(["written": true, "path": Spike.tilde(url.path)])
    } catch {
        emit(["written": false, "error": Spike.describe(error)])
    }
case "mcp":
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        emit(handle(request: line))
    }
case "cleanup":
    emit(Spike.cleanup())
default:
    fail("usage: knot-dev probe|add|export|export-group|mcp|cleanup", code: 2)
}
