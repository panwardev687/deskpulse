// PDFOps.swift - the PDF toolbox engine: merge, split, rotate, compress,
// password protect and unlock, watermark, page numbers, and OCR. Everything
// runs on PDFKit and the Vision framework that ship with macOS; nothing is
// ever uploaded anywhere. Every function writes a NEW file and leaves the
// original untouched.

import AppKit
import PDFKit
import Vision

// MARK: - Page ranges

/// Parse "1-3, 7, 12" into zero-based page indexes. Returns nil on bad input.
func parsePageRanges(_ s: String, pageCount: Int) -> [Int]? {
    var out: [Int] = []
    for part in s.split(separator: ",") {
        let piece = part.trimmingCharacters(in: .whitespaces)
        if piece.isEmpty { continue }
        let ends = piece.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        if ends.count == 1, let p = Int(ends[0]), p >= 1, p <= pageCount {
            out.append(p - 1)
        } else if ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]),
                  a >= 1, b >= a, b <= pageCount {
            out.append(contentsOf: (a - 1)...(b - 1))
        } else {
            return nil
        }
    }
    return out.isEmpty ? nil : out
}

// MARK: - Merge / split

func mergePDFs(_ urls: [URL], output: URL) -> (ok: Bool, why: String) {
    let merged = PDFDocument()
    var n = 0
    for url in urls {
        guard let doc = PDFDocument(url: url) else {
            return (false, "could not open \(url.lastPathComponent)")
        }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.copy() as? PDFPage {
                merged.insert(page, at: n)
                n += 1
            }
        }
    }
    guard n > 0, merged.write(to: output) else { return (false, "could not write PDF") }
    return (true, "")
}

/// Extract the given zero-based pages into one new PDF, in the given order.
func extractPages(_ url: URL, pages: [Int], output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    let out = PDFDocument()
    var n = 0
    for i in pages where i < doc.pageCount {
        if let page = doc.page(at: i)?.copy() as? PDFPage {
            out.insert(page, at: n)
            n += 1
        }
    }
    guard n > 0, out.write(to: output) else { return (false, "could not write PDF") }
    return (true, "")
}

/// One single-page PDF per page, into a new sibling folder. Returns the folder.
func splitEveryPage(_ url: URL) -> (out: URL?, why: String) {
    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
        return (nil, "could not open PDF")
    }
    let dir = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    var folder = dir.appendingPathComponent("\(base) split")
    var n = 2
    while FileManager.default.fileExists(atPath: folder.path) {
        folder = dir.appendingPathComponent("\(base) split \(n)")
        n += 1
    }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<doc.pageCount {
        let single = PDFDocument()
        guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
        single.insert(page, at: 0)
        guard single.write(to: folder.appendingPathComponent("page \(i + 1).pdf")) else {
            return (nil, "failed on page \(i + 1)")
        }
    }
    return (folder, "")
}

// MARK: - Rotate / compress / passwords

/// Rotate every page by the given degrees (multiples of 90, clockwise).
func rotatePDF(_ url: URL, degrees: Int, output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    for i in 0..<doc.pageCount {
        if let page = doc.page(at: i) {
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
    }
    guard doc.write(to: output) else { return (false, "could not write PDF") }
    return (true, "")
}

/// Shrink by re-encoding images as JPEG and downsampling for screen resolution.
/// The write options need macOS 13.4; older systems get a plain rewrite.
func compressPDF(_ url: URL, output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    let ok: Bool
    if #available(macOS 13.4, *) {
        ok = doc.write(to: output, withOptions: [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ])
    } else {
        ok = doc.write(to: output)
    }
    guard ok else { return (false, "could not write PDF") }
    return (true, "")
}

/// Rewrite a scanned PDF with an invisible OCR text layer so it becomes
/// searchable and selectable. Uses PDFKit's built-in OCR-on-save.
func makeSearchablePDF(_ url: URL, output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    guard doc.write(to: output, withOptions: [.saveTextFromOCROption: true]) else {
        return (false, "could not write PDF")
    }
    return (true, "")
}

func protectPDF(_ url: URL, password: String, output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    let ok = doc.write(to: output, withOptions: [
        .userPasswordOption: password,
        .ownerPasswordOption: password,
    ])
    guard ok else { return (false, "could not write PDF") }
    return (true, "")
}

