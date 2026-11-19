import Foundation
import KnotCore
import Synchronization

/// A file layer in memory that keeps what was synced apart from what was not, and loses the
/// unsynced part when a test cuts the power (docs/architecture.md §6, rule 7).
///
/// It models what a drive promises. A file's content survives a power cut only once the file
/// was synced. A name in a folder, made by a write, a rename, a removal or the creation of a
/// folder, survives only once that folder was synced, so a folder whose parent was never
/// synced is lost with everything in it. Only the root, `/`, is there from the start. The
/// store's and the recorder's tests use it too, to show that recovery holds whatever a power
/// cut drops.
public final class PowerCutFileLayer: FileLayer {
    private struct File {
        var current: Data
        var synced: Data
    }

    private enum Entry: Equatable {
        case file(Int)
        case folder
    }

    private struct Folder {
        var current: [String: Entry] = [:]
        var synced: [String: Entry] = [:]
    }

    private struct State {
        var files: [Int: File] = [:]
        var folders: [String: Folder] = ["/": Folder()]
        var nextFile = 0
        var operations = 0
        var syncs = 0
        var forgotten: Set<Int> = []
        var denied: Set<String> = []
        var dieAfter: Int?
        var failNextWrite: KnotError?
    }

    private let state = Mutex(State())

    public init() {}

    /// How many operations ran, which a test uses to cut the power after each one in turn.
    public var operationCount: Int { state.withLock { $0.operations } }

    /// How many syncs of files and folders ran.
    public var syncCount: Int { state.withLock { $0.syncs } }

    /// From now on, every operation after `count` more fails, as if the process had died
    /// there. Call `cutPower()` afterwards to drop what was not synced.
    public func die(afterOperations count: Int) {
        state.withLock { $0.dieAfter = $0.operations + count }
    }

    /// Fails the next write with `error`, such as `disk_full`.
    public func failNextWrite(with error: KnotError) {
        state.withLock { $0.failNextWrite = error }
    }

    /// Makes sync number `index` from now, counting from 0, return without syncing, as code
    /// that forgot it would. A test uses it to show that it notices every missing sync.
    public func forgetSync(_ index: Int) {
        state.withLock { _ = $0.forgotten.insert($0.syncs + index) }
    }

    /// Makes the folder at `url` one that this process may not open, as a sandboxed app may not
    /// open a folder above its container: syncing it fails with `EPERM`.
    public func denyOpening(_ url: URL) {
        state.withLock { _ = $0.denied.insert(Self.path(url)) }
    }

    /// Removes a folder and everything in it, synced, as something other than Knot might.
    /// Tests use it to change the store behind a `DurableFile`'s back; `FileLayer` itself has
    /// no way to remove a folder.
    public func removeFolderBehindTheStoresBack(_ url: URL) {
        state.withLock { state in
            let path = Self.path(url)
            let parent = Self.path(url.deletingLastPathComponent())
            state.folders[parent]?.current[url.lastPathComponent] = nil
            state.folders[parent]?.synced[url.lastPathComponent] = nil
            state.folders = state.folders.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        }
    }

    /// Cuts the power: every name and every file content that was not synced is lost.
    /// Afterwards the layer works again, as after a restart.
    public func cutPower() {
        state.withLock { state in
            var survivors: [String: Folder] = [:]
            var pending = ["/"]
            while let path = pending.popLast() {
                guard var folder = state.folders[path] else { continue }
                folder.current = folder.synced
                survivors[path] = folder
                for (name, entry) in folder.synced where entry == .folder {
                    pending.append(path == "/" ? "/" + name : path + "/" + name)
                }
            }
            state.folders = survivors
            let reachable = Set(
                survivors.values.flatMap { folder in
                    folder.current.values.compactMap { entry -> Int? in
                        if case .file(let id) = entry { return id }
                        return nil
                    }
                })
            state.files = state.files.filter { reachable.contains($0.key) }
            for id in state.files.keys {
                state.files[id]!.current = state.files[id]!.synced
            }
            state.dieAfter = nil
            state.failNextWrite = nil
            state.forgotten = []
        }
    }

    /// Creates one folder, whose parent must exist. A folder that is already there is kept.
    public func createFolder(_ url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let (parent, name) = try Self.locate(url, in: state)
            switch state.folders[parent]!.current[name] {
            case .folder: return
            case .file: throw KnotError.writeFailed.with(.init(posixError: EEXIST))
            case nil:
                state.folders[parent]!.current[name] = .folder
                state.folders[Self.path(url)] = Folder()
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
            switch state.folders[folder]!.current[name] {
            case .file(let id):
                state.files[id]!.current = data
            case .folder:
                throw KnotError.writeFailed.with(.init(posixError: EISDIR))
            case nil:
                let id = state.nextFile
                state.nextFile += 1
                state.files[id] = File(current: data, synced: Data())
                state.folders[folder]!.current[name] = .file(id)
            }
        }
    }

    public func syncFile(_ url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let id = try Self.file(url, in: state)
            if Self.forgets(&state) { return }
            state.files[id]!.synced = state.files[id]!.current
        }
    }

    public func rename(_ source: URL, to destination: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let id = try Self.file(source, in: state)
            let (from, name) = try Self.locate(source, in: state)
            let (to, newName) = try Self.locate(destination, in: state)
            // As rename(2): a file never replaces a folder.
            if state.folders[to]!.current[newName] == .folder {
                throw KnotError.writeFailed.with(.init(posixError: EISDIR))
            }
            state.folders[from]!.current[name] = nil
            state.folders[to]!.current[newName] = .file(id)
        }
    }

    public func syncFolder(_ url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let path = Self.path(url)
            guard !state.denied.contains(path) else { throw KnotError.writeFailed.with(.init(posixError: EPERM)) }
            guard state.folders[path] != nil else { throw KnotError.writeFailed.with(.init(posixError: ENOENT)) }
            if Self.forgets(&state) { return }
            state.folders[path]!.synced = state.folders[path]!.current
        }
    }

    public func remove(_ url: URL) throws(KnotError) {
        try run { state throws(KnotError) in
            let (folder, name) = try Self.locate(url, in: state)
            guard state.folders[folder]!.current[name] != .folder else {
                throw KnotError.writeFailed.with(.init(posixError: EISDIR))
            }
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

    public func entryKind(_ url: URL) -> FileEntryKind? {
        state.withLock { state in
            let path = Self.path(url)
            if path == "/" { return .folder }
            guard let (folder, name) = try? Self.locate(url, in: state) else { return nil }
            switch state.folders[folder]!.current[name] {
            case .folder: return .folder
            case .file: return .file
            case nil: return nil
            }
        }
    }

    public func contents(of folder: URL) throws(KnotError) -> [String] {
        try state.withLock { state throws(KnotError) in
            guard let entries = state.folders[Self.path(folder)]?.current else {
                throw KnotError.writeFailed.with(.init(posixError: ENOENT))
            }
            return entries.keys.sorted()
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

    /// Counts a sync, and says whether it is one to forget.
    private static func forgets(_ state: inout State) -> Bool {
        let index = state.syncs
        state.syncs += 1
        return state.forgotten.contains(index)
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
        guard case .file(let id) = state.folders[folder]!.current[name] else {
            throw KnotError.writeFailed.with(.init(posixError: ENOENT))
        }
        return id
    }
}
