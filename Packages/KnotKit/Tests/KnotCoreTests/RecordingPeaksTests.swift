import Foundation
import KnotCore
import Testing

/// The level peaks' format, held to its golden bytes, so that it cannot drift.
@Suite struct RecordingPeaksTests {
    /// The header and the values, byte for byte: `KNPK`, format 1, three zeros, the stretch as a
    /// 32-bit little-endian integer, then one byte for each value.
    @Test func theFormatMatchesItsGoldenBytes() {
        let peaks = RecordingPeaks(framesPerValue: 800, values: [0, 128, 255])
        let golden: [UInt8] = [
            0x4B, 0x4E, 0x50, 0x4B, 0x01, 0x00, 0x00, 0x00, 0x20, 0x03, 0x00, 0x00, 0x00, 0x80, 0xFF,
        ]
        #expect([UInt8](peaks.encoded()) == golden)
        #expect([UInt8](RecordingPeaks.header(framesPerValue: 800)) == Array(golden.prefix(12)))
        #expect(RecordingPeaks.headerLength == 12)
        #expect(RecordingPeaks(reading: Data(golden)) == peaks)
    }

    /// A file cut anywhere after its header reads back its whole values; one cut inside its
    /// header, or with a header this build does not know, is no peaks, and nothing throws.
    @Test func aReaderTakesWholeValuesAndNeverThrows() {
        let whole = [UInt8](RecordingPeaks(framesPerValue: 800, values: [1, 2, 3, 4]).encoded())
        for length in 0...whole.count {
            let read = RecordingPeaks(reading: Data(whole.prefix(length)))
            if length < RecordingPeaks.headerLength {
                #expect(read == nil, "Cut at \(length) bytes, inside the header.")
            } else {
                #expect(read?.values == Array(whole[RecordingPeaks.headerLength..<length]), "Cut at \(length) bytes.")
            }
        }
        var newer = whole
        newer[4] = 2
        #expect(RecordingPeaks(reading: Data(newer)) == nil, "A format this build does not know.")
        var other = whole
        other[0] = 0x58
        #expect(RecordingPeaks(reading: Data(other)) == nil, "Not a peaks file.")
        var empty = whole
        empty.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        #expect(RecordingPeaks(reading: Data(empty)) == nil, "A stretch of no frames.")
    }

    /// Peaks that ran ahead of the audio are held to its length; the last value may cover part
    /// of a stretch.
    @Test func peaksAreHeldToTheAudiosLength() {
        let peaks = RecordingPeaks(framesPerValue: 800, values: [9, 8, 7, 6, 5])
        #expect(peaks.held(toFrames: 0) == [])
        #expect(peaks.held(toFrames: 1) == [9])
        #expect(peaks.held(toFrames: 800) == [9])
        #expect(peaks.held(toFrames: 801) == [9, 8])
        #expect(peaks.held(toFrames: 2_400) == [9, 8, 7])
        #expect(peaks.held(toFrames: 1_000_000) == [9, 8, 7, 6, 5], "Peaks behind the audio stay as they are.")
    }

    /// A value is the largest absolute sample, linear: 0 for silence, 255 for full scale.
    @Test func aValueIsTheLargestAbsoluteSampleLinear() {
        #expect(RecordingPeaks.value(peak: 0) == 0)
        #expect(RecordingPeaks.value(peak: 1) == 255)
        #expect(RecordingPeaks.value(peak: -1) == 255)
        #expect(RecordingPeaks.value(peak: 0.5) == 128)
        #expect(RecordingPeaks.value(peak: 4) == 255)
        #expect(RecordingPeaks.value(peak: .nan) == 0)
        #expect(RecordingPeaks.value(largestSample: 0) == 0)
        #expect(RecordingPeaks.value(largestSample: .max) == 255)
        #expect(RecordingPeaks.value(largestSample: .min) == 255)
        #expect(RecordingPeaks.value(largestSample: -16_384) == 128)
    }

    /// At the 30-minute limit, at every rate an input gives, the file stays under 64 KB.
    @Test(arguments: [8_000.0, 16_000, 22_050, 44_100, 48_000, 96_000])
    func thirtyMinutesStayUnderSixtyFourKilobytes(rate: Double) {
        let stretch = RecordingPeaks.framesPerValue(sampleRate: rate)
        let frames = Int64(rate * Double(Limits.longestRecording))
        let values = (frames + Int64(stretch) - 1) / Int64(stretch)
        #expect(Int64(RecordingPeaks.headerLength) + values < 65_536, "\(values) values of \(stretch) frames")
    }
}

/// The one mapping from the stored snapshot to the state the press rule weighs.
@Suite struct SavedRecordingStateMappingTests {
    let capture = CaptureID(uuid: UUID())
    let launch = LaunchID(uuid: UUID())
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func anIdleSnapshotOrOneWithNoCaptureIsNoSavedState() {
        #expect(SavedRecordingState(.idle) == nil)
        #expect(SavedRecordingState(RecordingStateSnapshot(phase: .idle, captureID: capture, heartbeat: now)) == nil)
        #expect(SavedRecordingState(RecordingStateSnapshot(phase: .recording, heartbeat: now)) == nil)
    }

    @Test(arguments: [RecordingPhase.starting, .recording, .stopping])
    func aSnapshotWithACaptureIsItsSavedState(phase: RecordingPhase) {
        let snapshot = RecordingStateSnapshot(
            phase: phase, captureID: capture, startedAt: now, heartbeat: now, ownerLaunch: launch, ownerPID: 7)
        #expect(
            SavedRecordingState(snapshot) == SavedRecordingState(captureID: capture, launchID: launch, heartbeatAt: now)
        )
    }

    /// No heartbeat is no sign of life: stale. No owner launch is a launch that no process has,
    /// and the press rule still recovers the capture.
    @Test func aSnapshotWithNoHeartbeatOrNoLaunchIsAnOrphan() throws {
        let saved = try #require(SavedRecordingState(RecordingStateSnapshot(phase: .recording, captureID: capture)))
        #expect(saved.isStale(at: now))
        #expect(
            saved.launchID != launch
                && saved.launchID.uuid == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        let decision = RecordingPressRule.decide(Press(.tap, at: now), recorder: .idle, saved: saved)
        #expect(decision == .recoverOrphanThenStart(capture))
    }
}
