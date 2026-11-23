import MapKit
import UIKit

final class PlaneAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var plane: Plane

    init(_ plane: Plane, coordinate: CLLocationCoordinate2D) {
        id = plane.id
        self.plane = plane
        self.coordinate = coordinate
    }

    var title: String? { plane.title }
}

final class AirportAnnotation: NSObject, MKAnnotation {
    let airport: Airport
    var coordinate: CLLocationCoordinate2D { airport.coordinate }

    init(_ airport: Airport) {
        self.airport = airport
    }

    var title: String? { airport.code }
}

/// A plane glyph that turns to the plane's track, with a callsign label when zoomed in.
final class PlaneAnnotationView: MKAnnotationView {
    static let reuseID = "plane"

    enum Style: Equatable {
        case airborne
        case ground
        case approach
        case emergency
        case selected
    }

    private let glyph = UIImageView()
    private let label = UILabel()
    private let ring = CAShapeLayer()
    private let bubble = PaddedLabel()
    private var style: Style?

    /// The airborne glyph as a template, tinted per plane when coloring by altitude.
    private static let altitudeImage = UIImage(systemName: "airplane",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .bold))?
        .withRenderingMode(.alwaysTemplate)
    private var byAltitude = false
    /// The plane being talked to turns orange (and a bit bigger) while its glow lasts.
    private static let talkingImage = UIImage(systemName: "airplane",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .bold))?
        .withTintColor(Theme.uiHighlight, renderingMode: .alwaysOriginal)
    private var talkingTint = false

    /// tar1090-style altitude colors: orange low, through yellow and green, to blue and violet high.
    static func altitudeColor(_ feet: Int?) -> UIColor {
        guard let feet else { return Theme.uiAmber }
        let stops = altitudeStops
        if feet <= stops[0].0 { return stops[0].1 }
        for (low, high) in zip(stops, stops.dropFirst()) where feet <= high.0 {
            let t = CGFloat(feet - low.0) / CGFloat(high.0 - low.0)
            var (r1, g1, b1, a1, r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            low.1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            high.1.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
        }
        return stops.last!.1
    }

    private static let altitudeStops: [(Int, UIColor)] = [
        (0, UIColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 1)),
        (4000, UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)),
        (10000, UIColor(red: 0.45, green: 0.9, blue: 0.3, alpha: 1)),
        (20000, UIColor(red: 0.25, green: 0.8, blue: 1.0, alpha: 1)),
        (30000, UIColor(red: 0.45, green: 0.5, blue: 1.0, alpha: 1)),
        (40000, UIColor(red: 0.8, green: 0.4, blue: 1.0, alpha: 1)),
    ]

    private static let images: [Style: UIImage] = {
        var result: [Style: UIImage] = [:]
        // Every flying plane is yellow (approach too); the picked one is orange.
        let colors: [Style: UIColor] = [.airborne: Theme.uiPlane, .ground: Theme.uiGround,
                                        .approach: Theme.uiPlane, .selected: Theme.uiHighlight,
                                        .emergency: UIColor.systemRed]
        for (style, color) in colors {
            let size: CGFloat = style == .selected ? 26 : (style == .ground ? 14 : 19)
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
            result[style] = UIImage(systemName: "airplane", withConfiguration: config)?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        }
        return result
    }()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        glyph.frame = bounds
        glyph.contentMode = .center
        glyph.layer.shadowColor = UIColor.black.cgColor
        glyph.layer.shadowOpacity = 0.6
        glyph.layer.shadowRadius = 2
        glyph.layer.shadowOffset = .zero
        addSubview(glyph)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        label.frame = CGRect(x: -25, y: 28, width: 80, height: 13)
        addSubview(label)
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .required

        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: -4, dy: -4)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 2.5
        ring.frame = bounds
        ring.isHidden = true
        layer.insertSublayer(ring, at: 0)

        bubble.font = .systemFont(ofSize: 11, weight: .semibold)
        bubble.textColor = .white
        bubble.numberOfLines = 2
        bubble.layer.cornerRadius = 9
        bubble.layer.masksToBounds = true
        bubble.isHidden = true
        addSubview(bubble)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Radar-style data block: "DAL234" over "120 25" (altitude in hundreds of feet, speed in tens of knots).
    static func dataBlock(_ plane: Plane) -> String {
        var second: [String] = []
        if plane.onGround {
            second.append("GND")
        } else if let altitude = plane.altitude {
            second.append(String(format: "%03d", max(0, altitude) / 100))
        }
        if let speed = plane.groundSpeed, !plane.onGround { second.append(String(Int(speed / 10))) }
        return second.isEmpty ? plane.title : plane.title + "\n" + second.joined(separator: " ")
    }

    func configure(plane: Plane, style: Style, showLabel: Bool, mapHeading: Double, altitudeColors: Bool = false,
                   dataBlocks: Bool = false) {
        // Only ordinary airborne planes take the altitude color; selected, approach, ground and emergency keep theirs.
        let tintByAltitude = altitudeColors && style == .airborne
        if tintByAltitude {
            if !byAltitude || self.style != style { glyph.image = Self.altitudeImage }
            glyph.tintColor = Self.altitudeColor(plane.altitude)
        }
        if self.style != style || byAltitude != tintByAltitude {
            if !tintByAltitude { glyph.image = Self.images[style] }
            byAltitude = tintByAltitude
            self.style = style
            glyph.layer.shadowColor = (style == .selected ? Theme.uiHighlight : UIColor.black).cgColor
            glyph.layer.shadowRadius = style == .selected ? 8 : 2
            zPriority = style == .selected ? .max : (style == .approach || style == .emergency ? .defaultSelected : .defaultUnselected)
        }
        if talkingTint { glyph.image = Self.talkingImage }
        // The SF Symbol "airplane" points east, so 90° is "no turn".
        let angle = ((plane.track ?? 90) - mapHeading - 90) * .pi / 180
        let scale = Self.scale(forType: plane.type)
        glyph.transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
        label.isHidden = !showLabel
        label.text = dataBlocks ? Self.dataBlock(plane) : plane.title
        let lines: CGFloat = dataBlocks && label.text?.contains("\n") == true ? 2 : 1
        label.numberOfLines = Int(lines)
        label.frame = CGRect(x: -25, y: 28, width: 80, height: 13 * lines)
        isAccessibilityElement = true
        accessibilityLabel = [plane.title, plane.type, Format.altitude(plane), plane.emergency.map { "squawking \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
    }

    /// Widebodies draw bigger and light aircraft smaller, so a 777 stands out from a Cessna.
    private static let heavyPrefixes = ["B74", "B76", "B77", "B78", "A30", "A33", "A34", "A35", "A38", "MD11", "IL76", "A124", "KC10", "KC46"]
    // Exact codes: "C17"/"C5" as prefixes would catch Cessna 172s and Citations.
    private static let heavyCodes: Set<String> = ["C17", "C5", "C5M"]
    private static let lightPrefixes = ["C1", "C2", "PA", "P28", "SR2", "BE", "DA4", "DA2", "M20", "TB", "R44", "R22", "EC", "AS3", "H1"]

    static func scale(forType type: String?) -> CGFloat {
        guard let type = type?.uppercased(), !type.isEmpty else { return 1 }
        if heavyPrefixes.contains(where: type.hasPrefix) || heavyCodes.contains(type) { return 1.3 }
        // C-130s and C-2s are four-engine/military mediums, not Cessnas.
        if type.hasPrefix("C13") || type.hasPrefix("C30J") || type == "C2" { return 1 }
        if lightPrefixes.contains(where: type.hasPrefix) { return 0.72 }
        return 1
    }

    /// For tests: whether the ring shows, and the bubble's text.
    var isTalking: Bool { !ring.isHidden }
    var bubbleText: String? { bubble.isHidden ? nil : bubble.text }

    /// Glow ring and speech bubble while this plane is on the frequency.
    func setTalk(_ talk: TalkStore.Talk?) {
        guard let talk, talk.isFresh else {
            if talkingTint {
                talkingTint = false
                glyph.image = byAltitude ? Self.altitudeImage : Self.images[style ?? .airborne]
            }
            if !ring.isHidden {
                ring.removeAllAnimations()
                ring.isHidden = true
                bubble.isHidden = true
                zPriority = style == .selected ? .max : (style == .approach || style == .emergency ? .defaultSelected : .defaultUnselected)
            }
            return
        }
        let color = Theme.uiHighlight
        // An emergency stays red; everyone else being talked to turns orange.
        if style != .emergency, !talkingTint {
            talkingTint = true
            glyph.image = Self.talkingImage
        }
        ring.strokeColor = color.cgColor
        ring.isHidden = false
        if ring.animation(forKey: "pulse") == nil {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.8
            scale.toValue = 1.9
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.1
            group.repeatCount = .infinity
            ring.add(group, forKey: "pulse")
        }
        let arrow = talk.speaker == .pilot ? "✈︎ " : (talk.speaker == .controller ? "\(talk.facility) ▸ " : "")
        let text = talk.text.count > 42 ? String(talk.text.prefix(40)) + "…" : talk.text
        bubble.text = arrow + text
        bubble.backgroundColor = color.withAlphaComponent(0.85)
        bubble.textColor = .black
        let size = bubble.sizeThatFits(CGSize(width: 190, height: 40))
        bubble.frame = CGRect(x: bounds.midX - size.width / 2, y: -size.height - 6, width: size.width, height: size.height)
        bubble.isHidden = false
        zPriority = .max
    }
}

/// A label with padding, for map bubbles.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: min(inner.width + insets.left + insets.right, size.width),
                      height: inner.height + insets.top + insets.bottom)
    }
}

