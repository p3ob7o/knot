import AVFAudio
import Foundation

/// Audio that stands in for the microphone: a clip held in memory as 16-bit mono samples and
/// handed out in buffers, looping when a recording runs longer than the clip.
///
/// The recorder takes its audio from an injected source, and under test it never opens a
/// hardware input (docs/architecture.md §8). The clips come from the synthetic fixtures that
/// WP-04 generates.
public struct InjectedAudioClip: Sendable {
    /// 16-bit integer, mono, interleaved, at the clip's rate.
    public let format: AVAudioFormat
    public let samples: [Int16]

    public var sampleRate: Double { format.sampleRate }
    public var frameCount: Int { samples.count }

    public init(samples: [Int16], sampleRate: Double) throws(WorkingFileError) {
        guard
            !samples.isEmpty,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        else { throw .formatMismatch }
        self.format = format
        self.samples = samples
    }

    /// Decodes a mono audio file of any format that `AVAudioFile` reads.
    public static func load(contentsOf url: URL) throws(WorkingFileError) -> InjectedAudioClip {
        let contents = try WorkingFileReader.read(url, keepingSamples: true)
        return try InjectedAudioClip(samples: contents.samples ?? [], sampleRate: contents.sampleRate)
    }

    /// The clip at another sample rate, through `AVAudioConverter`, to inject audio at the rate
    /// a real input runs at.
    public func resampled(to rate: Double) throws(WorkingFileError) -> InjectedAudioClip {
        if rate == sampleRate { return self }
        guard
            let output = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: format, to: output)
        else { throw .formatMismatch }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let input = makeBuffer(from: 0, count: frameCount)
        let capacity = AVAudioFrameCount(Double(frameCount) * rate / sampleRate) + 4096
        var result: [Int16] = []
        result.reserveCapacity(Int(capacity))
        var supplied = false
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                throw .formatMismatch
            }
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw .unreadable(conversionError.map { .init($0) } ?? .init(domain: .other, code: 0))
            }
            if let data = chunk.int16ChannelData, chunk.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(chunk.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && chunk.frameLength == 0) { break }
        }
        return try InjectedAudioClip(samples: result, sampleRate: rate)
    }

    /// `count` frames that start `position` frames into a recording of this clip, looping.
    public func buffer(from position: Int64, count: Int) -> AVReadOnlyAudioPCMBuffer {
        AVReadOnlyAudioPCMBuffer(copying: makeBuffer(from: position, count: count))
    }

    /// The sample at `position` frames into a recording of this clip, looping.
    public func sample(at position: Int64) -> Int16 {
        samples[Int(position % Int64(samples.count))]
    }

    private func makeBuffer(from position: Int64, count: Int) -> AVAudioPCMBuffer {
        // The format is valid and the capacity positive, so the buffer always exists.
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(count, 1)))!
        buffer.frameLength = AVAudioFrameCount(count)
        if let destination = buffer.int16ChannelData?[0] {
            var source = Int(position % Int64(samples.count))
            for index in 0..<count {
                destination[index] = samples[source]
                source += 1
                if source == samples.count { source = 0 }
            }
        }
        return buffer
    }
}
