import AVFAudio
import Foundation
import KnotCore

/// The working file as a session writes it: the `AVAudioFile` on the drive, or, under test, one
/// that fails as a drive does when it fills.
protocol WorkingFileWriter: AnyObject, Sendable {
    /// The format it takes audio in.
    var processingFormat: AVAudioFormat { get }
    /// Appends `buffer`, or throws the system's error.
    func write(from buffer: AVReadOnlyAudioPCMBuffer) throws
    /// Closes the file, its header written whole.
    func close()
}

extension AVAudioFile: WorkingFileWriter {}

/// Makes the working file of a recording: `WorkingFile.create`, unless a test makes another.
typealias WorkingFileMaker =
    @Sendable (URL, Double, AVAudioCommonFormat, any FileLayer) throws(KnotError) -> any WorkingFileWriter
