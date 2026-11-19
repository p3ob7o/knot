import Foundation
import KnotCore

/// A fixed day for rule tables, so that times read as on a clock: `at("09:58")`.
let day = Date(timeIntervalSince1970: 1_795_000_000)

/// The time `clock` ("HH:MM" or "HH:MM:SS") on the fixed day.
func at(_ clock: String) -> Date {
    let parts = clock.split(separator: ":").map { Double($0)! }
    let seconds = parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)
    return day.addingTimeInterval(seconds)
}

/// A deterministic fresh ID for tests: version 7, numbered.
func id<Tag>(_ number: Int, _: Tag.Type = Tag.self) -> Identifier<Tag> {
    Identifier(uuid: UUIDv7.make(milliseconds: UInt64(number), random: Array(repeating: 0, count: 10)))
}

let thisDevice: DeviceID = id(9001)
let otherDevice: DeviceID = id(9002)
let fromDevice = SegmentOrigin.device(thisDevice)

/// The folder of the repository, found by walking up from this file.
func repositoryRoot(file: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appending(path: "PLAN.md").path) { return url }
    }
    fatalError("No repository root above \(file).")
}
