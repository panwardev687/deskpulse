// Shared.swift - helpers used across every DeskPulse pane.

import AppKit

let sponsorURL = URL(string: "https://github.com/sponsors/panwardev687")!
let issuesURL = URL(string: "https://github.com/panwardev687/deskpulse/issues")!

/// ~/Library/Application Support/DeskPulse, created on first use.
func supportDir() -> URL {
    let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DeskPulse")
    try? FileManager.default.createDirectory(
        at: base, withIntermediateDirectories: true)
    return base
}

func fmtBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: n)
}

func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
}

func runCommand(_ path: String, _ args: [String]) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    guard (try? p.run()) != nil else { return ("", false) }
    p.waitUntilExit()
    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (o + e, p.terminationStatus == 0)
}

/// "base.ext" in the same folder, appending " 2", " 3"... so nothing is ever overwritten.
func freeOutputURL(dir: URL, base: String, ext: String) -> URL {
    let fm = FileManager.default
    var candidate = dir.appendingPathComponent("\(base).\(ext)")
    var n = 2
    while fm.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
        n += 1
    }
    return candidate
}

func relativeTime(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}
