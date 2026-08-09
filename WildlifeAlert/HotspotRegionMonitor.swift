import CoreLocation
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Minimal, `Codable` snapshot of a corridor, persisted to `UserDefaults`.
///
/// This exists because of *cold launches*: iOS can relaunch a terminated app
/// purely to deliver a region-boundary crossing, and at that moment the
/// Firestore listener has not delivered anything yet. Without a local cache
/// the app would wake up knowing a region ID and nothing else — no name, no
/// species, no severity — and couldn't write a useful notification.
struct CachedHotspot: Codable {
    let id: String
    let name: String
    let species: String
    let riskLevel: String
    let latitude: Double
    let longitude: Double
    /// Radius of the wake circle registered with iOS (already enlarged to
    /// enclose a road-segment polyline where there is one).
    let regionRadiusMeters: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Turns the app from "works while you're staring at it" into something that
/// warns you with the phone in your pocket.
///
/// iOS hard-caps an app at **20 monitored regions**, and there are already 51+
/// corridors. So this monitors the nearest 19 corridors plus one "refresh
/// boundary" circle around the driver: when they exit that boundary, the
/// nearest-19 set is recomputed and re-registered. That's the standard way to
/// run an unbounded geofence set inside a 20-region budget, and it costs
/// essentially no battery — the OS does the boundary math in hardware rather
/// than the app polling GPS.
///
/// Foreground behaviour is untouched by design: region monitoring is a coarse
/// *wake* mechanism, deliberately over-broad (a long road segment becomes a
/// circle enclosing it), and the precise decision about whether to warn is
/// still made by `AlertManager` from a real fix. The two complement each
/// other rather than one replacing the other.
final class HotspotRegionMonitor {
    /// iOS's per-app ceiling. One slot is reserved for the refresh boundary.
    static let maximumMonitoredRegions = 20
    static let hotspotRegionPrefix = "wildlifeAlert.hotspot."
    static let refreshRegionIdentifier = "wildlifeAlert.refreshBoundary"

    private static let cacheKey = "wildlifeAlert.hotspotCache"
    private static let notifyLogKey = "wildlifeAlert.regionNotifyLog"

    /// Matches `AlertManager`'s snooze window: a corridor that just notified
    /// shouldn't notify again if iOS re-delivers the same boundary crossing
    /// (which it does, e.g. when a driver hovers on the edge).
    private static let renotifyInterval: TimeInterval = 20 * 60

    /// Don't churn the region set for small movements.
    private static let reselectionThresholdMeters: Double = 1_000

    /// Region radii below ~100 m are unreliable on real hardware.
    private static let minimumRegionRadius: Double = 120

    private let manager: CLLocationManager
    private let defaults: UserDefaults

    /// Supplies the live corridor list (i.e. `FirestoreManager.hotspots`).
    /// Set by the app once Firestore is up; nil during a cold, region-driven
    /// launch, where the persisted cache takes over.
    var hotspotsProvider: (() -> [Hotspot])?

    private var lastSelectionCenter: CLLocationCoordinate2D?
    private var monitoredHotspotIDs: Set<String> = []
    private var didRequestNotificationAuthorization = false

    init(manager: CLLocationManager, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
    }

    // MARK: - Authorization

