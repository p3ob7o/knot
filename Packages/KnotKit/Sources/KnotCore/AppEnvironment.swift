/// Everything a running Knot process needs, reached through ports (docs/architecture.md §3).
///
/// WP-01 declares the type with its `.unavailable` value and nothing else, because the
/// environment factory in KnotApp returns that value. WP-02 adds the ports as they land.
/// KnotFakes builds `.preview` and KnotApp builds `.live`.
public struct AppEnvironment: Sendable {
    /// Every port reports that it is not there yet.
    public static let unavailable = AppEnvironment()

    private init() {}
}
