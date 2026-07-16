// SnippetsView.swift - the text expander pane: snippet list on the left,
// editor on the right, with the Accessibility permission flow inline.

import SwiftUI

struct SnippetsView: View {
    @ObservedObject var model = SnippetsModel.shared
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.expansionOn && !model.axGranted { permissionBanner }
            HSplitView {
                snippetList
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                editor
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack {
            Toggle("Expand snippets as I type", isOn: $model.expansionOn)
                .toggleStyle(.switch)
            Spacer()
            if model.expandedCount > 0 {
                Text("\(model.expandedCount) expansions this session")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button {
                let s = model.addSnippet()
                selected = s.id
            } label: {
                Label("New Snippet", systemImage: "plus")
            }
        }
        .padding(12)
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("DeskPulse needs Accessibility access to watch for triggers and type expansions.")
                    .font(.system(size: 12))
                Text("System Settings → Privacy & Security → Accessibility → enable DeskPulse")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant Access") {
                model.requestAccess()
                NSWorkspace.shared.open(URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1))
    }

    private var snippetList: some View {
        List(selection: $selected) {
            ForEach(model.snippets) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.trigger.isEmpty ? "new snippet" : s.trigger)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(s.enabled ? .primary : .secondary)
                    Text(s.expansion.split(separator: "\n").first.map(String.init) ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(s.id)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var editor: some View {
        if let i = model.snippets.firstIndex(where: { $0.id == selected }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Trigger").font(.system(size: 12, weight: .semibold))
                    TextField(";addr", text: $model.snippets[i].trigger)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(maxWidth: 200)
                    Spacer()
                    Toggle("Enabled", isOn: $model.snippets[i].enabled)
                    Button(role: .destructive) {
                        let s = model.snippets[i]
                        selected = nil
                        model.delete(s)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                Text("Expansion").font(.system(size: 12, weight: .semibold))
                TextEditor(text: $model.snippets[i].expansion)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor)))
                Text("Placeholders: {date} {time} {clipboard}, filled in when the snippet expands. Start triggers with a character you never type mid-word, like ; or //")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 36)).foregroundStyle(.tertiary)
                Text("Select a snippet, or create one.\nType its trigger anywhere and DeskPulse replaces it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
