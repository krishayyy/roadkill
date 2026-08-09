import CoreLocation
import Foundation

struct Hotspot: Identifiable {
    /// Firestore document ID when this hotspot was loaded live; nil for the
    /// static mock/fallback list.
    let firestoreID: String?
    let id: String
    let name: String
    /// Cluster centroid. Always present — used for map centring, region
    /// monitoring, and as the whole geometry when `pathPoints` is absent.
    let coordinate: CLLocationCoordinate2D
    /// Circle radius when `pathPoints` is absent; buffer half-width around the
    /// road segment when `pathPoints` is present.
    let radiusMeters: Double
    let species: String
    let riskLevel: RiskLevel
    /// Honesty note about how precisely this location is known, e.g.
    /// "FHWA/State DOT reported corridor — approximate". Nil for the
    /// original hardcoded demo list, which predates this field.
    let source: String?

    /// Ordered road-segment polyline, when the upstream data pipeline knows
    /// the actual road geometry. Collisions happen *along roads*, not in
    /// circular blobs, so when this is present every distance check measures
    /// to the nearest point on the line rather than to the centroid.
    ///
    /// Nil (and everything falls back to centroid + radius) for the documents
    /// currently in Firestore, which predate the geometry upgrade.
    let pathPoints: [CLLocationCoordinate2D]?

    /// Pre-computed closed ring approximating the buffered road segment, for
    /// map rendering. Built once at parse time rather than per-frame; empty
    /// when there's no path.
    let bufferPolygon: [CLLocationCoordinate2D]

    enum RiskLevel: String {
        case moderate = "Moderate"
        case high = "High"
        case severe = "Severe"

        /// Maps a Firestore riskLevel string ("moderate"/"high"/"severe") to
        /// the existing display-cased enum used throughout the app.
        init?(firestoreValue: String) {
            switch firestoreValue.lowercased() {
            case "moderate": self = .moderate
            case "high": self = .high
            case "severe": self = .severe
            default: return nil
            }
        }
    }

    init(
        name: String,
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        species: String,
        riskLevel: RiskLevel,
        firestoreID: String? = nil,
        source: String? = nil,
        pathPoints: [CLLocationCoordinate2D]? = nil
    ) {
        self.firestoreID = firestoreID
        self.id = firestoreID ?? UUID().uuidString
        self.name = name
        self.coordinate = coordinate
        self.radiusMeters = radiusMeters
        self.species = species
        self.riskLevel = riskLevel
        self.source = source

        // A "path" of fewer than two distinct points carries no more
        // information than the centroid, so it's normalised away here and the
        // rest of the app never has to special-case it.
        let cleanedPath = pathPoints.map { GeoMath.deduplicated($0) } ?? []
        if cleanedPath.count >= 2 {
            self.pathPoints = cleanedPath
            self.bufferPolygon = GeoMath.bufferPolygon(along: cleanedPath, halfWidthMeters: radiusMeters)
        } else {
            self.pathPoints = nil
            self.bufferPolygon = []
        }
    }
}

// MARK: - Geometry

extension Hotspot {
    /// True when this hotspot describes a road segment rather than a circle.
    var hasRoadGeometry: Bool { pathPoints != nil }

    /// Nearest point of the hotspot's *centre geometry* (the polyline when
    /// present, otherwise the centroid) to `coordinate`, with its distance.
    /// The buffer/radius is deliberately not subtracted here — callers decide
    /// whether they want "distance to the corridor line" or "distance to the
    /// corridor edge".
    func nearestGeometryPoint(
        to coordinate: CLLocationCoordinate2D
    ) -> (distance: CLLocationDistance, coordinate: CLLocationCoordinate2D) {
        if let pathPoints, let nearest = GeoMath.nearestPoint(on: pathPoints, to: coordinate) {
            return (nearest.distance, nearest.closest)
        }
        return (GeoMath.distance(from: coordinate, to: self.coordinate), self.coordinate)
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        nearestGeometryPoint(to: coordinate).distance
    }

    func distance(to location: CLLocation) -> CLLocationDistance {
        distance(to: location.coordinate)
    }

    /// True when `coordinate` is inside the corridor itself (within the buffer
    /// of the road segment, or inside the circle).
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        distance(to: coordinate) <= radiusMeters
    }

    /// Radius of a circle centred on `coordinate` that fully encloses this
    /// hotspot's geometry plus its buffer. Used for `CLCircularRegion`
    /// monitoring, which can only express circles — a long road segment gets a
    /// deliberately over-broad wake circle, and the precise decision is then
    /// made in code once we have a fresh fix.
    var enclosingRadiusMeters: Double {
        guard let pathPoints else { return radiusMeters }
        let farthest = pathPoints.reduce(0.0) { partial, point in
            max(partial, GeoMath.distance(from: coordinate, to: point))
        }
        return farthest + radiusMeters
    }
}

enum HotspotData {
    // Mock/demo corridors. In production these would come from a real
    // DOT/FHWA roadkill dataset geocoded into risk polygons.
    static let all: [Hotspot] = [
        Hotspot(
            name: "US-26 Elk Corridor",
            coordinate: CLLocationCoordinate2D(latitude: 43.4799, longitude: -110.7624),
            radiusMeters: 1500,
            species: "Elk",
            riskLevel: .severe
        ),
        Hotspot(
            name: "I-80 Deer Crossing",
            coordinate: CLLocationCoordinate2D(latitude: 41.1400, longitude: -104.8202),
            radiusMeters: 2000,
            species: "Deer",
            riskLevel: .high
        ),
        Hotspot(
            name: "Route 6 Moose Zone",
            coordinate: CLLocationCoordinate2D(latitude: 44.2601, longitude: -71.3033),
            radiusMeters: 1200,
            species: "Moose",
            riskLevel: .severe
        ),
        Hotspot(
            name: "PA-15 Deer Corridor",
            coordinate: CLLocationCoordinate2D(latitude: 41.2033, longitude: -77.1945),
            radiusMeters: 1800,
            species: "Deer",
            riskLevel: .moderate
        ),
        Hotspot(
            name: "US-2 Wildlife Crossing",
            coordinate: CLLocationCoordinate2D(latitude: 48.2766, longitude: -114.1631),
            radiusMeters: 1600,
            species: "Deer & Elk",
            riskLevel: .high
        )
    ]
}
