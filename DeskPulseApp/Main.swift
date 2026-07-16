// Main.swift - DeskPulse: clipboard history, text snippets, and a file
// converter in one small native app. Sidebar navigation; models are singletons
// so capture and conversion survive switching panes. The menu bar item lives
// in AppDelegate (StatusBar.swift) and keeps running when the window closes.

import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case clipboard, snippets, convert, pdfTools, imageTools, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: return "Clipboard History"
        case .snippets: return "Text Snippets"
        case .convert: return "File Converter"
        case .pdfTools: return "PDF Tools"
        case .imageTools: return "Image Tools"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "keyboard"
        case .convert: return "arrow.triangle.2.circlepath"
        case .pdfTools: return "doc.badge.gearshape"
        case .imageTools: return "photo.on.rectangle.angled"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @State private var pane: Pane? = .clipboard

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch pane ?? .clipboard {
            case .clipboard: ClipboardView()
            case .snippets: SnippetsView()
            case .convert: ConvertView()
            case .pdfTools: PDFToolsView()
            case .imageTools: ImageToolsView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle("DeskPulse")
    }
}

@main
struct DeskPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("DeskPulse") {
            MainView()
        }
    }
}
