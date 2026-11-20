#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `DrawingImages` that gives a fixed image for every drawing, for the ink segment view
    /// of WP-21 and the app shells (docs/architecture.md §10). A test can script the image of
    /// a drawing by its bytes, such as one read from the fixtures, and mark a drawing as
    /// unreadable. Empty data is unreadable too.
    public final class ScriptedDrawingImages: DrawingImages {
        /// A synthetic image: one transparent pixel, as PNG.
        public static let placeholder = DrawingImage(
            png: Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
            )!,
            pixelWidth: 1, pixelHeight: 1)

        private struct State {
            var images: [Data: DrawingImage] = [:]
            var unreadable: Set<Data> = []
            var requests = 0
        }

        private let state = Mutex(State())

        public init() {}

        /// The image `drawing` gives.
        public func script(_ drawing: InkDrawingData, image: DrawingImage) {
            state.withLock { $0.images[drawing.bytes] = image }
        }

        /// A drawing whose data cannot be decoded.
        public func scriptUnreadable(_ drawing: InkDrawingData) {
            state.withLock { _ = $0.unreadable.insert(drawing.bytes) }
        }

        public var requestCount: Int { state.withLock { $0.requests } }

        public func image(of drawing: InkDrawingData, scale: Double) async throws(KnotError) -> DrawingImage {
            let (image, unreadable) = state.withLock { state in
                state.requests += 1
                return (state.images[drawing.bytes], state.unreadable.contains(drawing.bytes))
            }
            guard !unreadable, !drawing.bytes.isEmpty else { throw KnotError.drawingUnreadable }
            return image ?? Self.placeholder
        }
    }
#endif
