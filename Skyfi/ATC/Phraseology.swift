import Foundation

/// Turns a raw ATC transcript into tokens the callsign matcher can use:
/// lowercase words, with spoken numbers collapsed into digit strings.
enum Phraseology {
    enum Instruction: String {
        case landing, takeoff, lineUp, holdShort, taxi, heading, altitude, frequencyChange, traffic, other
    }

    static let phonetic: [Character: String] = [
        "a": "alpha", "b": "bravo", "c": "charlie", "d": "delta", "e": "echo", "f": "foxtrot", "g": "golf",
        "h": "hotel", "i": "india", "j": "juliet", "k": "kilo", "l": "lima", "m": "mike", "n": "november",
        "o": "oscar", "p": "papa", "q": "quebec", "r": "romeo", "s": "sierra", "t": "tango", "u": "uniform",
        "v": "victor", "w": "whiskey", "x": "xray", "y": "yankee", "z": "zulu",
    ]

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "tree": 3, "four": 4, "fower": 4, "five": 5, "fife": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "niner": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let dropped: Set<String> = ["uh", "um", "er", "ah", "erm", "heavy", "super"]

    /// Normalized tokens. Numbers become digit strings: "two thirty four" -> "234".
    static func tokens(_ text: String) -> [String] {
        var raw: [String] = []
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "x-ray", with: "xray")
            .replacingOccurrences(of: "take-off", with: "takeoff")
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        for word in String(cleaned).split(separator: " ") {
            raw.append(contentsOf: splitAlphanumeric(String(word)))
        }
        raw = raw.filter { !dropped.contains($0) }
        return collapseNumbers(raw)
    }

    /// "22l" -> ["22", "lima"], "n123ab" -> ["november", "123", "alpha", "bravo"]; plain words stay.
    private static func splitAlphanumeric(_ word: String) -> [String] {
        let hasDigit = word.contains { $0.isNumber }
        let hasLetter = word.contains { $0.isLetter }
        guard hasDigit && hasLetter else { return [word] }
        var parts: [String] = []
        var run = ""
        var runIsDigit = false
        for ch in word {
            let isDigit = ch.isNumber
            if !run.isEmpty && isDigit != runIsDigit {
                parts.append(contentsOf: runIsDigit ? [run] : run.map { phonetic[$0] ?? String($0) })
                run = ""
            }
            run.append(ch)
            runIsDigit = isDigit
        }
        if !run.isEmpty { parts.append(contentsOf: runIsDigit ? [run] : run.map { phonetic[$0] ?? String($0) }) }
        return parts
    }

    private static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }

    private static func isNumberWord(_ s: String) -> Bool {
        units[s] != nil || teens[s] != nil || tens[s] != nil || s == "hundred" || s == "thousand"
    }

    private static func collapseNumbers(_ words: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            if !run.isEmpty { out.append(value(of: run)) }
            run = []
        }
        for word in words {
            if isNumberWord(word) || (isDigits(word) && word.count == 1) {
                run.append(word)
            } else if isDigits(word) {
                flush()
                out.append(word)
            } else {
                flush()
                out.append(word)
            }
        }
        flush()
        return out
    }

    /// Value of a run of number words. Digit-by-digit unless it says hundred or thousand.
    static func value(of run: [String]) -> String {
        if run.contains("hundred") || run.contains("thousand") {
            var total = 0, current = 0
            for word in run {
                if let v = units[word] ?? teens[word] ?? tens[word] ?? Int(word) {
                    current += v
                } else if word == "hundred" {
                    current = (current == 0 ? 1 : current) * 100
                } else if word == "thousand" {
                    total += (current == 0 ? 1 : current) * 1000
                    current = 0
                }
            }
            return String(total + current)
        }
        var digits = ""
        var i = 0
        while i < run.count {
            let word = run[i]
            if let t = tens[word] {
                if i + 1 < run.count, let u = units[run[i + 1]], u > 0 {
                    digits += String(t + u)
                    i += 2
                    continue
                }
                digits += String(t)
            } else if let v = teens[word] {
                digits += String(v)
            } else if let v = units[word] {
                digits += String(v)
            } else {
                digits += word
            }
            i += 1
        }
        return digits
    }

    static func instruction(_ tokens: [String]) -> Instruction {
        let text = " " + tokens.joined(separator: " ") + " "
        func has(_ phrases: String...) -> Bool { phrases.contains { text.contains(" \($0) ") } }
        if has("cleared to land", "clear to land") { return .landing }
        if has("cleared for takeoff", "clear for takeoff", "cleared for take off") { return .takeoff }
        if has("line up and wait", "position and hold", "line up") { return .lineUp }
        if has("hold short") { return .holdShort }
        if has("taxi") { return .taxi }
        if has("heading", "turn left", "turn right") { return .heading }
        if has("climb", "descend", "maintain") { return .altitude }
        if has("contact", "monitor") { return .frequencyChange }
        if has("traffic") { return .traffic }
        return .other
    }

    /// "runway 22 left" -> "22L".
    static func runway(_ tokens: [String]) -> String? {
        guard let i = tokens.firstIndex(of: "runway"), i + 1 < tokens.count,
              let number = Int(tokens[i + 1]), (1...36).contains(number) else { return nil }
        var id = String(format: "%02d", number)
        if i + 2 < tokens.count {
            switch tokens[i + 2] {
            case "left", "lima": id += "L"
            case "right", "romeo": id += "R"
            case "center", "centre", "charlie": id += "C"
            default: break
            }
        }
        return id
    }
}
