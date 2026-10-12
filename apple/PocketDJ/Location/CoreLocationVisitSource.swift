#if os(iOS)
import CoreLocation
import Foundation

/// The iOS location source behind `ListeningLocationStore` (design spec §3.4).
///
/// Battery-friendly by construction: CLVisit monitoring + significant-change only. No standard
/// updates, no `allowsBackgroundLocationUpdates`, no `location` background mode — both services
/// relaunch the app on their own when something happens. Asks When-In-Use first; the Settings
/// section offers the Always upgrade (needed to notice trips while music plays in the background).
///
/// The manager is created on main, so its delegate callbacks arrive on main; each hops into the
/// `@MainActor` store and only the de-CoreLocation'd sample crosses.
@MainActor
final class CoreLocationVisitSource: NSObject, ListeningLocationSource, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private weak var store: ListeningLocationStore?
    private var monitoring = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
    }

    var authorization: ListeningLocationAuthorization { Self.map(manager.authorizationStatus) }

    func start(delivering store: ListeningLocationStore) {
        self.store = store
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        startMonitoringIfAuthorized()
    }

    func stop() {
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        monitoring = false
        store = nil
    }

    func requestAlwaysUpgrade() {
        manager.requestAlwaysAuthorization()
    }

    private func startMonitoringIfAuthorized() {
        guard store != nil, !monitoring, authorization.isGranted else { return }
        monitoring = true
        manager.startMonitoringVisits()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    nonisolated static func map(_ s: CLAuthorizationStatus) -> ListeningLocationAuthorization {
        switch s {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        @unknown default: return .denied
        }
    }

    /// Callbacks are delivered on the thread that created the manager (main); hop defensively if not.
    nonisolated private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.map(manager.authorizationStatus)
        onMain { [weak self] in
            guard let self else { return }
            self.store?.sourceAuthorizationDidChange(status)
            if status.isGranted { self.startMonitoringIfAuthorized() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let sample = LocationVisitSample(
            latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy,
            arrival: visit.arrivalDate == .distantPast ? nil : visit.arrivalDate,
            departure: visit.departureDate == .distantFuture ? nil : visit.departureDate)
        onMain { [weak self] in self?.store?.ingestVisit(sample) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            LocationFixSample(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                              horizontalAccuracy: $0.horizontalAccuracy, at: $0.timestamp)
        }
        onMain { [weak self] in fixes.forEach { self?.store?.noteMovement($0) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (kCLErrorLocationUnknown) or a denial that didChangeAuthorization also
        // reports — nothing to do here.
    }
}
#endif
