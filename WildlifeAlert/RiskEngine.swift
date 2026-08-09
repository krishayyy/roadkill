import CoreLocation
import Foundation

struct RiskFactor: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let multiplier: Double
}

struct RiskScore {
    let percent: Int
    let nearestHotspot: Hotspot?
    let distanceMeters: Double?
    let factors: [RiskFactor]
}

enum RiskEngine {
    /// Base severity weight per hotspot, before time/season/weather/distance are applied.
    private static func baseWeight(for level: Hotspot.RiskLevel) -> Double {
        switch level {
        case .moderate: return 0.35
        case .high: return 0.6
        case .severe: return 0.85
        }
    }

    /// Deer/elk/moose are most active at dawn and dusk (crepuscular). Peaks
    /// near 6am and 7pm, troughs at midday and overnight.
    private static func timeOfDayMultiplier(hour: Double) -> (value: Double, label: String) {
        let dawnPeak = gaussian(x: hour, center: 6, width: 2.2)
        let duskPeak = gaussian(x: hour, center: 19, width: 2.5)
        let value = 0.4 + 1.1 * max(dawnPeak, duskPeak)

        let label: String
        switch hour {
        case 4..<8: label = "Dawn — peak activity"
        case 17..<21: label = "Dusk — peak activity"
        case 8..<17: label = "Midday — lower activity"
        default: label = "Night — moderate activity"
        }
        return (value, label)
    }

    private static func gaussian(x: Double, center: Double, width: Double) -> Double {
        let diff = x - center
        return exp(-(diff * diff) / (2 * width * width))
    }

    /// Fall rut (Oct-Nov) is the sharpest peak; spring green-up (Apr-May) is
    /// a secondary peak; summer/winter are baseline.
    private static func seasonalMultiplier(month: Int) -> (value: Double, label: String) {
        switch month {
        case 10, 11: return (1.5, "Fall rut season — peak movement")
        case 4, 5: return (1.15, "Spring migration — elevated movement")
        case 12, 1, 2: return (0.9, "Winter — herd movement for forage")
        default: return (0.75, "Summer — baseline movement")
        }
    }

    /// Traffic/pace signal: the same corridor is far less dangerous when the
    /// driver is crawling in congestion (more time to see and react to an
    /// animal) than when they're moving at or above the route's own
    /// expected pace on an otherwise-clear road. `expectedSpeed` is derived
    /// by the caller from the route's `distance / expectedTravelTime`
    /// (which itself already factors Apple's live traffic data), so this is
    /// a real computed comparison, not a placeholder — a driver well below
    /// that pace is, by definition, in slower-than-normal traffic for this
    /// specific route right now.
    ///
    /// `actualSpeed` should be `nil` when CLLocation's `.speed` is invalid
    /// (reported as -1) or when no route/expected pace is available yet —
    /// in that case we apply full weight rather than assume congestion,
    /// since assuming safety we can't verify would be the wrong default.
    private static func trafficMultiplier(actualSpeed: Double?, expectedSpeed: Double?) -> (value: Double, label: String) {
        guard let actualSpeed, actualSpeed >= 0, let expectedSpeed, expectedSpeed > 0 else {
            return (1.0, "Pace unknown — full weight applied")
        }

        let ratio = actualSpeed / expectedSpeed
        let mph = Int((actualSpeed * 2.23694).rounded())

        if ratio >= 0.85 {
            return (1.0, "\(mph) mph — at/above route pace, full reaction-time risk")
        } else if ratio <= 0.35 {
            return (0.45, "\(mph) mph — heavy congestion, more time to react")
        } else {
            // Linear ramp between the two anchors above so the transition
            // from "congested" to "full risk" isn't a hard step.
            let t = (ratio - 0.35) / (0.85 - 0.35)
            let value = 0.45 + t * 0.55
            return (value, "\(mph) mph — slower than route pace, some extra reaction time")
        }
    }

    private static func weatherMultiplier(_ weather: WeatherSnapshot?) -> (value: Double, label: String) {
        guard let weather else { return (1.0, "Weather unavailable") }
        switch weather.condition {
        case .fog: return (1.4, "Fog — reduced visibility")
        case .rain, .snow: return (1.25, "\(weather.conditionLabel) — reduced visibility")
        case .clear: return (1.0, "Clear conditions")
        case .cloudy: return (1.05, "Cloudy conditions")
        }
        // low light from dusk/dawn is captured separately by time-of-day
    }

    /// Distance decay: full weight inside the hotspot radius, tapering to
    /// zero by 3x the radius.
    private static func distanceMultiplier(distance: Double, radius: Double) -> Double {
        if distance <= radius { return 1.0 }
        let falloffEnd = radius * 3
        if distance >= falloffEnd { return 0.0 }
        let t = (distance - radius) / (falloffEnd - radius)
        return 1.0 - t
    }

