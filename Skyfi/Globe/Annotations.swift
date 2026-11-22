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
        case selected
    }

    private let glyph = UIImageView()
    private let label = UILabel()
    private var style: Style?

    private static let images: [Style: UIImage] = {
        var result: [Style: UIImage] = [:]
        let colors: [Style: UIColor] = [.airborne: Theme.uiAmber, .ground: Theme.uiGround,
                                        .approach: Theme.uiApproach, .selected: Theme.uiCyan]
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(plane: Plane, style: Style, showLabel: Bool, mapHeading: Double) {
        if self.style != style {
            glyph.image = Self.images[style]
            self.style = style
            glyph.layer.shadowColor = (style == .selected ? Theme.uiCyan : UIColor.black).cgColor
            glyph.layer.shadowRadius = style == .selected ? 8 : 2
            zPriority = style == .selected ? .max : (style == .approach ? .defaultSelected : .defaultUnselected)
        }
        // The SF Symbol "airplane" points east, so 90° is "no turn".
        let angle = ((plane.track ?? 90) - mapHeading - 90) * .pi / 180
        glyph.transform = CGAffineTransform(rotationAngle: angle)
        label.isHidden = !showLabel
        label.text = plane.title
    }
}

final class AirportAnnotationView: MKAnnotationView {
    static let reuseID = "airport"

    private let dot = UIView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 24)
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

    func configure(airport: Airport, tuned: Bool, hasFeed: Bool) {
        label.text = airport.code
        dot.backgroundColor = tuned ? Theme.uiCyan : (hasFeed ? UIColor.white.withAlphaComponent(0.5) : .clear)
        dot.layer.borderColor = (tuned ? Theme.uiCyan : UIColor.white).cgColor
        label.textColor = tuned ? Theme.uiCyan : UIColor.white.withAlphaComponent(0.85)
        displayPriority = tuned ? .required : (airport.large ? .defaultHigh : .defaultLow)
    }
}
