// PDFToolsView.swift - the PDF toolbox pane. A launcher grid of tools (the
// same mental model as the web PDF sites, minus the uploading), each opening
// a simple drop-run view. The engine lives in PDFOps.swift; page reordering
// has its own editor in PDFOrganizeView.swift.

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum PDFTool: String, CaseIterable, Identifiable {
    case organize, merge, split, compress, watermark, pageNumbers, protect, unlock, ocr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .organize: return "Organize Pages"
        case .merge: return "Merge PDFs"
        case .split: return "Split PDF"
        case .compress: return "Compress PDF"
        case .watermark: return "Watermark"
        case .pageNumbers: return "Page Numbers"
        case .protect: return "Protect"
        case .unlock: return "Unlock"
        case .ocr: return "OCR"
        }
    }
    var icon: String {
        switch self {
        case .organize: return "square.grid.3x2"
        case .merge: return "arrow.triangle.merge"
        case .split: return "square.split.1x2"
        case .compress: return "arrow.down.circle"
        case .watermark: return "textformat"
        case .pageNumbers: return "number"
        case .protect: return "lock"
        case .unlock: return "lock.open"
        case .ocr: return "text.viewfinder"
        }
    }
    var subtitle: String {
        switch self {
        case .organize: return "Reorder, rotate, delete pages"
        case .merge: return "Combine PDFs into one"
        case .split: return "Every page, or a page range"
        case .compress: return "Shrink images inside the PDF"
        case .watermark: return "Stamp text on every page"
        case .pageNumbers: return "Add page numbers"
        case .protect: return "Add a password"
        case .unlock: return "Remove a password"
        case .ocr: return "Read text from scans"
        }
    }
}

// MARK: - Shared batch machinery

struct PDFJob: Identifiable {
    let id = UUID()
    let url: URL
    var status: JobStatus = .pending
    var outURL: URL?
    var inSize: Int64 = 0
    var outSize: Int64 = 0
}

final class PDFToolModel: ObservableObject {
    @Published var jobs: [PDFJob] = []
    @Published var running = false
    var accepts: Set<String> = ["pdf"]

    private let queue = DispatchQueue(label: "deskpulse.pdftools")

    func add(urls: [URL]) {
        for url in urls where accepts.contains(url.pathExtension.lowercased()) {
            guard !jobs.contains(where: { $0.url == url && $0.status == .pending }) else { continue }
            jobs.append(PDFJob(url: url, inSize: fileSize(url)))
        }
    }

    func clear() { jobs.removeAll { $0.status != .running } }

    var hasPending: Bool { jobs.contains { $0.status == .pending } }

    func run(_ op: @escaping (URL) -> (JobStatus, URL?)) {
        guard !running else { return }
        running = true
        let pending = jobs.enumerated().filter { $0.element.status == .pending }
        queue.async { [self] in
            for (i, job) in pending {
                DispatchQueue.main.sync { jobs[i].status = .running }
                let r = op(job.url)
                DispatchQueue.main.sync {
                    jobs[i].status = r.0
                    jobs[i].outURL = r.1
                    jobs[i].outSize = r.1.map(fileSize) ?? 0
                }
            }
            DispatchQueue.main.async { self.running = false }
        }
    }
}

/// Standard output path helper: "<source base> <suffix>.<ext>" next to the source.
func sibling(_ url: URL, suffix: String, ext: String) -> URL {
    freeOutputURL(dir: url.deletingLastPathComponent(),
                  base: url.deletingPathExtension().lastPathComponent
                        + (suffix.isEmpty ? "" : " " + suffix),
                  ext: ext)
}

// MARK: - Pane

struct PDFToolsView: View {
    @State private var tool: PDFTool?

