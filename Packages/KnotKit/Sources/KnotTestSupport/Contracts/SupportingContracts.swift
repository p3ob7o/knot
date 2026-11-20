import Foundation
import KnotCore
import Testing

/// The contract suite of `SurfaceRouter` (docs/architecture.md §5 and §14): each destination
/// lands where it was sent, in order.
public enum SurfaceRouterContract {
    /// - Parameter landed: where the opens landed, in order, as the app shows them.
    public static func run(
        _ router: any SurfaceRouter, landed: @Sendable () async -> [SurfaceDestination]
    ) async throws {
        let note: NoteID = Identifier(uuid: UUID())
        let destinations: [SurfaceDestination] = [.capture, .sketch, .search, .note(note)]
        for destination in destinations { await router.open(destination) }
        #expect(await landed() == destinations, "Each open lands where it was sent.")
    }
}

/// The contract suite of `CueEmitter` (docs/product-spec.md §4.5): every cue plays, in order.
public enum CueEmitterContract {
    /// - Parameter played: the cues that played, in order.
    public static func run(_ emitter: any CueEmitter, played: @Sendable () async -> [Cue]) async throws {
        for cue in Cue.allCases { emitter.emit(cue) }
        #expect(await played() == Cue.allCases, "Every cue plays, in order.")
    }
}

/// The contract suite of `FreeSpaceProbe` (docs/architecture.md §5).
public enum FreeSpaceProbeContract {
    /// - Parameter folder: a folder that exists.
    public static func run(_ probe: any FreeSpaceProbe, folder: URL) async throws {
        let bytes = probe.availableBytes(forVolumeAt: folder)
        #expect(bytes.map { $0 >= 0 } == true, "A volume that exists has a free space it can tell.")
    }
}

/// The contract suite of `InstallIdentity` (docs/architecture.md §4): one ID, the same every
/// time it is read on this install.
public enum InstallIdentityContract {
    public static func run(_ make: @Sendable () async throws -> any InstallIdentity) async throws {
        let identity = try await make()
        let first = try identity.installID()
        #expect(try identity.installID() == first, "The install ID stays the same.")
        #expect(first != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    }
}

/// The contract suite of `ProcessNotifier` (docs/architecture.md §7): a notice that one process
/// posts reaches another, and not the one that posted it.
public enum ProcessNotifierContract {
    /// - Parameters:
    ///   - poster: the notifier of the process that writes, such as the `knot` command.
    ///   - listener: the notifier of another process on the same store, such as the app.
    public static func run(poster: any ProcessNotifier, listener: any ProcessNotifier) async throws {
        let heard = listener.storeChanges()
        let echo = poster.storeChanges()
        poster.postStoreChanged()
        let arrived = await SuiteWait.value("the notice to reach the other process") {
            var iterator = heard.makeAsyncIterator()
            return await iterator.next() != nil
        }
        #expect(arrived == true, "A notice reaches the other process.")
        listener.postStoreChanged()
        let answered = await SuiteWait.value("the other process's notice") {
            var iterator = echo.makeAsyncIterator()
            return await iterator.next() != nil
        }
        #expect(answered == true, "And the other way.")
    }
}

/// The contract suite of `Lifecycle` (docs/architecture.md §5): each event arrives in order,
/// and the foreground state follows it.
public enum LifecycleContract {
    /// - Parameter send: makes the app meet an event.
    public static func run(_ lifecycle: any Lifecycle, send: @Sendable (LifecycleEvent) async -> Void) async throws {
        let events = lifecycle.events()
        await send(.wentToBackground)
        #expect(!lifecycle.isInForeground, "In the background after going there.")
        await send(.cameForward)
        #expect(lifecycle.isInForeground, "In front after coming forward.")
        let seen = await SuiteWait.value("the two events") {
            var iterator = events.makeAsyncIterator()
            var seen: [LifecycleEvent] = []
            while seen.count < 2, let event = await iterator.next() { seen.append(event) }
            return seen
        }
        #expect(seen == [.wentToBackground, .cameForward], "Each event arrives, in order.")
    }
}
