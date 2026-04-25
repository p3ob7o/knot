import Foundation

/// Renders a bullet template by replacing `{{...}}` placeholders. The token
/// `{{content}}` is replaced with the note's text; everything else inside
/// the braces is treated as a `MomentFormat` pattern and formatted against
/// the note's timestamp.
///
/// Example: `- [[{{YYYY-MM-DD}}]] {{HH:mm}} {{content}}` produces
/// `- [[2026-04-25]] 14:32 a thought`.
public enum BulletTemplate {

    public static func render(
        template: String,
        content: String,
        date: Date,
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone = .current
    ) -> String {
        var output = ""
        var i = template.startIndex
        let openMarker = "{{"
        let closeMarker = "}}"

        while i < template.endIndex {
            if let openRange = template.range(of: openMarker, range: i..<template.endIndex),
               openRange.lowerBound == i,
               let closeRange = template.range(
                    of: closeMarker,
                    range: openRange.upperBound..<template.endIndex
               ) {
                let inner = String(template[openRange.upperBound..<closeRange.lowerBound])
                if inner == "content" {
                    output.append(content)
                } else {
                    output.append(MomentFormat.string(
                        from: date,
                        format: inner,
                        locale: locale,
                        timeZone: timeZone
                    ))
                }
                i = closeRange.upperBound
            } else {
                output.append(template[i])
                i = template.index(after: i)
            }
        }
        return output
    }
}
