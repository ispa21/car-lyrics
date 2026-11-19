import CoreLocation

/// Keeps the app running in the background the way navigation apps stay running (UIBackgroundModes location).
/// Asks for the lowest accuracy, so iOS can use cell towers and Wi-Fi instead of GPS; while Google Maps
/// navigates, the GPS is on anyway and this shares its readings. The locations themselves are ignored.
@MainActor
final class LocationKeepAlive: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let log: (String) -> Void
    private var wanted = false
    private(set) var updating = false

    init(log: @escaping (String) -> Void) {
        self.log = log
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        // Without this, iOS stops updates when the car sits still (traffic, parking) and suspends the app.
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()  // begins in the delegate once answered
        case .denied, .restricted: log("Location is off for Lyrics Dash, so only silent audio keeps it running (Settings → Lyrics Dash → Location)")
        default: begin()
        }
    }

    func stop() {
        wanted = false
        guard updating else { return }
        updating = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        log("Location keep-alive off")
    }

    private func begin() {
        guard wanted, !updating else { return }
        updating = true
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        log("Location keep-alive on (low accuracy)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: begin()
        case .denied, .restricted:
            if wanted { log("Location access refused, so only silent audio keeps Lyrics Dash running") }
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // .locationUnknown is temporary (no signal yet); only a refusal matters here.
        if (error as? CLError)?.code == .denied, wanted { log("Location access refused; only silent audio keeps Lyrics Dash running") }
    }
}
