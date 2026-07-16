// ImageToolsView.swift - quick image jobs that are not format conversion:
// resize (pixels or percent), compress for email/upload, rotate and flip.
// Everything runs through sips, which ships with macOS. Originals are kept;
// results are written next to them with a " resized" / " compressed" /
// " rotated" suffix and never overwrite anything.

import SwiftUI
import UniformTypeIdentifiers

enum ImageOp: String, CaseIterable, Identifiable {
    case resize, compress, crop, watermark, enlarge, cutout, rotate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .resize: return "Resize"
        case .compress: return "Compress"
        case .crop: return "Crop"
        case .watermark: return "Watermark"
        case .enlarge: return "Enlarge"
        case .cutout: return "Remove Background"
        case .rotate: return "Rotate & Flip"
        }
    }

    /// Background removal needs Vision's subject lift, which is macOS 14+.
    static var available: [ImageOp] {
        if #available(macOS 14, *) { return allCases }
        return allCases.filter { $0 != .cutout }
    }
}

/// Formats ImageIO can write back; anything else (webp, gif, bmp) becomes png.
func editableOutExt(_ url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    return ["jpg", "jpeg", "png", "heic", "tiff", "tif"].contains(ext) ? ext : "png"
}

enum RotateAction: String, CaseIterable, Identifiable {
    case cw90, ccw90, half, flipH, flipV
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cw90: return "Rotate 90° right"
        case .ccw90: return "Rotate 90° left"
        case .half: return "Rotate 180°"
        case .flipH: return "Flip horizontal"
        case .flipV: return "Flip vertical"
        }
    }
}

struct ImageJob: Identifiable {
    let id = UUID()
    let url: URL
    var status: JobStatus = .pending
    var outURL: URL?
    var inSize: Int64 = 0
    var outSize: Int64 = 0
}

private let editableExts: Set<String> = [
    "heic", "heif", "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "webp",
]

final class ImageToolsModel: ObservableObject {
    static let shared = ImageToolsModel()

    @Published var jobs: [ImageJob] = []
    @Published var running = false
    @Published var op: ImageOp = .resize
    @Published var resizeByPercent = false
    @Published var maxSide = 1600.0          // px, longest side
    @Published var percent = 50.0
    @Published var compressQuality = 70.0
    @Published var compressAsHEIC = false    // false = JPEG
    @Published var compressResize = true     // also cap longest side while compressing
    @Published var compressMaxSide = 2048.0
    @Published var rotateAction: RotateAction = .cw90
    @Published var cropUnitRect: CGRect?
    @Published var cropAspect: Double?       // width/height, nil = free
    @Published var wmText = "© my name"
    @Published var wmLogoURL: URL?
    @Published var wmUseLogo = false
    @Published var wmPosition: StampPosition = .bottomRight
    @Published var wmOpacity = 0.6
    @Published var wmSizePercent = 16.0      // percent of image width
    @Published var wmWhite = true
    @Published var enlargeFactor = 2.0
    @Published var selectedID: UUID?

    /// The image shown in the preview panel: the clicked row, else first pending.
    var previewJob: ImageJob? {
        if let j = jobs.first(where: { $0.id == selectedID }) { return j }
        return jobs.first(where: { $0.status == .pending }) ?? jobs.first
    }

    /// Mark a single job finished from an interactive editor (cutout).
    func complete(_ id: UUID, status: JobStatus, out: URL?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = status
        jobs[i].outURL = out
        jobs[i].outSize = out.map(fileSize) ?? 0
        if selectedID == id { selectedID = nil }   // move on to the next pending
    }

    private let queue = DispatchQueue(label: "deskpulse.imagetools")

    func add(urls: [URL]) {
        for url in urls where editableExts.contains(url.pathExtension.lowercased()) {
            guard !jobs.contains(where: { $0.url == url && $0.status == .pending }) else { continue }
            jobs.append(ImageJob(url: url, inSize: fileSize(url)))
        }
    }

    func clear() {
        jobs.removeAll { $0.status != .running }
    }

