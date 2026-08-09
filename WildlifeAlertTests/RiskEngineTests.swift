import XCTest
import CoreLocation
@testable import WildlifeAlert

/// Tests for `RiskEngine.score(...)` — the rule-based + ML-blended risk
/// score that drives everything the driver sees. These are written against
/// the documented behaviour in RiskEngine.swift's own comments, not against
/// whatever the code happens to currently do, so a regression in the actual
/// decay/time/season/weather/traffic/sightings math will fail these tests.
final class RiskEngineTests: XCTestCase {

    // MARK: - Fixtures

    private let origin = CLLocationCoordinate2D(latitude: 40.0, longitude: -105.0)

    /// Builds a `Date` using the device's current calendar (RiskEngine reads
    /// hour/month via `Calendar.current`, so tests must construct dates the
    /// same way rather than assuming UTC).
    private func makeDate(hour: Int, minute: Int = 0, month: Int, day: Int = 15, year: Int = 2024) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)!
    }

    /// Coordinate `meters` due north of `coordinate`, using the exact same
    /// projection RiskEngine/GeoMath use internally, so placing a point at a
    /// given "distance" produces that distance when measured back through
    /// `Hotspot.distance(to:)`.
    private func coordinate(north meters: Double, of coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = GeoMath.metersPerDegreeLatitude(at: coordinate.latitude)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + meters / metersPerDegreeLat, longitude: coordinate.longitude)
    }

    private func hotspot(
        name: String = "Test Corridor",
        radius: Double = 1000,
        species: String = "Deer",
        level: Hotspot.RiskLevel = .high,
        at coord: CLLocationCoordinate2D? = nil
    ) -> Hotspot {
        Hotspot(name: name, coordinate: coord ?? origin, radiusMeters: radius, species: species, riskLevel: level)
    }

    /// Midday (low activity), summer (baseline season), clear/no-weather,
    /// unknown pace — a neutral situation so only the factor under test
    /// varies between calls.
    private var neutralDate: Date { makeDate(hour: 12, month: 7) }

    // MARK: - Distance decay

    func testDistanceDecay_maximalInsideRadius_zeroBy3xRadius() {
        let radius = 1000.0
        let spot = hotspot(radius: radius)
        let location = { [self] (distance: Double) in
            CLLocation(latitude: coordinate(north: distance, of: origin).latitude, longitude: origin.longitude)
        }

        let atCenter = RiskEngine.score(at: location(0), date: neutralDate, hotspots: [spot], weather: nil)
        let atRadiusEdge = RiskEngine.score(at: location(radius), date: neutralDate, hotspots: [spot], weather: nil)
        let atHalfFalloff = RiskEngine.score(at: location(radius * 2), date: neutralDate, hotspots: [spot], weather: nil)
        let atFalloffEnd = RiskEngine.score(at: location(radius * 3), date: neutralDate, hotspots: [spot], weather: nil)
        let wellBeyond = RiskEngine.score(at: location(radius * 4), date: neutralDate, hotspots: [spot], weather: nil)

        // Full weight anywhere inside the radius.
        XCTAssertEqual(atCenter.percent, atRadiusEdge.percent, "score should be maximal (unchanged) anywhere inside the radius")
        XCTAssertGreaterThan(atCenter.percent, 0)

        // Strictly decaying between radius and 3x radius.
        XCTAssertLessThan(atHalfFalloff.percent, atCenter.percent, "score should decay past the radius")

        // Zero at and beyond 3x radius — falls out of range entirely, so no
        // hotspot qualifies and the engine reports "no hotspots nearby".
        XCTAssertEqual(atFalloffEnd.percent, 0, "score should reach zero by 3x radius")
        XCTAssertNil(atFalloffEnd.nearestHotspot)
        XCTAssertEqual(wellBeyond.percent, 0)
        XCTAssertNil(wellBeyond.nearestHotspot)
    }

    // MARK: - Time of day

    func testTimeOfDay_dawnAndDusk_scoreHigherThanMidday() {
        let spot = hotspot()
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        let dawn = RiskEngine.score(at: location, date: makeDate(hour: 6, month: 7), hotspots: [spot], weather: nil)
        let dusk = RiskEngine.score(at: location, date: makeDate(hour: 19, month: 7), hotspots: [spot], weather: nil)
        let midday = RiskEngine.score(at: location, date: makeDate(hour: 13, month: 7), hotspots: [spot], weather: nil)

        XCTAssertGreaterThan(dawn.percent, midday.percent, "dawn (crepuscular peak) should score higher than midday")
        XCTAssertGreaterThan(dusk.percent, midday.percent, "dusk (crepuscular peak) should score higher than midday")
    }

    // MARK: - Season

    func testSeason_fallRut_scoresHigherThanSummerBaseline() {
        let spot = hotspot()
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        let fallRut = RiskEngine.score(at: location, date: makeDate(hour: 12, month: 10), hotspots: [spot], weather: nil)
        let summer = RiskEngine.score(at: location, date: makeDate(hour: 12, month: 7), hotspots: [spot], weather: nil)

        XCTAssertGreaterThan(fallRut.percent, summer.percent, "fall rut (Oct/Nov) should score higher than summer baseline")
    }

    // MARK: - Weather

    /// NOTE ON SCOPE: this asserts the *rule-based* weather factor
    /// (`weatherMultiplier`), which is what's directly under test here and is
    /// exactly the documented fog=1.4/rain,snow=1.25/clear=1.0/cloudy=1.05
    /// values in RiskEngine.swift. It deliberately does NOT assert on the
    /// final blended `percent` for fog/rain/snow vs. clear — see
    /// `testKnownIssue_MLBlendCanInvertTheRuleBasedWeatherSignal` below for
    /// why asserting that would encode a real, confirmed product bug as
    /// "expected" behaviour.
    func testWeather_fogRainSnow_ruleBasedFactorHigherThanClear() {
        let spot = hotspot()
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        func weather(_ condition: SimpleCondition) -> WeatherSnapshot {
            WeatherSnapshot(temperatureF: 40, condition: condition, conditionLabel: "test", visibilityMeters: 1000)
        }

        func weatherFactorMultiplier(_ condition: SimpleCondition) -> Double {
            let result = RiskEngine.score(at: location, date: neutralDate, hotspots: [spot], weather: weather(condition))
            guard let factor = result.factors.first(where: { $0.label == "Weather" }) else {
                XCTFail("expected a 'Weather' factor to be present")
                return 0
            }
            return factor.multiplier
        }

        let clear = weatherFactorMultiplier(.clear)
        let fog = weatherFactorMultiplier(.fog)
        let rain = weatherFactorMultiplier(.rain)
        let snow = weatherFactorMultiplier(.snow)

        XCTAssertGreaterThan(fog, clear, "fog's rule-based weather factor should exceed clear")
        XCTAssertGreaterThan(rain, clear, "rain's rule-based weather factor should exceed clear")
        XCTAssertGreaterThan(snow, clear, "snow's rule-based weather factor should exceed clear")
        XCTAssertEqual(fog, 1.4, accuracy: 0.001)
        XCTAssertEqual(rain, 1.25, accuracy: 0.001)
        XCTAssertEqual(snow, 1.25, accuracy: 0.001)
        XCTAssertEqual(clear, 1.0, accuracy: 0.001)
    }

    /// KNOWN ISSUE (confirmed while writing this test suite, not a test
    /// mistake): once the CoreML model's prediction is blended in at 40%
    /// weight, the *final* `percent` for fog/rain/snow can come out LOWER
    /// than for clear weather, in direct contradiction of the rule-based
    /// weather factor's own intent ("Fog — reduced visibility" should mean
    /// *more* risk, not less).
    ///
    /// Root cause: `RiskMLModel`'s trained classifier predicts a much higher
    /// raw collision probability for "clear" (~0.35 in this scenario) than
    /// for fog (~0.05), rain (~0.06), or snow (~0.14) — almost certainly
    /// because the overwhelming majority of real-world driving (and
    /// therefore of the crash records the model was trained on) happens in
    /// clear weather, so raw frequency swamps per-mile/per-encounter risk in
    /// the training signal. That's a property of the training data, not a
    /// bug in RiskEngine's blend arithmetic (the 60/40 blend itself is
    /// correct — see `testMLBlend_...` above).
    ///
    /// Practical effect: a driver in fog — where visibility and reaction
    /// time are objectively worse — can see a *lower* combined risk score
    /// than the same driver in clear conditions, which undermines the
    /// safety intent of the weather factor. This is reported as a real
    /// product-level finding, not fixed here (fixing it would mean changing
    /// RiskEngine's blend weighting or retraining the model, both business
    /// logic decisions outside test-writing scope).
    ///
    /// This test pins the current, confirmed behaviour so it's visible and
    /// intentional rather than silently drifting further.
    func testKnownIssue_MLBlendCanInvertTheRuleBasedWeatherSignal() {
        let spot = hotspot()
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        func weather(_ condition: SimpleCondition) -> WeatherSnapshot {
            WeatherSnapshot(temperatureF: 40, condition: condition, conditionLabel: "test", visibilityMeters: 1000)
        }

        let clear = RiskEngine.score(at: location, date: neutralDate, hotspots: [spot], weather: weather(.clear))
        let fog = RiskEngine.score(at: location, date: neutralDate, hotspots: [spot], weather: weather(.fog))

        guard clear.factors.contains(where: { $0.label == "ML model" }) else {
            // No CoreML model available in this environment — the blend
            // can't invert anything because there's nothing to blend with.
            // Falling back to rule-based-only, fog must correctly score
            // higher, exactly like `testWeather_...` above.
            XCTAssertGreaterThan(fog.percent, clear.percent)
            return
        }

        // This assertion documents the CURRENT (undesirable) behavior. If it
        // starts failing because fog now correctly scores higher than clear,
        // that means the underlying issue has been fixed — treat a failure
        // here as good news, not a regression, and delete this test.
        XCTAssertLessThanOrEqual(fog.percent, clear.percent, "documents the current ML-blend weather inversion; see class doc comment above")
    }

    // MARK: - Severity ordering

    func testSeverityOrdering_severeHigherThanHighHigherThanModerate() {
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        let severe = RiskEngine.score(at: location, date: neutralDate, hotspots: [hotspot(level: .severe)], weather: nil)
        let high = RiskEngine.score(at: location, date: neutralDate, hotspots: [hotspot(level: .high)], weather: nil)
        let moderate = RiskEngine.score(at: location, date: neutralDate, hotspots: [hotspot(level: .moderate)], weather: nil)

        XCTAssertGreaterThan(severe.percent, high.percent, "severe corridor should score higher than high, all else equal")
        XCTAssertGreaterThan(high.percent, moderate.percent, "high corridor should score higher than moderate, all else equal")
    }

    // MARK: - No hotspots nearby

    func testNoHotspots_returnsZeroWithoutCrashing() {
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let result = RiskEngine.score(at: location, date: neutralDate, hotspots: [], weather: nil)

        XCTAssertEqual(result.percent, 0)
        XCTAssertNil(result.nearestHotspot)
        XCTAssertNil(result.distanceMeters)
        XCTAssertFalse(result.factors.isEmpty, "should still explain why the score is zero")
    }

    func testHotspotsAllOutOfRange_returnsZeroLikeNoHotspots() {
        // A hotspot exists but is far outside its own 3x-radius falloff —
        // functionally identical to having no hotspots at all.
        let farHotspot = hotspot(radius: 100, at: coordinate(north: 10_000, of: origin))
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let result = RiskEngine.score(at: location, date: neutralDate, hotspots: [farHotspot], weather: nil)

        XCTAssertEqual(result.percent, 0)
        XCTAssertNil(result.nearestHotspot)
    }

    // MARK: - Multiple overlapping hotspots

    func testOverlappingHotspots_picksHighestScoringNotJustNearest() {
        // Two hotspots both fully "inside their radius" (proximity = 1.0 for
        // both), so distance can't distinguish them — this isolates whether
        // the engine picks the max-scoring hotspot (severe) rather than an
        // arbitrary/first/nearest one when several qualify.
        let nearerButWeaker = hotspot(name: "Weak-but-near", radius: 1000, level: .moderate, at: origin)
        let fartherButStronger = hotspot(
            name: "Strong-but-far",
            radius: 1000,
            level: .severe,
            at: coordinate(north: 300, of: origin) // still inside its own 1000m radius
        )

        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let result = RiskEngine.score(
            at: location,
            date: neutralDate,
            hotspots: [nearerButWeaker, fartherButStronger],
            weather: nil
        )

        XCTAssertEqual(result.nearestHotspot?.name, "Strong-but-far", "should pick the higher-scoring hotspot, not just the nearest one")
    }

    func testOverlappingHotspots_doesNotDoubleCount() {
        // Two identical-severity hotspots overlapping the same point should
        // produce the same score as just one of them — never inflated by
        // being counted twice.
        let single = hotspot(level: .high, at: origin)
        let duplicate = hotspot(name: "Duplicate", level: .high, at: origin)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        let soloResult = RiskEngine.score(at: location, date: neutralDate, hotspots: [single], weather: nil)
        let duplicatedResult = RiskEngine.score(at: location, date: neutralDate, hotspots: [single, duplicate], weather: nil)

        XCTAssertEqual(soloResult.percent, duplicatedResult.percent, "overlapping hotspots of equal severity must not stack")
    }

    // MARK: - Recent sightings

    func testSightings_raiseScoreVsNoSightings_andRespectDocumentedCap() {
        let spot = hotspot(radius: 1000, level: .moderate)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let now = neutralDate

        func sighting(ageDays: Double) -> Sighting {
            Sighting(id: UUID().uuidString, coordinate: origin, species: "Deer", timestamp: now.addingTimeInterval(-ageDays * 86400))
        }

        let noSightings = RiskEngine.score(at: location, date: now, hotspots: [spot], weather: nil, sightings: [])
        let oneRecentSighting = RiskEngine.score(at: location, date: now, hotspots: [spot], weather: nil, sightings: [sighting(ageDays: 0)])

        XCTAssertGreaterThan(
            oneRecentSighting.percent,
            noSightings.percent,
            "a recent nearby sighting should measurably raise the score"
        )

        // Documented cap: bump = min(0.35, weightedTotal * 0.06), i.e. the
        // sightings multiplier can never exceed 1.35x regardless of volume.
        // 10 fresh sightings already exceeds the cap (10 * 0.06 = 0.6 > 0.35);
        // adding many more must not push the score any higher.
        let manySightings = (0..<10).map { _ in sighting(ageDays: 0) }
        let floodedSightings = (0..<200).map { _ in sighting(ageDays: 0) }

        let cappedResult = RiskEngine.score(at: location, date: now, hotspots: [spot], weather: nil, sightings: manySightings)
        let floodedResult = RiskEngine.score(at: location, date: now, hotspots: [spot], weather: nil, sightings: floodedSightings)

        XCTAssertEqual(
            cappedResult.percent,
            floodedResult.percent,
            "the sightings bump must be capped — a flood of reports can't keep raising the score"
        )
        XCTAssertGreaterThan(cappedResult.percent, oneRecentSighting.percent, "more (uncapped-range) sightings should still weigh more than a single one")
    }

    func testSightings_tooFarAway_doNotAffectScore() {
        let spot = hotspot(radius: 500, level: .moderate)
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let now = neutralDate

        // catchmentRadius = max(radius * 1.5, 2000) = 2000m here; put the
        // sighting well outside that.
        let farSighting = Sighting(
            id: "far",
            coordinate: coordinate(north: 50_000, of: origin),
            species: "Deer",
            timestamp: now
        )

        let withFarSighting = RiskEngine.score(at: location, date: now, hotspots: [spot], weather: nil, sightings: [farSighting])
        let withoutSighting = RiskEngine.score(at: location, date: now, hotspots: [spot], weather: nil, sightings: [])

        XCTAssertEqual(withFarSighting.percent, withoutSighting.percent, "a sighting far outside the catchment radius shouldn't move the score")
    }

    // MARK: - Traffic / pace factor

    func testTrafficMultiplier_reflectsSpeedVsExpectedPaceRatio() {
        let spot = hotspot(radius: 1000, level: .high)
        let expectedSpeed = 20.0 // m/s, ~45 mph route pace

        func location(speed: Double) -> CLLocation {
            CLLocation(
                coordinate: origin,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: 0,
                speed: speed,
                timestamp: neutralDate
            )
        }

        // ratio >= 0.85 -> full weight (1.0)
        let atFullPace = RiskEngine.score(at: location(speed: 18), date: neutralDate, hotspots: [spot], weather: nil, routeExpectedSpeedMetersPerSecond: expectedSpeed)
        // ratio <= 0.35 -> heavy congestion (0.45)
        let congested = RiskEngine.score(at: location(speed: 5), date: neutralDate, hotspots: [spot], weather: nil, routeExpectedSpeedMetersPerSecond: expectedSpeed)
        // ratio 0.6 -> linear ramp between the anchors
        let midPace = RiskEngine.score(at: location(speed: 12), date: neutralDate, hotspots: [spot], weather: nil, routeExpectedSpeedMetersPerSecond: expectedSpeed)
        // unknown pace (no route speed available) -> full weight, same as at-pace
        let unknownPace = RiskEngine.score(at: location(speed: 12), date: neutralDate, hotspots: [spot], weather: nil, routeExpectedSpeedMetersPerSecond: nil)

        XCTAssertGreaterThan(atFullPace.percent, midPace.percent, "at/above route pace should score higher than a mid-congestion pace")
        XCTAssertGreaterThan(midPace.percent, congested.percent, "mid-congestion pace should score higher than heavy congestion")
        XCTAssertEqual(unknownPace.percent, atFullPace.percent, "unknown pace should apply full weight, same as being at full route pace")
    }

    func testTrafficMultiplier_invalidSpeed_appliesFullWeightRatherThanAssumingSafety() {
        let spot = hotspot(radius: 1000, level: .high)
        // CoreLocation's -1 sentinel for an invalid speed reading.
        let location = CLLocation(
            coordinate: origin,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: -1,
            timestamp: neutralDate
        )

        let withInvalidSpeed = RiskEngine.score(at: location, date: neutralDate, hotspots: [spot], weather: nil, routeExpectedSpeedMetersPerSecond: 20)
        let atFullPaceLocation = CLLocation(
            coordinate: origin, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 18, timestamp: neutralDate
        )
        let atFullPace = RiskEngine.score(at: atFullPaceLocation, date: neutralDate, hotspots: [spot], weather: nil, routeExpectedSpeedMetersPerSecond: 20)

        XCTAssertEqual(withInvalidSpeed.percent, atFullPace.percent, "an invalid/unavailable speed reading should apply full risk weight, not assume congestion")
    }

    // MARK: - ML blend

    func testMLBlend_whenModelAvailable_isRealBlendOfRuleAndMLNotEitherAlone() {
        // Chosen so the rule-based percent stays well under the 100 clamp,
        // which would otherwise mask the blend arithmetic.
        let spot = hotspot(radius: 1000, level: .moderate, at: origin)
        let date = makeDate(hour: 12, month: 7) // midday, summer baseline
        let location = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        let result = RiskEngine.score(at: location, date: date, hotspots: [spot], weather: nil)

        let mlProbability = RiskMLModel.predictProbability(
            hourOfDay: 12,
            month: 7,
            distanceToCorridorMeters: 0,
            corridorBaseSeverity: 0.35, // baseWeight(.moderate)
            weatherCondition: nil,
            species: "Deer"
        )

        // Independently reproduce the rule-based-only percent using the same
        // documented formula RiskEngine itself uses, so this test doesn't
        // just restate the implementation — it recomputes expected output
        // from the doc-commented factors and checks the engine agrees.
        let time = 0.4 + 1.1 * max(
            exp(-pow(12.0 - 6, 2) / (2 * 2.2 * 2.2)),
            exp(-pow(12.0 - 19, 2) / (2 * 2.5 * 2.5))
        )
        let season = 0.75 // summer baseline
        let ruleBasedRaw = 0.35 * 1.0 * time * season * 1.0 * 1.0 // severity * proximity * time * season * weather * traffic
        let ruleBasedPercent = min(100, max(0, ruleBasedRaw * 100))

        if let mlProbability {
            let mlPercent = mlProbability * 100
            let expectedBlended = ruleBasedPercent * 0.6 + mlPercent * 0.4
            let expectedPercent = Int(min(100, max(0, expectedBlended)))

            XCTAssertEqual(result.percent, expectedPercent, "blended score should be exactly 60% rule-based / 40% ML when both are available")
            XCTAssertNotEqual(result.percent, Int(ruleBasedPercent), "with an ML model available the result should not equal the pure rule-based score alone (unless coincidentally identical)")
            XCTAssertTrue(result.factors.contains { $0.label == "ML model" }, "should surface the ML contribution as a named, visible factor")
        } else {
            // Graceful fallback: CoreML model unavailable in this environment.
            XCTAssertEqual(result.percent, Int(ruleBasedPercent), "with no ML model available, should fall back to the rule-based score exactly")
            XCTAssertFalse(result.factors.contains { $0.label == "ML model" })
        }
    }

    func testMLModel_unknownSpeciesAndWeather_degradesGracefullyWithoutCrashing() {
        // Species/weather combinations the model wasn't trained on should be
        // mapped to a sensible fallback (see RiskMLModel.mapSpecies/mapWeather)
        // rather than crashing or producing a nonsensical probability.
        let probability = RiskMLModel.predictProbability(
            hourOfDay: 15,
            month: 3,
            distanceToCorridorMeters: 250,
            corridorBaseSeverity: 0.6,
            weatherCondition: nil,
            species: "Deer & Elk" // not in knownSpecies; should map to Deer
        )
        if let probability {
            XCTAssertGreaterThanOrEqual(probability, 0)
            XCTAssertLessThanOrEqual(probability, 1)
        }
        // No explicit else — nil is an equally valid, documented outcome
        // (model unavailable in this test environment); the point of this
        // test is the absence of a crash and a probability within [0, 1]
        // when a value is produced.
    }
}
