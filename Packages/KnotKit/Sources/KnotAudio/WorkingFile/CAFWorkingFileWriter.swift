import AVFAudio
import Foundation

/// Writes 16-bit linear PCM, mono, in a Core Audio Format file, through `AVAudioFile`.
///
/// Core Audio writes the CAF data chunk with its size set to -1, which the format defines as
/// "to the end of the file", and leaves it so until the file is closed. A file whose process
/// was killed is therefore readable up to its last complete frame without any repair. Each
/// `append` reaches the operating system before it returns: `AVAudioFile` keeps no frames of
/// its own between writes of linear PCM, which the kill test checks.
final class CAFWorkingFileWriter: WorkingFileWriter {
    let url: URL
    let format = WorkingFileFormat.caf
    let sampleRate: Double
    private(set) var appendedFrames: Int64 = 0

    private var file: AVAudioFile?
    private let processingFormat: AVAudioFormat
    private let driveSync: DriveSync

    init(url: URL, sampleRate: Double, inputFormat: AVAudioCommonFormat) throws(WorkingFileError) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file: AVAudioFile
        do {
            // The file type comes from the extension, `.caf`.
            file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: inputFormat, interleaved: true)
        } catch {
            throw .create(error)
        }
        self.url = url
        self.sampleRate = sampleRate
        self.file = file
        self.processingFormat = file.processingFormat
        self.driveSync = try DriveSync(url: url)
    }

    func append(_ buffer: AVReadOnlyAudioPCMBuffer) throws(WorkingFileError) {
        guard let file else { throw .finished }
        guard buffer.format == processingFormat else { throw .formatMismatch }
        do {
            try file.write(from: buffer)
        } catch {
            throw .write(error)
        }
        appendedFrames += Int64(buffer.frameLength)
    }

    func syncToDrive() throws(WorkingFileError) {
        guard file != nil else { throw .finished }
        try driveSync.sync()
    }

    nonisolated(nonsending) func finish() async throws(WorkingFileError) {
        guard let file else { throw .finished }
        // Closing writes the final data size into the header. Sync after it, so that the
        // finished file, header included, is on the drive.
        file.close()
        self.file = nil
        try driveSync.sync()
        driveSync.close()
    }
}
