// Prints the on-screen windows of a process, one line each: its ID, layer and size.
// It reads only what CGWindowList gives without the Screen Recording permission.
//
//   xcrun swift scripts/lib/windows.swift <pid>

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: windows.swift <pid>\n".utf8))
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == pid {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    print("\(number) layer \(layer) \(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)")
}
