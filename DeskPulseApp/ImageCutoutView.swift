// ImageCutoutView.swift - the interactive background removal editor. Vision
// finds the subjects; the user decides. Click a subject to keep or drop it,
// then fix the edges by hand with Restore and Erase brushes. The preview
// composites live over a checkerboard so transparency is obvious.

import SwiftUI

@available(macOS 14.0, *)
struct CutoutEditor: View {
    let url: URL
    let onApplied: (JobStatus, URL?) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case select, restore, erase
        var id: String { rawValue }
        var label: String {
            switch self {
            case .select: return "Pick Subjects"
            case .restore: return "Restore"
            case .erase: return "Erase"
            }
        }
    }

    @State private var fullCG: CGImage?
    @State private var masker: SubjectMasker?
    @State private var baseMaskFull: CGImage?
    @State private var selected: Set<Int> = []
    @State private var strokes: [BrushStroke] = []
    @State private var liveStroke: BrushStroke?
    @State private var mode: Mode = .select
    @State private var brushPct = 5.0          // brush diameter, percent of image width
    @State private var previewBase: CGImage?   // downscaled original
    @State private var composited: CGImage?
    @State private var note = ""
    @State private var busy = true
    @State private var applying = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            preview
        }
        .onAppear(perform: load)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            if mode != .select {
                Text("Brush").font(.system(size: 11))
                Slider(value: $brushPct, in: 1...15, step: 0.5).frame(width: 90)
            }
            if let masker {
                Text("\(masker.allInstances.count) subjects · \(selected.count) kept")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo Brush") {
                _ = strokes.popLast()
                recomposite()
            }
            .controlSize(.small).disabled(strokes.isEmpty)
            Button("Reset") {
                strokes = []
                selected = masker?.allInstances ?? []
                rebuildBaseMask()
            }
            .controlSize(.small)
            Button(applying ? "Applying…" : "Apply This Image") { apply() }
                .disabled(busy || applying)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var preview: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Checkerboard()
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                if let composited {
                    Image(decorative: composited, scale: 1)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                } else if busy {
                    ProgressView("Finding subjects…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11)).foregroundStyle(.white)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.55)))
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard !busy, mode != .select else { return }
                        let p = unitPoint(v.location, in: fitted)
                        if liveStroke == nil {
                            liveStroke = BrushStroke(points: [p], radius: brushPct / 200,
                                                     keep: mode == .restore)
                        } else {
                            liveStroke?.points.append(p)
                        }
                        recomposite()
                    }
                    .onEnded { v in
                        guard !busy else { return }
                        if mode == .select {
                            let moved = hypot(v.translation.width, v.translation.height)
                            if moved < 4 { toggleSubject(at: unitPoint(v.location, in: fitted)) }
                        } else if let s = liveStroke {
                            strokes.append(s)
                            liveStroke = nil
                            recomposite()
                        }
                    }
            )
        }
        .padding(8)
    }

    // MARK: - Geometry

    private func fittedRect(in size: CGSize) -> CGRect {
        guard let cg = previewBase else { return .zero }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func unitPoint(_ p: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - fitted.minX) / fitted.width, 0), 1),
                y: min(max((p.y - fitted.minY) / fitted.height, 0), 1))
    }

    // MARK: - Pipeline

    private func load() {
        busy = true
        DispatchQueue.global().async {
            let cg = loadCGImage(url)
            let small = cg.map { downscale($0, maxSide: 1000) }
            let m = cg.flatMap { SubjectMasker(cgImage: $0) }
            let sel = m?.allInstances ?? []
            let mask = sel.isEmpty ? nil : m?.mask(instances: sel)
            DispatchQueue.main.async {
                fullCG = cg
                previewBase = small
                masker = m
                selected = sel
                baseMaskFull = mask
                busy = false
                if cg == nil {
                    note = "could not open image"
                } else if m == nil {
                    note = "No subject found automatically. Paint what you want to keep with the Restore brush."
                    mode = .restore
                } else {
                    note = "Click a subject to keep or drop it. Fix edges with the brushes."
                }
                recomposite()
            }
        }
    }

    private func toggleSubject(at p: CGPoint) {
        guard let masker else { return }
        guard let inst = masker.instance(at: p) else {
            note = "That spot is background. Use the Restore brush to keep it."
            return
        }
        if selected.contains(inst) { selected.remove(inst) } else { selected.insert(inst) }
        note = ""
        rebuildBaseMask()
    }

    private func rebuildBaseMask() {
        guard let masker else { recomposite(); return }
        let sel = selected
        busy = true
        DispatchQueue.global().async {
            let mask = sel.isEmpty ? nil : masker.mask(instances: sel)
            DispatchQueue.main.async {
                baseMaskFull = mask
                busy = false
                recomposite()
            }
        }
    }

    private func recomposite() {
        guard let previewBase else { return }
        let size = CGSize(width: previewBase.width, height: previewBase.height)
        var all = strokes
        if let liveStroke { all.append(liveStroke) }
        guard let mask = composeMask(base: baseMaskFull, size: size, strokes: all) else {
            composited = nil
            return
        }
        composited = applyMask(previewBase, mask: mask)
    }

    private func apply() {
        guard let fullCG else { return }
        let size = CGSize(width: fullCG.width, height: fullCG.height)
        let base = baseMaskFull, all = strokes
        if base == nil && !all.contains(where: \.keep) {
            note = "Nothing is kept. Select a subject or paint with Restore first."
            return
        }
        applying = true
        let out = freeOutputURL(
            dir: url.deletingLastPathComponent(),
            base: url.deletingPathExtension().lastPathComponent + " no background",
            ext: "png")
        DispatchQueue.global().async {
            let ok: Bool
            if let mask = composeMask(base: base, size: size, strokes: all),
               let result = applyMask(fullCG, mask: mask),
               writeCGImage(result, to: out) {
                ok = true
            } else {
                ok = false
            }
            DispatchQueue.main.async {
                applying = false
                onApplied(ok ? .done : .failed("could not write image"), ok ? out : nil)
                if ok { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
        }
    }
}

/// The classic transparency checkerboard.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for row in 0...Int(size.height / s) {
                for col in 0...Int(size.width / s) {
                    let dark = (row + col) % 2 == 0
                    ctx.fill(
                        Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                        with: .color(dark ? Color(white: 0.75) : Color(white: 0.92)))
                }
            }
        }
        .clipped()
    }
}
