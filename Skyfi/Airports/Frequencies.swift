import Foundation

/// An airport's published radio frequencies (OurAirports open data, built by scripts/build_frequencies.py).
struct Frequency: Equatable, Hashable {
    /// ATIS, DEL, GND, TWR, DEP, APP or CTAF.
    let kind: String
    let name: String
    let mhz: Double

    /// "128.8", "132.225", "135.0": the way it's read on the radio.
    var mhzText: String {
        var text = String(format: "%.3f", mhz)
        while text.hasSuffix("0") && !text.hasSuffix(".0") { text.removeLast() }
        return text
    }
}

final class FrequencyIndex {
    static let shared = FrequencyIndex(bundle: .main)

    private let byICAO: [String: [Frequency]]

    init(_ byICAO: [String: [Frequency]]) { self.byICAO = byICAO }

    convenience init(bundle: Bundle) {
        var result: [String: [Frequency]] = [:]
        if let url = bundle.url(forResource: "frequencies", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            result = Self.parse(data)
        }
        self.init(result)
    }

    /// {"KBOS": [["TWR", "Boston Tower West", 128.8], ...]}
    static func parse(_ data: Data) -> [String: [Frequency]] {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[Any]]] else { return [:] }
        return raw.mapValues { rows in
            rows.compactMap { row in
                guard row.count == 3, let kind = row[0] as? String, let name = row[1] as? String,
                      let mhz = (row[2] as? NSNumber)?.doubleValue else { return nil }
                return Frequency(kind: kind, name: name, mhz: mhz)
            }
        }
    }

    func frequencies(_ icao: String) -> [Frequency] { byICAO[icao] ?? [] }

    /// The frequency for a facility guess ("TWR"), when the airport publishes exactly one.
    func single(_ icao: String, kind: String) -> Frequency? {
        let matches = frequencies(icao).filter { $0.kind == kind }
        return matches.count == 1 ? matches[0] : nil
    }
}
