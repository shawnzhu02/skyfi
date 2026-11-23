import Foundation
import Observation
import UIKit
import WhisperKit

/// The on-device ATC speech model: Whisper small.en fine-tuned on air traffic control radio
/// (jlvdoorn/WhisperATC, TU Delft), converted to Core ML for WhisperKit by
/// stebox/whisperkit-atc-coreml (MIT). About 13.5% word error rate on the ATCO2 recordings vs
/// roughly 50% for generic Whisper. Downloaded once (488 MB, pinned) into Application Support.
@Observable
@MainActor
final class ATCModel {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        /// On disk, not in memory. Loads when a tower is tuned.
        case downloaded
        case preparing
        case ready
        case failed(String)
        case unsupported
    }

    static let repo = "stebox/whisperkit-atc-coreml"
    static let revision = "7cd30d79f2a2acbe662b78e91de4dd99e573a4c1"
    static let variant = "small.en-atco2-asr"
    /// The converted repo has no tokenizer; small.en uses the same one as OpenAI's original.
    static let tokenizerRepo = "openai/whisper-small.en"
    static let tokenizerRevision = "e8727524f962ee844a7319d92be39ac1bd25655a"
    static let files: [(path: String, size: Int64)] = [
        ("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243),
        ("AudioEncoder.mlmodelc/coremldata.bin", 408),
        ("AudioEncoder.mlmodelc/metadata.json", 1_916),
        ("AudioEncoder.mlmodelc/model.mil", 2_236_846),
        ("AudioEncoder.mlmodelc/weights/weight.bin", 176_323_456),
        ("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243),
        ("MelSpectrogram.mlmodelc/coremldata.bin", 389),
        ("MelSpectrogram.mlmodelc/metadata.json", 1_947),
        ("MelSpectrogram.mlmodelc/model.mil", 10_133),
        ("MelSpectrogram.mlmodelc/weights/weight.bin", 354_080),
        ("TextDecoder.mlmodelc/analytics/coremldata.bin", 243),
        ("TextDecoder.mlmodelc/coremldata.bin", 694),
        ("TextDecoder.mlmodelc/metadata.json", 4_856),
        ("TextDecoder.mlmodelc/model.mil", 381_628),
        ("TextDecoder.mlmodelc/weights/weight.bin", 307_285_808),
        ("config.json", 1_332),
        ("generation_config.json", 1_183),
        ("tokenizer.json", 2_405_679),
        ("tokenizer_config.json", 805),
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    /// Small loads in well under 1 GB of memory; any phone with 4 GB or more is fine.
    static var deviceSupported: Bool { ProcessInfo.processInfo.physicalMemory >= 3_500_000_000 }

    static func remoteURL(for path: String) -> URL {
        if path.hasPrefix("tokenizer") {
            return URL(string: "https://huggingface.co/\(tokenizerRepo)/resolve/\(tokenizerRevision)/\(path)")!
        }
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(variant)/\(path)")!
    }

    /// Model folders from older builds (the 1.5 GB medium model) take space for nothing.
    private static func removeOldModels() {
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        let keep = folder.deletingLastPathComponent().lastPathComponent
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in items where name != keep {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            dlog("model", "removed old model folder \(name)")
        }
    }

    private(set) var state: State = .notDownloaded
    @ObservationIgnored private let engine = WhisperEngine()
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var pendingUnload: Task<Void, Never>?
    /// Whether the model should end up in memory (a tower is tuned). Can change mid-download.
    @ObservationIgnored private var wantLoad = false
    /// Bumped whenever a job is replaced, so a stale job can't overwrite the state.
    @ObservationIgnored private var generation = 0

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ATCModel/\(revision.prefix(8))/\(variant)", isDirectory: true)
    }

    init() {
        Self.removeOldModels()
        if !Self.deviceSupported {
            state = .unsupported
        } else if Self.isDownloaded {
            state = .downloaded
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

    /// Downloads what's missing; with `load`, also loads the model into memory.
    /// Safe to call again after a failure or a pause: finished files are kept and a
    /// half-done file resumes where it stopped.
    func start(load: Bool = true) {
        if load { wantLoad = true }
        guard Self.deviceSupported, job == nil, state != .ready else { return }
        generation += 1
        let gen = generation
        // Runs after any unload or older job has fully finished, so the engine never
        // unloads a model this job just loaded.
        let before = pendingUnload
        job = Task {
            defer { if generation == gen { job = nil } }
            await before?.value
            do {
                if !Self.isDownloaded {
                    dlog("model", "download start (\(Self.totalBytes / 1_000_000) MB)")
                    UIApplication.shared.isIdleTimerDisabled = true
                    defer { UIApplication.shared.isIdleTimerDisabled = false }
                    try await download()
                }
                guard wantLoad else {
                    if generation == gen { state = .downloaded }
                    return
                }
                if generation == gen { state = .preparing }
                dlog("model", "loading into memory")
                let loadStart = Date()
                try await engine.load(folder: Self.folder)
                // The load itself can't be interrupted: check whether we were asked to stop meanwhile.
                try Task.checkCancellation()
                dlog("model", String(format: "ready in %.1f s", Date().timeIntervalSince(loadStart)))
                if generation == gen { state = .ready }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    await engine.unload()
                    if generation == gen { state = Self.isDownloaded ? .downloaded : .notDownloaded }
                } else {
                    dlog("model", "failed: \(String(describing: error))")
                    if generation == gen { state = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// Pauses a download (progress is kept) or stops a load.
    func cancel() {
        job?.cancel()
    }

    /// Frees the memory when no tower is tuned; the files stay.
    func unload() {
        wantLoad = false
        // A download keeps going (it ends as .downloaded); only a load or a loaded model stops.
        if case .downloading = state { return }
        guard job != nil || state == .ready else { return }
        stopJob { [engine] in
            await engine.unload()
        }
        if Self.isDownloaded { state = .downloaded }
    }

    func delete() {
        wantLoad = false
        let folder = Self.folder.deletingLastPathComponent()
        stopJob { [engine] in
            await engine.unload()
            try? FileManager.default.removeItem(at: folder)
        }
        state = Self.deviceSupported ? .notDownloaded : .unsupported
    }

    /// Cancels the running job and queues `work` after it (and after any earlier unload).
    private func stopJob(then work: @escaping @Sendable () async -> Void) {
        let old = job
        let before = pendingUnload
        old?.cancel()
        job = nil
        generation += 1
        pendingUnload = Task {
            await before?.value
            await old?.value
            await work()
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
            let url = Self.remoteURL(for: file.path)
            let base = done
            // A paused or dropped download leaves resume data next to the file.
            let resumeFile = target.appendingPathExtension("resume")
            let resumeData = try? Data(contentsOf: resumeFile)
            try? FileManager.default.removeItem(at: resumeFile)
            let temp: URL
            do {
                temp = try await FileDownload.fetch(url, resumeData: resumeData) { [weak self] written in
                    Task { @MainActor in
                        self?.state = .downloading(Double(base + written) / Double(total))
                    }
                }
            } catch {
                if let data = (error as? URLError)?.downloadTaskResumeData {
                    try? data.write(to: resumeFile)
                }
                throw error
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            // An error page saved as the file would fail later as a corrupt model; catch it here.
            let got = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1
            guard got == file.size else {
                try? FileManager.default.removeItem(at: target)
                dlog("model", "\(file.path): got \(got) bytes, expected \(file.size)")
                throw ModelError.badFile(file.path)
            }
            dlog("model", "downloaded \(file.path)")
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

enum ModelError: LocalizedError {
    case badFile(String)

    var errorDescription: String? {
        switch self {
        case .badFile(let path): return "Download of \(path) came back wrong. Tap to try again."
        }
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
            task: .transcribe, language: "en", temperature: 0, temperatureFallbackCount: 0,
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
    static func fetch(_ url: URL, resumeData: Data? = nil, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
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
