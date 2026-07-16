// ConvertView.swift - the file converter pane. Images go through sips and
// audio through afconvert, both of which ship with macOS, so conversion adds
// zero dependencies and never touches the network. Output lands next to the
// source with a new extension; existing files are never overwritten.

import SwiftUI
import UniformTypeIdentifiers

enum MediaKind { case image, audio, document, pdf, unsupported }

enum JobStatus: Equatable {
    case pending, running, done, failed(String)
}

struct ConvertJob: Identifiable {
    let id = UUID()
    let url: URL
    let kind: MediaKind
    var status: JobStatus = .pending
    var outURL: URL?
    var inSize: Int64 = 0
    var outSize: Int64 = 0
}

struct ImageFormat: Identifiable, Hashable {
    let name: String     // sips format name
    let ext: String
    var id: String { name }
    static let all = [
        ImageFormat(name: "jpeg", ext: "jpg"),
        ImageFormat(name: "png", ext: "png"),
        ImageFormat(name: "heic", ext: "heic"),
        ImageFormat(name: "tiff", ext: "tiff"),
        ImageFormat(name: "pdf", ext: "pdf"),
    ]
}

struct DocFormat: Identifiable, Hashable {
    let label: String
    let ext: String      // also the textutil format name, except pdf
    var id: String { ext }
    static let all = [
        DocFormat(label: "Word (DOCX)", ext: "docx"),
        DocFormat(label: "PDF", ext: "pdf"),
        DocFormat(label: "RTF", ext: "rtf"),
        DocFormat(label: "Plain Text", ext: "txt"),
        DocFormat(label: "HTML", ext: "html"),
        DocFormat(label: "OpenDocument (ODT)", ext: "odt"),
    ]
}

struct PdfTarget: Identifiable, Hashable {
    let label: String
    let ext: String
    var id: String { ext }
    static let all = [
        PdfTarget(label: "Word (DOCX)", ext: "docx"),
        PdfTarget(label: "Plain Text", ext: "txt"),
        PdfTarget(label: "RTF", ext: "rtf"),
        PdfTarget(label: "HTML", ext: "html"),
        PdfTarget(label: "PNG images", ext: "png"),
        PdfTarget(label: "JPG images", ext: "jpg"),
    ]
}

struct AudioFormat: Identifiable, Hashable {
    let label: String
    let ext: String
    let args: [String]   // afconvert format/data flags
    let usesBitrate: Bool
    var id: String { ext }
    static let all = [
        AudioFormat(label: "M4A (AAC)", ext: "m4a", args: ["-f", "m4af", "-d", "aac"], usesBitrate: true),
        AudioFormat(label: "WAV", ext: "wav", args: ["-f", "WAVE", "-d", "LEI16"], usesBitrate: false),
        AudioFormat(label: "AIFF", ext: "aiff", args: ["-f", "AIFF", "-d", "BEI16"], usesBitrate: false),
        AudioFormat(label: "FLAC", ext: "flac", args: ["-f", "flac", "-d", "flac"], usesBitrate: false),
    ]
}

private let imageExts: Set<String> = [
    "heic", "heif", "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "webp", "avif", "jp2",
]
private let audioExts: Set<String> = [
    "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "m4b", "au", "snd",
]
private let docExts: Set<String> = [
    "doc", "docx", "rtf", "rtfd", "txt", "html", "htm", "odt", "md",
]

final class ConvertModel: ObservableObject {
    static let shared = ConvertModel()

    @Published var jobs: [ConvertJob] = []
    @Published var running = false
    @Published var imageFormat = ImageFormat.all[0]
    @Published var quality = 85.0            // jpeg/heic
    @Published var resizeOn = false
    @Published var maxDimension = 2048.0     // longest side, px
    @Published var audioFormat = AudioFormat.all[0]
    @Published var bitrate = 192             // kbps for AAC
    @Published var docFormat = DocFormat.all[0]
    @Published var pdfTarget = PdfTarget.all[0]

    private let queue = DispatchQueue(label: "deskpulse.convert")

    var hasImages: Bool { jobs.contains { $0.kind == .image } }
    var hasAudio: Bool { jobs.contains { $0.kind == .audio } }
    var hasDocs: Bool { jobs.contains { $0.kind == .document } }
    var hasPDFs: Bool { jobs.contains { $0.kind == .pdf } }
    var imageURLs: [URL] { jobs.filter { $0.kind == .image }.map(\.url) }

    func add(urls: [URL]) {
        for url in urls {
            guard !jobs.contains(where: { $0.url == url && $0.status == .pending }) else { continue }
            let ext = url.pathExtension.lowercased()
            let kind: MediaKind =
                imageExts.contains(ext) ? .image
                : audioExts.contains(ext) ? .audio
                : docExts.contains(ext) ? .document
                : ext == "pdf" ? .pdf
                : .unsupported
            var job = ConvertJob(url: url, kind: kind, inSize: fileSize(url))
            if kind == .unsupported {
                job.status = .failed("not an image or audio file")
            }
            jobs.append(job)
        }
    }

