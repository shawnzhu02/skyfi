import Foundation

/// One radio transmission cut out of the tower feed: 16 kHz mono samples.
struct Transmission {
    let samples: [Float]
    let start: Date

    var duration: Double { Double(samples.count) / Squelch.sampleRate }
}

/// Splits the tower audio into transmissions by energy against an adaptive noise floor,
/// the way a radio's squelch opens and closes. Not thread-safe: use from one queue.
final class Squelch {
    enum Event {
        case opened
        case closed(Transmission?)
    }

    static let sampleRate = 16_000.0
    static let frame = 320                 // 20 ms
    static let openAboveFloor = 9.0        // dB
    static let closeAboveFloor = 5.0       // dB, lower than open: hysteresis
    static let framesToOpen = 5            // 100 ms
    static let framesToClose = 25          // 500 ms
    static let maxFrames = 750             // 15 s
    static let minFrames = 15              // 300 ms; shorter blips are clicks
    static let prerollFrames = 10          // 200 ms kept before the open
    static let lowestFloor = -70.0         // digital silence between transmissions

    private var pending: [Float] = []
    private(set) var floorDB: Double?
    private(set) var isOpen = false
    private var above = 0
    private var below = 0
    private var current: [Float] = []
    private var currentFrames = 0
    private var framesSinceOpen = 0
    private var preroll: [[Float]] = []
    private var openedAt = Date()

    func reset() {
        pending = []
        floorDB = nil
        isOpen = false
        above = 0
        below = 0
        current = []
        currentFrames = 0
        framesSinceOpen = 0
        preroll = []
    }

    static func level(_ frame: ArraySlice<Float>) -> Double {
        var sum: Float = 0
        for x in frame { sum += x * x }
        let rms = sqrt(sum / Float(max(frame.count, 1)))
        return 20 * log10(Double(rms) + 1e-9)
    }

    func process(_ samples: [Float], now: Date = Date()) -> [Event] {
        pending.append(contentsOf: samples)
        var events: [Event] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            let frame = pending[offset..<(offset + Self.frame)]
            offset += Self.frame
            if let event = step(frame, now: now) { events.append(event) }
        }
        pending.removeFirst(offset)
        return events
    }

    private func step(_ frame: ArraySlice<Float>, now: Date) -> Event? {
        let db = Self.level(frame)
        let floor = floorDB ?? max(db, Self.lowestFloor)

        if !isOpen {
            // Floor falls fast and rises slowly (about 0.5 dB a second).
            var next = db < floor ? 0.7 * floor + 0.3 * db : floor + 0.01
            next = max(next, Self.lowestFloor)
            floorDB = next
            preroll.append(Array(frame))
            if preroll.count > Self.prerollFrames + Self.framesToOpen { preroll.removeFirst() }
            above = db > next + Self.openAboveFloor ? above + 1 : 0
            if above >= Self.framesToOpen {
                isOpen = true
                below = 0
                current = preroll.flatMap { $0 }
                currentFrames = preroll.count
                framesSinceOpen = 0
                preroll = []
                openedAt = now
                return .opened
            }
            return nil
        }

        current.append(contentsOf: frame)
        currentFrames += 1
        framesSinceOpen += 1
        below = db < floor + Self.closeAboveFloor ? below + 1 : 0
        if below >= Self.framesToClose || currentFrames >= Self.maxFrames {
            isOpen = false
            above = 0
            // Frames that held signal: the ones that opened it plus the open ones before the quiet tail.
            let voiced = Self.framesToOpen + framesSinceOpen - below
            // Drop the trailing quiet frames.
            let keep = max(0, current.count - below * Self.frame + 4 * Self.frame)
            let samples = Array(current.prefix(keep))
            current = []
            currentFrames = 0
            below = 0
            return .closed(voiced >= Self.minFrames ? Transmission(samples: samples, start: openedAt) : nil)
        }
        return nil
    }
}

/// Mono downmix plus resampling to 16 kHz. A short box filter stands in for a
/// low-pass; radio audio has little energy above 4 kHz anyway.
struct Resampler {
    let inputRate: Double
    private var position = 0.0
    private var history: [Float] = []

    init(inputRate: Double) {
        self.inputRate = inputRate
    }

    mutating func process(_ input: [Float]) -> [Float] {
        guard inputRate > 0, !input.isEmpty else { return [] }
        if abs(inputRate - Squelch.sampleRate) < 1 { return input }
        let taps = max(1, Int((inputRate / Squelch.sampleRate).rounded(.down)))
        let window = history + input
        let lead = history.count
        var smoothed = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            let end = lead + i
            let start = max(0, end - taps + 1)
            var sum: Float = 0
            for j in start...end { sum += window[j] }
            smoothed[i] = sum / Float(end - start + 1)
        }
        history = Array(window.suffix(max(taps - 1, 0)))

        let step = inputRate / Squelch.sampleRate
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 1)
        while position < Double(input.count - 1) {
            let i = Int(position)
            let t = Float(position - Double(i))
            output.append(smoothed[i] * (1 - t) + smoothed[i + 1] * t)
            position += step
        }
        position -= Double(input.count)
        if position < 0 { position = 0 }
        return output
    }
}
