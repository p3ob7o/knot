import KnotCore

/// The live entry point of KnotLink. It provides `WatchLink`, and the Watch's coordinator.
///
/// KnotApp calls `wire(_:)` when it builds `.live` on the iPhone, and the Watch app calls it
/// too, so that this package wires itself in without editing `Sources/KnotApp/`.
public enum KnotLinkLive {
    /// Leaves the environment's `WatchLink` as it is. Only the Watch has a link, so on the
    /// iPhone it stays the unavailable one. On the Watch the link needs its store's locations
    /// and the session's transport, which WP-17's second pull request brings: until then the
    /// Watch app gets the unavailable one here, and its composition calls
    /// `wire(_:locations:transport:)` once it has a transport.
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        environment
    }

    /// The Watch's link: an `OutboxLink` over `transport`, with its outbox in `locations`
    /// (`StoreLocations.outbox`, in the Watch app's own container), on the environment's clock.
    public static func wire(
        _ environment: AppEnvironment, locations: StoreLocations, transport: any LinkTransport
    ) -> AppEnvironment {
        var wired = environment
        wired.watchLink = OutboxLink(
            outbox: WatchOutbox(locations: locations), transport: transport, clock: environment.clock)
        return wired
    }

    /// The Watch's sequence of record, convert and send, over the environment's recorder and the
    /// link that `wire(_:locations:transport:)` made. `nil` when the environment has no such link.
    /// The Watch app calls `launch()` on it once, at launch, and sends it every press.
    public static func coordinator(for environment: AppEnvironment, launchID: LaunchID, device: DeviceID)
        -> WatchCoordinator?
    {
        guard let link = environment.watchLink as? OutboxLink else { return nil }
        return WatchCoordinator(
            recorder: environment.recorder, link: link, ids: environment.ids, clock: environment.clock,
            launchID: launchID, device: device)
    }
}
