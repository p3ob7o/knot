/// The stored copy of a recording: AAC, mono, in `.m4a`, about 0.5 MB a minute
/// (docs/architecture.md §8). The conversion itself belongs to WP-12's second pull request.
public enum StoredCopy {
    /// The AAC bit rate for mono audio at `sampleRate`.
    ///
    /// 64 kbit/s is about 0.5 MB a minute. The AAC encoder accepts 64 kbit/s for mono only from
    /// 22.05 kHz; at 16 kHz it accepts at most 48 kbit/s (measured on macOS 27.3 by WP-12's
    /// proof step), so a slower input gets that.
    public static func bitRate(forSampleRate sampleRate: Double) -> Int {
        sampleRate >= 22_050 ? 64_000 : 48_000
    }
}