    func clear() {
        jobs.removeAll { $0.status != .running }
    }

    func convertAll() {
        guard !running else { return }
        running = true
        let pending = jobs.enumerated().filter { $0.element.status == .pending }
        queue.async { [self] in
            for (i, job) in pending {
                DispatchQueue.main.sync { jobs[i].status = .running }
                let result = convert(job)
                DispatchQueue.main.sync {
                    jobs[i].status = result.status
                    jobs[i].outURL = result.out
                    jobs[i].outSize = result.out.map(fileSize) ?? 0
                }
            }
            DispatchQueue.main.async { self.running = false }
        }
    }

    private func convert(_ job: ConvertJob) -> (status: JobStatus, out: URL?) {
        let dir = job.url.deletingLastPathComponent()
        let base = job.url.deletingPathExtension().lastPathComponent

        switch job.kind {
        case .image:
            let out = freeOutputURL(dir: dir, base: base, ext: imageFormat.ext)
            var args = ["-s", "format", imageFormat.name]
            if imageFormat.name == "jpeg" || imageFormat.name == "heic" {
                args += ["-s", "formatOptions", String(Int(quality))]
            }
            if resizeOn {
                args += ["-Z", String(Int(maxDimension))]
            }
            args += [job.url.path, "--out", out.path]
            let r = runCommand("/usr/bin/sips", args)
            // sips can exit 0 yet not write on some inputs, so verify the file
            guard r.ok, FileManager.default.fileExists(atPath: out.path) else {
                return (.failed(firstLine(r.out)), nil)
            }
            return (.done, out)

        case .audio:
            let out = freeOutputURL(dir: dir, base: base, ext: audioFormat.ext)
            var args = audioFormat.args
            if audioFormat.usesBitrate {
                args += ["-b", String(bitrate * 1000)]
            }
            args += [job.url.path, out.path]
            let r = runCommand("/usr/bin/afconvert", args)
            guard r.ok, FileManager.default.fileExists(atPath: out.path) else {
                return (.failed(firstLine(r.out)), nil)
            }
            return (.done, out)

        case .document:
            let out = freeOutputURL(dir: dir, base: base, ext: docFormat.ext)
            if docFormat.ext == "pdf" {
                guard let attr = readDocument(job.url) else {
                    return (.failed("could not read document"), nil)
                }
                guard renderPDF(attr, to: out) else {
                    return (.failed("could not write PDF"), nil)
                }
                return (.done, out)
            }
            let r = textutilConvert(job.url, to: docFormat.ext, output: out)
            return r.ok ? (.done, out) : (.failed(r.why), nil)

        case .pdf:
            if pdfTarget.ext == "png" || pdfTarget.ext == "jpg" {
                let r = pdfToImages(job.url, format: pdfTarget.ext)
                return r.out.map { (.done, $0) } ?? (.failed(r.why), nil)
            }
            guard let text = pdfText(job.url) else {
                return (.failed("no text in PDF (scanned image?)"), nil)
            }
            let out = freeOutputURL(dir: dir, base: base, ext: pdfTarget.ext)
            if pdfTarget.ext == "txt" {
                guard (try? text.write(to: out, atomically: true, encoding: .utf8)) != nil else {
                    return (.failed("could not write file"), nil)
                }
                return (.done, out)
            }
            // docx/rtf/html: go through a temp txt file so textutil does the writing
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".txt")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
                return (.failed("could not write file"), nil)
            }
            let r = textutilConvert(tmp, to: pdfTarget.ext, output: out)
            return r.ok ? (.done, out) : (.failed(r.why), nil)

        case .unsupported:
            return (.failed("unsupported type"), nil)
        }
    }

    /// One multi-page PDF from every image in the list, in list order.
    func combineImagesToPDF() {
        let urls = imageURLs
        guard urls.count >= 2, let first = urls.first else { return }
        let out = freeOutputURL(
            dir: first.deletingLastPathComponent(),
            base: first.deletingPathExtension().lastPathComponent + " combined",
            ext: "pdf")
        let totalIn = urls.map(fileSize).reduce(0, +)
        queue.async { [self] in
            let ok = imagesToPDF(urls, output: out)
            DispatchQueue.main.async {
                var job = ConvertJob(url: out, kind: .pdf, inSize: totalIn)
                job.status = ok ? .done : .failed("could not combine images")
                job.outURL = ok ? out : nil
                job.outSize = ok ? fileSize(out) : 0
                self.jobs.append(job)
            }
        }
    }

    private func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n").last.map(String.init) ?? "conversion failed"
        return line.isEmpty ? "conversion failed" : line
    }
}

