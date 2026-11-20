#if DEBUG || KNOT_FAKES
    import CoreGraphics
    import Foundation
    import ImageIO
    import KnotCore
    import Synchronization

    /// A `DrawingImages` that draws a synthetic image for every drawing, for the ink segment
    /// view of WP-21 and the app shells (docs/architecture.md §10): a line across a canvas of
    /// `pointSize`, at the scale asked, as PNG. A test can script the image of a drawing by its
    /// bytes, and mark a drawing as unreadable. Empty data is unreadable too.
    public final class ScriptedDrawingImages: DrawingImages {
        /// The size of the synthetic drawing, in points.
        public static let pointSize = (width: 64, height: 32)

        /// The synthetic image at `scale` pixels per point.
        public static func synthetic(scale: Double) -> DrawingImage {
            let width = max(1, Int((Double(pointSize.width) * scale).rounded()))
            let height = max(1, Int((Double(pointSize.height) * scale).rounded()))
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return DrawingImage(png: Data(), pixelWidth: 0, pixelHeight: 0) }
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(2 * scale)
            context.move(to: CGPoint(x: 4 * scale, y: Double(height) / 2))
            context.addLine(to: CGPoint(x: Double(width) - 4 * scale, y: Double(height) / 2))
            context.strokePath()
            let png = NSMutableData()
            guard let image = context.makeImage(),
                let destination = CGImageDestinationCreateWithData(
                    png as CFMutableData, "public.png" as CFString, 1, nil)
            else { return DrawingImage(png: Data(), pixelWidth: 0, pixelHeight: 0) }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return DrawingImage(png: png as Data, pixelWidth: width, pixelHeight: height)
        }

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
            return image ?? Self.synthetic(scale: scale)
        }
    }
#endif
