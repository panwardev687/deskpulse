// SnippetsModel.swift - the text expansion engine. A listen-only CGEventTap
// watches keystrokes and keeps a small rolling buffer of what was typed. When
// the buffer ends with a snippet trigger (";addr"), it posts backspaces to
// erase the trigger and types the expansion with synthetic key events.
// Requires the Accessibility permission; nothing runs until it is granted
// and the user turns expansion on.

import AppKit
import Combine

/// Synthetic events we post carry this tag so the tap ignores them.
let expanderEventTag: Int64 = 0xDE5C

struct Snippet: Identifiable, Codable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
    var enabled = true
}

final class SnippetsModel: ObservableObject {
    static let shared = SnippetsModel()

    @Published var snippets: [Snippet] = [] { didSet { save() } }
    @Published var axGranted = AXIsProcessTrusted()
    @Published var expansionOn: Bool {
        didSet {
            UserDefaults.standard.set(expansionOn, forKey: "snippets.on")
            expansionOn ? start() : stop()
        }
    }
    @Published var expandedCount = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private let typeQueue = DispatchQueue(label: "deskpulse.expander")
    private let snippetsFile = supportDir().appendingPathComponent("snippets.json")
    private var axTimer: Timer?

    private init() {
        expansionOn = UserDefaults.standard.bool(forKey: "snippets.on")
        load()
        if snippets.isEmpty {
            snippets = [
                Snippet(trigger: ";date", expansion: "{date}"),
                Snippet(trigger: ";shrug", expansion: #"¯\_(ツ)_/¯"#),
            ]
        }
        if expansionOn { start() }
    }

    /// Ask macOS for Accessibility, showing the system prompt if not yet granted.
    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        axGranted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !axGranted { watchForGrant() }
    }

    /// Poll until the permission shows up, then start the tap if expansion is on.
    private func watchForGrant() {
        axTimer?.invalidate()
        axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if AXIsProcessTrusted() {
                t.invalidate()
                self.axGranted = true
                if self.expansionOn { self.start() }
            }
        }
    }

    // MARK: - Event tap

    private func start() {
        axGranted = AXIsProcessTrusted()
        guard axGranted else { return watchForGrant() }
        guard tap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let model = Unmanaged<SnippetsModel>.fromOpaque(info).takeUnretainedValue()
                model.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: info)

        guard let tap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        buffer = ""
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall; just switch ours back on
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        if event.getIntegerValueField(.eventSourceUserData) == expanderEventTag { return }

        // shortcuts and caret moves invalidate whatever was being typed
        if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) {
            buffer = ""
            return
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        switch key {
        case 51:                                   // delete
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case 36, 76, 48, 53, 123, 124, 125, 126,   // return, enter, tab, esc, arrows
             115, 116, 119, 121:                   // home, page up, end, page down
            buffer = ""
            return
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length,
                                       unicodeString: &chars)
        guard length > 0 else { return }
        buffer += String(utf16CodeUnits: chars, count: length)
        if buffer.count > 64 { buffer.removeFirst(buffer.count - 64) }

        for s in snippets where s.enabled && !s.trigger.isEmpty {
            if buffer.hasSuffix(s.trigger) {
                buffer = ""
                let text = Self.resolve(s.expansion)
                let erase = s.trigger.count
                typeQueue.async { [weak self] in
                    self?.erase(erase)
                    self?.type(text)
                    DispatchQueue.main.async { self?.expandedCount += 1 }
                }
                break
            }
        }
    }

    /// Fill {date}, {time}, {clipboard} at expansion time.
    static func resolve(_ expansion: String) -> String {
        var out = expansion
        if out.contains("{date}") {
            let f = DateFormatter()
            f.dateStyle = .medium
            out = out.replacingOccurrences(of: "{date}", with: f.string(from: Date()))
        }
        if out.contains("{time}") {
            let f = DateFormatter()
            f.timeStyle = .short
            out = out.replacingOccurrences(of: "{time}", with: f.string(from: Date()))
        }
        if out.contains("{clipboard}") {
            let clip = NSPasteboard.general.string(forType: .string) ?? ""
            out = out.replacingOccurrences(of: "{clipboard}", with: clip)
        }
        return out
    }

    // MARK: - Synthetic typing

    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: expanderEventTag)
        event?.post(tap: .cghidEventTap)
        usleep(4000)
    }

    private func erase(_ count: Int) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            post(CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true))
            post(CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false))
        }
    }

    private func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(down)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(up)
            i += 20
        }
    }

    // MARK: - CRUD + persistence

    func addSnippet() -> Snippet {
        let s = Snippet(trigger: "", expansion: "")
        snippets.append(s)
        return s
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: snippetsFile)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: snippetsFile),
              let saved = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return }
        snippets = saved
    }
}