    func runAll() {
        guard !running else { return }
        running = true
        let pending = jobs.enumerated().filter { $0.element.status == .pending }
        queue.async { [self] in
            for (i, job) in pending {
                DispatchQueue.main.sync { jobs[i].status = .running }
                let result = process(job)
                DispatchQueue.main.sync {
                    jobs[i].status = result.status
                    jobs[i].outURL = result.out
                    jobs[i].outSize = result.out.map(fileSize) ?? 0
                }
            }
            DispatchQueue.main.async { self.running = false }
        }
    }

    private func process(_ job: ImageJob) -> (status: JobStatus, out: URL?) {
        let dir = job.url.deletingLastPathComponent()
        let base = job.url.deletingPathExtension().lastPathComponent
        let ext = job.url.pathExtension.lowercased()

        switch op {
        case .resize:
            var target = Int(maxSide)
            if resizeByPercent {
                guard let side = longestSide(job.url) else {
                    return (.failed("could not read dimensions"), nil)
                }
                target = max(1, Int(Double(side) * percent / 100))
            }
            let out = freeOutputURL(dir: dir, base: base + " resized", ext: ext)
            let r = runCommand("/usr/bin/sips",
                               ["-Z", String(target), job.url.path, "--out", out.path])
            return finish(r, out)

        case .compress:
            let fmt = compressAsHEIC ? "heic" : "jpeg"
            let outExt = compressAsHEIC ? "heic" : "jpg"
            var args = ["-s", "format", fmt, "-s", "formatOptions", String(Int(compressQuality))]
            if compressResize {
                args += ["-Z", String(Int(compressMaxSide))]
            }
            args += [job.url.path, "--out", ""]
            let out = freeOutputURL(dir: dir, base: base + " compressed", ext: outExt)
            args[args.count - 1] = out.path
            let r = runCommand("/usr/bin/sips", args)
            return finish(r, out)

        case .rotate:
            let suffix = (rotateAction == .flipH || rotateAction == .flipV)
                ? " flipped" : " rotated"
            let out = freeOutputURL(dir: dir, base: base + suffix, ext: ext)
            var args: [String]
            switch rotateAction {
            case .cw90: args = ["-r", "90"]
            case .ccw90: args = ["-r", "270"]
            case .half: args = ["-r", "180"]
            case .flipH: args = ["-f", "horizontal"]
            case .flipV: args = ["-f", "vertical"]
            }
            args += [job.url.path, "--out", out.path]
            let r = runCommand("/usr/bin/sips", args)
            return finish(r, out)

        case .crop:
            guard let unit = cropUnitRect else {
                return (.failed("draw a crop area on the preview first"), nil)
            }
            let out = freeOutputURL(dir: dir, base: base + " cropped",
                                    ext: editableOutExt(job.url))
            let r = cropImage(job.url, unitRect: unit, output: out)
            return r.ok ? (.done, out) : (.failed(r.why), nil)

        case .watermark:
            let out = freeOutputURL(dir: dir, base: base + " watermarked",
                                    ext: editableOutExt(job.url))
            let r = watermarkImage(
                job.url, text: wmUseLogo ? "" : wmText,
                logo: wmUseLogo ? wmLogoURL : nil,
                position: wmPosition, opacity: wmOpacity,
                sizePercent: wmSizePercent, white: wmWhite, output: out)
            return r.ok ? (.done, out) : (.failed(r.why), nil)

        case .enlarge:
            let out = freeOutputURL(dir: dir, base: base + " enlarged",
                                    ext: editableOutExt(job.url))
            let r = enlargeImage(job.url, factor: enlargeFactor, output: out)
            return r.ok ? (.done, out) : (.failed(r.why), nil)

        case .cutout:
            guard #available(macOS 14, *) else {
                return (.failed("needs macOS 14 or newer"), nil)
            }
            let out = freeOutputURL(dir: dir, base: base + " no background", ext: "png")
            let r = removeBackground(job.url, output: out)
            return r.ok ? (.done, out) : (.failed(r.why), nil)
        }
    }

    private func finish(_ r: (out: String, ok: Bool), _ out: URL) -> (JobStatus, URL?) {
        guard r.ok, FileManager.default.fileExists(atPath: out.path) else {
            let why = r.out.split(separator: "\n").last.map(String.init) ?? "sips failed"
            return (.failed(why), nil)
        }
        return (.done, out)
    }

    private func longestSide(_ url: URL) -> Int? {
        let r = runCommand("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", url.path])
        guard r.ok else { return nil }
        let nums = r.out.split(separator: "\n").compactMap { line -> Int? in
            guard let v = line.split(separator: ":").last else { return nil }
            return Int(v.trimmingCharacters(in: .whitespaces))
        }
        return nums.max()
    }
}

