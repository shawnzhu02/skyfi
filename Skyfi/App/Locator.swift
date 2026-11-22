import CoreLocation
import Observation

/// Your position, asked for only when you tap the locate button (when-in-use, one fix at a time).
@Observable
@MainActor
final class Locator {
    static let shared = Locator()

    private(set) var location: CLLocation?
    private(set) var denied = false
    private(set) var authorized = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let helper = LocatorHelper()

    private init() {
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = helper
        helper.owner = self
        update(manager.authorizationStatus)
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            denied = true
            dlog("app", "location denied")
        default:
            manager.requestLocation()
        }
    }

    fileprivate func update(_ status: CLAuthorizationStatus) {
        authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        denied = status == .denied || status == .restricted
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        let wasAuthorized = authorized
        update(status)
        // Just said yes: get the fix they asked for.
        if authorized, !wasAuthorized { manager.requestLocation() }
    }

    fileprivate func found(_ location: CLLocation) {
        self.location = location
    }

    fileprivate func failed(_ error: Error) {
        dlog("app", "location failed: \(error.localizedDescription)")
    }
}

private final class LocatorHelper: NSObject, CLLocationManagerDelegate {
    weak var owner: Locator?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.owner?.authorizationChanged(status) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor [weak self] in self?.owner?.found(last) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.owner?.failed(error) }
    }
}
