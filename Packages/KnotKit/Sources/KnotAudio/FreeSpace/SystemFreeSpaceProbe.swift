import Foundation
import KnotCore

/// The free space of a volume, read from the system (docs/architecture.md §5). The recorder
/// tells a full disk from another failed write by it, because the audio file's error does not
/// say, and refuses to start a recording that would not have room.
///
/// It reads the volume that holds `url`, or, when `url` is not there yet, the volume of the
/// nearest folder above it that is: a folder the recorder makes sits on its parent's volume. On
/// iOS and macOS it answers the space free for important use, which counts what the system can
/// purge for it; the watchOS SDK has no such key, and there it answers the space free now.
public struct SystemFreeSpaceProbe: FreeSpaceProbe {
    public init() {}

    public func availableBytes(forVolumeAt url: URL) -> Int64? {
        var place = url
        while true {
            // A fresh read every time: a URL keeps the values it read.
            place.removeAllCachedResourceValues()
            if let bytes = Self.free(at: place) { return max(bytes, 0) }
            let parent = place.deletingLastPathComponent()
            guard parent.path != place.path else { return nil }
            place = parent
        }
    }

    private static func free(at url: URL) -> Int64? {
        #if os(watchOS)
            guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]) else { return nil }
            return values.volumeAvailableCapacity.map(Int64.init)
        #else
            guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            else { return nil }
            return values.volumeAvailableCapacityForImportantUsage
        #endif
    }
}
