import Foundation
import KnotCore
import Testing

/// The contract suite of `DrawingImages` (docs/architecture.md §10): a drawing gives an image
/// with a size, a higher scale never a smaller one, and data that is not a drawing fails as
/// final.
public enum DrawingImagesContract {
    /// - Parameters:
    ///   - drawing: a drawing that holds strokes.
    ///   - unreadable: data that is not a drawing.
    public static func run(
        drawing: InkDrawingData, unreadable: InkDrawingData, _ make: @Sendable () async throws -> any DrawingImages
    ) async throws {
        let images = try await make()
        let image = try await images.image(of: drawing, scale: 1)
        #expect(!image.png.isEmpty && image.pixelWidth > 0 && image.pixelHeight > 0, "A drawing gives an image.")
        #expect(image.png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "The image is PNG.")
        let sharper = try await images.image(of: drawing, scale: 2)
        #expect(sharper.pixelWidth >= image.pixelWidth && sharper.pixelHeight >= image.pixelHeight)
        await refuses(.drawingUnreadable, "Data that is not a drawing.") {
            try await images.image(of: unreadable, scale: 1)
        }
    }
}
