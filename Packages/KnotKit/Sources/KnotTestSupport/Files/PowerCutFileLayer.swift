import Foundation
import KnotCore
import Synchronization

/// A file layer in memory that keeps what was synced apart from what was not, and loses the
/// unsynced part when a test cuts the power (docs/architecture.md §6, rule 7).
///
/// It models what a drive promises. A file's content survives a power cut only once the file
/// was synced. A file's name in its folder, made by a write, a rename or a removal, survives
/// only once the folder was synced. Folders themselves are taken as durable once made. The
/// store's and the recorder's tests use it too, to show that recovery holds whatever a power
/// cut drops.
public final class PowerCutFileLayer: FileLayer {
    private struct File {
        var current: Data
        var synced: Data
    }

    private struct Folder {
        var current: [String: Int] = [:]
        var synced: [String: Int] = [:]
    }

    private struct State {
        var files: [Int: File] = [:]
        var folders: [String: Folder] = [:]
        var nextFile = 0
        var operations = 0
        var dieAfter: Int?
        var failNextWrite: KnotError?
    }

    private let state = Mutex(State())

    public init() {}

    /// How many operations ran, which a test uses to cut the power after each one in turn.
    public var operationCount: Int { state.withLock { $0.operations } }

    /// From now on, every operation after `count` more fails, as if the process had died
    /// there. Call `cutPower()` afterwards to drop what was not synced.
    public func die(afterOperations count: Int) {
        state.withLock { $0.dieAfter = $0.operations + count }
    }

    /// Fails the next write with `error`, such as `disk_full`.
    public func failNextWrite(with error: KnotError) {
        state.withLock { $0.failNextWrite = error }
    }

    /// Cuts the power: every folder entry and every file content that was not synced is lost.
    /// Afterwards the layer works again, as after a restart.
    public func cutPower() {
        state.withLock { state in
            for path in state.folders.keys {
                state.folders[path]!.current = state.folders[path]!.synced
            }
            let reachable = Set(state.folders.values.flatMap { $0.current.values })
            state.files = state.files.filter { reachable.contains($0.key) }
            for id in state.files.keys {
                state.files[id]!.current = state.files[id]!.synced
            }
            state.dieAfter = nil
            state.failNextWrite = nil
        }
    }

    public func createFolder(_ url: URL) throws(KnotError) {
        try run { state in
            var path = ""
            for component in Self.components(url) {
                path += "/" + component
                if state.folders[path] == nil { state.folders[path] = Folder() }
            }
        }
    }

    public func write(_ data: Data, to url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            if let error = state.failNextWrite {
                state.failNextWrite = nil
                throw error
            }
            let (folder, name) = try Self.locate(url, in: state)
            if let id = state.folders[folder]!.current[name] {
                state.files[id]!.current = data
            } else {
                let id = state.nextFile
                state.nextFile += 1
                state.files[id] = File(current: data, synced: Data())
                state.folders[folder]!.current[name] = id
            }
        }
    }

    public func syncFile(_ url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let id = try Self.file(url, in: state)
            state.files[id]!.synced = state.files[id]!.current
        }
    }

    public func rename(_ source: URL, to destination: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let id = try Self.file(source, in: state)
            let (from, name) = try Self.locate(source, in: state)
            let (to, newName) = try Self.locate(destination, in: state)
            state.folders[from]!.current[name] = nil
            state.folders[to]!.current[newName] = id
        }
    }

    public func syncFolder(_ url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let path = Self.path(url)
            guard state.folders[path] != nil else { throw KnotError.writeFailed.with(.init(posixError: ENOENT)) }
            state.folders[path]!.synced = state.folders[path]!.current
        }
    }

    public func remove(_ url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let (folder, name) = try Self.locate(url, in: state)
            state.folders[folder]!.current[name] = nil
        }
    }

    public func read(_ url: URL) throws(KnotError) -> Data {
        try state.withLock { state throws(KnotError) in
            let id = try Self.file(url, in: state)
            return state.files[id]!.current
        }
    }

    public func exists(_ url: URL) -> Bool {
        state.withLock { state in
            let path = Self.path(url)
            if state.folders[path] != nil { return true }
            return (try? Self.file(url, in: state)) != nil
        }
    }

    public func contents(of folder: URL) throws(KnotError) -> [String] {
        try state.withLock { state throws(KnotError) in
            guard let entries = state.folders[Self.path(folder)]?.current else {
                throw KnotError.writeFailed.with(.init(posixError: ENOENT))
            }
            let subfolders = state.folders.keys.compactMap { path -> String? in
                let parent = (path as NSString).deletingLastPathComponent
                return parent == Self.path(folder) ? (path as NSString).lastPathComponent : nil
            }
            return (Array(entries.keys) + subfolders).sorted()
        }
    }

    private func run(_ body: (inout State) throws(KnotError) -> Void) throws(KnotError) {
        try state.withLock { state throws(KnotError) in
            if let dieAfter = state.dieAfter, state.operations >= dieAfter {
                throw KnotError.writeFailed
            }
            state.operations += 1
            try body(&state)
        }
    }

    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.filter { $0 != "/" }
    }

    private static func path(_ url: URL) -> String {
        "/" + components(url).joined(separator: "/")
    }

    private static func locate(_ url: URL, in state: State) throws(KnotError) -> (String, String) {
        let folder = path(url.deletingLastPathComponent())
        guard state.folders[folder] != nil else { throw KnotError.writeFailed.with(.init(posixError: ENOENT)) }
        return (folder, url.lastPathComponent)
    }

    private static func file(_ url: URL, in state: State) throws(KnotError) -> Int {
        let (folder, name) = try locate(url, in: state)
        guard let id = state.folders[folder]!.current[name] else {
            throw KnotError.writeFailed.with(.init(posixError: ENOENT))
        }
        return id
    }
}
