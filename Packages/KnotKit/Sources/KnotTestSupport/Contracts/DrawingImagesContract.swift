import Foundation
import ImageIO
import KnotCore
import Testing

/// The contract suite of `DrawingImages` (docs/architecture.md §10): a drawing gives a PNG that
/// decodes at the size it states, a size that follows the scale asked, and data that is not a
/// drawing fails as final.
public enum DrawingImagesContract {
    /// - Parameters:
    ///   - drawing: a drawing that holds strokes.
    ///   - unreadable: data that is not a drawing.
    public static func run(
        drawing: InkDrawingData, unreadable: InkDrawingData, _ make: @Sendable () async throws -> any DrawingImages
    ) async throws {
        let images = try await make()
        let image = try await images.image(of: drawing, scale: 1)
        #expect(image.pixelWidth > 0 && image.pixelHeight > 0, "A drawing gives an image.")
        #expect(decodedSize(of: image.png) == [image.pixelWidth, image.pixelHeight], "The PNG decodes, at its size.")
        // Twice the pixels per point gives twice the pixels each way (finding 19).
        let sharper = try await images.image(of: drawing, scale: 2)
        #expect(decodedSize(of: sharper.png) == [sharper.pixelWidth, sharper.pixelHeight], "It decodes.")
        #expect(sharper.pixelWidth > image.pixelWidth && sharper.pixelHeight > image.pixelHeight, "It is larger.")
        #expect(
            abs(sharper.pixelWidth - 2 * image.pixelWidth) <= 1
                && abs(sharper.pixelHeight - 2 * image.pixelHeight) <= 1,
            "Its size follows the scale asked, give or take a pixel of rounding.")
        await refuses(.drawingUnreadable, "Data that is not a drawing.") {
            try await images.image(of: unreadable, scale: 1)
        }
    }

    /// The width and height of a PNG, as ImageIO decodes it; `nil` when it does not decode.
    static func decodedSize(of png: Data) -> [Int]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            CGImageSourceGetType(source).map({ $0 as String }) == "public.png",
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return [image.width, image.height]
    }
}
