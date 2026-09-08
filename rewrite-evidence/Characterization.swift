// Baseline observations only. Exit zero means the harness ran, not that the app is safe.
import Foundation

@main
struct Characterization {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("knot-audit-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let vault = base.appendingPathComponent("Vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var results: [[String: String]] = []

        var settings = AppSettings()
        settings.dailyFolder = ""
        settings.dailyFilenameFormat = "[Invalid]"
        let daily = vault.appendingPathComponent("Invalid.md")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: daily)
        _ = try DailyAppender(vault: vault, settings: settings).append(Note(content: "new", mode: .daily, createdAt: date))
        let after = try Data(contentsOf: daily)
        results.append(["id": "R01", "result": "invalid UTF-8 replaced: \(after != Data([0xFF, 0xFE, 0x00, 0x80]))"])

        settings.dailyHeading = ""
        let before = try Data(contentsOf: daily)
        _ = try DailyAppender(vault: vault, settings: settings).append(Note(content: "lost", mode: .daily, createdAt: date))
        results.append(["id": "R02", "result": "empty heading returned success without insertion: \(try Data(contentsOf: daily) == before)"])

        settings.inboxFolder = ""
        settings.inboxFilenameFormat = "[Collision]"
        let writer = InboxWriter(vault: vault, settings: settings)
        let first = try writer.makePlan(for: Note(content: "first", mode: .inbox, createdAt: date))
        let second = try writer.makePlan(for: Note(content: "second", mode: .inbox, createdAt: date))
        _ = try writer.write(first)
        _ = try writer.write(second)
        results.append(["id": "R03", "result": "two plans same URL: \(first.fileURL == second.fileURL); final content: \(try String(contentsOf: first.fileURL, encoding: .utf8))"])

        settings.inboxFolder = "../Outside"
        _ = try InboxWriter(vault: vault, settings: settings).write(Note(content: "escape", mode: .inbox, createdAt: date))
        results.append(["id": "R04", "result": "inbox escaped vault: \(fm.fileExists(atPath: base.appendingPathComponent("Outside/Collision.md").path))"])

        let outside = base.appendingPathComponent("Outside")
        try fm.createSymbolicLink(at: vault.appendingPathComponent("assets"), withDestinationURL: outside)
        settings.attachmentFolderPath = "assets"
        let attachment = try AttachmentWriter(vault: vault, settings: settings).write(AttachmentWriteRequest(filename: "photo.png", data: Data([1, 2, 3]), noteURL: vault.appendingPathComponent("note.md")))
        results.append(["id": "R05", "result": "attachment followed symlink outside: \(fm.fileExists(atPath: outside.appendingPathComponent("photo.png").path)); returned: \(attachment.markdownEmbed)"])

        let markdown = "```markdown\n## Quick notes\nexample\n```\n\n## Quick notes\nreal\n"
        let spliced = HeadingSplicer(heading: "## Quick notes").append(bullet: "- capture", to: markdown)
        results.append(["id": "R06", "result": "matched heading in fenced example; capture placed before the real section: \(spliced.range(of: "- capture")!.lowerBound < spliced.range(of: "real")!.lowerBound); output: \(spliced)"])
        let headingsURL = vault.appendingPathComponent("Headings.md")
        try markdown.write(to: headingsURL, atomically: true, encoding: .utf8)
        let headings = VaultStructure.markdownHeadings(in: headingsURL)
        results.append(["id": "R07", "result": "heading count: \(headings.count); unique IDs: \(Set(headings.map(\.id)).count)"])

        let queue = try Queue(directory: base.appendingPathComponent("Queue"))
        let note = Note(content: "recoverable", mode: .daily, createdAt: date)
        var data = try JSONEncoder().encode(note)
        data.append(contentsOf: "\n{broken JSON\n".utf8)
        try data.write(to: queue.url)
        results.append(["id": "R08", "result": "queue with malformed line returned without error; recovered records: \(try queue.loadAll().count)"])
        let noContent = BulletTemplate.render(template: "- {{HH:mm}}", content: "missing thought", date: date)
        results.append(["id": "R09", "result": "template omitted note: \(!noContent.contains("missing thought"))"])
        results.append(["id": "R10", "result": "lone CR multiline route: \(RoutingPolicy().decide(for: "one\rtwo").rawValue)"])
        let json = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
