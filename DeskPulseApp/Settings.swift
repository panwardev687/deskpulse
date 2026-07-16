// Settings.swift - user preferences: history size, what gets captured,
// launch at login. Persisted in UserDefaults.

import SwiftUI
import ServiceManagement

final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    private let d = UserDefaults.standard

    @Published var historyLimit: Int {
        didSet { d.set(historyLimit, forKey: "clip.limit") }
    }
    @Published var captureImages: Bool {
        didSet { d.set(captureImages, forKey: "clip.images") }
    }
    @Published var launchError: String? = nil

    private init() {
        let limit = d.integer(forKey: "clip.limit")
        historyLimit = limit > 0 ? limit : 200
        captureImages = d.object(forKey: "clip.images") as? Bool ?? true
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        launchError = nil
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchError = error.localizedDescription
        }
        objectWillChange.send()
    }
}

struct SettingsView: View {
    @ObservedObject var settings = SettingsModel.shared
    @State private var launchOn = SettingsModel.shared.launchAtLogin

    var body: some View {
        Form {
            Section("Clipboard History") {
                Picker("Keep", selection: $settings.historyLimit) {
                    Text("50 items").tag(50)
                    Text("200 items").tag(200)
                    Text("500 items").tag(500)
                    Text("1000 items").tag(1000)
                }
                Toggle("Capture copied images", isOn: $settings.captureImages)
                Text("Pinned items never expire. Anything a password manager marks confidential is never recorded.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch DeskPulse at login", isOn: Binding(
                    get: { launchOn },
                    set: { on in
                        settings.setLaunchAtLogin(on)
                        launchOn = settings.launchAtLogin
                    }))
                if let err = settings.launchError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("DeskPulse stays in the menu bar when the window is closed. Quit it from the menu bar popover.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("DeskPulse makes zero network connections. Clipboard history and snippets are stored locally in ~/Library/Application Support/DeskPulse and never leave this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.pink)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Support the Developer")
                            .font(.system(size: 13, weight: .semibold))
                        Text("DeskPulse is built by an independent developer. If it replaced a paid app for you, consider sponsoring - it directly funds new features.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button {
                                NSWorkspace.shared.open(sponsorURL)
                            } label: {
                                Label("Sponsor on GitHub", systemImage: "heart")
                            }
                            Button {
                                NSWorkspace.shared.open(issuesURL)
                            } label: {
                                Label("Report an Issue", systemImage: "ladybug")
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("About") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("More free Mac tools") {
                    Button("MacPulse: system monitor and cleaner") {
                        NSWorkspace.shared.open(
                            URL(string: "https://github.com/panwardev687/macpulse")!)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}