    func requestNotificationAuthorization() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("Notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                // Not fatal: foreground banner/voice/haptics still work. Only
                // the backgrounded warning is lost.
                print("Notification authorization declined — background warnings will be silent.")
            }
        }
    }

    // MARK: - Region selection

    /// Recomputes and re-registers the nearest-N region set if the driver has
    /// moved far enough (or `force` is set — used on first fix, on a corridor
    /// data change, and on refresh-boundary exit).
    func refreshIfNeeded(around coordinate: CLLocationCoordinate2D, force: Bool = false) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }

        if !force, let last = lastSelectionCenter,
           GeoMath.distance(from: last, to: coordinate) < Self.reselectionThresholdMeters {
            return
        }

        let hotspots = hotspotsProvider?() ?? []
        guard !hotspots.isEmpty else { return }

        // Rank by true geometry distance so a long road segment is judged by
        // its nearest point, not by how far away its centroid happens to be.
        let ranked = hotspots
            .map { (hotspot: $0, distance: $0.distance(to: coordinate)) }
            .sorted { $0.distance < $1.distance }

        let capacity = Self.maximumMonitoredRegions - 1 // one slot for the refresh boundary
        let selected = Array(ranked.prefix(capacity))
        guard !selected.isEmpty else { return }

        let selectedIDs = Set(selected.map { $0.hotspot.id })

        // Stop monitoring anything of ours that fell out of the set.
        for region in manager.monitoredRegions {
            guard region.identifier.hasPrefix(Self.hotspotRegionPrefix) else { continue }
            let id = String(region.identifier.dropFirst(Self.hotspotRegionPrefix.count))
            if !selectedIDs.contains(id) {
                manager.stopMonitoring(for: region)
            }
        }

        var cache: [CachedHotspot] = []
        for entry in selected {
            let hotspot = entry.hotspot
            let radius = regionRadius(for: hotspot)
            let identifier = Self.hotspotRegionPrefix + hotspot.id
            let region = CLCircularRegion(center: hotspot.coordinate, radius: radius, identifier: identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)

            cache.append(
                CachedHotspot(
                    id: hotspot.id,
                    name: hotspot.name,
                    species: hotspot.species,
                    riskLevel: hotspot.riskLevel.rawValue,
                    latitude: hotspot.coordinate.latitude,
                    longitude: hotspot.coordinate.longitude,
                    regionRadiusMeters: radius
                )
            )
        }

        registerRefreshBoundary(around: coordinate, selected: selected, totalCount: ranked.count)

        monitoredHotspotIDs = selectedIDs
        lastSelectionCenter = coordinate
        writeCache(cache)
    }

    /// The circle that, when the driver leaves it, means "your nearest-19 set
    /// is probably stale — recompute".
    ///
    /// Sized off the farthest corridor we're currently monitoring: leaving
    /// 60% of that distance is a good proxy for "a corridor you aren't
    /// monitoring may now be closer than one you are". Clamped so it neither
    /// thrashes in a dense cluster nor goes so wide it never fires. When every
    /// known corridor already fits inside the budget, the boundary is pushed
    /// out wide because there is nothing to re-select.
    private func registerRefreshBoundary(
        around coordinate: CLLocationCoordinate2D,
        selected: [(hotspot: Hotspot, distance: CLLocationDistance)],
        totalCount: Int
    ) {
        let radius: Double
        if totalCount <= selected.count {
            radius = 50_000
        } else {
            let farthest = selected.last?.distance ?? 5_000
            radius = min(max(farthest * 0.6, 2_000), 20_000)
        }

        let clamped = min(radius, manager.maximumRegionMonitoringDistance)
        for region in manager.monitoredRegions where region.identifier == Self.refreshRegionIdentifier {
            manager.stopMonitoring(for: region)
        }
        let region = CLCircularRegion(center: coordinate, radius: clamped, identifier: Self.refreshRegionIdentifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    /// A `CLCircularRegion` can only be a circle, so a road-segment corridor
    /// gets a circle big enough to enclose the whole segment plus its buffer.
    /// Over-broad on purpose: this only decides *when iOS wakes us*, never
    /// whether the driver is actually at risk.
    private func regionRadius(for hotspot: Hotspot) -> Double {
        let desired = max(hotspot.enclosingRadiusMeters, Self.minimumRegionRadius)
        return min(desired, manager.maximumRegionMonitoringDistance)
    }

    // MARK: - Region events

    func handleRegionEntry(_ region: CLRegion) {
        guard region.identifier.hasPrefix(Self.hotspotRegionPrefix) else { return }
        let id = String(region.identifier.dropFirst(Self.hotspotRegionPrefix.count))
        guard let cached = readCache().first(where: { $0.id == id }) else { return }

        // Foreground already has the full treatment — live map, banner with
        // distance/ETA, voice, haptics — and a duplicate system notification
        // on top of that is noise.
        guard !isAppActive else { return }
        guard shouldNotify(hotspotID: id) else { return }

        postNotification(for: cached)
    }

    func handleRegionExit(_ region: CLRegion, userLocation: CLLocationCoordinate2D?) {
        guard region.identifier == Self.refreshRegionIdentifier else { return }
        let center = userLocation ?? (region as? CLCircularRegion)?.center
        guard let center else { return }
        refreshIfNeeded(around: center, force: true)
    }

    private var isAppActive: Bool {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return UIApplication.shared.applicationState == .active
        }
        return DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
        #else
        return false
        #endif
    }

    private func postNotification(for hotspot: CachedHotspot) {
        let content = UNMutableNotificationContent()
        content.title = "\(hotspot.species) crossing zone"
        content.body = "You're entering \(hotspot.name) — \(hotspot.riskLevel.lowercased()) collision risk. Watch the verges."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "wildlifeAlert.region.\(hotspot.id).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to deliver region notification: \(error.localizedDescription)")
            }
        }
    }

    /// Same anti-cry-wolf principle as the foreground snooze: iOS happily
    /// re-delivers boundary crossings when a driver lingers on the edge, and a
    /// corridor buzzing every 30 seconds is how an app gets deleted.
    private func shouldNotify(hotspotID: String) -> Bool {
        var log = defaults.dictionary(forKey: Self.notifyLogKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        if let last = log[hotspotID], now - last < Self.renotifyInterval {
            return false
        }
        log[hotspotID] = now
        // Keep the log from growing without bound across a long ownership.
        if log.count > 200 {
            let cutoff = now - Self.renotifyInterval * 4
            log = log.filter { $0.value >= cutoff }
        }
        defaults.set(log, forKey: Self.notifyLogKey)
        return true
    }

    // MARK: - Persistence

    private func writeCache(_ hotspots: [CachedHotspot]) {
        guard let data = try? JSONEncoder().encode(hotspots) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }

    private func readCache() -> [CachedHotspot] {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return [] }
        return (try? JSONDecoder().decode([CachedHotspot].self, from: data)) ?? []
    }
}
