import CoreLocation
import Foundation

/// Small great-circle helpers. Distances are in nautical miles, angles in degrees true.
enum Geo {
    static let earthRadiusNM = 3440.065

    static func distanceNM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusNM * atan2(sqrt(a), sqrt(1 - a))
    }

    static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalize(atan2(y, x) * 180 / .pi)
    }

    /// The point reached from (lat, lon) after `distanceNM` along `bearing`.
    static func destination(_ lat: Double, _ lon: Double, bearing: Double, distanceNM: Double) -> CLLocationCoordinate2D {
        let d = distanceNM / earthRadiusNM
        let b = bearing * .pi / 180
        let p1 = lat * .pi / 180, l1 = lon * .pi / 180
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
        let l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        var lonDeg = l2 * 180 / .pi
        lonDeg = (lonDeg + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: p2 * 180 / .pi, longitude: lonDeg)
    }

    static func normalize(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// Smallest difference between two headings, 0...180.
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(normalize(a) - normalize(b))
        return diff > 180 ? 360 - diff : diff
    }
}
