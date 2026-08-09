import CoreLocation
import FirebaseCore
import FirebaseFirestore
import Foundation

/// Live Firestore-backed hotspot source. Configures Firebase on init, then
/// keeps a real-time snapshot listener (not a one-shot fetch) on the
/// `wildlifeHotspots` collection so new/updated corridors show up on the map
/// without restarting the app. Also supports writing crowdsourced sightings
/// to a top-level `sightings` collection.
///
/// If Firestore has no data yet, or the listener errors (offline, no
/// network, rules issue, etc.), `hotspots` falls back to the bundled
/// `HotspotData.all` static list so the map is never empty.
@Observable
final class FirestoreManager {
    private(set) var hotspots: [Hotspot] = HotspotData.all
    private(set) var isLive = false
    private(set) var lastError: String?

    /// Sightings reported in roughly the last 30 days, kept live via a
    /// snapshot listener so the feedback loop (RiskEngine factoring in
    /// nearby recent sightings) reflects new reports without a restart.
    private(set) var recentSightings: [Sighting] = []

    private var db: Firestore?
    private var listener: ListenerRegistration?
    private var sightingsListener: ListenerRegistration?
    private static var didConfigure = false

    init() {
        if !FirestoreManager.didConfigure {
            if FirebaseApp.app() == nil {
                FirebaseApp.configure()
            }
            FirestoreManager.didConfigure = true
        }
        db = Firestore.firestore()
        startListening()
        startListeningToSightings()
    }

    deinit {
        listener?.remove()
        sightingsListener?.remove()
    }

    /// Listens to the last 30 days of `sightings`. Deliberately client-side
    /// filtered by a fixed cutoff (recomputed each time the listener fires)
    /// rather than a Cloud Function — a live-updating client query is
    /// enough to make the feedback loop real without extra hackathon infra.
    private func startListeningToSightings() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 24 * 3600)
        sightingsListener = db?.collection("sightings")
            .whereField("timestamp", isGreaterThan: Timestamp(date: cutoff))
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                guard let documents = snapshot?.documents, error == nil else {
                    self.recentSightings = []
                    return
                }
                self.recentSightings = documents.compactMap { Sighting(firestoreDocument: $0) }
            }
    }

    private func startListening() {
        listener = db?.collection("wildlifeHotspots").addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }

            if let error {
                self.lastError = error.localizedDescription
                // Keep whatever we had (static fallback or last-good live data).
                if self.hotspots.isEmpty {
                    self.hotspots = HotspotData.all
                }
                self.isLive = false
                return
            }

            guard let documents = snapshot?.documents, !documents.isEmpty else {
                // No data seeded yet (or collection briefly empty) — fall back
                // so the map never renders blank.
                self.hotspots = HotspotData.all
                self.isLive = false
                return
            }

            let parsed = documents.compactMap { Hotspot(firestoreDocument: $0) }
            if parsed.isEmpty {
                self.hotspots = HotspotData.all
                self.isLive = false
            } else {
                self.hotspots = parsed
                self.isLive = true
                self.lastError = nil
            }
        }
    }

    /// Writes a crowdsourced sighting report to the top-level `sightings`
    /// collection. Fire-and-forget from the UI's perspective; errors are
    /// surfaced via `lastSightingError` for a lightweight toast if desired.
    private(set) var lastSightingError: String?

    func reportSighting(
        coordinate: CLLocationCoordinate2D,
        species: String,
        deviceID: UUID
    ) {
        let data: [String: Any] = [
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude,
            "species": species,
            "timestamp": Timestamp(date: Date()),
            "reportedByDevice": deviceID.uuidString
        ]
        db?.collection("sightings").addDocument(data: data) { [weak self] error in
            self?.lastSightingError = error?.localizedDescription
        }
    }
}

private extension Sighting {
    /// Builds a Sighting from a `sightings` document shaped like the ones
    /// `reportSighting` writes: latitude/longitude (doubles), species
    /// (string), timestamp (Firestore Timestamp).
    init?(firestoreDocument document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let latitude = data["latitude"] as? Double,
            let longitude = data["longitude"] as? Double,
            let species = data["species"] as? String,
            let timestamp = data["timestamp"] as? Timestamp
        else {
            return nil
        }
        self.init(
            id: document.documentID,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            species: species,
            timestamp: timestamp.dateValue()
        )
    }
}

private extension Hotspot {
    /// Builds a Hotspot from a Firestore document shaped like the seeded
    /// `wildlifeHotspots` records.
    ///
    /// Schema:
    /// - `name` (string), `species` (string), `riskLevel` (string), `source` (string)
    /// - `location` (GeoPoint) — cluster centroid, always present
    /// - `radiusMeters` (double) — circle radius when `pathPoints` is absent;
    ///   buffer half-width around the road segment when it's present
    /// - `pathPoints` (optional ordered array of GeoPoint) — the road-segment
    ///   polyline
    ///
    /// `pathPoints` is optional on purpose: every document currently in
    /// Firestore predates the geometry upgrade and has no such field, and
    /// those must keep working exactly as circles.
    init?(firestoreDocument document: QueryDocumentSnapshot) {
        let data = document.data()
        guard
            let name = data["name"] as? String,
            let geoPoint = data["location"] as? GeoPoint,
            let species = data["species"] as? String,
            let riskLevelRaw = data["riskLevel"] as? String,
            let riskLevel = Hotspot.RiskLevel(firestoreValue: riskLevelRaw)
        else {
            return nil
        }

        let radiusMeters = (data["radiusMeters"] as? Double) ?? (data["radiusMeters"] as? NSNumber)?.doubleValue ?? 1500
        let source = data["source"] as? String

        // Decoded permissively via [Any] + compactMap rather than a direct
        // [GeoPoint] cast: one malformed element in the array shouldn't drop
        // the entire corridor from the map, it should just degrade that
        // corridor back to a circle.
        var pathPoints: [CLLocationCoordinate2D]?
        if let rawPath = data["pathPoints"] as? [Any] {
            let decoded = rawPath.compactMap { element -> CLLocationCoordinate2D? in
                guard let point = element as? GeoPoint else { return nil }
                return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            if decoded.count >= 2 { pathPoints = decoded }
        }

        self.init(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: geoPoint.latitude, longitude: geoPoint.longitude),
            radiusMeters: radiusMeters,
            species: species,
            riskLevel: riskLevel,
            firestoreID: document.documentID,
            source: source,
            pathPoints: pathPoints
        )
    }
}
