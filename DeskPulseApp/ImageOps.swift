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

/// Stamp text (and optionally a logo image) onto a photo.
/// Font size and logo width scale with the image so batches look consistent.
func watermarkImage(_ url: URL, text: String, logo: URL?, position: StampPosition,
                    opacity: CGFloat, sizePercent: CGFloat, white: Bool,
                    output: URL) -> (ok: Bool, why: String) {
    guard let base = NSImage(contentsOf: url), let cg = loadCGImage(url) else {
        return (false, "could not open image")
    }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    guard let ctx = CGContext(
        data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return (false, "could not draw")
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    let margin = w * 0.03

    if let logo, let logoImg = NSImage(contentsOf: logo) {
        let lw = w * sizePercent / 100
        let lh = lw * (logoImg.size.height / max(logoImg.size.width, 1))
        let rect = position.rect(for: CGSize(width: lw, height: lh), in: bounds, margin: margin)
        logoImg.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
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
    _ = base   // keep the NSImage alive through drawing

    guard let outCG = ctx.makeImage(), writeCGImage(outCG, to: output) else {
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
@available(macOS 14.0, *)
func removeBackground(_ url: URL, output: URL) -> (ok: Bool, why: String) {
    guard let cg = loadCGImage(url) else { return (false, "could not open image") }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cg)
    do {
        try handler.perform([request])
    } catch {
        return (false, "segmentation failed")
    }
    guard let result = request.results?.first, !result.allInstances.isEmpty else {
        return (false, "no subject found")
    }
    guard let maskBuffer = try? result.generateScaledMaskForImage(
        forInstances: result.allInstances, from: handler) else {
        return (false, "could not build mask")
    }
    let blend = CIFilter.blendWithMask()
    blend.inputImage = CIImage(cgImage: cg)
    blend.maskImage = CIImage(cvPixelBuffer: maskBuffer)
    blend.backgroundImage = CIImage.empty()
    let extent = CIImage(cgImage: cg).extent
    guard let out = blend.outputImage,
          let outCG = CIContext().createCGImage(out, from: extent),
          writeCGImage(outCG, to: output) else {
        return (false, "could not write image")
    }
    return (true, "")
}
