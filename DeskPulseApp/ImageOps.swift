// ImageOps.swift - image operations beyond what sips offers: crop, text and
// logo watermarks, Lanczos enlargement, and background removal (Vision,
// macOS 14+). All CoreGraphics/CoreImage, all on-device.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import Vision

func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Write a CGImage as png/jpg/heic/tiff via ImageIO.
func writeCGImage(_ cg: CGImage, to url: URL, quality: Double = 0.9) -> Bool {
    let type: UTType
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": type = .jpeg
    case "heic": type = .heic
    case "tiff", "tif": type = .tiff
    default: type = .png
    }
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, type.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, cg, [
        kCGImageDestinationLossyCompressionQuality: quality,
    ] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

/// Crop by a rectangle given in unit coordinates (0-1, origin top left).
func cropImage(_ url: URL, unitRect: CGRect, output: URL) -> (ok: Bool, why: String) {
    guard let cg = loadCGImage(url) else { return (false, "could not open image") }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let pixelRect = CGRect(x: (unitRect.minX * w).rounded(),
                           y: (unitRect.minY * h).rounded(),
                           width: (unitRect.width * w).rounded(),
                           height: (unitRect.height * h).rounded())
        .intersection(CGRect(x: 0, y: 0, width: w, height: h))
    guard pixelRect.width >= 1, pixelRect.height >= 1,
          let cropped = cg.cropping(to: pixelRect) else {
        return (false, "empty crop area")
    }
    guard writeCGImage(cropped, to: output) else { return (false, "could not write image") }
    return (true, "")
}

