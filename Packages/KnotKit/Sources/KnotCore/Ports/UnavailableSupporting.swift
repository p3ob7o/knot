import Foundation

// The unavailable ports of WP-02's third pull request, for `AppEnvironment.unavailable`
// (docs/architecture.md §3), as Unavailable.swift holds those of the second. A call that can
// fail throws `port_unavailable`; a read answers what a port that is not there would.

/// An `InkRecogniser` that is not there yet: no language is read, and a recognition fails.
public struct UnavailableInkRecogniser: InkRecogniser {
    public init() {}

    public func availability(for language: Locale.Language) async -> InkRecogniserAvailability {
        .unsupportedLanguage
    }
    public func recognise(_ drawing: InkDrawingData, language: Locale.Language) async throws(KnotError)
        -> InkRecognition
    { throw KnotError.portUnavailable }
}

/// A `DrawingImages` that is not there yet, until WP-18 merges: the ink segment view shows its
/// placeholder with the recognised text.
public struct UnavailableDrawingImages: DrawingImages {
    public init() {}

    public func image(of drawing: InkDrawingData, scale: Double) async throws(KnotError) -> DrawingImage {
        throw KnotError.portUnavailable
    }
}

/// A `SyncEngine` that is not there: sync is off, and a manual sync fails.
public struct UnavailableSyncEngine: SyncEngine {
    public init() {}

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { continuation in
            continuation.yield(.off)
            continuation.finish()
        }
    }
    public func start() async {}
    public func stop() async {}
    public func syncNow() async throws(KnotError) { throw KnotError.portUnavailable }
    public func answer(_ question: SyncQuestion, _ answer: SyncAnswer) async {}
}
