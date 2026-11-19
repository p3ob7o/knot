/// The format of the file written while a recording runs (docs/architecture.md §8).
///
/// The file must stay readable when the process is killed in the middle of a write. WP-12's
/// proof step measures both candidates with a kill test and picks one; docs/notes/WP-12.md
/// gives the result.
public enum WorkingFileFormat: String, Sendable, CaseIterable {
    /// Core Audio Format holding 16-bit linear PCM, mono. Core Audio writes the data chunk
    /// with an unknown size, so a reader takes the audio to the end of the file.
    case caf

    /// AAC, mono, in fragmented MPEG-4 with a fragment every second. A reader sees the audio
    /// up to the last complete fragment. AVAssetWriter is unavailable on watchOS, so this
    /// candidate does not exist there.
    case fragmentedMPEG4 = "fmp4"

    /// The file name extension of a working file in this format.
    public var fileExtension: String {
        switch self {
        case .caf: "caf"
        case .fragmentedMPEG4: "m4a"
        }
    }

    /// Whether every sample written is read back unchanged. AAC is lossy, so only the count of
    /// frames of a fragmented MPEG-4 file can be compared with what was written.
    public var isLossless: Bool {
        switch self {
        case .caf: true
        case .fragmentedMPEG4: false
        }
    }

    /// Whether this platform can write the format.
    public static var availableOnThisPlatform: [WorkingFileFormat] {
        #if os(watchOS)
            [.caf]
        #else
            [.caf, .fragmentedMPEG4]
        #endif
    }
}
