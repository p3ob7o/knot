import Foundation

/// An image of a drawing: PNG bytes and the image's size in pixels.
///
/// Not named `DrawingImage`: KnotExport has a type of that name, the image its caller passes
/// in, and a file that imports both modules would find the name ambiguous.
public struct RenderedDrawing: Hashable, Sendable {
    /// The image, encoded as PNG.
    public var png: Data
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(png: Data, pixelWidth: Int, pixelHeight: Int) {
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Gives a stored drawing's image, for the ink segment view and the app shells
/// (docs/architecture.md §10). KnotInk implements it in WP-18. Until then `.live` answers
/// `port_unavailable`: the ink segment view shows its placeholder with the recognised text,
/// and export writes the drawing's stored data file under its ID.
public protocol DrawingImages: Sendable {
    /// The image of `drawing` at `scale` pixels per point: a PNG that decodes at the size it
    /// states, which follows the scale asked. A drawing whose data cannot be decoded fails with
    /// `drawing_unreadable`.
    func image(of drawing: InkDrawingData, scale: Double) async throws(KnotError) -> RenderedDrawing
}
