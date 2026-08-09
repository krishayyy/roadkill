import XCTest
import CoreLocation
@testable import WildlifeAlert

/// Test double for `RouteApproachProvider` (see ApproachModels.swift). Lets
/// tests control exactly what "ahead on the route" means without depending
/// on MapKit or a real route.
private final class StubRouteApproachProvider: RouteApproachProvider {
    var result: RouteApproach?
    func approach(to hotspot: Hotspot, from coordinate: CLLocationCoordinate2D) -> RouteApproach? {
        result
    }
}

/// Tests for `AlertManager.evaluate(...)` — the anti-false-urgency alert
/// gating logic. This is the most safety-critical, previously-untested
/// decision path in the app: when to actually interrupt the driver.
final class AlertManagerTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 40.0, longitude: -105.0)

    private func coordinate(north meters: Double, of coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = GeoMath.metersPerDegreeLatitude(at: coordinate.latitude)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + meters / metersPerDegreeLat, longitude: coordinate.longitude)
    }

    private func hotspot(
        name: String = "Test Corridor",
        radius: Double = 500,
        level: Hotspot.RiskLevel = .moderate,
        at coord: CLLocationCoordinate2D? = nil
    ) -> Hotspot {
        Hotspot(name: name, coordinate: coord ?? origin, radiusMeters: radius, species: "Deer", riskLevel: level)
    }

    /// A location with an explicit (possibly invalid) course/speed, since the
    /// plain `CLLocation(latitude:longitude:)` convenience initializer
    /// already defaults both to CoreLocation's -1 "invalid" sentinel.
    private func location(
        at coord: CLLocationCoordinate2D,
        course: CLLocationDirection = -1,
        speed: CLLocationSpeed = -1
    ) -> CLLocation {
        CLLocation(
            coordinate: coord,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course,
            speed: speed,
            timestamp: Date()
        )
    }

    /// Reads a private stored property off any instance via `Mirror`. Mirror
    /// walks the actual memory layout of an instance regardless of Swift
    /// access control, so this is a legitimate (if blunt) way to assert on
    /// `AlertManager`'s internal bookkeeping without changing its API surface
    /// just to make it testable.
    private func privateValue<T>(_ instance: Any, _ label: String) -> T? {
        for child in Mirror(reflecting: instance).children where child.label == label {
            return child.value as? T
        }
        return nil
    }

    // MARK: - New entry fires; continued presence at the same level does not re-fire

    func testNewEntry_firesAlert() {
        let manager = AlertManager()
        let spot = hotspot(radius: 500)
        manager.evaluate(userLocation: location(at: origin), hotspots: [spot])

        XCTAssertNotNil(manager.activeAlert, "a brand-new entry into a hotspot's radius should raise a banner")
        XCTAssertEqual(manager.activeAlert?.hotspot.id, spot.id)
        XCTAssertTrue(manager.activeAlert?.isInside ?? false)
    }

    func testContinuedPresenceSameLevel_doesNotBreakThroughAnActiveSnooze() {
        // The observable proxy for "did this tick count as a fresh
        // fire/escalation" is whether it breaks an active snooze (only
        // escalation does, per AlertManager's documented semantics). If
        // continued presence at the same level were incorrectly treated as
        // a new fire, it would clear the snooze and the banner would
        // reappear here — which must NOT happen.
        let manager = AlertManager()
        let spot = hotspot(radius: 500, level: .moderate)

        manager.evaluate(userLocation: location(at: origin), hotspots: [spot]) // new entry, fires
        XCTAssertNotNil(manager.activeAlert)

        manager.dismissActiveAlert()
        XCTAssertNil(manager.activeAlert)

        // Still inside, same risk level, several ticks in a row.
        for _ in 0..<3 {
            manager.evaluate(userLocation: location(at: origin), hotspots: [spot])
            XCTAssertNil(manager.activeAlert, "sitting inside at the same risk level must stay snoozed, not re-fire")
        }
    }

    // MARK: - Escalation while inside re-fires and breaks snooze

    func testEscalationWhileInside_breaksActiveSnoozeAndRefires() {
        let manager = AlertManager()
        let moderateSpot = hotspot(name: "Corridor", radius: 500, level: .moderate)

        manager.evaluate(userLocation: location(at: origin), hotspots: [moderateSpot])
        XCTAssertNotNil(manager.activeAlert)

        manager.dismissActiveAlert()
        XCTAssertNil(manager.activeAlert)

        // Same corridor id, but now reported as severe — an escalation.
        // Hotspot's `id` is a `let` derived from `firestoreID` (or a fresh
        // UUID when nil), so to keep the same `id` across the "escalation"
        // we round-trip through `firestoreID`.
        manager.evaluate(userLocation: location(at: origin), hotspots: [escalatedSpotWithSameID(as: moderateSpot)])
        XCTAssertNotNil(manager.activeAlert, "an escalation should break through the snooze and re-fire")
        XCTAssertEqual(manager.activeAlert?.hotspot.riskLevel, .severe)
    }

    /// Builds a hotspot sharing `original`'s `id` (required because
    /// `Hotspot.id` is a `let` derived from `firestoreID` or a fresh UUID —
    /// there's no public initializer that both omits a firestoreID and lets
    /// the caller pin the resulting `id`), by round-tripping through
    /// `firestoreID`.
    private func escalatedSpotWithSameID(as original: Hotspot) -> Hotspot {
        Hotspot(
            name: original.name,
            coordinate: original.coordinate,
            radiusMeters: original.radiusMeters,
            species: original.species,
            riskLevel: .severe,
            firestoreID: original.id
        )
    }

    // MARK: - Dismiss snoozes only that hotspot, for the documented window

    func testDismiss_snoozesOnlyThatHotspot_documentedWindow() {
        let manager = AlertManager()

        // Confirm the documented 20-minute snooze window constant directly,
        // since the actual elapse of 20 real minutes isn't something a unit
        // test can safely wait for (see note in class doc below).
        let snoozeDuration: TimeInterval? = privateValue(manager, "snoozeDuration")
        XCTAssertEqual(snoozeDuration, 20 * 60, "snooze window should be the documented 20 minutes")

        let hotspotA = hotspot(name: "A", radius: 300, at: origin)
        // Hotspot B is farther away, but still within A's alert envelope
        // when both are supplied together, so we can prove A stays
        // suppressed while B still fires independently.
        let farPoint = coordinate(north: 250, of: origin)
        let hotspotB = hotspot(name: "B", radius: 300, at: farPoint)

        manager.evaluate(userLocation: location(at: origin), hotspots: [hotspotA])
        XCTAssertEqual(manager.activeAlert?.hotspot.name, "A")
        manager.dismissActiveAlert()
        XCTAssertNil(manager.activeAlert)

        // A stays suppressed on its own.
        manager.evaluate(userLocation: location(at: origin), hotspots: [hotspotA])
        XCTAssertNil(manager.activeAlert, "hotspot A should remain snoozed")

        // A different hotspot (B) still fires normally even while A is snoozed.
        manager.evaluate(userLocation: location(at: origin), hotspots: [hotspotB])
        XCTAssertEqual(manager.activeAlert?.hotspot.name, "B", "a different hotspot must not be affected by A's snooze")
    }

    // MARK: - Exit and re-entry counts as a fresh new entry

    func testExitAndReentry_firesAgainWithoutEscalation() {
        let manager = AlertManager()
        let spot = hotspot(radius: 300, level: .moderate)

        manager.evaluate(userLocation: location(at: origin), hotspots: [spot])
        XCTAssertNotNil(manager.activeAlert)

        // Engagement release distance is envelope * 1.25 + 100, where
        // envelope = radius + lookahead (150 minimum here since speed is
        // invalid/unknown) = 450. Release distance = 450*1.25+100 = 662.5.
        // Move well beyond that so the engagement is actually dropped.
        let farAway = coordinate(north: 5000, of: origin)
        manager.evaluate(userLocation: location(at: farAway), hotspots: [spot])
        XCTAssertNil(manager.activeAlert, "far outside the envelope, nothing should be active")

        // Note: `AlertManager` is `@Observable`, which rewrites stored
        // properties into observation-tracked storage backed by an
        // underscore-prefixed field (`_engagements`, not `engagements`).
        let engagementsAfterExit: [String: Any]? = privateValue(manager, "_engagements")
        XCTAssertEqual(engagementsAfterExit?.isEmpty, true, "engagement should be cleared once released")

        // Re-enter — this must be treated as a brand-new entry, not a stale
        // continuation, and fire again.
        manager.evaluate(userLocation: location(at: origin), hotspots: [spot])
        XCTAssertNotNil(manager.activeAlert, "re-entering after a genuine exit should fire again")
        XCTAssertEqual(manager.activeAlert?.hotspot.id, spot.id)
    }

    // MARK: - Lookahead distance

    func testLookaheadDistance_scalesWithSpeedWithinFloorAndCeiling() {
        XCTAssertEqual(AlertManager.lookaheadDistance(speedMetersPerSecond: nil), AlertManager.minimumLookaheadMeters, "unknown speed should use the floor")
        XCTAssertEqual(AlertManager.lookaheadDistance(speedMetersPerSecond: 0.5), AlertManager.minimumLookaheadMeters, "below the usable-speed threshold should use the floor")
        XCTAssertEqual(AlertManager.lookaheadDistance(speedMetersPerSecond: -1), AlertManager.minimumLookaheadMeters, "CoreLocation's invalid -1 speed should use the floor")

        // 29 m/s (~65 mph) * 25s = 725m, within [150, 1200].
        XCTAssertEqual(AlertManager.lookaheadDistance(speedMetersPerSecond: 29), 29 * AlertManager.lookaheadSeconds, accuracy: 0.01)

        // A very high speed should be clamped to the ceiling.
        XCTAssertEqual(AlertManager.lookaheadDistance(speedMetersPerSecond: 100), AlertManager.maximumLookaheadMeters)
    }

    // MARK: - Direction-aware gating (compass course, no route)

    func testDirectionGate_headingAway_doesNotAlert() {
        let manager = AlertManager()
        let radius = 300.0
        let spot = hotspot(radius: radius, at: origin)

        // Driver is north of the hotspot (hotspot is due south, bearing
        // ~180 from the driver), outside the "core zone" so heading can
        // suppress, but still within the alert envelope (radius + 150m
        // minimum lookahead = 450m).
        let driverPoint = coordinate(north: 400, of: origin)
        // Course 0 = heading north = heading away from the hotspot to the south.
        manager.evaluate(userLocation: location(at: driverPoint, course: 0), hotspots: [spot])

        XCTAssertNil(manager.activeAlert, "heading away from a corridor should not trigger an alert even when nominally close")
    }

    func testDirectionGate_headingToward_atPlausibleLookahead_doesAlert() {
        let manager = AlertManager()
        let radius = 300.0
        let spot = hotspot(radius: radius, at: origin)

        let driverPoint = coordinate(north: 400, of: origin)
        // Course 180 = heading south = heading toward the hotspot.
        manager.evaluate(userLocation: location(at: driverPoint, course: 180), hotspots: [spot])

        XCTAssertNotNil(manager.activeAlert, "heading toward a corridor at a plausible lookahead distance should alert")
        XCTAssertEqual(manager.activeAlert?.hotspot.id, spot.id)
    }

    func testDirectionGate_alreadyPastHotspot_doesNotAlert() {
        // "Already past" modeled as: hotspot is behind the driver on their
        // current heading, well outside the core zone.
        let manager = AlertManager()
        let spot = hotspot(radius: 300, at: origin)

        let driverPoint = coordinate(north: 400, of: origin) // hotspot is south of driver
        // Driver continues heading north (away/past), hotspot is behind them.
        manager.evaluate(userLocation: location(at: driverPoint, course: 10), hotspots: [spot])

        XCTAssertNil(manager.activeAlert, "a corridor behind the driver should not alert")
    }

    func testDirectionGate_insideRadius_alertsRegardlessOfHeading() {
        // Doc comment: direction is not used to suppress once inside (or
        // effectively on top of) the corridor — being inside is itself the
        // hazard.
        let manager = AlertManager()
        let spot = hotspot(radius: 300, at: origin)

        // Heading due north while standing inside a corridor whose only
        // geometry point is its own centroid — direction must not matter.
        manager.evaluate(userLocation: location(at: origin, course: 0), hotspots: [spot])

        XCTAssertNotNil(manager.activeAlert, "being inside the corridor should alert regardless of heading")
    }

    // MARK: - Route-based approach gating

    func testRouteProvider_notAhead_suppressesAlert() {
        let manager = AlertManager()
        let spot = hotspot(radius: 300, at: origin)
        let provider = StubRouteApproachProvider()
        provider.result = RouteApproach(distanceToEntryMeters: 100, isAhead: false)

        let driverPoint = coordinate(north: 400, of: origin)
        manager.evaluate(userLocation: location(at: driverPoint, course: -1), hotspots: [spot], routeProvider: provider)

        XCTAssertNil(manager.activeAlert, "route provider saying the corridor is behind should suppress the alert")
    }

    func testRouteProvider_aheadWithinLookahead_alerts() {
        let manager = AlertManager()
        let spot = hotspot(radius: 300, at: origin)
        let provider = StubRouteApproachProvider()
        provider.result = RouteApproach(distanceToEntryMeters: 100, isAhead: true)

        let driverPoint = coordinate(north: 400, of: origin)
        manager.evaluate(userLocation: location(at: driverPoint, course: -1), hotspots: [spot], routeProvider: provider)

        XCTAssertNotNil(manager.activeAlert, "route provider confirming ahead-and-within-lookahead should alert")
        XCTAssertTrue(manager.activeAlert?.usedRouteDistance ?? false)
    }

    func testRouteProvider_aheadButBeyondLookahead_doesNotAlert() {
        let manager = AlertManager()
        let spot = hotspot(radius: 300, at: origin)
        let provider = StubRouteApproachProvider()
        // Ahead on the route, but 3km away by road — far beyond even the
        // maximum lookahead (1200m), so must not alert yet.
        provider.result = RouteApproach(distanceToEntryMeters: 3000, isAhead: true)

        let driverPoint = coordinate(north: 400, of: origin)
        manager.evaluate(userLocation: location(at: driverPoint, course: -1), hotspots: [spot], routeProvider: provider)

        XCTAssertNil(manager.activeAlert, "a corridor far ahead by road should not alert yet, even if nominally within straight-line envelope")
    }

    // MARK: - Invalid speed/course sentinels degrade sensibly

    func testInvalidCourseAndSpeed_failsOpenRatherThanCrashingOrSuppressing() {
        let manager = AlertManager()
        let spot = hotspot(radius: 300, at: origin)

        // Driver near (not inside) the corridor with entirely invalid
        // course/speed (-1 sentinels). Direction can't be verified, so per
        // the documented "fails open" behaviour this should still alert
        // rather than silently suppress a safety warning.
        let driverPoint = coordinate(north: 400, of: origin)
        manager.evaluate(userLocation: location(at: driverPoint, course: -1, speed: -1), hotspots: [spot])

        XCTAssertNotNil(manager.activeAlert, "an unverifiable course must not silently suppress a warning")
        XCTAssertNil(manager.activeAlert?.secondsToEntry, "an invalid speed should yield no ETA rather than a nonsense one")
    }
}
