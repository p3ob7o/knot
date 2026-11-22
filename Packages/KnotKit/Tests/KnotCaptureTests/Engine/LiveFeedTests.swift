import Foundation
import KnotCore
import Testing

@testable import KnotCapture

/// The live feed's mailboxes, on their own: a slow consumer gets the newest value of each kind,
/// in the order the newest came, and drops the older ones; a consumer that comes after the end
/// gets nothing.
@Suite struct LiveFeedTests {
    private static func feed() -> (LiveFeed, AsyncStream<AudioChunk>.Continuation) {
        let (audio, sink) = AsyncStream.makeStream(of: AudioChunk.self)
        return (LiveFeed(capture: CaptureID(uuid: UUID()), audio: audio, transcriber: nil, log: KnotLog(.capture)), sink)
    }

    @Test func aSlowConsumerGetsTheNewestLevel() async throws {
        let (feed, sink) = Self.feed()
        defer { sink.finish() }
        var it = feed.stream().makeAsyncIterator()
        feed.level(peak: 0.1, average: 0.1)
        feed.level(peak: 0.2, average: 0.2)
        feed.level(peak: 0.3, average: 0.3)
        // With no transcriber, live text was unavailable first; then only the newest level.
        #expect(await it.next() == .transcriptUnavailable(KnotError.portUnavailable.code))
        #expect(await it.next() == .level(peak: 0.3, average: 0.3))
        feed.finish()
        #expect(await it.next() == nil)
    }

    @Test func aConsumerAfterTheEndGetsNothing() async throws {
        let (feed, sink) = Self.feed()
        defer { sink.finish() }
        feed.finish()
        var it = feed.stream().makeAsyncIterator()
        #expect(await it.next() == nil)
    }

    @Test func aConsumerThatLeftGetsNothingMore() async throws {
        let (feed, sink) = Self.feed()
        defer { sink.finish() }
        let reading = Task {
            var count = 0
            for await _ in feed.stream() { count += 1 }
            return count
        }
        reading.cancel()
        _ = await reading.value
        feed.level(peak: 0.5, average: 0.5)
        var other = feed.stream().makeAsyncIterator()
        feed.level(peak: 0.6, average: 0.6)
        #expect(await other.next() == .transcriptUnavailable(KnotError.portUnavailable.code))
        #expect(await other.next() == .level(peak: 0.6, average: 0.6))
    }
}
