import Foundation

/// A plane that could be on the frequency right now.
struct Candidate: Equatable {
    let id: String
    let callsign: String?
    let registration: String?
    let type: String?
    let onGround: Bool
    let approaching: Bool
    let track: Double?
}

/// ICAO airline code -> spoken radio callsign ("DAL" -> "delta"), from OpenFlights.
enum Telephony {
    static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "telephony", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()
}

/// Finds which nearby plane a transmission is about. It matches the spoken forms of the
/// real candidates' callsigns rather than parsing any callsign out of the text, and it
/// answers "unknown" instead of guessing when two planes score close.
struct CallsignMatcher {
    enum Speaker: String {
        case controller
        case pilot
        case unknown
    }

    struct Match: Equatable {
        let candidateID: String
        let spoken: String
        let score: Double
        let speaker: Speaker
        /// The transcript tokens the callsign covers (for highlighting it in subtitles).
        var range: Range<Int>? = nil
    }

    struct Result: Equatable {
        let best: Match?
        let runnerUp: Match?
        /// Set only when the best match is good enough and clearly ahead.
        let accepted: Match?
    }

    /// How a callsign sounds: [name words] + number + [suffix letters as phonetic words].
    struct Form: Equatable {
        var names: [[String]]
        var nameRequired: Bool
        var number: String
        var suffix: [String]
        var isShort = false

        var spoken: String {
            ((names.first ?? []) + (number.isEmpty ? [] : [number]) + suffix).joined(separator: " ")
        }
    }

    static let acceptScore = 0.70
    static let margin = 0.08

    var telephony: [String: String] = Telephony.table

    // MARK: Spoken forms

    private static let makers: [(prefix: String, words: [[String]])] = [
        ("C1", [["cessna"], ["skyhawk"], ["skylane"]]), ("C2", [["cessna"], ["centurion"]]),
        ("C4", [["cessna"]]), ("C5", [["citation"]]), ("C6", [["citation"]]), ("C68", [["citation"]]),
        ("P28", [["piper"], ["cherokee"], ["archer"], ["warrior"]]), ("PA", [["piper"]]),
        ("SR2", [["cirrus"]]), ("BE", [["bonanza"], ["baron"], ["beech"], ["king", "air"]]),
        ("DA4", [["diamond"], ["diamond", "star"]]), ("DA2", [["diamond"]]), ("M20", [["mooney"]]),
        ("PC12", [["pilatus"]]), ("TBM", [["tbm"]]), ("GLF", [["gulfstream"]]), ("CL", [["challenger"]]),
        ("E55", [["phenom"]]), ("E50", [["phenom"]]),
    ]

    func forms(for c: Candidate) -> [Form] {
        var result: [Form] = []
        if let callsign = c.callsign?.uppercased(), let airline = airlineForm(callsign) {
            result.append(airline)
        }
        if let reg = (c.registration ?? c.callsign)?.uppercased().replacingOccurrences(of: "-", with: "") {
            result.append(contentsOf: registrationForms(reg, type: c.type))
        }
        return result
    }

    private func airlineForm(_ callsign: String) -> Form? {
        let chars = Array(callsign)
        guard chars.count >= 4, chars.prefix(3).allSatisfy(\.isLetter) else { return nil }
        let code = String(chars.prefix(3))
        guard let spoken = telephony[code] else { return nil }
        let rest = chars.dropFirst(3)
        let digits = String(rest.prefix { $0.isNumber })
        let letters = rest.drop { $0.isNumber }
        guard !digits.isEmpty, letters.allSatisfy(\.isLetter) else { return nil }
        let number = String(Int(digits) ?? 0)
        let suffix = letters.map { Phraseology.phonetic[Character($0.lowercased())] ?? String($0).lowercased() }
        return Form(names: [spoken.split(separator: " ").map(String.init)], nameRequired: true, number: number, suffix: suffix)
    }