    var body: some View {
        if let tool {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        self.tool = nil
                    } label: {
                        Label("All Tools", systemImage: "chevron.left")
                    }
                    Text(tool.title).font(.system(size: 14, weight: .semibold))
                        .padding(.leading, 4)
                    Spacer()
                }
                .padding(10)
                Divider()
                switch tool {
                case .organize: PDFOrganizeView()
                case .merge: MergeTool()
                case .split: SplitTool()
                case .compress: BatchTool(kind: .compress)
                case .watermark: BatchTool(kind: .watermark)
                case .pageNumbers: BatchTool(kind: .pageNumbers)
                case .protect: BatchTool(kind: .protect)
                case .unlock: BatchTool(kind: .unlock)
                case .ocr: OCRTool()
                }
            }
        } else {
            launcher
        }
    }

    private var launcher: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Everything the PDF websites do, without uploading your files anywhere.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(PDFTool.allCases) { t in
                        Button { tool = t } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: t.icon)
                                    .font(.system(size: 20)).foregroundStyle(.blue)
                                Text(t.title).font(.system(size: 13, weight: .semibold))
                                Text(t.subtitle)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Shared subviews

struct PDFJobRows: View {
    @ObservedObject var model: PDFToolModel
    var showSavings = false

    var body: some View {
        List(model.jobs) { job in
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.url.lastPathComponent).font(.system(size: 12.5))
                    Text(sizeLine(job)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                switch job.status {
                case .pending: Text("ready").font(.system(size: 11)).foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        if let out = job.outURL {
                            Button("Show") {
                                NSWorkspace.shared.activateFileViewerSelecting([out])
                            }.controlSize(.small)
                        }
                    }
                case .failed(let why):
                    Label(why, systemImage: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private func sizeLine(_ job: PDFJob) -> String {
        if case .done = job.status, job.outSize > 0, showSavings {
            let saved = job.inSize > 0
                ? 100 - Int(Double(job.outSize) / Double(job.inSize) * 100) : 0
            return saved > 0
                ? "\(fmtBytes(job.inSize)) → \(fmtBytes(job.outSize)) (\(saved)% smaller)"
                : "\(fmtBytes(job.inSize)) → \(fmtBytes(job.outSize))"
        }
        return fmtBytes(job.inSize)
    }
}

struct PDFDropZone: View {
    var caption: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(caption).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Wire file drops into a handler; shared by every tool view.
    func acceptDrops(_ handle: @escaping ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { handle([url]) } }
                }
            }
            return true
        }
    }
}

func choosePDFs(_ multiple: Bool = true, types: [String] = ["pdf"],
                handler: ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = multiple
    panel.canChooseDirectories = false
    panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
    if panel.runModal() == .OK { handler(panel.urls) }
}

// MARK: - Batch tools (compress, watermark, page numbers, protect, unlock)

enum BatchKind { case compress, watermark, pageNumbers, protect, unlock }

struct BatchTool: View {
    let kind: BatchKind
    @StateObject private var model = PDFToolModel()

    @State private var wmText = "CONFIDENTIAL"
    @State private var wmSize = 36.0
    @State private var wmOpacity = 0.35
    @State private var position: StampPosition = .center
    @State private var password = ""
    @State private var password2 = ""

