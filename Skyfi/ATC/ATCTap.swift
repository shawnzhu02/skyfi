import AVFoundation
import MediaToolbox
import os

/// Copies the tower feed's audio out of the AVPlayer while it plays, as 16 kHz mono.
/// Uses an MTAudioProcessingTap on the player item, which works for progressive
/// streams like LiveATC's Icecast MP3 (not for HLS).
final class ATCTap {
    /// Called on the tap's queue about every 100 ms with new 16 kHz mono samples.
    var onAudio: (([Float]) -> Void)?

    let queue = DispatchQueue(label: "skyfi.atc.tap")
    private let captured = OSAllocatedUnfairLock(initialState: [Float]())
    private let format = OSAllocatedUnfairLock(initialState: (rate: 44_100.0, channels: 1, interleaved: true, float: true))
    private var resampler = Resampler(inputRate: 44_100)
    private var resamplerRate = 44_100.0
    private var timer: DispatchSourceTimer?
    private weak var item: AVPlayerItem?
    private var attachTask: Task<Void, Never>?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }

    /// Attaches to a new tower item (or detaches with nil). Waits for the item's audio track.
    @MainActor
    func attach(to item: AVPlayerItem?) {
        attachTask?.cancel()
        self.item = item
        captured.withLock { $0.removeAll() }
        guard let item else { return }
        attachTask = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if let track = item.tracks.compactMap(\.assetTrack).first(where: { $0.mediaType == .audio }) {
                    self?.install(on: item, track: track)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    @MainActor
    private func install(on item: AVPlayerItem, track: AVAssetTrack) {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(self).release()
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    // Called from the tap callbacks (audio threads).

    fileprivate func prepare(_ description: AudioStreamBasicDescription) {
        let interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        format.withLock {
            $0 = (rate: description.mSampleRate, channels: Int(description.mChannelsPerFrame),
                  interleaved: interleaved, float: isFloat)
        }
    }

    fileprivate func capture(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let info = format.withLock { $0 }
        guard info.float, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let data = first.mData else { return }
        var mono = [Float](repeating: 0, count: frames)
        let samples = data.assumingMemoryBound(to: Float.self)
        if info.interleaved {
            let channels = max(info.channels, 1)
            for i in 0..<frames { mono[i] = samples[i * channels] }
        } else if buffers.count > 1, let secondData = buffers[1].mData {
            let second = secondData.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { mono[i] = 0.5 * (samples[i] + second[i]) }
        } else {
            for i in 0..<frames { mono[i] = samples[i] }
        }
        captured.withLock { buffer in
            buffer.append(contentsOf: mono)
            // Never hold more than ~10 s if nobody drains.
            if buffer.count > 480_000 { buffer.removeFirst(buffer.count - 480_000) }
        }
    }

    private func drain() {
        let chunk = captured.withLock { buffer -> [Float] in
            let out = buffer
            buffer.removeAll(keepingCapacity: true)
            return out
        }
        guard !chunk.isEmpty else { return }
        let rate = format.withLock { $0.rate }
        if rate != resamplerRate {
            resampler = Resampler(inputRate: rate)
            resamplerRate = rate
        }
        let samples = resampler.process(chunk)
        if !samples.isEmpty { onAudio?(samples) }
    }
}

private func tapOwner(_ tap: MTAudioProcessingTap) -> ATCTap {
    Unmanaged<ATCTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<ATCTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, description in
    tapOwner(tap).prepare(description.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    tapOwner(tap).capture(bufferList, frames: Int(framesOut.pointee))
}
