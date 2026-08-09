import CoreLocation
import Foundation

@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    /// Single shared instance.
    ///
    /// Region monitoring is an *app-wide* registration held by iOS, not by a
    /// particular object: when the OS relaunches a terminated app to deliver a
    /// boundary crossing, it calls back on whichever `CLLocationManager` has a
    /// delegate attached at that moment. Having exactly one manager, created
    /// early in the launch sequence (see `AppDelegate`), is what makes that
    /// callback land somewhere instead of being dropped.
    static let shared = LocationManager()

    private let manager: CLLocationManager

    @ObservationIgnored let regionMonitor: HotspotRegionMonitor

    var userLocation: CLLocation?
    var heading: CLLocationDirection = 0
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Set once, after "when in use" is granted, so the OS upgrade prompt for
    /// "always" isn't re-thrown at the driver on every authorization change.
    @ObservationIgnored private var didRequestAlwaysAuthorization = false

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.regionMonitor = HotspotRegionMonitor(manager: manager)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        // A drive shouldn't be silently paused by the OS deciding the user has
        // stopped moving — the next corridor is exactly when we need updates.
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
        regionMonitor.requestNotificationAuthorization()
    }

    func startTracking() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        switch authorizationStatus {
        case .authorizedWhenInUse:
            startTracking()
            // Region monitoring only survives backgrounding/termination with
            // "always". Ask for the upgrade once the basic grant is in hand,
            // which is the sequence iOS expects (and the only one where the
            // upgrade prompt is shown at all).
            if !didRequestAlwaysAuthorization {
                didRequestAlwaysAuthorization = true
                manager.requestAlwaysAuthorization()
            }
        case .authorizedAlways:
            // Safe only because UIBackgroundModes contains `location`;
            // setting it without that entry traps at runtime.
            manager.allowsBackgroundLocationUpdates = true
            startTracking()
            if let coordinate = userLocation?.coordinate ?? manager.location?.coordinate {
                regionMonitor.refreshIfNeeded(around: coordinate, force: true)
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        userLocation = location
        // Cheap: this early-returns unless the driver has moved a kilometre
        // since the last selection.
        regionMonitor.refreshIfNeeded(around: location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading.trueHeading
    }

    // MARK: - Region monitoring callbacks

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        regionMonitor.handleRegionEntry(region)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        regionMonitor.handleRegionExit(region, userLocation: userLocation?.coordinate ?? manager.location?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        print("Region monitoring failed for \(region?.identifier ?? "unknown"): \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}
