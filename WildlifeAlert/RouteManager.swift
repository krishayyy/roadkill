import Combine
import CoreLocation
import MapKit
import Foundation

@Observable
final class SearchCompleterModel: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    var results: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, region: MKCoordinateRegion?) {
        if let region { completer.region = region }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

/// Route-level pre-trip summary: how many known corridors the selected
/// route passes near, broken down by severity, plus a coarse traffic
/// outlook for the trip as a whole.
struct PreTripSummary {
    let severeCount: Int
    let highCount: Int
    let moderateCount: Int
    let trafficLabel: String
    /// true = traffic is flowing near-normal speed (full risk weight along
    /// the route); false = traffic is slower than normal (reduced risk,
    /// more reaction time for drivers overall).
    let trafficIsElevated: Bool

    var totalCount: Int { severeCount + highCount + moderateCount }
}

@Observable
final class RouteManager {
    var route: MKRoute?
    var destinationName: String?
    var isCalculating = false
    var errorMessage: String?

    /// Route's own traffic-aware average pace (distance / expectedTravelTime,
    /// in m/s). MKDirections' `expectedTravelTime` already factors Apple's
    /// live traffic data internally when the request is for "now", so this
    /// average speed is itself a traffic-aware signal — it's what
    /// RiskEngine compares a driver's live CLLocation speed against.
    var expectedSpeedMetersPerSecond: Double? {
        guard let route, route.expectedTravelTime > 0 else { return nil }
        return route.distance / route.expectedTravelTime
    }

    /// Corridor buffer added on top of each hotspot's own alert radius when
    /// checking whether the route passes near it — the route polyline is a
    /// thin line, not the full width of a real road, so a modest buffer
    /// keeps us from missing corridors that clip the road's shoulder.
    private static let routeProximityBufferMeters: Double = 250

    /// How far off the route polyline the driver can be before projecting
    /// them onto it stops meaning anything (parallel frontage road, wrong
    /// turn, GPS drift in a canyon). Past this, `approach(to:from:)` declines
    /// to answer and AlertManager falls back to compass heading.
    private static let offRouteToleranceMeters: Double = 300

    /// How far ahead along the route to look for a corridor entry. Comfortably
    /// past the maximum lookahead distance, and it bounds the scan cost on a
    /// cross-country route.
    private static let forwardScanMeters: Double = 5_000

    /// Route polyline resampled to ~150 m spacing, with the cumulative
    /// distance along the route at each sample. Cached when the route is set
    /// rather than rebuilt per query — `approach(to:from:)` runs for every
    /// candidate corridor on every location tick.
    @ObservationIgnored private var sampleCoordinates: [CLLocationCoordinate2D] = []
    @ObservationIgnored private var sampleDistances: [CLLocationDistance] = []

    /// Memo for "where on the route is the driver right now". Every corridor
    /// in a single evaluation pass asks about the same coordinate, so
    /// projecting once per tick instead of once per corridor turns an
    /// O(corridors x samples) scan into O(samples).
    @ObservationIgnored private var cachedProjectionCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var cachedProjectionIndex: Int?

    /// Builds the pre-trip summary card's data: which known hotspots this
    /// route passes near, and a coarse traffic outlook for the trip.
    func preTripSummary(hotspots: [Hotspot]) -> PreTripSummary? {
        guard let route else { return nil }
        let samples = sampleCoordinates.isEmpty ? sampledCoordinates(from: route.polyline) : sampleCoordinates
        guard !samples.isEmpty else { return nil }

        var severe = 0, high = 0, moderate = 0
        for hotspot in hotspots {
            let threshold = hotspot.radiusMeters + Self.routeProximityBufferMeters
            // Geometry-aware: for a road-segment corridor this measures to the
            // nearest point on the segment, not to its centroid.
            let passesNear = samples.contains { sample in
                hotspot.distance(to: sample) <= threshold
            }
            guard passesNear else { continue }
            switch hotspot.riskLevel {
            case .severe: severe += 1
            case .high: high += 1
            case .moderate: moderate += 1
            }
        }

        let (trafficLabel, elevated) = trafficOutlook(for: route)
        return PreTripSummary(
            severeCount: severe,
            highCount: high,
            moderateCount: moderate,
            trafficLabel: trafficLabel,
            trafficIsElevated: elevated
        )
    }

    /// Resamples the route polyline's raw coordinates down to points spaced
    /// ~150m apart so the proximity check above stays cheap on long routes.
    private func sampledCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        guard coords.count > 1 else { return coords }

        var result: [CLLocationCoordinate2D] = [coords[0]]
        var last = CLLocation(latitude: coords[0].latitude, longitude: coords[0].longitude)
        let minSpacing: Double = 150
        for coord in coords.dropFirst() {
            let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            if loc.distance(from: last) >= minSpacing {
                result.append(coord)
                last = loc
            }
        }
        return result
    }

