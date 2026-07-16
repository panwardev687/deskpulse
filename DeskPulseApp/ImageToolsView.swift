// ImageToolsView.swift - quick image jobs that are not format conversion:
// resize (pixels or percent), compress for email/upload, rotate and flip.
// Everything runs through sips, which ships with macOS. Originals are kept;
// results are written next to them with a " resized" / " compressed" /
// " rotated" suffix and never overwrite anything.

import SwiftUI
import UniformTypeIdentifiers

enum ImageOp: String, CaseIterable, Identifiable {
    case resize, compress, rotate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .resize: return "Resize"
        case .compress: return "Compress"
        case .rotate: return "Rotate & Flip"
        }
    }
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
            Picker("", selection: $model.op) {
                ForEach(ImageOp.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

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
            Text("Originals are kept.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(model.running ? "Working…" : "Apply") { model.runAll() }
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
