import AVFAudio
import Foundation
import KnotCore
import Synchronization

/// The level peaks of one recording, appended beside its working file while it records, in the
/// format of `RecordingPeaks` (docs/architecture.md §8): one value for each fixed stretch of the
/// file's frames, the largest absolute sample in it, so that a waveform never needs the audio
/// decoded.
///
/// The values are made in the delivery, from what was written to the working file and nothing
/// else, and the file is written only on the session's queue, at each sync and at the end: a
/// delivery never waits for the peaks file. A recording never fails, ends or waits because its
/// peaks could not be written: a peaks file that cannot be made or appended is given up, with
/// one log line, and the recording goes on. The peaks are made from audio, so no log line, error
/// or diagnostics file holds a value.
final class PeaksWriter: Sendable {
    private let url: URL
    private let framesPerValue: Int
    private let capture: CaptureID
    private let log: KnotLog
    /// The values being made, in the delivery.
    private let making = Mutex(Making())
    /// The file, touched on the session's queue only.
    private let file = Mutex(File())

    private struct Making {
        /// The largest absolute sample of the stretch under way, and how many of its frames came.
        var largest: Float = 0
        var framesInStretch = 0
        /// Whole stretches' values not yet appended.
        var pending: [UInt8] = []
        /// True once the recording's audio has all come: nothing more is taken.
        var closed = false
    }

    private struct File {
        var handle: FileHandle?
        /// True once the file is made, true once it is given up or closed.
        var made = false
        var done = false
    }

    init(url: URL, sampleRate: Double, capture: CaptureID, log: KnotLog) {
        self.url = url
        framesPerValue = RecordingPeaks.framesPerValue(sampleRate: sampleRate)
        self.capture = capture
        self.log = log
    }

    /// Takes the samples of a buffer the working file accepted. In the delivery; never touches
    /// the drive.
    func take(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let samples = Levels.floats(of: buffer)
        let framesPerValue = self.framesPerValue
        making.withLock { making in
            guard !making.closed else { return }
            for sample in samples {
                let magnitude = sample.magnitude
                if magnitude > making.largest { making.largest = magnitude }
                making.framesInStretch += 1
                if making.framesInStretch == framesPerValue {
                    making.pending.append(RecordingPeaks.value(peak: making.largest))
                    making.largest = 0
                    making.framesInStretch = 0
                }
            }
        }
    }

    /// Appends the whole stretches made since the last time. On the session's queue, at a sync.
    func flush() {
        append(
            making.withLock { making in
                defer { making.pending = [] }
                return making.pending
            })
    }

    /// Appends the rest, the stretch under way among it, and closes the file: the recording's
    /// audio has all come. On the session's queue, as the recording ends.
    func finish() {
        let rest = making.withLock { making in
            making.closed = true
            if making.framesInStretch > 0 { making.pending.append(RecordingPeaks.value(peak: making.largest)) }
            defer { making.pending = [] }
            return making.pending
        }
        append(rest)
        close()
    }

    /// Takes nothing more and writes nothing more, for a recording whose files are removed.
    func abandon() {
        making.withLock {
            $0.closed = true
            $0.pending = []
        }
        close()
    }

    private func close() {
        let handle = file.withLock { file in
            file.done = true
            defer { file.handle = nil }
            return file.handle
        }
        try? handle?.close()
    }

    /// Appends `values`, making the file with its header the first time. A failure gives the
    /// file up.
    private func append(_ values: [UInt8]) {
        file.withLock { file in
            guard !file.done else { return }
            do {
                if !file.made {
                    file.made = true
                    guard
                        FileManager.default.createFile(
                            atPath: url.path, contents: RecordingPeaks.header(framesPerValue: framesPerValue))
                    else { throw CocoaError(.fileWriteUnknown) }
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    file.handle = handle
                }
                guard !values.isEmpty, let handle = file.handle else { return }
                try handle.write(contentsOf: Data(values))
            } catch {
                // The recording goes on without its peaks.
                file.done = true
                try? file.handle?.close()
                file.handle = nil
                log.capture(
                    capture, "recording_peaks_given_up", .number("error_code", (error as NSError).code), level: .error)
            }
        }
    }
}
