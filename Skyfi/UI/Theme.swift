import SwiftUI
import UIKit

/// Skyfi look: night-radar dark with amber planes and cyan ATC.
enum Theme {
    static let background = Color(red: 0.04, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.08, green: 0.10, blue: 0.13).opacity(0.92)
    static let stroke = Color.white.opacity(0.08)
    static let amber = Color(red: 1.0, green: 0.71, blue: 0.28)
    static let cyan = Color(red: 0.35, green: 0.82, blue: 1.0)
    static let text = Color.white
    static let muted = Color.white.opacity(0.6)

    static let uiAmber = UIColor(red: 1.0, green: 0.71, blue: 0.28, alpha: 1)
    static let uiCyan = UIColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1)
    static let uiGround = UIColor(white: 0.75, alpha: 0.9)
    static let uiApproach = UIColor(red: 1.0, green: 0.42, blue: 0.35, alpha: 1)
    /// Planes are yellow; the one that's highlighted (picked, or being talked to) is orange.
    static let uiPlane = UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
    static let uiHighlight = UIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1)
    static let plane = Color(uiPlane)
    static let highlight = Color(uiHighlight)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
    }
}

extension View {
    func panel() -> some View { modifier(Panel()) }
}

enum Format {
    static func altitude(_ plane: Plane) -> String {
        if plane.onGround { return "Ground" }
        guard let feet = plane.altitude else { return "—" }
        return feet >= 18000 ? "FL\(feet / 100)" : "\(feet.formatted()) ft"
    }

    static func speed(_ knots: Double?) -> String {
        knots.map { "\(Int($0.rounded())) kt" } ?? "—"
    }

    static func verticalRate(_ rate: Double?) -> String {
        guard let rate, abs(rate) >= 100 else { return "Level" }
        return (rate > 0 ? "↑ " : "↓ ") + "\(Int(abs(rate)).formatted()) fpm"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}
