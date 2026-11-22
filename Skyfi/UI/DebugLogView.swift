import SwiftUI

/// Mixer sheet > Debug log: every stream attempt, HTTP status, player error and model step.
/// Copy or Share sends the whole report (with the previous launch) for bug fixing.
struct DebugLogView: View {
    @State private var log = DebugLog.shared
    @State private var copied = false

    var body: some View {
        List {
            Section {
                HStack {
                    Button(copied ? "Copied" : "Copy report") {
                        UIPasteboard.general.string = log.report
                        copied = true
                    }
                    Spacer()
                    ShareLink(item: log.report, subject: Text("Skyfi debug log"),
                              preview: SharePreview("Skyfi debug log")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Copy or share this after something goes wrong, then send it to Claude. It has no account details, only what the app tried and what failed.")
                    .font(.system(size: 12))
            }

            Section("This launch") {
                if log.entries.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(DebugLog.format(entry).prefix(12)) · \(entry.area)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(entry.text.localizedCaseInsensitiveContains("fail")
                                             || entry.text.contains("error") || entry.text.contains("HTTP 4")
                                             || entry.text.contains("HTTP 5") ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                }
            }

            if !log.previous.isEmpty {
                Section("Previous launch") {
                    Text(log.previous.suffix(20_000))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Debug log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Clear", role: .destructive) { log.clear() }
        }
    }
}
