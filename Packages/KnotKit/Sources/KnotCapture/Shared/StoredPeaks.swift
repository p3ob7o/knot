import Foundation
import KnotCore

/// Keeps a stored recording's level peaks with its segment (`NoteStore.setPeaks(_:of:)`, pull
/// request 86), so that a waveform never needs the audio decoded (docs/architecture.md §8).
///
/// The recorder leaves the peaks beside the recording, at `StoreLocations.recordingPeaks(_:)`,
/// and they go with the working file. So whoever stores a recording, the engine, ingest or
/// recovery, keeps them once the capture's row points to its stored file and before
/// `Recorder.removeWorkingFile(of:)`. A death between the two leaves the working file and its
/// peaks, and recovery keeps them then. Peaks never fail, end or hold a capture: a store that
/// refuses them is logged by its code, and the capture goes on. They are made from audio, so no
/// value of them reaches a log line.
struct StoredPeaks: Sendable {
    let notes: any NoteStore
    let locations: StoreLocations
    let layer: any FileLayer
    let log: KnotLog

    /// The peaks the recorder left beside a recording, held to the `frames` its audio has: peaks
    /// that ran ahead of the audio are cut to its length. `nil` when there are none, or none this
    /// build reads.
    func fromFile(_ capture: CaptureID, frames: Int64) -> Data? {
        guard let data = try? layer.read(locations.recordingPeaks(capture)),
            let peaks = RecordingPeaks(reading: data)
        else { return nil }
        return RecordingPeaks(framesPerValue: peaks.framesPerValue, values: peaks.held(toFrames: frames)).encoded()
    }

    /// Keeps `peaks` with the capture's segment. Nothing to keep is not an error, and a refusal is
    /// logged and dropped.
    func keep(_ peaks: Data?, of capture: CaptureID) async {
        guard let peaks else { return }
        do throws(KnotError) {
            try await notes.setPeaks(peaks, of: SegmentID(capture))
            log.capture(capture, "recording_peaks_kept")
        } catch {
            log.failure(error.about(capture: capture), "recording_peaks_not_kept")
        }
    }
}
