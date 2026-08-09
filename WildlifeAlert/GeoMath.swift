import CoreLocation
import Foundation

/// Shared geometry used by *both* the alerting path (`AlertManager`) and the
/// scoring path (`RiskEngine`) so "how far am I from this corridor" is
/// computed exactly one way, whether the corridor is a point+radius circle or
/// a road-segment polyline.
///
/// Everything here uses a local equirectangular projection (metres per degree
/// of latitude is ~constant; metres per degree of longitude is scaled by
/// cos(latitude) at the local origin). At corridor scales — a few hundred
/// metres to a few kilometres — the error versus a full great-circle solve is
/// well under a metre, which is far below GPS noise, and it lets us do
/// point-to-segment math with plain 2-D vectors.
enum GeoMath {
    /// Metres per degree of latitude at a given latitude (WGS84 meridian-arc
    /// series). A flat 111_320 constant is ~0.12% out at mid-latitudes, which
    /// is ~6 m over 5 km — small, but this costs two cosines and removes the
    /// error entirely, so there's no reason to eat it.
    static func metersPerDegreeLatitude(at latitude: Double) -> Double {
        let phi = latitude * .pi / 180
        return 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi) - 0.0023 * cos(6 * phi)
    }

    /// Metres per degree of longitude at a given latitude (WGS84).
    static func metersPerDegreeLongitude(at latitude: Double) -> Double {
        let phi = latitude * .pi / 180
        return 111_412.84 * cos(phi) - 93.5 * cos(3 * phi) + 0.118 * cos(5 * phi)
    }

    struct Vector2 {
        var x: Double
        var y: Double

        static func + (a: Vector2, b: Vector2) -> Vector2 { Vector2(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: Vector2, b: Vector2) -> Vector2 { Vector2(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: Vector2, s: Double) -> Vector2 { Vector2(x: a.x * s, y: a.y * s) }

        var length: Double { (x * x + y * y).squareRoot() }

        /// Unit vector, or nil for a degenerate zero-length vector.
        var normalized: Vector2? {
            let l = length
            guard l > 1e-9 else { return nil }
            return Vector2(x: x / l, y: y / l)
        }

        /// Left-hand normal (90 degrees counter-clockwise).
        var normal: Vector2 { Vector2(x: -y, y: x) }
    }

    /// Flat local metre frame anchored at a chosen origin coordinate.
    struct LocalFrame {
        let originLatitude: Double
        let originLongitude: Double
        let metersPerDegreeLatitude: Double
        let metersPerDegreeLongitude: Double

        init(origin: CLLocationCoordinate2D) {
            originLatitude = origin.latitude
            originLongitude = origin.longitude
            metersPerDegreeLatitude = GeoMath.metersPerDegreeLatitude(at: origin.latitude)
            // Guard against the poles collapsing the longitude scale to zero.
            metersPerDegreeLongitude = max(GeoMath.metersPerDegreeLongitude(at: origin.latitude), 1e-6)
        }

        func project(_ coordinate: CLLocationCoordinate2D) -> Vector2 {
            Vector2(
                x: (coordinate.longitude - originLongitude) * metersPerDegreeLongitude,
                y: (coordinate.latitude - originLatitude) * metersPerDegreeLatitude
            )
        }

        func unproject(_ point: Vector2) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: originLatitude + point.y / metersPerDegreeLatitude,
                longitude: originLongitude + point.x / metersPerDegreeLongitude
            )
        }
    }

    // MARK: - Distances

    /// Straight-line distance in metres between two coordinates.
    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        let frame = LocalFrame(origin: a)
        return frame.project(b).length
    }

    /// Distance from `point` to the segment `a`→`b`, plus the closest point on
    /// that segment. Handles the degenerate a == b case (returns the point).
    static func distance(
        from point: CLLocationCoordinate2D,
        toSegment a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> (distance: CLLocationDistance, closest: CLLocationCoordinate2D) {
        let frame = LocalFrame(origin: point)
        let p = Vector2(x: 0, y: 0) // point is the frame origin
        let pa = frame.project(a)
        let pb = frame.project(b)

        let ab = pb - pa
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 1e-9 else {
            return (pa.length, a)
        }

        let ap = p - pa
        // Parametric position of the projection of p onto ab, clamped to the segment.
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / lengthSquared))
        let closest = pa + ab * t
        return ((closest - p).length, frame.unproject(closest))
    }

    /// Distance from `point` to the nearest point on an ordered polyline.
    /// Returns nil for an empty path.
    static func nearestPoint(
        on path: [CLLocationCoordinate2D],
        to point: CLLocationCoordinate2D
    ) -> (distance: CLLocationDistance, closest: CLLocationCoordinate2D)? {
        guard let first = path.first else { return nil }
        guard path.count > 1 else {
            return (distance(from: point, to: first), first)
        }

        var best: (distance: CLLocationDistance, closest: CLLocationCoordinate2D) = (.greatestFiniteMagnitude, first)
        for index in 1..<path.count {
            let candidate = distance(from: point, toSegment: path[index - 1], path[index])
            if candidate.distance < best.distance {
                best = candidate
            }
        }
        return best
    }

    // MARK: - Bearings

    /// Initial great-circle bearing in degrees (0 = north, clockwise).
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = from.latitude * .pi / 180
        let lon1 = from.longitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let lon2 = to.longitude * .pi / 180

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest absolute angle between two compass bearings, 0...180.
    static func angleDifference(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }

    // MARK: - Buffered-polyline rendering

    /// Builds a closed polygon that approximates "everything within
    /// `halfWidthMeters` of this polyline" — i.e. the road corridor with its
    /// buffer, for map rendering. A `MapPolyline`'s stroke width is in screen
    /// points, so it can't represent a real-world buffer at every zoom level;
    /// a polygon can.
    ///
    /// Sharp switchbacks can self-intersect the offset on the inside of the
    /// turn. That's cosmetically fine for a translucent overlay and never
    /// affects alerting, which always uses true point-to-segment distance.
    static func bufferPolygon(
        along path: [CLLocationCoordinate2D],
        halfWidthMeters: Double,
        capSegments: Int = 8
    ) -> [CLLocationCoordinate2D] {
        let cleaned = deduplicated(path)
        let halfWidth = max(halfWidthMeters, 1)

        guard cleaned.count >= 2 else {
            guard let only = cleaned.first else { return [] }
            return circlePolygon(center: only, radiusMeters: halfWidth, segments: max(capSegments * 4, 16))
        }

        let frame = LocalFrame(origin: cleaned[0])
        let points = cleaned.map { frame.project($0) }

        // Per-vertex unit normal: bisector of the two adjacent segment
        // directions, so the offset turns smoothly at each vertex.
        var normals: [Vector2] = []
        normals.reserveCapacity(points.count)
        for index in points.indices {
            let incoming = index > 0 ? (points[index] - points[index - 1]).normalized : nil
            let outgoing = index < points.count - 1 ? (points[index + 1] - points[index]).normalized : nil
            let direction: Vector2
            switch (incoming, outgoing) {
            case let (inDir?, outDir?):
                direction = (inDir + outDir).normalized ?? inDir
            case let (inDir?, nil):
                direction = inDir
            case let (nil, outDir?):
                direction = outDir
            default:
                direction = Vector2(x: 1, y: 0)
            }
            normals.append(direction.normal)
        }

        let leftSide = zip(points, normals).map { pair in pair.0 + pair.1 * halfWidth }
        let rightSide = zip(points, normals).map { pair in pair.0 - pair.1 * halfWidth }

        var polygon: [Vector2] = leftSide

        // Rounded cap at the far end: sweep from the left offset around
        // through the direction of travel to the right offset.
        if let endNormal = normals.last, let endPoint = points.last {
            polygon += arcPoints(
                center: endPoint,
                radius: halfWidth,
                startAngle: atan2(endNormal.y, endNormal.x),
                sweep: -Double.pi,
                segments: capSegments
            )
        }

        polygon += rightSide.reversed()

        // Rounded cap at the near end, closing the ring back to leftSide[0].
        if let startNormal = normals.first, let startPoint = points.first {
            polygon += arcPoints(
                center: startPoint,
                radius: halfWidth,
                startAngle: atan2(-startNormal.y, -startNormal.x),
                sweep: -Double.pi,
                segments: capSegments
            )
        }

        return polygon.map { frame.unproject($0) }
    }

    /// Regular polygon approximating a circle, in geographic coordinates.
    static func circlePolygon(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        segments: Int = 32
    ) -> [CLLocationCoordinate2D] {
        let frame = LocalFrame(origin: center)
        let count = max(segments, 8)
        return (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return frame.unproject(Vector2(x: cos(angle) * radiusMeters, y: sin(angle) * radiusMeters))
        }
    }

    /// Interior points of an arc, excluding both endpoints (they're already
    /// contributed by the offset sides).
    private static func arcPoints(
        center: Vector2,
        radius: Double,
        startAngle: Double,
        sweep: Double,
        segments: Int
    ) -> [Vector2] {
        guard segments > 1 else { return [] }
        return (1..<segments).map { step in
            let angle = startAngle + sweep * Double(step) / Double(segments)
            return Vector2(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    /// Drops invalid coordinates and consecutive near-duplicates (< 0.5 m
    /// apart), which would otherwise produce zero-length segments and NaN
    /// normals.
    static func deduplicated(_ path: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in path where CLLocationCoordinate2DIsValid(coordinate) {
            if let last = result.last, distance(from: last, to: coordinate) < 0.5 { continue }
            result.append(coordinate)
        }
        return result
    }
}
