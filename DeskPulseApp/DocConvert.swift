// DocConvert.swift - document and PDF conversion built entirely on what ships
// with macOS: textutil handles the Word/RTF/TXT/HTML/ODT family, PDFKit reads
// and writes PDFs, and CoreText paginates documents into new PDF pages.
// Conversions are text and formatting focused: images embedded inside Word
// documents are not carried over.

import AppKit
import PDFKit

/// Word-family conversion via /usr/bin/textutil. Markdown is read as plain text.
func textutilConvert(_ input: URL, to format: String, output: URL) -> (ok: Bool, why: String) {
    var args = ["-convert", format]
    if input.pathExtension.lowercased() == "md" {
        args += ["-format", "txt"]
    }
    args += [input.path, "-output", output.path]
    let r = runCommand("/usr/bin/textutil", args)
    guard r.ok, FileManager.default.fileExists(atPath: output.path) else {
        return (false, r.out.split(separator: "\n").last.map(String.init) ?? "textutil failed")
    }
    return (true, "")
}

/// Read any document Cocoa's text system understands (docx, doc, rtf, html, odt, txt).
func readDocument(_ url: URL) -> NSAttributedString? {
    if url.pathExtension.lowercased() == "md" {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }
    return try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
}

/// Paginate attributed text into a US Letter PDF with 0.75 inch margins.
func renderPDF(_ attr: NSAttributedString, to url: URL) -> Bool {
    let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    let textRect = pageRect.insetBy(dx: 54, dy: 54)
    var mediaBox = pageRect
    guard attr.length > 0,
          let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return false }
    let framesetter = CTFramesetterCreateWithAttributedString(attr)
    var start = 0
    repeat {
        ctx.beginPDFPage(nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: start, length: 0),
            CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        let visible = CTFrameGetVisibleStringRange(frame)
        ctx.endPDFPage()
        if visible.length == 0 { break }   // content that can't lay out; stop rather than loop
        start += visible.length
    } while start < attr.length
    ctx.closePDF()
    return FileManager.default.fileExists(atPath: url.path)
}

/// Extract a PDF's text. Returns nil for scanned/image-only PDFs.
func pdfText(_ url: URL) -> String? {
    guard let doc = PDFDocument(url: url), let s = doc.string,
          !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s
}

/// Render every PDF page to PNG or JPG at 144 dpi. One page goes next to the
/// source as a single image; multiple pages go into their own new folder.
/// Returns the file or folder that was written.
func pdfToImages(_ url: URL, format: String) -> (out: URL?, why: String) {
    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
        return (nil, "could not open PDF")
    }
    let dir = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    let ext = format == "png" ? "png" : "jpg"

    func write(_ page: PDFPage, to out: URL) -> Bool {
        let b = page.bounds(for: .mediaBox)
        let img = page.thumbnail(of: CGSize(width: b.width * 2, height: b.height * 2),
                                 for: .mediaBox)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(
                using: ext == "png" ? .png : .jpeg,
                properties: ext == "png" ? [:] : [.compressionFactor: 0.85])
        else { return false }
        return (try? data.write(to: out)) != nil
    }

    if doc.pageCount == 1 {
        let out = freeOutputURL(dir: dir, base: base, ext: ext)
        guard let page = doc.page(at: 0), write(page, to: out) else {
            return (nil, "could not render page")
        }
        return (out, "")
    }

    var folder = dir.appendingPathComponent("\(base) pages")
    var n = 2
    while FileManager.default.fileExists(atPath: folder.path) {
        folder = dir.appendingPathComponent("\(base) pages \(n)")
        n += 1
    }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i),
              write(page, to: folder.appendingPathComponent("page \(i + 1).\(ext)"))
        else { return (nil, "failed on page \(i + 1)") }
    }
    return (folder, "")
}

/// Combine images into one multi-page PDF, one image per page, in the given order.
func imagesToPDF(_ urls: [URL], output: URL) -> Bool {
    let doc = PDFDocument()
    var i = 0
    for url in urls {
        guard let img = NSImage(contentsOf: url), let page = PDFPage(image: img) else {
            continue
        }
        doc.insert(page, at: i)
        i += 1
    }
    guard i > 0 else { return false }
    return doc.write(to: output)
}
