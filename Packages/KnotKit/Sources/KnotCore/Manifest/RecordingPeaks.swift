import Foundation

/// The level peaks of a recording, kept beside it so that a waveform never needs the audio
/// decoded (docs/architecture.md §8): the one format for them in a file, as `CaptureManifest`
/// is for a manifest. They are made from audio, so like the audio itself they are in no log
/// line, no error and no diagnostics file.
///
/// A file of peaks is a header of 12 bytes, then one byte for each value:
///
/// - bytes 0 to 3: `KNPK`, in ASCII;
/// - byte 4: the format, 1;
/// - bytes 5 to 7: zero;
/// - bytes 8 to 11: how many of the recording's own frames one value covers, a 32-bit
///   little-endian integer above zero.
///
/// A value is the largest absolute sample in its stretch of frames, linear: 0 for silence and
/// 255 for full scale. The stretch is a fixed count of the file's own frames, never a buffer,
/// because buffers last from 100 to 400 ms and vary. At `framesPerValue(sampleRate:)`, 50 ms, a
/// recording at the 30-minute limit has 36,000 values, and its file stays under 64 KB.
///
/// A writer writes the header once, then appends values. A reader takes whole values, accepts
/// a file cut anywhere after its header, and answers no peaks for a header it does not know: it
/// never throws into a recording's path. The values may run a sync ahead of the audio or behind
/// it, and `held(toFrames:)` holds them to the audio's length.
public struct RecordingPeaks: Hashable, Sendable {
    /// The format this build writes and reads.
    public static let currentFormat: UInt8 = 1
    /// The bytes before the first value.
    public static let headerLength = 12
    private static let magic = Array("KNPK".utf8)

    /// How many of the recording's frames one value covers.
    public var framesPerValue: Int
    /// The values, one for each stretch, in order.
    public var values: [UInt8]

    public init(framesPerValue: Int, values: [UInt8] = []) {
        self.framesPerValue = framesPerValue
        self.values = values
    }

    /// The stretch for audio at `sampleRate`: 50 ms of its frames, at least one frame.
    public static func framesPerValue(sampleRate: Double) -> Int {
        max(1, Int((sampleRate / 20).rounded()))
    }

    /// The header that begins a file of peaks whose values each cover `framesPerValue` frames.
    public static func header(framesPerValue: Int) -> Data {
        let stretch = UInt32(clamping: max(framesPerValue, 1))
        var header = Data(magic)
        header.append(contentsOf: [currentFormat, 0, 0, 0])
        withUnsafeBytes(of: stretch.littleEndian) { header.append(contentsOf: $0) }
        return header
    }

    /// The value of a stretch whose largest absolute sample is `peak`, on a scale where 1 is full
    /// scale: linear, held between 0 and 255. Not a number is silence.
    public static func value(peak: Float) -> UInt8 {
        guard peak.isFinite else { return 0 }
        return UInt8(min(255, max(0, (peak.magnitude * 255).rounded())))
    }

    /// The value of a stretch whose largest absolute 16-bit sample is `largestSample`.
    public static func value(largestSample: Int16) -> UInt8 {
        let magnitude = Int(largestSample.magnitude)
        return UInt8(min(255, (magnitude * 255 + 16_383) / 32_767))
    }

    /// The whole file: the header, then every value.
    public func encoded() -> Data {
        Self.header(framesPerValue: framesPerValue) + Data(values)
    }

    /// The peaks a file holds, cut anywhere after its header: every whole value. `nil`, no
    /// peaks, for a file shorter than its header, a header this build does not know, or a
    /// stretch of zero frames.
    public init?(reading data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerLength, Array(bytes[0..<4]) == Self.magic,
            bytes[4] == Self.currentFormat, bytes[5] == 0, bytes[6] == 0, bytes[7] == 0
        else { return nil }
        let stretch = bytes[8..<12].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard stretch > 0 else { return nil }
        self.init(framesPerValue: Int(stretch), values: Array(bytes[Self.headerLength...]))
    }

    /// Whether `data` is peaks a store keeps with a recording: it reads as this format, and holds
    /// no more values than a recording of `Limits.longestRecording` has at 50 ms a value, 36,000,
    /// which is 36,012 bytes with the header. A file of peaks does not say its sample rate, so the
    /// bound is on the values. Both stores and the `NoteStore` suite hold peaks to it.
    public static func isStorable(_ data: Data) -> Bool {
        guard data.count <= headerLength + Int(Limits.longestRecording) * 20, let peaks = RecordingPeaks(reading: data)
        else { return false }
        return peaks.values.count <= Int(Limits.longestRecording) * 20
    }

    /// The values that cover the first `frames` frames of the audio, none past its end: peaks
    /// that ran ahead of the audio are held to its length.
    public func held(toFrames frames: Int64) -> [UInt8] {
        guard frames > 0, framesPerValue > 0 else { return [] }
        let covering = (frames + Int64(framesPerValue) - 1) / Int64(framesPerValue)
        return Array(values.prefix(Int(min(covering, Int64(values.count)))))
    }
}