final class AirportAnnotationView: MKAnnotationView {
    static let reuseID = "airport"

    private let dot = UIView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 28)
        dot.frame = CGRect(x: 18, y: 0, width: 8, height: 8)
        dot.layer.cornerRadius = 4
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor.white.cgColor
        addSubview(dot)
        label.frame = CGRect(x: 0, y: 9, width: 44, height: 13)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.textAlignment = .center
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(label)
        centerOffset = CGPoint(x: 0, y: 8)
        canShowCallout = false
        displayPriority = .defaultHigh
        collisionMode = .rectangle
        zPriority = .min
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Airports you can connect to get a larger cyan-ringed dot and are always shown;
    /// the connected one is filled. Others are small grey dots for orientation.
    func configure(airport: Airport, tuned: Bool, hasFeed: Bool, favorite: Bool = false) {
        label.text = favorite ? "★\(airport.code)" : airport.code
        isAccessibilityElement = true
        accessibilityLabel = "\(airport.name)\(hasFeed ? ", live tower" : "")\(tuned ? ", connected" : "")"
        accessibilityTraits = .button
        let size: CGFloat = hasFeed ? 12 : 7
        dot.frame = CGRect(x: (bounds.width - size) / 2, y: 0, width: size, height: size)
        dot.layer.cornerRadius = size / 2
        dot.layer.borderWidth = hasFeed ? 2 : 1
        dot.backgroundColor = tuned ? Theme.uiCyan : (hasFeed ? Theme.uiCyan.withAlphaComponent(0.25) : UIColor.white.withAlphaComponent(0.35))
        dot.layer.borderColor = (hasFeed ? Theme.uiCyan : UIColor.white.withAlphaComponent(0.6)).cgColor
        label.frame = CGRect(x: 0, y: size + 1, width: bounds.width, height: 13)
        label.font = .monospacedSystemFont(ofSize: hasFeed ? 11 : 9, weight: .bold)
        label.textColor = favorite ? Theme.uiAmber : (tuned || hasFeed ? Theme.uiCyan : UIColor.white.withAlphaComponent(0.6))
        displayPriority = hasFeed || tuned || favorite ? .required : .defaultLow
        zPriority = hasFeed ? .defaultSelected : .min
    }
}
