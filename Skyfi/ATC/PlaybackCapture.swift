import AVFoundation
import CoreMedia
import os
import ReplayKit

/// Subtitles for LiveATC's page. iOS won't hand a web page's audio to the app, so Skyfi records
/// what it is playing with Apple's in-app recording (ReplayKit) and passes the sound, as 16 kHz
/// mono, to the speech model on the phone. Screen frames are dropped unread, nothing is saved,
/// and the stream itself is never touched. Only works while Skyfi is on screen.
final class PlaybackCapture: @unchecked Sendable {
    static let shared = PlaybackCapture()

    /// Called on ReplayKit's queue with new 16 kHz mono samples.
    var onAudio: (([Float]) -> Void)?

    /// Main thread only.
    private(set) var running = false

    private struct State {
        var resampler: Resampler?
        var rate = 0.0
        var buffers = 0
        var peak: Float = 0
        var lastReport = Date()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts recording Skyfi's own sound. iOS asks you first. `done` gets nil or why it failed,
    /// on the main thread.
    func start(done: @escaping (String?) -> Void) {
        guard !running else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            done("In-app recording isn't available right now (it's off during calls and screen mirroring).")
            return
        }
        running = true
        recorder.isMicrophoneEnabled = false
        state.withLock { $0 = State() }
        dlog("talk", "starting in-app recording for subtitles")
        recorder.startCapture(handler: Self.handler(for: self)) { error in
            DispatchQueue.main.async {
                if let error {
                    self.running = false
                    dlog("talk", "in-app recording didn't start: \(error.localizedDescription)")
                    done("Subtitles need iOS's OK to record Skyfi's sound. \(error.localizedDescription)")
                } else {
                    dlog("talk", "in-app recording on")
                    done(nil)
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        dlog("talk", "stopping in-app recording")
        RPScreenRecorder.shared().stopCapture { error in
            if let error { dlog("talk", "stopping in-app recording: \(error.localizedDescription)") }
        }
    }

    /// Built outside any actor: ReplayKit calls it on its own queue.
    private static func handler(for owner: PlaybackCapture) -> (CMSampleBuffer, RPSampleBufferType, Error?) -> Void {
        { [weak owner] buffer, type, error in
            guard let owner, error == nil, type == .audioApp else { return }
            owner.ingest(buffer)
        }
    }

    private func ingest(_ buffer: CMSampleBuffer) {
        guard let (samples, rate) = Self.monoSamples(buffer), rate > 0 else { return }
        let (out, report): ([Float], (Int, Float)?) = state.withLock { s in
            if s.resampler == nil || abs(s.rate - rate) > 1 {
                s.resampler = Resampler(inputRate: rate)
                s.rate = rate
            }
            s.buffers += 1
            for sample in samples { s.peak = max(s.peak, abs(sample)) }
            let out = s.resampler!.process(samples)
            var report: (Int, Float)?
            if Date().timeIntervalSince(s.lastReport) >= 10 {
                report = (s.buffers, s.peak)
                s.buffers = 0
                s.peak = 0
                s.lastReport = Date()
            }
            return (out, report)
        }
        // Peak 0 means the recording doesn't include LiveATC's sound: the debug log shows it.
        if let report { dlog("talk", String(format: "recording: %d sound buffers in 10 s, peak %.3f", report.0, report.1)) }
        if !out.isEmpty { onAudio?(out) }
    }

    /// One mono Float track from a ReplayKit sound buffer (16-bit or 32-bit float, either byte
    /// order, interleaved or not), plus its sample rate.
    static func monoSamples(_ buffer: CMSampleBuffer) -> ([Float], Double)? {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0 else { return nil }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return nil }

        let flags = basic.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let separate = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(basic.mBitsPerChannel)
        let channels = max(1, Int(basic.mChannelsPerFrame))
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return nil }
        let bytes = bits / 8
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let perBuffer = separate ? 1 : channels
        var mono = [Float](repeating: 0, count: frames)
        var used = 0
        for audio in buffers {
            guard let data = audio.mData else { continue }
            let available = Int(audio.mDataByteSize) / (bytes * perBuffer)
            let count = min(frames, available)
            for frame in 0..<count {
                for channel in 0..<perBuffer {
                    let offset = (frame * perBuffer + channel) * bytes
                    let value: Float
                    if isFloat {
                        var word = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                        if bigEndian { word = word.byteSwapped }
                        value = Float(bitPattern: word)
                    } else {
                        var word = data.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                        if bigEndian { word = word.byteSwapped }
                        value = Float(Int16(bitPattern: word)) / 32768
                    }
                    mono[frame] += value
                }
            }
            used += perBuffer
        }
        guard used > 0 else { return nil }
        let scale = 1 / Float(used)
        return (mono.map { $0 * scale }, basic.mSampleRate)
    }
}
