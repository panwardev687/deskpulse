// PDFOrganizeView.swift - the page editor: open a PDF, see its pages as
// thumbnails, drag to reorder, rotate or delete the selected ones, save as a
// new file. The original is never modified.

import SwiftUI
import PDFKit

struct OrgPage: Identifiable {
    let id = UUID()
    let originalIndex: Int
    var rotation = 0          // extra degrees on top of the page's own
    var thumb: NSImage?
}

final class OrganizeModel: ObservableObject {
    @Published var source: URL?
    @Published var pages: [OrgPage] = []
    @Published var selection = Set<UUID>()
    @Published var saving = false
    @Published var note = ""

    func load(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            note = "could not open \(url.lastPathComponent)"
            return
        }
        source = url
        note = ""
        selection = []
        pages = (0..<doc.pageCount).map { OrgPage(originalIndex: $0) }
        DispatchQueue.global().async { [weak self] in
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let img = page.thumbnail(of: CGSize(width: 260, height: 340), for: .mediaBox)
                DispatchQueue.main.async {
                    if let self, i < self.pages.count,
                       self.pages[i].originalIndex == i {
                        self.pages[i].thumb = img
                    }
                }
            }
        }
    }

    func rotateSelected() {
        for i in pages.indices where selection.contains(pages[i].id) {
            pages[i].rotation = (pages[i].rotation + 90) % 360
        }
    }

    func deleteSelected() {
        pages.removeAll { selection.contains($0.id) }
        selection = []
    }

    func save() {
        guard let source, let doc = PDFDocument(url: source), !pages.isEmpty else { return }
        saving = true
        let order = pages
        let out = sibling(source, suffix: "organized", ext: "pdf")
        DispatchQueue.global().async { [weak self] in
            let newDoc = PDFDocument()
            for (i, p) in order.enumerated() {
                guard let page = doc.page(at: p.originalIndex)?.copy() as? PDFPage else { continue }
                page.rotation = ((page.rotation + p.rotation) % 360 + 360) % 360
                newDoc.insert(page, at: i)
            }
            let ok = newDoc.pageCount > 0 && newDoc.write(to: out)
            DispatchQueue.main.async {
                self?.saving = false
                self?.note = ok ? "Saved \(out.lastPathComponent)" : "could not write PDF"
                if ok { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
        }
    }
}

struct PDFOrganizeView: View {
    @StateObject private var model = OrganizeModel()

    var body: some View {
        VStack(spacing: 0) {
            if model.source == nil {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.3x2")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Drop a PDF here to organize its pages")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Choose PDF…") { choosePDFs(false) { $0.first.map(model.load) } }
                    if !model.note.isEmpty {
                        Text(model.note).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.pages) { page in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary).font(.system(size: 10))
                            Group {
                                if let t = page.thumb {
                                    Image(nsImage: t)
                                        .resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .frame(width: 64, height: 84)
                            .rotationEffect(.degrees(Double(page.rotation)))
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .textBackgroundColor)))
                            Text("Page \(page.originalIndex + 1)")
                                .font(.system(size: 12))
                            if page.rotation != 0 {
                                Text("rotated \(page.rotation)°")
                                    .font(.system(size: 10.5)).foregroundStyle(.blue)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .tag(page.id)
                    }
                    .onMove { from, to in model.pages.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Button("Open Another…") { choosePDFs(false) { $0.first.map(model.load) } }
                    Spacer()
                    Text("\(model.pages.count) pages · drag to reorder")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Rotate 90°") { model.rotateSelected() }
                        .disabled(model.selection.isEmpty)
                    Button("Delete") { model.deleteSelected() }
                        .disabled(model.selection.isEmpty)
                    Button(model.saving ? "Saving…" : "Save as New PDF") { model.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.saving || model.pages.isEmpty)
                }
                .padding(12)
                if !model.note.isEmpty {
                    Text(model.note)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
        }
        .acceptDrops { urls in
            if let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                model.load(pdf)
            }
        }
    }
}
