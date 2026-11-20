import Foundation
import KnotCore
import Testing

/// The contract suite of `SurfaceRouter` (docs/architecture.md §5 and §14): each destination
/// lands where it was sent, in order, a second identical request too (finding 21).
public enum SurfaceRouterContract {
    /// - Parameter landed: where the opens landed, in order, as the app shows them.
    public static func run(
        _ router: any SurfaceRouter, landed: @Sendable () async -> [SurfaceDestination]
    ) async throws {
        let note: NoteID = Identifier(uuid: UUID())
        let destinations: [SurfaceDestination] = [.capture, .sketch, .search, .search, .note(note), .note(note)]
        for destination in destinations { await router.open(destination) }
        #expect(await landed() == destinations, "Each open lands where it was sent.")
    }
}

/// The contract suite of `CueEmitter` (docs/product-spec.md §4.5): every cue plays, in order, and
/// a cue emitted twice plays twice, as a second capture saved is cued again (finding 21).
public enum CueEmitterContract {
    /// - Parameter played: the cues that played, in order.
    public static func run(_ emitter: any CueEmitter, played: @Sendable () async -> [Cue]) async throws {
        let cues = Cue.allCases.flatMap { [$0, $0] }
        for cue in cues { emitter.emit(cue) }
        #expect(await played() == cues, "Every cue plays, in order, each time.")
    }
}

/// The contract suite of `FreeSpaceProbe` (docs/architecture.md §5). The port lets a probe
/// answer that it cannot tell, for any volume (finding 21); what it tells is never negative,
/// and a probe that cannot tell never answers a number instead.
public enum FreeSpaceProbeContract {
    /// - Parameters:
    ///   - folder: a folder that exists.
    ///   - cannotTell: a place for which the probe cannot tell, such as a path with no volume
    ///     behind it, if the subject has one.
    public static func run(_ probe: any FreeSpaceProbe, folder: URL, cannotTell: URL? = nil) async throws {
        if let bytes = probe.availableBytes(forVolumeAt: folder) {
            #expect(bytes >= 0, "Free space is never negative.")
        }
        if let cannotTell {
            #expect(probe.availableBytes(forVolumeAt: cannotTell) == nil, "It says when it cannot tell.")
        }
    }
}

/// The contract suite of `InstallIdentity` (docs/architecture.md §4): one ID, the same every
/// time it is read on this install, and another on another install, so that a store restored
/// onto another device is told apart (finding 21).
public enum InstallIdentityContract {
    /// - Parameters:
    ///   - thisInstall: the identity of this install.
    ///   - anotherInstall: the identity of another install, as on another device.
    public static func run(
        thisInstall: @Sendable () async throws -> any InstallIdentity,
        anotherInstall: @Sendable () async throws -> any InstallIdentity
    ) async throws {
        let identity = try await thisInstall()
        let first = try identity.installID()
        #expect(try identity.installID() == first, "The install ID stays the same.")
        #expect(first != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        #expect(try await anotherInstall().installID() != first, "Another install has another ID.")
    }
}

/// The contract suite of `ProcessNotifier` (docs/architecture.md §7): a notice that one process
/// posts reaches another, either way. Whether the poster hears its own is left open: Darwin
/// notifications deliver it, and acting on it is harmless.
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
        await send(.willTerminate)
        #expect(!lifecycle.isInForeground, "Not in front once it terminates.")
        let seen = await SuiteWait.value("the three events") {
            var iterator = events.makeAsyncIterator()
            var seen: [LifecycleEvent] = []
            while seen.count < 3, let event = await iterator.next() { seen.append(event) }
            return seen
        }
        #expect(seen == [.wentToBackground, .cameForward, .willTerminate], "Each event arrives, in order.")
    }
}