    /// How many recent-sighting "points" push the score up by how much.
    /// Each sighting contributes a weight that decays linearly with age
    /// over the 30-day window the caller already filtered to, so a
    /// sighting from yesterday matters more than one from three weeks ago.
    /// The bump is capped so a flood of reports can't blow the score past
    /// what the underlying corridor severity/time/season/weather already
    /// justify — it nudges, it doesn't dominate.
    private static func sightingsMultiplier(
        near hotspot: Hotspot,
        sightings: [Sighting],
        now: Date
    ) -> (value: Double, count: Int, label: String)? {
        guard !sightings.isEmpty else { return nil }
        // A wider catchment than the hotspot's own alert radius: sightings
        // near but not strictly inside a corridor are still informative.
        let catchmentRadius = max(hotspot.radiusMeters * 1.5, 2000)

        var weightedTotal = 0.0
        var count = 0
        for sighting in sightings {
            // Geometry-aware: for a road-segment corridor a sighting is judged
            // by its distance to the road, not to the segment's midpoint —
            // otherwise a sighting beside one end of a long corridor would be
            // scored as if it were kilometres away.
            guard hotspot.distance(to: sighting.coordinate) <= catchmentRadius else { continue }
            let ageDays = max(0, now.timeIntervalSince(sighting.timestamp) / 86400)
            let recencyWeight = max(0, 1 - ageDays / 30) // 1.0 today -> 0.0 at 30 days
            weightedTotal += recencyWeight
            count += 1
        }

        guard count > 0 else { return nil }

        // Diminishing-returns bump: 0.06 per weighted-sighting-point, capped at 0.35.
        let bump = min(0.35, weightedTotal * 0.06)
        let value = 1.0 + bump
        let label = count == 1
            ? "1 recent sighting reported nearby — elevated"
            : "\(count) recent sightings reported nearby — elevated"
        return (value, count, label)
    }

    static func score(
        at location: CLLocation,
        date: Date,
        hotspots: [Hotspot],
        weather: WeatherSnapshot?,
        sightings: [Sighting] = [],
        routeExpectedSpeedMetersPerSecond: Double? = nil
    ) -> RiskScore {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60.0
        let month = calendar.component(.month, from: date)

        let time = timeOfDayMultiplier(hour: hour)
        let season = seasonalMultiplier(month: month)
        let weatherEffect = weatherMultiplier(weather)
        // location.speed is in m/s, or negative when CoreLocation can't
        // report a valid reading (e.g. a fresh/low-accuracy fix).
        let actualSpeed: Double? = location.speed >= 0 ? location.speed : nil
        let traffic = trafficMultiplier(actualSpeed: actualSpeed, expectedSpeed: routeExpectedSpeedMetersPerSecond)

        var best: (hotspot: Hotspot, distance: Double, score: Double)?

        for hotspot in hotspots {
            // Distance to the nearest point on the corridor's road-segment
            // polyline when it has one, falling back to the centroid when it
            // doesn't — the same helper AlertManager uses, so the score and
            // the alert can never disagree about how far away a corridor is.
            let distance = hotspot.distance(to: location.coordinate)
            let proximity = distanceMultiplier(distance: distance, radius: hotspot.radiusMeters)
            guard proximity > 0 else { continue }

            let raw = baseWeight(for: hotspot.riskLevel) * proximity * time.value * season.value * weatherEffect.value * traffic.value
            if best == nil || raw > best!.score {
                best = (hotspot, distance, raw)
            }
        }

        guard let best else {
            return RiskScore(
                percent: 0,
                nearestHotspot: nil,
                distanceMeters: nil,
                factors: [RiskFactor(label: "No hotspots nearby", detail: "Outside all known corridors", multiplier: 0)]
            )
        }

        let sightingsEffect = sightingsMultiplier(near: best.hotspot, sightings: sightings, now: date)
        let sightingsAdjustedScore = best.score * (sightingsEffect?.value ?? 1.0)

        let ruleBasedPercent = min(100, max(0, sightingsAdjustedScore * 100))

        // Additional named factor: an on-device CoreML model (trained offline
        // on a synthetic, structured dataset — see RiskMLModel.swift) predicts
        // a collision-risk probability from the same situational inputs.
        // This is blended with, not a replacement for, the rule-based score:
        // the individual rule-based factors above remain fully visible so the
        // "here's exactly how this number is computed" transparency holds.
        let mlProbability = RiskMLModel.predictProbability(
            hourOfDay: hour,
            month: month,
            distanceToCorridorMeters: best.distance,
            corridorBaseSeverity: baseWeight(for: best.hotspot.riskLevel),
            weatherCondition: weather?.condition,
            species: best.hotspot.species
        )

        let blendedPercent: Double
        let mlFactor: RiskFactor?
        if let mlProbability {
            let mlPercent = mlProbability * 100
            blendedPercent = ruleBasedPercent * 0.6 + mlPercent * 0.4
            mlFactor = RiskFactor(
                label: "ML model",
                detail: "\(Int(mlPercent.rounded()))% predicted (CoreML, synthetic-trained, 40% weight)",
                multiplier: mlProbability
            )
        } else {
            blendedPercent = ruleBasedPercent
            mlFactor = nil
        }

        var factors = [
            RiskFactor(label: "Corridor severity", detail: best.hotspot.riskLevel.rawValue, multiplier: baseWeight(for: best.hotspot.riskLevel)),
            RiskFactor(label: "Distance to corridor", detail: "\(Int(best.distance))m from \(best.hotspot.name)", multiplier: distanceMultiplier(distance: best.distance, radius: best.hotspot.radiusMeters)),
            RiskFactor(label: "Time of day", detail: time.label, multiplier: time.value),
            RiskFactor(label: "Season", detail: season.label, multiplier: season.value),
            RiskFactor(label: "Weather", detail: weatherEffect.label, multiplier: weatherEffect.value),
            RiskFactor(label: "Traffic conditions", detail: traffic.label, multiplier: traffic.value)
        ]
        if let mlFactor {
            factors.append(mlFactor)
        }
        if let sightingsEffect {
            factors.append(RiskFactor(label: "Community sightings", detail: sightingsEffect.label, multiplier: sightingsEffect.value))
        }

        let percent = Int(min(100, max(0, blendedPercent)))
        return RiskScore(percent: percent, nearestHotspot: best.hotspot, distanceMeters: best.distance, factors: factors)
    }
}
