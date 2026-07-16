// StatusBar.swift - the menu bar presence: a clipboard icon whose popover
// shows the last few clips for one-click copying. Also hosts the app delegate
// that keeps DeskPulse alive in the menu bar when the window closes.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ note: Notification) {
        _ = ClipboardModel.shared   // start capturing right away
        _ = SnippetsModel.shared    // resume expansion if it was on

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard.fill",
            accessibilityDescription: "DeskPulse")
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                openMain: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openMain()
                }))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMain() }
        return true
    }

    func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows
        where window.canBecomeMain && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

/// The quick-access clip list under the menu bar icon.
struct PopoverView: View {
    var openMain: () -> Void
    @ObservedObject var model = ClipboardModel.shared
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DeskPulse")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.top, 10)

            if model.items.isEmpty {
                Text("Copy something and it shows up here.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 16)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(model.items.prefix(8))) { item in
                        clipRow(item)
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider().padding(.horizontal, 8)
            HStack {
                Button("Open DeskPulse", action: openMain)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .frame(width: 300)
    }

    private func clipRow(_ item: ClipItem) -> some View {
        Button {
            model.copy(item)
            copiedID = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if copiedID == item.id { copiedID = nil }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.kind == .image ? "photo"
                      : item.kind == .file ? "doc" : "text.alignleft")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(item.kind == .image ? "Image" : item.preview)
                    .font(.system(size: 11.5)).lineLimit(1)
                Spacer()
                if copiedID == item.id {
                    Text("copied").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                } else if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
