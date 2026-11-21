import Foundation

/// Whether the Watch app has an app group, from its Info dictionary alone: `KnotSigning`, which
/// follows the build's signing configuration, and `KnotAppGroup`, the group it names.
///
/// A build that says it is team-signed and names no usable group is refused, never run without
/// one: the composition passes it to `StoreLocations.resolve` as a group with no container,
/// which refuses it with a typed error. The UI test target compiles this file too, and tests
/// each row.
enum WatchAppGroup: Equatable, Sendable {
    /// A team-signed build, with the group it names.
    case present(identifier: String)
    /// A build with the local signing configuration, which has no group: what would sit in it
    /// stays in the app's own container.
    case absent
    /// A build whose configuration says nothing usable: refused.
    case refused

    init(info: [String: Any]) {
        switch info["KnotSigning"] as? String {
        case "local":
            self = .absent
        case "team":
            let identifier = (info["KnotAppGroup"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // An identifier still holding `$(` is a build setting that was never filled in.
            self = identifier.isEmpty || identifier.contains("$(") ? .refused : .present(identifier: identifier)
        default:
            self = .refused
        }
    }
}
