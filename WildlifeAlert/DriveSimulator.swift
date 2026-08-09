import CoreLocation
import MapKit
import Foundation

@Observable
final class DriveSimulator {
    private(set) var simulatedLocation: CLLocation?
    private(set) var heading: Double = 0
    private(set) var isDriving = false
    private(set) var progress: Double = 0 // 0...1 along the route

    private var points: [CLLocationCoordinate2D] = []
    private var cumulativeDistances: [Double] = []
    private var totalDistance: Double = 0
    private var traveled: Double = 0
    private var task: Task<Void, Never>?

    /// Simulated highway driving speed.
    var speedMetersPerSecond: Double = 27 // ~60 mph

    func start(route: MKRoute, onTick: @escaping (CLLocation) -> Void) {
        stop()

        let coordCount = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: coordCount)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: coordCount))
        points = coords

        cumulativeDistances = [0]
        var running: Double = 0
        for i in 1..<max(points.count, 1) {
            guard i < points.count else { break }
            let a = CLLocation(latitude: points[i - 1].latitude, longitude: points[i - 1].longitude)
            let b = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
            running += a.distance(from: b)
            cumulativeDistances.append(running)
        }
        totalDistance = running
        traveled = 0
        progress = 0
        isDriving = true

        task = Task { [weak self] in
            guard let self else { return }
            let tickInterval: Double = 1.0
            while !Task.isCancelled && self.isDriving {
                self.traveled = min(self.totalDistance, self.traveled + self.speedMetersPerSecond * tickInterval)
                self.progress = self.totalDistance > 0 ? self.traveled / self.totalDistance : 1
                if let location = self.locationAtTraveledDistance(self.traveled) {
                    self.simulatedLocation = location
                    onTick(location)
                }
                if self.traveled >= self.totalDistance {
                    self.isDriving = false
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isDriving = false
    }

    private func locationAtTraveledDistance(_ distance: Double) -> CLLocation? {
        guard points.count >= 2 else { return nil }

        var segmentIndex = 0
        for i in 1..<cumulativeDistances.count {
            if cumulativeDistances[i] >= distance {
                segmentIndex = i - 1
                break
            }
            segmentIndex = i - 1
        }
        segmentIndex = min(segmentIndex, points.count - 2)

        let segmentStart = cumulativeDistances[segmentIndex]
        let segmentEnd = cumulativeDistances[segmentIndex + 1]
        let segmentLength = segmentEnd - segmentStart
        let t = segmentLength > 0 ? (distance - segmentStart) / segmentLength : 0

        let a = points[segmentIndex]
        let b = points[segmentIndex + 1]
        let lat = a.latitude + (b.latitude - a.latitude) * t
        let lon = a.longitude + (b.longitude - a.longitude) * t

        heading = bearing(from: a, to: b)

        // Use the full CLLocation initializer so `.speed` and `.course` are
        // populated with real values (matching the simulator's current
        // speed setting) rather than left at CLLocation's default -1
        // "invalid" sentinel — RiskEngine's traffic/pace factor reads
        // `.speed` the same way it would from live CoreLocation, so the
        // simulator needs to report a real number for that factor to work
        // in the simulated-drive flow, not just on-device with real GPS.
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1,
            course: heading,
            speed: speedMetersPerSecond,
            timestamp: Date()
        )
    }

    private func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lon1 = from.longitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let lon2 = to.longitude * .pi / 180

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)
        return (radiansBearing * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