    var body: some View {
        VStack(spacing: 0) {
            options
            Divider()
            if model.jobs.isEmpty {
                PDFDropZone(caption: "Drop PDFs here, or use Add PDFs below")
            } else {
                PDFJobRows(model: model, showSavings: kind == .compress)
            }
            Divider()
            footer
        }
        .acceptDrops { model.add(urls: $0) }
    }

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .compress:
                Text("Re-encodes images inside the PDF for screen resolution. Text stays sharp. Scanned PDFs shrink the most.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .watermark:
                HStack(spacing: 10) {
                    TextField("Watermark text", text: $wmText).frame(maxWidth: 220)
                    Picker("Position", selection: $position) {
                        ForEach(StampPosition.allCases) { Text($0.label).tag($0) }
                    }.frame(maxWidth: 200)
                    Text("Size \(Int(wmSize))").font(.system(size: 11)).monospacedDigit()
                    Slider(value: $wmSize, in: 12...72, step: 2).frame(width: 100)
                    Text("Opacity \(Int(wmOpacity * 100))%").font(.system(size: 11)).monospacedDigit()
                    Slider(value: $wmOpacity, in: 0.1...1, step: 0.05).frame(width: 100)
                }
            case .pageNumbers:
                Picker("Position", selection: $position) {
                    ForEach([StampPosition.bottomCenter, .bottomLeft, .bottomRight,
                             .topCenter, .topLeft, .topRight]) { Text($0.label).tag($0) }
                }.frame(maxWidth: 240)
            case .protect:
                HStack(spacing: 10) {
                    SecureField("Password", text: $password).frame(maxWidth: 180)
                    SecureField("Repeat password", text: $password2).frame(maxWidth: 180)
                    if !password.isEmpty && password != password2 {
                        Text("Passwords do not match")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            case .unlock:
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("Current password", text: $password).frame(maxWidth: 220)
                    Text("Writes a password-free copy. You need the password; DeskPulse never guesses or cracks it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runDisabled: Bool {
        if model.running || !model.hasPending { return true }
        switch kind {
        case .watermark: return wmText.isEmpty
        case .protect: return password.isEmpty || password != password2
        case .unlock: return false
        default: return false
        }
    }

    private var footer: some View {
        HStack {
            Button("Add PDFs…") { choosePDFs { model.add(urls: $0) } }
            Button("Clear") { model.clear() }.disabled(model.running)
            Spacer()
            Text("Originals are kept.").font(.system(size: 11)).foregroundStyle(.secondary)
            Button(model.running ? "Working…" : "Run") { runJobs() }
                .keyboardShortcut(.defaultAction)
                .disabled(runDisabled)
        }
        .padding(12)
    }

    private func runJobs() {
        let kind = kind
        let text = wmText, size = wmSize, opacity = wmOpacity, pos = position
        let pw = password
        model.run { url in
            switch kind {
            case .compress:
                let out = sibling(url, suffix: "compressed", ext: "pdf")
                let r = compressPDF(url, output: out)
                return r.ok ? (.done, out) : (.failed(r.why), nil)
            case .watermark:
                let out = sibling(url, suffix: "watermarked", ext: "pdf")
                let r = watermarkPDF(url, text: text, position: pos,
                                     fontSize: size, opacity: opacity, output: out)
                return r.ok ? (.done, out) : (.failed(r.why), nil)
            case .pageNumbers:
                let out = sibling(url, suffix: "numbered", ext: "pdf")
                let r = numberPages(url, position: pos, output: out)
                return r.ok ? (.done, out) : (.failed(r.why), nil)
            case .protect:
                let out = sibling(url, suffix: "protected", ext: "pdf")
                let r = protectPDF(url, password: pw, output: out)
                return r.ok ? (.done, out) : (.failed(r.why), nil)
            case .unlock:
                let out = sibling(url, suffix: "unlocked", ext: "pdf")
                let r = unlockPDF(url, password: pw, output: out)
                return r.ok ? (.done, out) : (.failed(r.why), nil)
            }
        }
    }
}

// MARK: - Merge

struct MergeTool: View {
    @StateObject private var model = PDFToolModel()

    var body: some View {
        VStack(spacing: 0) {
            Text("Drag rows to set the order. The merged PDF lands next to the first file.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            if model.jobs.isEmpty {
                PDFDropZone(caption: "Drop two or more PDFs here")
            } else {
                List {
                    ForEach(model.jobs) { job in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary).font(.system(size: 10))
                            Text(job.url.lastPathComponent).font(.system(size: 12.5))
                            Spacer()
                            Text(fmtBytes(job.inSize))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .onMove { from, to in model.jobs.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button("Add PDFs…") { choosePDFs { model.add(urls: $0) } }
                Button("Clear") { model.jobs.removeAll() }
                Spacer()
                Button(model.running ? "Merging…" : "Merge \(model.jobs.count) PDFs") { merge() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.jobs.count < 2 || model.running)
            }
            .padding(12)
        }
        .acceptDrops { model.add(urls: $0) }
    }

    private func merge() {
        guard let first = model.jobs.first?.url else { return }
        let urls = model.jobs.map(\.url)
        let out = sibling(first, suffix: "merged", ext: "pdf")
        model.running = true
        DispatchQueue.global().async {
            let r = mergePDFs(urls, output: out)
            DispatchQueue.main.async {
                model.running = false
                if r.ok {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                    model.jobs.removeAll()
                }
            }
        }
    }
}

// MARK: - Split

struct SplitTool: View {
    @StateObject private var model = PDFToolModel()
    @State private var everyPage = true
    @State private var ranges = ""

    private var pageCount: Int {
        model.jobs.first.flatMap { PDFDocument(url: $0.url)?.pageCount } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $everyPage) {
                    Text("One PDF per page").tag(true)
                    Text("Extract pages").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                if !everyPage {
                    HStack {
                        TextField("Pages, like 1-3, 7", text: $ranges).frame(maxWidth: 180)
                        if pageCount > 0 {
                            Text("of \(pageCount) pages")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if model.jobs.isEmpty {
                PDFDropZone(caption: "Drop a PDF here")
            } else {
                PDFJobRows(model: model)
            }
            Divider()
            HStack {
                Button("Choose PDF…") { choosePDFs(false) { model.jobs.removeAll(); model.add(urls: $0) } }
                Button("Clear") { model.clear() }.disabled(model.running)
                Spacer()
                Button(model.running ? "Splitting…" : "Split") { split() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.running || !model.hasPending
                              || (!everyPage && ranges.isEmpty))
            }
            .padding(12)
        }
        .acceptDrops { urls in
            model.jobs.removeAll()
            model.add(urls: urls)
        }
    }

    private func split() {
        let every = everyPage, rangeText = ranges
        model.run { url in
            if every {
                let r = splitEveryPage(url)
                return r.out.map { (.done, $0) } ?? (.failed(r.why), nil)
            }
            guard let count = PDFDocument(url: url)?.pageCount,
                  let pages = parsePageRanges(rangeText, pageCount: count) else {
                return (.failed("bad page range"), nil)
            }
            let out = sibling(url, suffix: "pages \(rangeText.replacingOccurrences(of: " ", with: ""))", ext: "pdf")
            let r = extractPages(url, pages: pages, output: out)
            return r.ok ? (.done, out) : (.failed(r.why), nil)
        }
    }
}

// MARK: - OCR

struct OCRTool: View {
    @StateObject private var model: PDFToolModel = {
        let m = PDFToolModel()
        m.accepts = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "bmp", "gif"]
        return m
    }()
    @State private var output = "txt"   // txt, docx, searchable

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Output", selection: $output) {
                    Text("Plain text").tag("txt")
                    Text("Word (DOCX)").tag("docx")
                    Text("Searchable PDF").tag("searchable")
                }.frame(maxWidth: 260)
                Text(output == "searchable"
                     ? "Rewrites a scanned PDF with an invisible text layer, so it becomes searchable and selectable. PDFs only."
                     : "Reads text from scanned PDFs and photos with Apple's on-device recognition. Nothing is uploaded.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if model.jobs.isEmpty {
                PDFDropZone(caption: "Drop scanned PDFs or images here")
            } else {
                PDFJobRows(model: model)
            }
            Divider()
            HStack {
                Button("Add Files…") {
                    choosePDFs(types: Array(model.accepts)) { model.add(urls: $0) }
                }
                Button("Clear") { model.clear() }.disabled(model.running)
                Spacer()
                Button(model.running ? "Reading…" : "Run OCR") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.running || !model.hasPending)
            }
            .padding(12)
        }
        .acceptDrops { model.add(urls: $0) }
    }

    private func run() {
        let mode = output
        model.run { url in
            let isPDF = url.pathExtension.lowercased() == "pdf"
            if mode == "searchable" {
                guard isPDF else { return (.failed("searchable output needs a PDF"), nil) }
                let out = sibling(url, suffix: "searchable", ext: "pdf")
                let r = makeSearchablePDF(url, output: out)
                return r.ok ? (.done, out) : (.failed(r.why), nil)
            }
            let r = isPDF ? ocrPDF(url) : ocrImage(url)
            guard let text = r.text else { return (.failed(r.why), nil) }
            let out = sibling(url, suffix: "text", ext: mode)
            if mode == "txt" {
                guard (try? text.write(to: out, atomically: true, encoding: .utf8)) != nil else {
                    return (.failed("could not write file"), nil)
                }
                return (.done, out)
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".txt")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
                return (.failed("could not write file"), nil)
            }
            let t = textutilConvert(tmp, to: "docx", output: out)
            return t.ok ? (.done, out) : (.failed(t.why), nil)
        }
    }
}
