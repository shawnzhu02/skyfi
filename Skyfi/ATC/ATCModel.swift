import Foundation
import Observation
import WhisperKit

/// The on-device ATC speech model: Whisper medium.en fine-tuned on air traffic control
/// radio (jacktol/whisper-medium.en-fine-tuned-for-ATC, MIT), converted to Core ML for
/// WhisperKit by Arthur-Z-Dent/atcpal-whisperkit (MIT). About 15% word error rate on the
/// ATCO2 test recordings vs roughly 50%+ for generic speech recognizers.
/// Downloaded once (1.5 GB, pinned to one revision) into Application Support.
@Observable
@MainActor
final class ATCModel {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
        case unsupported
    }

    static let repo = "Arthur-Z-Dent/atcpal-whisperkit"
    static let revision = "d91954d7bc282504b02cebcbd93a99ea192b9457"
    static let variant = "medium.en-atc"
    static let files: [(path: String, size: Int64)] = [
        ("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243),
        ("AudioEncoder.mlmodelc/coremldata.bin", 408),
        ("AudioEncoder.mlmodelc/metadata.json", 1921),
        ("AudioEncoder.mlmodelc/model.mil", 5_904_331),
        ("AudioEncoder.mlmodelc/weights/weight.bin", 614_460_544),
        ("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243),
        ("MelSpectrogram.mlmodelc/coremldata.bin", 389),
        ("MelSpectrogram.mlmodelc/metadata.json", 1947),
        ("MelSpectrogram.mlmodelc/model.mil", 10_133),
        ("MelSpectrogram.mlmodelc/weights/weight.bin", 354_080),
        ("TextDecoder.mlmodelc/analytics/coremldata.bin", 243),
        ("TextDecoder.mlmodelc/coremldata.bin", 698),
        ("TextDecoder.mlmodelc/metadata.json", 4869),
        ("TextDecoder.mlmodelc/model.mil", 726_980),
        ("TextDecoder.mlmodelc/weights/weight.bin", 913_426_224),
        ("config.json", 1297),
        ("generation_config.json", 1065),
        ("tokenizer.json", 2_405_679),
        ("tokenizer_config.json", 805),
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    /// Medium needs room: phones with less than 6 GB of memory get killed loading it.
    static var deviceSupported: Bool { ProcessInfo.processInfo.physicalMemory >= 5_500_000_000 }

    private(set) var state: State = .notDownloaded
    @ObservationIgnored private let engine = WhisperEngine()
    @ObservationIgnored private var job: Task<Void, Never>?

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ATCModel/\(revision.prefix(8))/\(variant)", isDirectory: true)
    }

    init() {
        if !Self.deviceSupported {
            state = .unsupported
        } else if Self.isDownloaded {
            state = .preparing
        }
    }

    static var isDownloaded: Bool {
        files.allSatisfy { file in
            let url = folder.appendingPathComponent(file.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
            return size == file.size
        }
    }

    var isReady: Bool { state == .ready }

    /// Downloads what's missing, then loads the model. Safe to call again after a failure.
    func start() {
        guard Self.deviceSupported, job == nil, state != .ready else { return }
        job = Task {
            defer { job = nil }
            do {
                if !Self.isDownloaded { try await download() }
                state = .preparing
                try await engine.load(folder: Self.folder)
                state = .ready
            } catch is CancellationError {
                state = Self.isDownloaded ? .preparing : .notDownloaded
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        job?.cancel()
    }

    func delete() {
        job?.cancel()
        Task {
            await engine.unload()
            try? FileManager.default.removeItem(at: Self.folder.deletingLastPathComponent())
            state = Self.deviceSupported ? .notDownloaded : .unsupported
        }
    }

    private func download() async throws {
        var done: Int64 = 0
        let total = Self.totalBytes
        state = .downloading(0)
        for file in Self.files {
            try Task.checkCancellation()
            let target = Self.folder.appendingPathComponent(file.path)
            let existing = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1
            if existing == file.size {
                done += file.size
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(Self.variant)/\(file.path)")!
            let base = done
            let temp = try await FileDownload.fetch(url) { [weak self] written in
                Task { @MainActor in
                    self?.state = .downloading(Double(base + written) / Double(total))
                }
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dir = Self.folder.deletingLastPathComponent()
            try? dir.setResourceValues(values)
            done += file.size
            state = .downloading(Double(done) / Double(total))
        }
    }

    /// Text for one transmission, or nil when the model hears no speech.
    func transcribe(_ samples: [Float], prompt: String?) async -> WhisperEngine.Heard? {
        guard state == .ready else { return nil }
        return await engine.transcribe(samples, prompt: prompt)
    }
}

/// Owns the WhisperKit pipeline off the main actor.
actor WhisperEngine {
    struct Heard: Equatable {
        let text: String
        let avgLogProb: Float
        let noSpeechProb: Float
    }

    private var pipe: WhisperKit?

    func load(folder: URL) async throws {
        if pipe != nil { return }
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        pipe = try await WhisperKit(config)
    }

    func unload() {
        pipe = nil
    }

    func transcribe(_ samples: [Float], prompt: String?) async -> Heard? {
        guard let pipe else { return nil }
        var promptTokens: [Int]?
        if let prompt, !prompt.isEmpty, let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = Array(tokens.suffix(120))
        }
        let options = DecodingOptions(
            task: .transcribe, language: "en", temperature: 0, temperatureFallbackCount: 2,
            usePrefillPrompt: true, skipSpecialTokens: true, withoutTimestamps: true,
            promptTokens: promptTokens, suppressBlank: true, noSpeechThreshold: 0.6)
        guard let results = try? await pipe.transcribe(audioArray: samples, decodeOptions: options),
              let result = results.first else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = result.segments
        let noSpeech = segments.map(\.noSpeechProb).max() ?? 0
        let logProb = segments.isEmpty ? 0 : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
        guard !text.isEmpty, noSpeech < 0.6 else { return nil }
        return Heard(text: text, avgLogProb: logProb, noSpeechProb: noSpeech)
    }
}

/// One file download with byte progress. Returns a temp file URL that the caller moves.
enum FileDownload {
    static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.downloadTask(with: url)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.task?.cancel()
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        var task: URLSessionDownloadTask?
        private var lastReport = Date.distantPast

        init(progress: @escaping @Sendable (Int64) -> Void) {
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.25 {
                lastReport = now
                progress(totalBytesWritten)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file at `location` is deleted when this returns, so move it first.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                continuation?.resume(throwing: URLError(.badServerResponse))
            } else if (try? FileManager.default.moveItem(at: location, to: keep)) != nil {
                continuation?.resume(returning: keep)
            } else {
                continuation?.resume(throwing: URLError(.cannotMoveFile))
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }
}