    /// Coarse route-level traffic signal for the pre-trip card. Honest
    /// caveat: MapKit's public API doesn't expose a distinct "free-flow"
    /// ETA alongside the live-traffic-aware `expectedTravelTime` — there is
    /// no second number from Apple to diff against, and `MKRoute`/`MKRouteStep`
    /// expose no explicit speed-limit or live-congestion field either. So
    /// this compares the route's own traffic-aware average speed
    /// (distance / expectedTravelTime) against a free-flow benchmark speed
    /// chosen from the route's step-length profile: long steps suggest a
    /// highway-like corridor (higher free-flow benchmark), short/frequent
    /// steps suggest surface streets (lower benchmark).
    private func trafficOutlook(for route: MKRoute) -> (String, Bool) {
        guard route.expectedTravelTime > 0 else { return ("Traffic outlook unavailable", false) }
        let avgSpeed = route.distance / route.expectedTravelTime

        let steps = route.steps.filter { $0.distance > 0 }
        let avgStepDistance = steps.isEmpty ? 0 : steps.reduce(0) { $0 + $1.distance } / Double(steps.count)
        let freeFlowSpeed: Double = avgStepDistance > 500 ? 26.8 : 13.4 // ~60mph highway vs ~30mph surface streets

        let ratio = avgSpeed / freeFlowSpeed
        if ratio <= 0.7 {
            return ("Traffic is running slow on this route — more reaction time, somewhat lower risk overall", false)
        } else if ratio >= 0.9 {
            return ("Traffic is flowing near normal speed — full collision-risk weight applies along the route", true)
        } else {
            return ("Traffic is moderate on this route right now", true)
        }
    }

    func resolve(completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            return response.mapItems.first
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Rebuilds the cached sample/cumulative-distance arrays. Called
    /// explicitly whenever `route` changes.
    private func rebuildRouteSamples() {
        cachedProjectionCoordinate = nil
        cachedProjectionIndex = nil

        guard let route else {
            sampleCoordinates = []
            sampleDistances = []
            return
        }

        let coordinates = sampledCoordinates(from: route.polyline)
        var cumulative: [CLLocationDistance] = []
        cumulative.reserveCapacity(coordinates.count)
        var running: CLLocationDistance = 0
        for (index, coordinate) in coordinates.enumerated() {
            if index > 0 {
                running += GeoMath.distance(from: coordinates[index - 1], to: coordinate)
            }
            cumulative.append(running)
        }
        sampleCoordinates = coordinates
        sampleDistances = cumulative
    }

    /// Index of the route sample closest to `coordinate`, or nil when the
    /// driver is too far off the route to project meaningfully.
    private func projectionIndex(for coordinate: CLLocationCoordinate2D) -> Int? {
        if let cachedProjectionCoordinate,
           cachedProjectionCoordinate.latitude == coordinate.latitude,
           cachedProjectionCoordinate.longitude == coordinate.longitude {
            return cachedProjectionIndex
        }

        var bestIndex: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, sample) in sampleCoordinates.enumerated() {
            let distance = GeoMath.distance(from: coordinate, to: sample)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        let result = bestDistance <= Self.offRouteToleranceMeters ? bestIndex : nil
        cachedProjectionCoordinate = coordinate
        cachedProjectionIndex = result
        return result
    }

    func calculateRoute(from origin: CLLocationCoordinate2D, to destination: MKMapItem) async {
        isCalculating = true
        defer { isCalculating = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = destination
        request.transportType = .automobile

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            route = response.routes.first
            rebuildRouteSamples()
            destinationName = destination.name
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            route = nil
            rebuildRouteSamples()
        }
    }

    func clear() {
        route = nil
        rebuildRouteSamples()
        destinationName = nil
        errorMessage = nil
    }
}

// MARK: - RouteApproachProvider

extension RouteManager: RouteApproachProvider {
    /// Answers "is this corridor ahead of me on the road I'm actually
    /// driving, and how far until I'm in it?".
    ///
    /// This is strictly better than a compass test, which a curving road
    /// defeats in both directions: a corridor dead ahead on a bend can read as
    /// 90 degrees off the current course, and a corridor already passed can
    /// briefly read as straight ahead. Projecting the driver onto the route
    /// and scanning *forward only* gets both cases right, and yields the real
    /// driving distance to the corridor rather than a crow-flies figure.
    ///
    /// Returns nil when there's no route or the driver isn't on it, which is
    /// the caller's signal to fall back to heading.
    func approach(to hotspot: Hotspot, from coordinate: CLLocationCoordinate2D) -> RouteApproach? {
        guard !sampleCoordinates.isEmpty, sampleCoordinates.count == sampleDistances.count else { return nil }
        guard let userIndex = projectionIndex(for: coordinate) else { return nil }

        let userAlong = sampleDistances[userIndex]
        let scanLimit = userAlong + Self.forwardScanMeters

        var index = userIndex
        while index < sampleCoordinates.count, sampleDistances[index] <= scanLimit {
            if hotspot.distance(to: sampleCoordinates[index]) <= hotspot.radiusMeters {
                return RouteApproach(
                    distanceToEntryMeters: max(0, sampleDistances[index] - userAlong),
                    isAhead: true
                )
            }
            index += 1
        }

        // Either behind us on this route, or the route never enters it.
        return RouteApproach(distanceToEntryMeters: .greatestFiniteMagnitude, isAhead: false)
    }
}