    private func registrationForms(_ reg: String, type: String?) -> [Form] {
        let maker = Self.makers.first { type?.uppercased().hasPrefix($0.prefix) == true }?.words ?? []
        let chars = Array(reg)
        guard chars.count >= 3, chars.contains(where: \.isLetter) else { return [] }
        if chars[0] == "N", chars.count >= 2, chars[1].isNumber {
            // US: N + digits + up to two letters.
            let body = chars.dropFirst()
            let digits = String(body.prefix { $0.isNumber })
            let letters = body.drop { $0.isNumber }
            guard letters.allSatisfy(\.isLetter) else { return [] }
            let suffix = letters.map { Phraseology.phonetic[Character($0.lowercased())] ?? "" }
            var forms = [Form(names: [["november"]] + maker, nameRequired: false, number: digits, suffix: suffix)]
            // After first contact controllers shorten to the last three characters.
            let tail = Array(body.suffix(3))
            let tailDigits = String(tail.prefix { $0.isNumber })
            let tailLetters = tail.drop { $0.isNumber }
            if !tailDigits.isEmpty, !tailLetters.isEmpty, tailLetters.allSatisfy(\.isLetter), tail.count < body.count {
                forms.append(Form(names: maker, nameRequired: false, number: tailDigits,
                                  suffix: tailLetters.map { Phraseology.phonetic[Character($0.lowercased())] ?? "" },
                                  isShort: true))
            }
            return forms
        }
        // Elsewhere registrations are letters: C-GABC, G-EUPT. Spoken letter by letter.
        guard chars.allSatisfy(\.isLetter) else { return [] }
        let letters = chars.map { Phraseology.phonetic[Character($0.lowercased())] ?? "" }
        return [Form(names: maker, nameRequired: false, number: "", suffix: letters)]
    }

    // MARK: Matching

    func match(tokens: [String], candidates: [Candidate]) -> Result {
        let instruction = Phraseology.instruction(tokens)
        let runway = Phraseology.runway(tokens)
        var best: [Match] = []
        for candidate in candidates {
            var top: Match?
            for form in forms(for: candidate) {
                guard let placed = place(form: form, tokens: tokens) else { continue }
                let adjusted = placed.score + contextBonus(candidate, instruction: instruction, runway: runway)
                if adjusted > (top?.score ?? -1) {
                    top = Match(candidateID: candidate.id, spoken: form.spoken, score: min(adjusted, 1),
                                speaker: Self.speaker(tokens: tokens, range: placed.range), range: placed.range)
                }
            }
            if let top { best.append(top) }
        }
        best.sort { $0.score > $1.score }
        let first = best.first
        let second = best.dropFirst().first
        var accepted: Match?
        if let first, first.score >= Self.acceptScore, first.score - (second?.score ?? 0) >= Self.margin {
            accepted = first
        }
        return Result(best: first, runnerUp: second, accepted: accepted)
    }

    /// Best placement of a form in the transcript: score 0...1 and the token range it covers.
    func place(form: Form, tokens: [String]) -> (score: Double, range: Range<Int>)? {
        var best: (score: Double, range: Range<Int>)?
        func consider(_ value: Double, _ range: Range<Int>) {
            if value > (best?.score ?? 0) { best = (value, range) }
        }

        if form.number.isEmpty {
            // Letters-only registration: slide the letter sequence over the transcript.
            let n = form.suffix.count
            guard n > 0, tokens.count >= n else { return nil }
            for start in 0...(tokens.count - n) {
                let letters = zip(tokens[start..<(start + n)], form.suffix).map { Self.similarity($0, $1) }
                let letterScore = letters.reduce(0, +) / Double(n)
                guard letterScore >= 0.8 else { continue }
                let (nameScore, nameLength) = nameMatch(form, tokens: tokens, before: start)
                consider(0.8 * letterScore + 0.2 * nameScore, (start - nameLength)..<(start + n))
            }
            return best
        }

        for (i, token) in tokens.enumerated() where token.allSatisfy(\.isNumber) {
            let numberScore = Self.numberSimilarity(token, form.number)
            guard numberScore > 0 else { continue }
            let (nameScore, nameLength) = nameMatch(form, tokens: tokens, before: i)
            let suffixScore = suffixMatch(form, tokens: tokens, after: i)
            let range = (i - nameLength)..<(i + 1 + form.suffix.count)
            if form.nameRequired {
                // Airline: the name must be there; the number carries the most weight.
                guard nameScore >= 0.6 else { continue }
                consider(0.5 * numberScore + 0.35 * nameScore + 0.15 * suffixScore, range)
            } else if form.isShort {
                // Short GA form ("3 alpha bravo"): the letters must all be heard, the digit exactly.
                guard numberScore == 1, suffixScore >= 0.8 else { continue }
                consider(0.3 * numberScore + 0.5 * suffixScore + 0.2 * nameScore, range)
            } else {
                guard form.suffix.isEmpty || suffixScore >= 0.5 else { continue }
                consider(0.45 * numberScore + 0.35 * suffixScore + 0.2 * nameScore, range)
            }
        }
        return best
    }

