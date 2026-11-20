import CryptoKit
import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Synchronization
import Testing

/// A fresh, empty folder in the system's temporary folder, which the test removes at its end.
func scratchFolder(_ name: String) -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "knot-link-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Waits, within `SuiteWait`'s bound, until an asynchronous condition holds.
@discardableResult
func eventually(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let held =
        await SuiteWait.value(what, sourceLocation: sourceLocation) {
            while !(await condition()) {
                if Task.isCancelled { return false }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return true
        } ?? false
    return held
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The iPhone in these tests: it checks each file against its manifest's checksum, and
/// acknowledges only a file that matches. It keeps nothing but counts.
final class TestPhone: Sendable {
    private struct Counts {
        var intact: [CaptureID: Int] = [:]
        var damaged: [CaptureID: Int] = [:]
    }

    private let counts = Mutex(Counts())
    let transport: FakeLinkTransport

    init(system: FakeLinkSystem) {
        transport = system.launch(.phone)
        transport.setFileReceiver { [self] file in receive(file) }
    }

    private func receive(_ file: ReceivedFile) -> LinkMessage? {
        guard let manifest = try? CaptureManifest.decode(file.manifest), let bytes = try? Data(contentsOf: file.url)
        else { return nil }
        let capture = manifest.captureID
        guard manifest.payloadSHA256 == sha256(bytes), manifest.payloadByteCount == Int64(bytes.count) else {
            counts.withLock { $0.damaged[capture, default: 0] += 1 }
            return nil
        }
        counts.withLock { $0.intact[capture, default: 0] += 1 }
        return .acknowledgement(capture)
    }

    /// True once the iPhone has acknowledged the capture.
    func acknowledged(_ capture: CaptureID) -> Bool { counts.withLock { ($0.intact[capture] ?? 0) > 0 } }

    func intactArrivals(_ capture: CaptureID) -> Int { counts.withLock { $0.intact[capture] ?? 0 } }

    func damagedArrivals(_ capture: CaptureID) -> Int { counts.withLock { $0.damaged[capture] ?? 0 } }
}

/// A Watch and an iPhone over a `FakeLinkSystem`, with a store in a scratch folder.
final class LinkHarness: Sendable {
    let root: URL
    let locations: StoreLocations
    let system: FakeLinkSystem
    let clock: FakeClock
    let ids: SeededIDGenerator
    let outbox: WatchOutbox
    let phone: TestPhone
    let files: StoreFiles
    private let watches = Mutex<[OutboxLink]>([])
    private let acknowledgedOnWatch = Box<[CaptureID]>([])

    init(seed: UInt64 = 1) {
        root = scratchFolder("harness")
        locations = StoreLocations.testing(root: root)
        system = FakeLinkSystem(receiving: root.appending(path: "Received", directoryHint: .isDirectory))
        clock = FakeClock()
        ids = SeededIDGenerator(seed: seed, clock: clock)
        outbox = WatchOutbox(locations: locations)
        phone = TestPhone(system: system)
        files = locations.durableFiles(layer: PosixFileLayer())
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// A new launch of the Watch app, with its link. Every acknowledgement its link reports
    /// is kept, in order.
    func launchWatch(stallLimit: TimeInterval = OutboxLink.defaultStallLimit) -> (OutboxLink, FakeLinkTransport) {
        let transport = system.launch(.watch)
        let link = OutboxLink(outbox: outbox, transport: transport, clock: clock, stallLimit: stallLimit)
        let stream = link.acknowledgements()
        Task { [acknowledgedOnWatch] in
            for await capture in stream { acknowledgedOnWatch.update { $0.append(capture) } }
        }
        watches.withLock { $0.append(link) }
        return (link, transport)
    }

    /// The captures the Watch's links reported as acknowledged.
    var acknowledgementsSeen: [CaptureID] { acknowledgedOnWatch.value }

    /// A converted recording beside the recorder's files, as the coordinator hands it to the link.
    func convertedRecording(bytes: Data? = nil) throws -> (CaptureManifest, URL) {
        let capture: CaptureID = ids.make()
        let data = bytes ?? Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(capture.uuid.uuid.15)) })
        let url = locations.convertedRecording(capture)
        try files.place(data, at: url)
        let manifest = CaptureManifest(
            captureID: capture, kind: .voice,
            origin: CaptureOrigin(source: .device(Identifier(uuid: UUID())), surface: .watch),
            launchID: ids.make(), startedAt: clock.now(), endedAt: clock.now().addingTimeInterval(1),
            duration: .seconds(1), placement: .window)
        return (manifest, url)
    }

    /// Sends a new converted recording and returns its capture.
    @discardableResult
    func sendNew(on link: OutboxLink) async throws -> CaptureID {
        let (manifest, url) = try convertedRecording()
        try await link.send(manifest, file: url)
        return manifest.captureID
    }

    func inOutbox(_ capture: CaptureID) -> Bool { outbox.entry(capture) != nil }
}

/// A value that tasks share.
final class Box<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) { state = Mutex(value) }

    var value: Value { state.withLock { $0 } }

    func update(_ change: (inout Value) -> Void) { state.withLock { change(&$0) } }
}