/// Stamp text (and optionally a logo image) onto a CGImage in memory.
/// Font size and logo width scale with the image so batches look consistent.
/// Also drives the live preview in the Image Tools pane.
func watermarkCG(_ cg: CGImage, text: String, logo: NSImage?, position: StampPosition,
                 opacity: CGFloat, sizePercent: CGFloat, white: Bool) -> CGImage? {
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    guard let ctx = CGContext(
        data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    let margin = w * 0.03

    if let logo {
        let lw = w * sizePercent / 100
        let lh = lw * (logo.size.height / max(logo.size.width, 1))
        let rect = position.rect(for: CGSize(width: lw, height: lh), in: bounds, margin: margin)
        logo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
    } else if !text.isEmpty {
        let font = NSFont.boldSystemFont(ofSize: max(10, w * sizePercent / 100 * 0.5))
        let color = (white ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
        let shadow = NSShadow()
        shadow.shadowColor = (white ? NSColor.black : NSColor.white).withAlphaComponent(opacity * 0.5)
        shadow.shadowBlurRadius = font.pointSize * 0.08
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .shadow: shadow,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = position.rect(for: size, in: bounds, margin: margin)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

func watermarkImage(_ url: URL, text: String, logo: URL?, position: StampPosition,
                    opacity: CGFloat, sizePercent: CGFloat, white: Bool,
                    output: URL) -> (ok: Bool, why: String) {
    guard let cg = loadCGImage(url) else { return (false, "could not open image") }
    let logoImg = logo.flatMap { NSImage(contentsOf: $0) }
    guard let outCG = watermarkCG(cg, text: text, logo: logoImg, position: position,
                                  opacity: opacity, sizePercent: sizePercent, white: white),
          writeCGImage(outCG, to: output) else {
        return (false, "could not write image")
    }
    return (true, "")
}

/// High-quality Lanczos upscale. Honest naming: sharper than a plain resize,
/// but it does not invent detail like AI upscalers.
func enlargeImage(_ url: URL, factor: CGFloat, output: URL) -> (ok: Bool, why: String) {
    guard let cg = loadCGImage(url) else { return (false, "could not open image") }
    let filter = CIFilter.lanczosScaleTransform()
    filter.inputImage = CIImage(cgImage: cg)
    filter.scale = Float(factor)
    filter.aspectRatio = 1
    guard let out = filter.outputImage,
          let outCG = CIContext().createCGImage(out, from: out.extent),
          writeCGImage(outCG, to: output) else {
        return (false, "could not scale image")
    }
    return (true, "")
}

/// Cut the subject out of a photo (people, pets, objects) with Vision's
/// on-device segmentation. Output is a PNG with transparency. macOS 14+.
/// This is the automatic path; the interactive editor uses SubjectMasker.
@available(macOS 14.0, *)
func removeBackground(_ url: URL, output: URL) -> (ok: Bool, why: String) {
    guard let cg = loadCGImage(url) else { return (false, "could not open image") }
    guard let masker = SubjectMasker(cgImage: cg) else {
        return (false, "no subject found")
    }
    guard let mask = masker.mask(instances: masker.allInstances),
          let outCG = applyMask(cg, mask: mask),
          writeCGImage(outCG, to: output) else {
        return (false, "could not build mask")
    }
    return (true, "")
}

// MARK: - Interactive cutout support

/// One brush stroke in unit coordinates (origin top left). keep = restore
/// (paint the image back in), otherwise erase.
struct BrushStroke {
    var points: [CGPoint]
    var radius: CGFloat      // fraction of image width
    var keep: Bool
}

/// Wraps one Vision segmentation pass so the editor can ask "which subject is
/// under this point" and build masks for any subset of the found subjects.
@available(macOS 14.0, *)
final class SubjectMasker {
    private let handler: VNImageRequestHandler
    private let result: VNInstanceMaskObservation
    let allInstances: Set<Int>

    init?(cgImage: CGImage) {
        handler = VNImageRequestHandler(cgImage: cgImage)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try? handler.perform([request])
        guard let r = request.results?.first, !r.allInstances.isEmpty else { return nil }
        result = r
        allInstances = Set(r.allInstances)
    }

    /// The subject under a unit-space point (origin top left), nil = background.
    func instance(at p: CGPoint) -> Int? {
        let buf = result.instanceMask
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let x = min(max(Int(p.x * CGFloat(w)), 0), w - 1)
        let y = min(max(Int(p.y * CGFloat(h)), 0), h - 1)
        let v = base.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(buf) + x,
                          as: UInt8.self)
        return v == 0 ? nil : Int(v)
    }

    /// Grayscale mask (white = keep) for the chosen subjects, at image size.
    func mask(instances: Set<Int>) -> CGImage? {
        guard !instances.isEmpty,
              let buf = try? result.generateScaledMaskForImage(
                forInstances: IndexSet(instances), from: handler) else { return nil }
        let ci = CIImage(cvPixelBuffer: buf)
        return CIContext().createCGImage(ci, from: ci.extent)
    }
}

func downscale(_ cg: CGImage, maxSide: CGFloat) -> CGImage {
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let scale = min(1, maxSide / max(w, h))
    guard scale < 1 else { return cg }
    let filter = CIFilter.lanczosScaleTransform()
    filter.inputImage = CIImage(cgImage: cg)
    filter.scale = Float(scale)
    filter.aspectRatio = 1
    guard let out = filter.outputImage,
          let scaled = CIContext().createCGImage(out, from: out.extent) else { return cg }
    return scaled
}

/// Combine the segmentation mask with manual brush strokes into one grayscale
/// mask at the given pixel size. nil base = start fully erased (pure manual).
func composeMask(base: CGImage?, size: CGSize, strokes: [BrushStroke]) -> CGImage? {
    let w = Int(size.width), h = Int(size.height)
    guard w > 0, h > 0, let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if let base {
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    for s in strokes where !s.points.isEmpty {
        ctx.setStrokeColor(CGColor(gray: s.keep ? 1 : 0, alpha: 1))
        ctx.setFillColor(CGColor(gray: s.keep ? 1 : 0, alpha: 1))
        ctx.setLineWidth(s.radius * size.width * 2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // unit points have a top-left origin; CGContext draws from bottom left
        let pts = s.points.map {
            CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height)
        }
        if pts.count == 1 {
            let r = s.radius * size.width
            ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r,
                                       width: r * 2, height: r * 2))
        } else {
            ctx.beginPath()
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
    }
    return ctx.makeImage()
}

/// Keep the image where the mask is white, transparent where black.
func applyMask(_ cg: CGImage, mask: CGImage) -> CGImage? {
    let blend = CIFilter.blendWithMask()
    let input = CIImage(cgImage: cg)
    blend.inputImage = input
    blend.maskImage = CIImage(cgImage: mask)
    blend.backgroundImage = CIImage.empty()
    guard let out = blend.outputImage else { return nil }
    return CIContext().createCGImage(out, from: input.extent)
}
