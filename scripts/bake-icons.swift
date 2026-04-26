import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Bake-icons — render the Knot brand mark into platform-ready app icons.
//
// Visual recipe (locked-in by the design handoff):
//   • Background: vertical gradient from #2a2a2c (top) to #1a1a1c (bottom).
//   • Mark: tinted to #f2f2f3, centered, occupying ~60% of the canvas.
//
// macOS variants bake the squircle mask into the artwork because AppKit
// does not apply one at runtime. iOS gets a single full-bleed square at
// 1024×1024 — the system applies its own squircle mask.

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: bake-icons <input.svg> <ios-out-dir> <mac-out-dir>\n", stderr)
    exit(64)
}

let svgPath = CommandLine.arguments[1]
let iosOutDir = CommandLine.arguments[2]
let macOutDir = CommandLine.arguments[3]

let svgURL = URL(fileURLWithPath: svgPath)
guard let svgImage = NSImage(contentsOf: svgURL) else {
    fputs("Could not load SVG at \(svgPath)\n", stderr)
    exit(70)
}

// Force the SVG to report a high logical size so AppKit will scale its
// vector representation cleanly when we draw it into a CGContext.
svgImage.size = NSSize(width: 1024, height: 1024)

// Colours
let bgTop = CGColor(srgbRed: 0.165, green: 0.165, blue: 0.173, alpha: 1.0)
let bgBot = CGColor(srgbRed: 0.102, green: 0.102, blue: 0.110, alpha: 1.0)
let markTint = CGColor(srgbRed: 0.949, green: 0.949, blue: 0.953, alpha: 1.0)

enum Variant {
    case iosFlat              // square, system masks
    case macOSWithSquircle    // squircle mask baked in
}

/// Build a CGImage of the Knot icon at the given pixel size, with or
/// without the macOS squircle.
func renderIconCG(size: Int, variant: Variant) -> CGImage {
    let pxSize = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Could not create CGContext at size \(size)\n", stderr)
        exit(74)
    }

    let bounds = CGRect(x: 0, y: 0, width: pxSize, height: pxSize)

    // macOS: clip to a squircle so the artwork has the system app-icon
    // shape baked in. iOS leaves the canvas square; the system masks at
    // runtime.
    if case .macOSWithSquircle = variant {
        let radius = pxSize * 0.2237 // approximation of the iOS squircle
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.clip()
    }

    // Background gradient (vertical, top → bottom).
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [bgTop, bgBot] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: pxSize),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Mark inset: centred, ~60% of canvas (20% inset on each side).
    let inset = pxSize * 0.20
    let markRect = bounds.insetBy(dx: inset, dy: inset)

    // Rasterise the SVG to a CGImage at the mark's pixel size, using
    // AppKit's NSImage so we get a sensible vector resample.
    let markCG = svgRasterised(at: markRect.size)

    // Tint: fill the masked region with the desired colour, then knock
    // it down to the mark's alpha so only the SVG paths show through.
    ctx.saveGState()
    ctx.setBlendMode(.normal)
    ctx.clip(to: markRect, mask: markCG)
    ctx.setFillColor(markTint)
    ctx.fill(markRect)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        fputs("Could not finalise CGImage at size \(size)\n", stderr)
        exit(74)
    }
    return image
}

/// Rasterise the loaded SVG to a CGImage at the requested pixel size.
func svgRasterised(at size: CGSize) -> CGImage {
    var rect = CGRect(origin: .zero, size: size)
    guard let cg = svgImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        // Fall back to a CGContext draw of the NSImage if cgImage is nil.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        svgImage.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
    return cg
}

func writePNG(_ cgImage: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fputs("Could not open PNG destination at \(path)\n", stderr)
        exit(74)
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    if !CGImageDestinationFinalize(dest) {
        fputs("Could not finalise PNG at \(path)\n", stderr)
        exit(74)
    }
    print("wrote \(path)")
}

// MARK: - iOS — single 1024 square, system masks.

writePNG(
    renderIconCG(size: 1024, variant: .iosFlat),
    to: "\(iosOutDir)/icon-1024.png"
)

// MARK: - macOS — every slot in the .appiconset, squircle baked in.

struct MacSlot {
    let size: Int
    let filename: String
}

let macSlots: [MacSlot] = [
    MacSlot(size: 16,   filename: "icon_16x16.png"),
    MacSlot(size: 32,   filename: "icon_16x16@2x.png"),
    MacSlot(size: 32,   filename: "icon_32x32.png"),
    MacSlot(size: 64,   filename: "icon_32x32@2x.png"),
    MacSlot(size: 128,  filename: "icon_128x128.png"),
    MacSlot(size: 256,  filename: "icon_128x128@2x.png"),
    MacSlot(size: 256,  filename: "icon_256x256.png"),
    MacSlot(size: 512,  filename: "icon_256x256@2x.png"),
    MacSlot(size: 512,  filename: "icon_512x512.png"),
    MacSlot(size: 1024, filename: "icon_512x512@2x.png"),
]

for slot in macSlots {
    writePNG(
        renderIconCG(size: slot.size, variant: .macOSWithSquircle),
        to: "\(macOutDir)/\(slot.filename)"
    )
}

print("done")
