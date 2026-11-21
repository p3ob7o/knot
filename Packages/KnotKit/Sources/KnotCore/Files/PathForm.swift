import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// How the files code compares paths: by the real folder or file they name, never by the form
/// in which they are written.
///
/// `URL.standardizedFileURL` drops a leading `/private` only from a path that exists, so the
/// same folder reads as `/private/var/x` before `x` exists and as `/var/x` after, and an app
/// group's container is handed over in its `/private/var/…` form. A root kept in one form then
/// stops matching the paths below it once they are made. Here `.` and `..` are worked out from
/// the text alone, and the deepest part of the path that exists is read as the system resolves
/// it, through every symbolic link, from the real file system.
enum PathForm {
    /// `url`'s path as components below `/`, with `.` and `..` worked out from the text alone.
    static func lexical(_ url: URL) -> [String] {
        var parts: [String] = []
        for component in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return parts
    }

    /// The real path of what `url` names, as components below `/`: its deepest part that
    /// exists, resolved as the system resolves it, then the rest as written. The same folder
    /// gives the same components whether it is written with `/private` or without, through a
    /// symbolic link or not, and whether it exists yet or not.
    static func real(_ url: URL) -> [String] {
        real(lexical(url))
    }

    static func real(_ parts: [String]) -> [String] {
        var count = parts.count
        while count > 0 {
            let path = "/" + parts.prefix(count).joined(separator: "/")
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                return lexical(URL(fileURLWithPath: String(cString: resolved))) + parts.dropFirst(count)
            }
            count -= 1
        }
        return parts
    }

    /// A folder's URL for `parts`.
    static func folder(_ parts: [String]) -> URL {
        URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: true)
    }
}