// MARK: - Pane

struct ImageToolsView: View {
    @ObservedObject var model = ImageToolsModel.shared
    @State private var dropActive = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let job = model.previewJob {
                previewPanel(job)
                    .frame(height: 300)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
            }
            if model.jobs.isEmpty {
                dropZone
            } else {
                jobList
                Divider()
                footer
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async { model.add(urls: [url]) }
                    }
                }
            }
            return true
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tool").font(.system(size: 12, weight: .semibold))
                Picker("", selection: $model.op) {
                    ForEach(ImageOp.available) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                if #unavailable(macOS 14) {
                    Text("Remove Background needs macOS 14+")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }

            switch model.op {
            case .resize:
                HStack(spacing: 10) {
                    Picker("", selection: $model.resizeByPercent) {
                        Text("Longest side").tag(false)
                        Text("Percent").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    if model.resizeByPercent {
                        Slider(value: $model.percent, in: 10...90, step: 5).frame(width: 140)
                        Text("\(Int(model.percent))%").monospacedDigit()
                    } else {
                        TextField("px", value: $model.maxSide, format: .number)
                            .frame(width: 70)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
            case .compress:
                HStack(spacing: 12) {
                    Picker("", selection: $model.compressAsHEIC) {
                        Text("JPEG").tag(false)
                        Text("HEIC (smaller)").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Text("Quality \(Int(model.compressQuality))")
                        .font(.system(size: 11)).monospacedDigit()
                    Slider(value: $model.compressQuality, in: 30...90, step: 5).frame(width: 130)
                    Toggle("Cap longest side at", isOn: $model.compressResize)
                        .font(.system(size: 11))
                    TextField("px", value: $model.compressMaxSide, format: .number)
                        .frame(width: 64).disabled(!model.compressResize)
                }
                Text("Re-encodes the image, so PNG transparency is lost. Good for email and uploads.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            case .rotate:
                Picker("", selection: $model.rotateAction) {
                    ForEach(RotateAction.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 200)
            case .crop:
                HStack(spacing: 10) {
                    Text("Aspect").font(.system(size: 11))
                    Picker("", selection: $model.cropAspect) {
                        Text("Free").tag(Double?.none)
                        Text("Square").tag(Double?.some(1))
                        Text("16:9").tag(Double?.some(16.0 / 9))
                        Text("4:3").tag(Double?.some(4.0 / 3))
                        Text("3:2").tag(Double?.some(1.5))
                    }
                    .labelsHidden().frame(maxWidth: 110)
                    Text("Drag on the preview below. The same area (as a fraction of each image) is cropped from every file.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if model.cropUnitRect != nil {
                        Button("Reset") { model.cropUnitRect = nil }.controlSize(.small)
                    }
                }
            case .watermark:
                HStack(spacing: 10) {
                    Picker("", selection: $model.wmUseLogo) {
                        Text("Text").tag(false)
                        Text("Logo").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    if model.wmUseLogo {
                        Button(model.wmLogoURL?.lastPathComponent ?? "Choose Logo…") {
                            choosePDFs(false, types: ["png", "jpg", "jpeg", "heic", "tiff"]) {
                                model.wmLogoURL = $0.first
                            }
                        }
                    } else {
                        TextField("Watermark text", text: $model.wmText).frame(maxWidth: 160)
                        Toggle("White", isOn: $model.wmWhite).font(.system(size: 11))
                    }
                    Picker("", selection: $model.wmPosition) {
                        ForEach(StampPosition.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 130)
                    Text("Size").font(.system(size: 11))
                    Slider(value: $model.wmSizePercent, in: 5...40, step: 1).frame(width: 90)
                    Text("Opacity").font(.system(size: 11))
                    Slider(value: $model.wmOpacity, in: 0.15...1, step: 0.05).frame(width: 90)
                }
            case .enlarge:
                HStack(spacing: 10) {
                    Picker("", selection: $model.enlargeFactor) {
                        Text("2x").tag(2.0)
                        Text("3x").tag(3.0)
                        Text("4x").tag(4.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                    Text("High quality Lanczos scaling. Sharper than a plain resize; it does not invent detail like AI upscalers.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            case .cutout:
                Text("Cuts the subject (people, pets, products) out of the photo with Apple's on-device segmentation. Output is a PNG with a transparent background.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(dropActive ? AnyShapeStyle(.blue) : AnyShapeStyle(.tertiary))
            Text("Drop images here")
                .font(.system(size: 15, weight: .medium))
            Text("HEIC, JPG, PNG, TIFF, WebP, GIF, BMP")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Choose Images…") { openPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropActive ? Color.blue.opacity(0.06) : Color.clear)
    }

    /// Live preview of the current tool applied to the selected image.
    @ViewBuilder
    private func previewPanel(_ job: ImageJob) -> some View {
        switch model.op {
        case .crop:
            CropPreviewLoader(url: job.url, unitRect: $model.cropUnitRect,
                              aspect: model.cropAspect)
                .id(job.id)
        case .cutout:
            if #available(macOS 14, *) {
                CutoutEditor(url: job.url) { status, out in
                    model.complete(job.id, status: status, out: out)
                }
                .id(job.id)
            }
        case .watermark:
            WatermarkPreview(url: job.url, model: model).id(job.id)
        case .rotate:
            RotatePreview(url: job.url, action: model.rotateAction).id(job.id)
        case .resize, .compress, .enlarge:
            DimsPreview(url: job.url, model: model).id(job.id)
        }
    }

    private var jobList: some View {
        List(model.jobs) { job in
            HStack(spacing: 10) {
                Image(systemName: "photo").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.url.lastPathComponent).font(.system(size: 12.5))
                    Text(sizeLine(job))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
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
                        .font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedID = job.id }
            .listRowBackground(
                model.previewJob?.id == job.id
                    ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .listStyle(.inset)
    }

    private func sizeLine(_ job: ImageJob) -> String {
        if case .done = job.status, job.outSize > 0 {
            let saved = job.inSize > 0
                ? 100 - Int(Double(job.outSize) / Double(job.inSize) * 100) : 0
            return saved > 0
                ? "\(fmtBytes(job.inSize)) → \(fmtBytes(job.outSize)) (\(saved)% smaller)"
                : "\(fmtBytes(job.inSize)) → \(fmtBytes(job.outSize))"
        }
        return fmtBytes(job.inSize)
    }

    private var footer: some View {
        HStack {
            Button("Add Images…") { openPanel() }
            Button("Clear") { model.clear() }.disabled(model.running)
            Spacer()
            Text(model.op == .cutout
                 ? "Use the editor above per image, or cut out every image automatically."
                 : "Originals are kept.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(model.running ? "Working…"
                   : model.op == .cutout ? "Auto Cutout All" : "Apply") { model.runAll() }
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
}

// MARK: - Live previews

/// Watermark preview: re-renders the stamp live as settings change.
struct WatermarkPreview: View {
    let url: URL
    @ObservedObject var model: ImageToolsModel
    @State private var base: CGImage?
    @State private var logo: NSImage?

    var body: some View {
        Group {
            if let base {
                let rendered = watermarkCG(
                    base, text: model.wmUseLogo ? "" : model.wmText,
                    logo: model.wmUseLogo ? logo : nil,
                    position: model.wmPosition, opacity: model.wmOpacity,
                    sizePercent: model.wmSizePercent, white: model.wmWhite)
                Image(decorative: rendered ?? base, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .padding(10)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.global().async {
                let cg = loadCGImage(url).map { downscale($0, maxSide: 900) }
                DispatchQueue.main.async { base = cg }
            }
        }
        .onChange(of: model.wmLogoURL) { newURL in
            logo = newURL.flatMap { NSImage(contentsOf: $0) }
        }
        .onAppear { logo = model.wmLogoURL.flatMap { NSImage(contentsOf: $0) } }
    }
}

/// Rotate and flip preview, done with view transforms so it is instant.
struct RotatePreview: View {
    let url: URL
    let action: RotateAction
    @State private var img: NSImage?

    var body: some View {
        Group {
            if let img {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(rotation))
                    .scaleEffect(x: flipX ? -1 : 1, y: flipY ? -1 : 1)
                    .padding(24)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { img = NSImage(contentsOf: url) }
    }

    private var rotation: Double {
        switch action {
        case .cw90: return 90
        case .ccw90: return -90
        case .half: return 180
        default: return 0
        }
    }
    private var flipX: Bool { action == .flipH }
    private var flipY: Bool { action == .flipV }
}

/// Resize / compress / enlarge preview: the image plus what its pixel
/// dimensions will become.
struct DimsPreview: View {
    let url: URL
    @ObservedObject var model: ImageToolsModel
    @State private var img: NSImage?
    @State private var dims = (w: 0, h: 0)

    var body: some View {
        VStack(spacing: 6) {
            if let img {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .padding(.top, 10)
                Text(caption)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.global().async {
                let cg = loadCGImage(url)
                let d = cg.map { ($0.width, $0.height) } ?? (0, 0)
                let preview = cg.map { downscale($0, maxSide: 900) }
                DispatchQueue.main.async {
                    dims = d
                    img = preview.map { NSImage(cgImage: $0, size: .zero) }
                }
            }
        }
    }

    private var caption: String {
        let (w, h) = dims
        guard w > 0, h > 0 else { return "" }
        func scaled(_ f: Double) -> String {
            "\(w) × \(h) px  →  \(Int(Double(w) * f)) × \(Int(Double(h) * f)) px"
        }
        let longest = Double(max(w, h))
        switch model.op {
        case .resize:
            let f = model.resizeByPercent
                ? model.percent / 100
                : min(1, model.maxSide / longest)
            return scaled(f)
        case .compress:
            let f = model.compressResize ? min(1, model.compressMaxSide / longest) : 1
            return scaled(f) + "  ·  quality \(Int(model.compressQuality))"
        case .enlarge:
            return scaled(model.enlargeFactor)
        default:
            return "\(w) × \(h) px"
        }
    }
}

// MARK: - Crop preview

/// Loads the first image once and hosts the drag-to-crop surface.
struct CropPreviewLoader: View {
    let url: URL
    @Binding var unitRect: CGRect?
    let aspect: Double?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                CropPreview(image: image, unitRect: $unitRect, aspect: aspect)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { image = NSImage(contentsOf: url) }
        .onChange(of: url) { image = NSImage(contentsOf: $0) }
    }
}

struct CropPreview: View {
    let image: NSImage
    @Binding var unitRect: CGRect?
    let aspect: Double?

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                if let unit = unitRect {
                    let r = CGRect(
                        x: fitted.minX + unit.minX * fitted.width,
                        y: fitted.minY + unit.minY * fitted.height,
                        width: unit.width * fitted.width,
                        height: unit.height * fitted.height)
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.12))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        unitRect = dragRect(from: v.startLocation, to: v.location, in: fitted)
                    }
            )
        }
        .padding(8)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func dragRect(from a: CGPoint, to b: CGPoint, in fitted: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, fitted.minX), fitted.maxX),
                    y: min(max(p.y, fitted.minY), fitted.maxY))
        }
        let p1 = clamp(a), p2 = clamp(b)
        var w = abs(p2.x - p1.x), h = abs(p2.y - p1.y)
        if let aspect {
            // lock to the chosen ratio, sized by the larger drag direction
            if w / max(h, 1) > aspect { h = w / aspect } else { w = h * aspect }
        }
        var x = p2.x >= p1.x ? p1.x : p1.x - w
        var y = p2.y >= p1.y ? p1.y : p1.y - h
        x = min(max(x, fitted.minX), fitted.maxX - w)
        y = min(max(y, fitted.minY), fitted.maxY - h)
        w = min(w, fitted.maxX - x)
        h = min(h, fitted.maxY - y)
        return CGRect(x: (x - fitted.minX) / fitted.width,
                      y: (y - fitted.minY) / fitted.height,
                      width: w / fitted.width,
                      height: h / fitted.height)
    }
}
