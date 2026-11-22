import Foundation
import KnotCore
import Synchronization

#if os(iOS)
    import UIKit
#endif

/// The app's foreground and background events, read from the system (docs/architecture.md §5):
/// the `Lifecycle` port's adapter for iOS and for macOS. No module takes the port itself; the
/// composition wires its events to the calls the modules expose for the app coming forward.
///
/// It observes the application's notifications by name, so it never touches the application
/// object itself: on iOS `UIApplication`'s did-become-active, did-enter-background and
/// will-terminate, which the SDK declares nonisolated; on macOS `NSApplication`'s
/// did-become-active, did-resign-active and will-terminate, by the names of their constants. A
/// process starts in the foreground, as an app does when it is launched.
public final class SystemLifecycle: NSObject, Lifecycle {
    private struct State {
        var inForeground = true
        var watchers: [UUID: AsyncStream<LifecycleEvent>.Continuation] = [:]
    }

    private let state = Mutex(State())
    private let center: NotificationCenter

    /// The notification of each event, as this platform names it.
    static var names: [(Notification.Name, LifecycleEvent)] {
        #if os(iOS)
            [
                (UIApplication.didBecomeActiveNotification, .cameForward),
                (UIApplication.didEnterBackgroundNotification, .wentToBackground),
                (UIApplication.willTerminateNotification, .willTerminate),
            ]
        #elseif os(macOS)
            [
                (Notification.Name("NSApplicationDidBecomeActiveNotification"), .cameForward),
                (Notification.Name("NSApplicationDidResignActiveNotification"), .wentToBackground),
                (Notification.Name("NSApplicationWillTerminateNotification"), .willTerminate),
            ]
        #else
            []
        #endif
    }

    /// - Parameter center: the notification centre the application posts to; a test passes its own.
    public init(center: NotificationCenter = .default) {
        self.center = center
        super.init()
        for (name, _) in Self.names {
            center.addObserver(self, selector: #selector(received(_:)), name: name, object: nil)
        }
    }

    deinit {
        center.removeObserver(self)
    }

    @objc private func received(_ notification: Notification) {
        guard let event = Self.names.first(where: { $0.0 == notification.name })?.1 else { return }
        meet(event)
    }

    public var isInForeground: Bool { state.withLock { $0.inForeground } }

    public func events() -> AsyncStream<LifecycleEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LifecycleEvent.self)
        let key = UUID()
        state.withLock { $0.watchers[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.watchers.removeValue(forKey: key) }
        }
        return stream
    }

    private func meet(_ event: LifecycleEvent) {
        let watchers = state.withLock { state in
            state.inForeground = event == .cameForward
            return Array(state.watchers.values)
        }
        for watcher in watchers { watcher.yield(event) }
    }
}

/// Background time held around work that must not be cut short by a suspension, such as the
/// store's opening, which may migrate (docs/architecture.md §7 and §13).
public protocol BackgroundTimeHold: Sendable {
    /// Holds background time until `release` is called on what it returns.
    func hold(_ name: String) async -> any BackgroundTimeRelease
}

/// Ends a hold of background time. Ending it twice ends it once.
public protocol BackgroundTimeRelease: Sendable {
    func release() async
}

/// The system's background time: on iOS a background task of the application, and nothing
/// elsewhere, where a process is not suspended for being behind.
public struct SystemBackgroundTime: BackgroundTimeHold {
    public init() {}

    public func hold(_ name: String) async -> any BackgroundTimeRelease {
        #if os(iOS)
            let task = BackgroundTask()
            await task.begin(name)
            return task
        #else
            return NoBackgroundTime()
        #endif
    }
}

struct NoBackgroundTime: BackgroundTimeRelease {
    func release() async {}
}

#if os(iOS)
    /// One background task of the application. If the time runs out first, the system's handler
    /// ends it, and a later `release` does nothing.
    final class BackgroundTask: BackgroundTimeRelease {
        private let identifier = Mutex(UIBackgroundTaskIdentifier.invalid)

        @MainActor
        func begin(_ name: String) {
            let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
            identifier.withLock { $0 = id }
        }

        func release() async {
            await MainActor.run { end() }
        }

        @MainActor
        private func end() {
            let id = identifier.withLock { id -> UIBackgroundTaskIdentifier in
                defer { id = .invalid }
                return id
            }
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
        }
    }
#endif