/// Write a password-free copy. Needs the current password unless the PDF only
/// has an owner password macOS can open by itself. Pages are copied into a
/// fresh document because rewriting the original keeps its encryption.
func unlockPDF(_ url: URL, password: String, output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    if doc.isLocked && !doc.unlock(withPassword: password) {
        return (false, "wrong password")
    }
    guard !doc.isLocked else { return (false, "wrong password") }
    let plain = PDFDocument()
    for i in 0..<doc.pageCount {
        if let page = doc.page(at: i)?.copy() as? PDFPage {
            plain.insert(page, at: plain.pageCount)
        }
    }
    guard plain.pageCount > 0, plain.write(to: output) else {
        return (false, "could not write PDF")
    }
    return (true, "")
}

// MARK: - Watermark / page numbers

enum StampPosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight
    case center
    case bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }

    func rect(for textSize: CGSize, in bounds: CGRect, margin: CGFloat = 28) -> CGRect {
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = bounds.minX + margin
        case .topCenter, .center, .bottomCenter: x = bounds.midX - textSize.width / 2
        case .topRight, .bottomRight: x = bounds.maxX - margin - textSize.width
        }
        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight: y = bounds.maxY - margin - textSize.height
        case .center: y = bounds.midY - textSize.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = bounds.minY + margin
        }
        return CGRect(x: x, y: y, width: textSize.width, height: textSize.height)
    }
}

private func stamp(_ page: PDFPage, text: String, position: StampPosition,
                   fontSize: CGFloat, opacity: CGFloat) {
    let font = NSFont.boldSystemFont(ofSize: fontSize)
    let size = (text as NSString).size(withAttributes: [.font: font])
    let padded = CGSize(width: ceil(size.width) + 8, height: ceil(size.height) + 6)
    let bounds = page.bounds(for: .mediaBox)
    let ann = PDFAnnotation(
        bounds: position.rect(for: padded, in: bounds),
        forType: .freeText, withProperties: nil)
    ann.contents = text
    ann.font = font
    ann.fontColor = NSColor.gray.withAlphaComponent(opacity)
    ann.color = .clear
    ann.isReadOnly = true
    page.addAnnotation(ann)
}

/// Burn a text watermark onto every page. The PDF's own text stays selectable.
func watermarkPDF(_ url: URL, text: String, position: StampPosition,
                  fontSize: CGFloat, opacity: CGFloat, output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    for i in 0..<doc.pageCount {
        if let page = doc.page(at: i) {
            stamp(page, text: text, position: position, fontSize: fontSize, opacity: opacity)
        }
    }
    guard doc.write(to: output, withOptions: [.burnInAnnotationsOption: true]) else {
        return (false, "could not write PDF")
    }
    return (true, "")
}

func numberPages(_ url: URL, position: StampPosition, output: URL) -> (ok: Bool, why: String) {
    guard let doc = PDFDocument(url: url) else { return (false, "could not open PDF") }
    for i in 0..<doc.pageCount {
        if let page = doc.page(at: i) {
            stamp(page, text: "\(i + 1)", position: position, fontSize: 11, opacity: 0.9)
        }
    }
    guard doc.write(to: output, withOptions: [.burnInAnnotationsOption: true]) else {
        return (false, "could not write PDF")
    }
    return (true, "")
}

// MARK: - OCR

/// Recognize text in a CGImage with Vision. Lines top to bottom.
func recognizeText(in cgImage: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cgImage)
    try? handler.perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
}

/// OCR a scanned PDF: render each page around 300 dpi and recognize it.
func ocrPDF(_ url: URL) -> (text: String?, why: String) {
    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
        return (nil, "could not open PDF")
    }
    var pages: [String] = []
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        let b = page.bounds(for: .mediaBox)
        // ~300 dpi, capped so huge pages don't blow up memory
        let scale = min(300.0 / 72.0, 4000 / max(b.width, b.height))
        let img = page.thumbnail(of: CGSize(width: b.width * scale, height: b.height * scale),
                                 for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        pages.append(recognizeText(in: cg))
    }
    let text = pages.joined(separator: "\n\n")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (nil, "no readable text found")
    }
    return (text, "")
}

/// OCR an image file.
func ocrImage(_ url: URL) -> (text: String?, why: String) {
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return (nil, "could not open image")
    }
    let text = recognizeText(in: cg)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (nil, "no readable text found")
    }
    return (text, "")
}
