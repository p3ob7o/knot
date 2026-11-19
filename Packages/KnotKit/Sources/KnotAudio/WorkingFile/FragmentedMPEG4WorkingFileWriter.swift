#if !os(watchOS)
    import AVFoundation
    import CoreMedia
    import Foundation

    /// Writes AAC, mono, in fragmented MPEG-4, through `AVAssetWriter`, with a movie fragment
    /// every second.
    ///
    /// The writer encodes and writes on its own schedule. A frame is in the file only once the
    /// fragment that holds it has been written, so a kill loses what the encoder and the open
    /// fragment held. `AVAssetWriter` is unavailable on watchOS.
    final class FragmentedMPEG4WorkingFileWriter: WorkingFileWriter {
        let url: URL
        let format = WorkingFileFormat.fragmentedMPEG4
        let sampleRate: Double
        private(set) var appendedFrames: Int64 = 0

        private let writer: AVAssetWriter
        private var receiver: AVAssetWriterInput.SampleBufferReceiver?
        private let processingFormat: AVAudioFormat
        private let driveSync: DriveSync

        init(url: URL, sampleRate: Double, inputFormat: AVAudioCommonFormat) throws(WorkingFileError) {
            guard
                let processingFormat = AVAudioFormat(
                    commonFormat: inputFormat, sampleRate: sampleRate, channels: 1, interleaved: true)
            else { throw .formatMismatch }
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            } catch {
                throw .create(error)
            }
            let fragment = CMTime(value: 1, timescale: 1)
            writer.movieFragmentInterval = fragment
            writer.initialMovieFragmentInterval = fragment
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    // The stored copy's rate, so that the working file is already its size.
                    AVEncoderBitRateKey: StoredCopy.bitRate(forSampleRate: sampleRate),
                ])
            // From OS 27 `appendImmediately` stands for `expectsMediaDataInRealTime`.
            guard writer.canAdd(input) else { throw .formatMismatch }
            // From OS 26 the receiver adds the input to the writer.
            let receiver = writer.inputReceiver(for: input)
            do {
                try writer.start()
            } catch {
                throw .create(error)
            }
            writer.startSession(atSourceTime: .zero)
            self.url = url
            self.sampleRate = sampleRate
            self.writer = writer
            self.receiver = receiver
            self.processingFormat = processingFormat
            self.driveSync = try DriveSync(url: url)
        }

        func append(_ buffer: AVReadOnlyAudioPCMBuffer) throws(WorkingFileError) {
            guard let receiver else { throw .finished }
            guard buffer.format == processingFormat else { throw .formatMismatch }
            let sampleBuffer = Self.makeSampleBuffer(
                buffer,
                formatDescription: processingFormat.formatDescription,
                presentationTime: CMTime(value: appendedFrames, timescale: CMTimeScale(sampleRate.rounded())))
            let accepted: Bool
            do {
                accepted = try receiver.appendImmediately(sampleBuffer)
            } catch {
                throw .write(writer.error ?? error)
            }
            // A real-time input that is not ready drops the buffer, and a writer that failed
            // refuses it without throwing: its error is on the writer. The recorder must know.
            guard accepted else {
                if writer.status == .failed, let error = writer.error { throw .write(error) }
                throw .writeFailed(.init(domain: .other, code: 0))
            }
            appendedFrames += Int64(buffer.frameLength)
        }

        func syncToDrive() throws(WorkingFileError) {
            guard receiver != nil else { throw .finished }
            try driveSync.sync()
        }

        nonisolated(nonsending) func finish() async throws(WorkingFileError) {
            guard let receiver else { throw .finished }
            receiver.finish()
            self.receiver = nil
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw .write(writer.error ?? WorkingFileError.writeFailed(.init(domain: .other, code: 0)))
            }
            try driveSync.sync()
            driveSync.close()
        }

        /// A sample buffer that holds a copy of `buffer`'s frames, presented at `presentationTime`.
        private static func makeSampleBuffer(
            _ buffer: AVReadOnlyAudioPCMBuffer,
            formatDescription: CMAudioFormatDescription,
            presentationTime: CMTime
        ) -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
            let data = buffer.withUnsafeAudioBufferList { list in
                CMReadOnlyDataBlockBuffer(CMMutableDataBlockBuffer(copying: list))
            }
            return CMReadySampleBuffer(
                CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>(
                    audioDataBuffer: data,
                    formatDescription: formatDescription,
                    sampleCount: Int(buffer.frameLength),
                    presentationTimeStamp: presentationTime))
        }
    }
#endif
