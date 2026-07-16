// ClipboardView.swift - the clipboard history pane: search, pinned favorites,
// then everything else newest first. Click a row to copy it back.

import SwiftUI

struct ClipboardView: View {
    @ObservedObject var model = ClipboardModel.shared
    @State private var confirmClear = false
    @State private var copiedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $model.search)
                    .textFieldStyle(.plain)
                Text("\(model.items.count) items")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Clear…") { confirmClear = true }
                    .disabled(model.items.allSatisfy(\.pinned))
            }
            .padding(12)
            Divider()

            if model.filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(model.items.isEmpty
                         ? "Copy something and it shows up here."
                         : "No matches.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !model.pinnedItems.isEmpty {
                        Section("Pinned") {
                            ForEach(model.pinnedItems) { row($0) }
                        }
                    }
                    Section(model.pinnedItems.isEmpty ? "History" : "Recent") {
                        ForEach(model.unpinnedItems) { row($0) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $confirmClear) {
            Button("Clear \(model.items.filter { !$0.pinned }.count) items", role: .destructive) {
                model.clearUnpinned()
            }
        } message: {
            Text("Pinned items are kept. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func row(_ item: ClipItem) -> some View {
        HStack(spacing: 10) {
            switch item.kind {
            case .image:
                if let img = model.image(for: item) {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 120, maxHeight: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Label("Image", systemImage: "photo")
                }
            case .file:
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(item.preview).lineLimit(2)
            case .text:
                Text(item.preview).lineLimit(3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(relativeTime(item.date))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                if let app = item.app {
                    Text(app).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if copiedID == item.id {
                    Text("Copied").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { copy(item, plain: false) }
        .contextMenu {
            Button("Copy") { copy(item, plain: false) }
            if item.kind == .text {
                Button("Copy as Plain Text") { copy(item, plain: true) }
            }
            Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(item) }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func copy(_ item: ClipItem, plain: Bool) {
        plain ? model.copyPlain(item) : model.copy(item)
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == item.id { copiedID = nil }
        }
    }
}
