import Foundation
import Observation
import os
import UIKit

/// Logs one line to the in-app debug log (Mixer sheet > Debug log) and to the system log.
/// Safe from any thread.
func dlog(_ area: String, _ text: String) {
    let time = Date()
    DebugLog.system.notice("[\(area, privacy: .public)] \(text, privacy: .public)")
    Task { @MainActor in DebugLog.shared.add(area: area, text: text, time: time) }
}

/// What the app tried and what failed, kept on the phone so a bug report shows the cause.
/// The last session's log survives a relaunch (a crash or a kill), shown under "Previous launch".
@Observable
@MainActor
final class DebugLog {
    static let shared = DebugLog()
    nonisolated static let system = Logger(subsystem: "com.shawnzhu.skyfi", category: "debug")

    struct Entry: Identifiable {
        let id: Int
        let time: Date
        let area: String
        let text: String
    }

    private(set) var entries: [Entry] = []
    /// The log file from the launch before this one.
    private(set) var previous: String = ""

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private let maxEntries = 2000
    /// File writes happen off the main thread, in order.
    @ObservationIgnored private let writer = DispatchQueue(label: "com.shawnzhu.skyfi.log", qos: .utility)

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("skyfi-log.txt")
        let previousURL = dir.appendingPathComponent("skyfi-log-previous.txt")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousURL)
        previous = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    func add(area: String, text: String, time: Date = Date()) {
        nextID += 1
        let entry = Entry(id: nextID, time: time, area: area, text: text)
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        if let data = (Self.format(entry) + "\n").data(using: .utf8), let handle {
            writer.async { try? handle.write(contentsOf: data) }
        }
    }

    func clear() {
        entries.removeAll()
        previous = ""
        if let handle { writer.async { try? handle.truncate(atOffset: 0) } }
    }

    /// The whole report: device and app details, this launch, then the previous launch.
    var report: String {
        let browser = LiveATCBrowser.shared
        let mixer = Mixer.shared
        let state = "Now: airport \(mixer.airport ?? "none") · feed \(mixer.feed?.mount ?? "none") · tower in LiveATC player \(mixer.towerInBrowser) · page \(browser.isOpen ? "open" : "closed") \(browser.media) \(browser.suspended ? "suspended" : "")"
        var lines = [Self.header(), state, "", "== This launch"]
        lines += entries.map(Self.format)
        if !previous.isEmpty {
            lines += ["", "== Previous launch", previous]
        }
        return lines.joined(separator: "\n")
    }

    static func format(_ entry: Entry) -> String {
        "\(timeFormatter.string(from: entry.time)) [\(entry.area)] \(entry.text)"
    }

    static func header() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return """
        Skyfi \(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · \(model) · \(String(format: "%.1f", memoryGB)) GB RAM
        Report made \(ISO8601DateFormatter().string(from: Date()))
        """
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