// MARK: - Pane

struct ConvertView: View {
    @ObservedObject var model = ConvertModel.shared
    @State private var dropActive = false

    var body: some View {
        VStack(spacing: 0) {
            if model.jobs.isEmpty {
                dropZone
            } else {
                options
                Divider()
                jobList
                Divider()
                footer
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
            loadDrop(providers)
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(dropActive ? AnyShapeStyle(.blue) : AnyShapeStyle(.tertiary))
            Text("Drop images, audio, documents, or PDFs here")
                .font(.system(size: 15, weight: .medium))
            Text("HEIC, JPG, PNG, TIFF, WebP · MP3, M4A, WAV, AIFF, FLAC · DOCX, DOC, RTF, TXT, HTML, ODT, MD, PDF")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Choose Files…") { openPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropActive ? Color.blue.opacity(0.06) : Color.clear)
    }

    private var options: some View {
        HStack(alignment: .top, spacing: 16) {
            if model.hasImages {
                GroupBox("Images") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Convert to", selection: $model.imageFormat) {
                            ForEach(ImageFormat.all) { Text($0.ext.uppercased()).tag($0) }
                        }
                        .frame(maxWidth: 220)
                        if model.imageFormat.name == "jpeg" || model.imageFormat.name == "heic" {
                            HStack {
                                Text("Quality \(Int(model.quality))")
                                    .font(.system(size: 11)).frame(width: 70, alignment: .leading)
                                Slider(value: $model.quality, in: 40...100, step: 5)
                                    .frame(width: 140)
                            }
                        }
                        HStack {
                            Toggle("Resize longest side to", isOn: $model.resizeOn)
                                .font(.system(size: 11))
                            TextField("px", value: $model.maxDimension, format: .number)
                                .frame(width: 60)
                                .disabled(!model.resizeOn)
                            Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
            }
            if model.hasAudio {
                GroupBox("Audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Convert to", selection: $model.audioFormat) {
                            ForEach(AudioFormat.all) { Text($0.label).tag($0) }
                        }
                        .frame(maxWidth: 220)
                        if model.audioFormat.usesBitrate {
                            Picker("Bitrate", selection: $model.bitrate) {
                                Text("128 kbps").tag(128)
                                Text("192 kbps").tag(192)
                                Text("256 kbps").tag(256)
                            }
                            .frame(maxWidth: 220)
                        }
                    }
                    .padding(4)
                }
            }
            if model.hasDocs {
                GroupBox("Documents") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Convert to", selection: $model.docFormat) {
                            ForEach(DocFormat.all) { Text($0.label).tag($0) }
                        }
                        .frame(maxWidth: 240)
                        Text("Text and formatting convert; images inside documents do not.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }
            if model.hasPDFs {
                GroupBox("PDFs") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Convert to", selection: $model.pdfTarget) {
                            ForEach(PdfTarget.all) { Text($0.label).tag($0) }
                        }
                        .frame(maxWidth: 240)
                        Text(model.pdfTarget.ext == "png" || model.pdfTarget.ext == "jpg"
                             ? "Each page becomes an image at 144 dpi."
                             : "Extracts the text. Layout and images are not carried over.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private var jobList: some View {
        List(model.jobs) { job in
            HStack(spacing: 10) {
                Image(systemName: rowIcon(job.kind))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.url.lastPathComponent).font(.system(size: 12.5))
                    Text(sizeLine(job))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                statusView(job)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private func rowIcon(_ kind: MediaKind) -> String {
        switch kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .pdf: return "doc.richtext"
        case .unsupported: return "questionmark.circle"
        }
    }

    private func sizeLine(_ job: ConvertJob) -> String {
        if case .done = job.status, job.outSize > 0 {
            return "\(fmtBytes(job.inSize)) → \(fmtBytes(job.outSize))"
        }
        return fmtBytes(job.inSize)
    }

    @ViewBuilder
    private func statusView(_ job: ConvertJob) -> some View {
        switch job.status {
        case .pending:
            Text("ready").font(.system(size: 11)).foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let out = job.outURL {
                    Button("Show") {
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                    }
                    .controlSize(.small)
                }
            }
        case .failed(let why):
            Label(why, systemImage: "xmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack {
            Button("Add Files…") { openPanel() }
            Button("Clear") { model.clear() }.disabled(model.running)
            if model.imageURLs.count >= 2 {
                Button("Combine Images into One PDF") { model.combineImagesToPDF() }
                    .disabled(model.running)
            }
            Spacer()
            Text("Originals are kept. New files land in the same folder.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(model.running ? "Converting…" : "Convert") { model.convertAll() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.running || !model.jobs.contains { $0.status == .pending })
        }
        .padding(12)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }

    private func loadDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { model.add(urls: [url]) }
                }
            }
        }
    }
}
