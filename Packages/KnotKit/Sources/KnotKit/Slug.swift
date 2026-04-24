import Foundation

/// Generates filesystem-safe slugs from free text. Uses the first non-empty
/// line, lowercases, removes non-alphanumeric characters, and joins the
/// remaining word-runs with hyphens. Limited to `maxLength` characters.
public enum Slug {

    public static func from(_ text: String, maxLength: Int = 50) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""

        let lowered = firstLine.lowercased()

        // Replace any character outside [a-z0-9] with whitespace, then split
        // on whitespace runs and rejoin with single hyphens.
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let normalized = String(lowered.map { allowed.contains($0) ? $0 : " " })
        let words = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let joined = words.joined(separator: "-")
        if joined.isEmpty { return "" }
        return String(joined.prefix(maxLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