    /// The best name option in the 1-3 tokens right before `index` (one filler token allowed in between).
    private func nameMatch(_ form: Form, tokens: [String], before index: Int) -> (Double, Int) {
        var best = (0.0, 0)
        for name in form.names where !name.isEmpty {
            let target = name.joined()
            for gap in 0...1 {
                for length in 1...3 {
                    let end = index - gap
                    let start = end - length
                    guard start >= 0 else { continue }
                    let heard = tokens[start..<end].joined()
                    let score = Self.similarity(heard, target) - (gap == 1 ? 0.1 : 0)
                    if score > best.0 { best = (score, length + gap) }
                }
            }
        }
        return best
    }

    private func suffixMatch(_ form: Form, tokens: [String], after index: Int) -> Double {
        guard !form.suffix.isEmpty else { return 1 }
        var total = 0.0
        for (k, letter) in form.suffix.enumerated() {
            let i = index + 1 + k
            guard i < tokens.count else { break }
            total += Self.similarity(tokens[i], letter)
        }
        return total / Double(form.suffix.count)
    }

    private func contextBonus(_ c: Candidate, instruction: Phraseology.Instruction, runway: String?) -> Double {
        var bonus = 0.0
        switch instruction {
        case .landing:
            if c.approaching { bonus += 0.06 }
            if c.onGround { bonus -= 0.1 }
        case .lineUp, .taxi, .holdShort:
            bonus += c.onGround ? 0.05 : -0.1
        case .takeoff:
            // The feed lags a few seconds, so the plane may already be rolling or airborne.
            if c.onGround { bonus += 0.03 }
        case .heading, .altitude:
            bonus += c.onGround ? -0.1 : 0.03
        case .frequencyChange, .traffic, .other:
            break
        }
        if let runway, let track = c.track, let number = Double(runway.prefix(2)),
           instruction == .landing || instruction == .takeoff || instruction == .lineUp {
            // Runway numbers are magnetic, tracks are true: allow 30°.
            if Geo.angleDifference(track, number * 10) < 30 { bonus += 0.04 }
        }
        return bonus
    }

    /// Callsign first: the controller is talking to the plane. Callsign last, or after
    /// the facility name ("Boston tower, Delta 234…"): the pilot is talking.
    static func speaker(tokens: [String], range: Range<Int>) -> Speaker {
        let facilities: Set<String> = ["tower", "ground", "approach", "departure", "center", "clearance", "delivery", "radio", "unicom"]
        let before = tokens[..<max(range.lowerBound, 0)]
        if before.contains(where: { facilities.contains($0) }) { return .pilot }
        if range.lowerBound <= 1 { return .controller }
        if range.upperBound >= tokens.count - 1 { return .pilot }
        return range.lowerBound <= 3 ? .controller : .unknown
    }

    // MARK: Similarity

    static func numberSimilarity(_ heard: String, _ expected: String) -> Double {
        if heard == expected { return 1 }
        let distance = levenshtein(Array(heard), Array(expected))
        guard distance == 1, expected.count >= 3 else { return 0 }
        return heard.count == expected.count ? 0.6 : 0.5
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return max(0, 1 - Double(levenshtein(Array(a), Array(b))) / Double(longest))
    }

    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Callsign hints for the speech model's prompt, like "Delta 234, JetBlue 697".
    func hint(for candidates: [Candidate], limit: Int = 40) -> String {
        candidates.prefix(limit).compactMap { c -> String? in
            guard let form = forms(for: c).first else { return nil }
            let name = (form.names.first ?? []).map { $0.capitalized }.joined(separator: " ")
            let suffix = form.suffix.map { $0.capitalized }.joined(separator: " ")
            return [name, form.number, suffix].filter { !$0.isEmpty }.joined(separator: " ")
        }
        .joined(separator: ", ")
    }
}
