import AVFAudio
import KnotCore

/// What a session says about each buffer it writes: its level, and its audio for live text.
enum Levels {
    /// The peak and the root mean square of a mono buffer, each from 0 to 1.
    static func of(_ buffer: AVReadOnlyAudioPCMBuffer) -> (peak: Float, average: Float) {
        let samples = floats(of: buffer)
        guard !samples.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var squares: Double = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            squares += Double(sample) * Double(sample)
        }
        let average = Float((squares / Double(samples.count)).squareRoot())
        return (min(peak, 1), min(average, 1))
    }

    /// The buffer as chunks of at most 100 ms, the stretch the transcriber takes at a time
    /// (docs/architecture.md §8).
    static func chunks(of buffer: AVReadOnlyAudioPCMBuffer) -> [AudioChunk] {
        let samples = floats(of: buffer)
        let rate = buffer.format.sampleRate
        let size = max(Int(rate / 10), 1)
        return stride(from: 0, to: samples.count, by: size).map { start in
            AudioChunk(samples: Array(samples[start..<min(start + size, samples.count)]), sampleRate: rate)
        }
    }

    /// The samples of a mono buffer of 16-bit integers or 32-bit floats, from -1 to 1.
    static func floats(of buffer: AVReadOnlyAudioPCMBuffer) -> [Float] {
        let frames = buffer.frameLength
        guard frames > 0, buffer.format.channelCount == 1 else { return [] }
        return buffer.withUnsafeAudioBufferList { list -> [Float] in
            guard let data = list.pointee.mBuffers.mData else { return [] }
            switch buffer.format.commonFormat {
            case .pcmFormatInt16:
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: frames)
                return samples.map { Float($0) / 32_768 }
            case .pcmFormatFloat32:
                return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames))
            default:
                return []
            }
        }
    }
}
