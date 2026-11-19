import AVFAudio
import Foundation

/// Writes the file of a recording in progress.
///
/// A writer belongs to one isolation domain: the recorder calls it from one place at a time,
/// in the order the audio arrived. `append` returns once the frames are in the file as far as
/// the operating system is concerned, so they survive a kill of the process. `syncToDrive`
/// returns once they would also survive a power cut.
public protocol WorkingFileWriter: AnyObject {
    var url: URL { get }
    var format: WorkingFileFormat { get }
    var sampleRate: Double { get }

    /// The frames handed to `append` so far.
    var appendedFrames: Int64 { get }

    /// Adds frames at the end of the file. The buffer must be mono at the writer's sample rate,
    /// in the common format the writer was made with.
    func append(_ buffer: AVReadOnlyAudioPCMBuffer) throws(WorkingFileError)

    /// Pushes everything appended so far to the drive.
    func syncToDrive() throws(WorkingFileError)

    /// Ends the file: writes what is left and closes it. Later calls fail with `finished`.
    nonisolated(nonsending) func finish() async throws(WorkingFileError)
}

/// Makes working-file writers.
public enum WorkingFile {
    /// A writer for a new file at `url`, which must not exist yet. Audio is mono at
    /// `sampleRate`, handed over in `inputFormat`. The folder that holds `url` is synced once
    /// the file exists, so its name survives a power cut.
    public static func makeWriter(
        format: WorkingFileFormat,
        url: URL,
        sampleRate: Double,
        inputFormat: AVAudioCommonFormat = .pcmFormatInt16
    ) throws(WorkingFileError) -> any WorkingFileWriter {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw .cannotCreate(.init(domain: .posix, code: Int(EEXIST)))
        }
        let writer: any WorkingFileWriter
        switch format {
        case .caf:
            writer = try CAFWorkingFileWriter(url: url, sampleRate: sampleRate, inputFormat: inputFormat)
        case .fragmentedMPEG4:
            #if os(watchOS)
                throw .unavailableOnThisPlatform
            #else
                writer = try FragmentedMPEG4WorkingFileWriter(
                    url: url, sampleRate: sampleRate, inputFormat: inputFormat)
            #endif
        }
        try DriveSync.syncFolder(url.deletingLastPathComponent())
        return writer
    }
}
