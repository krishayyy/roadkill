import CoreLocation
import Foundation

struct RiskFactor: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let multiplier: Double
}

struct RiskScore {
    /// What the number is actually anchored to. The UI must present these
    /// differently: a `.corridor` score is a located, data-backed risk for a
    /// specific mapped collision corridor, while an `.ambient` score is only
    /// a general-conditions estimate for an area we have no corridor data
    /// for. Collapsing the two would let "we don't know" render as "you're
    /// safe", which is the failure this distinction exists to prevent.
    enum Basis {
        case corridor
        case ambient
    }

    let percent: Int
    let basis: Basis
    let nearestHotspot: Hotspot?
    let distanceMeters: Double?
    let factors: [RiskFactor]
}

enum RiskEngine {
    /// Baseline weight for a location with no mapped collision corridor
    /// nearby. Deliberately well below `baseWeight(.moderate)` (0.35): it
    /// stands for "ordinary road, conditions only", never a located risk.
    /// With the time/season/weather/traffic multipliers this yields roughly
    /// 4% on a clear summer midday and roughly 38% at dusk during the fall
    /// rut in fog — responsive to real conditions without ever implying we
    /// know something about this specific road that we don't.
    private static let ambientBaseWeight = 0.12

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

            // Weather is deliberately NOT applied here. It's a single
            // scalar applied once to the final blended score below, so the
            // ML model's own (frequency-driven, not risk-driven) weather
            // signal can't cancel it out. Leaving it out of this loop does
            // not change which hotspot wins: the weather multiplier is the
            // same constant for every candidate.
            let raw = baseWeight(for: hotspot.riskLevel) * proximity * time.value * season.value * traffic.value
            if best == nil || raw > best!.score {
                best = (hotspot, distance, raw)
            }
        }

        // No mapped corridor in range. This used to return a hard 0%, which
        // the HUD rendered in green — telling a driver in a state we have no
        // crash data for that their collision risk was *zero*, at dusk, in
        // the rain. Absence of data is not evidence of safety, so instead we
        // fall back to the factors that are genuinely location-independent:
        // deer are crepuscular and rut in the fall everywhere, fog reduces
        // visibility everywhere, and speed governs reaction time everywhere.
        // None of that needs Iowa crash records to be true.
        //
        // Deliberately excluded: the CoreML model (its inputs are corridor
        // severity and distance-to-corridor — feeding it invented values for
        // a corridor that doesn't exist would be fabrication, not
        // inference). This path is the transparent rule-based engine alone,
        // which is exactly what the README claims happens outside the five
        // data states.
        guard let best else {
            let ambientRaw = ambientBaseWeight * time.value * season.value * weatherEffect.value * traffic.value
            return RiskScore(
                percent: Int(min(100, max(0, ambientRaw * 100))),
                basis: .ambient,
                nearestHotspot: nil,
                distanceMeters: nil,
                factors: [
                    RiskFactor(
                        label: "No corridor data",
                        detail: "No mapped collision corridor near here — general conditions only",
                        multiplier: ambientBaseWeight
                    ),
                    RiskFactor(label: "Time of day", detail: time.label, multiplier: time.value),
                    RiskFactor(label: "Season", detail: season.label, multiplier: season.value),
                    RiskFactor(label: "Weather", detail: weatherEffect.label, multiplier: weatherEffect.value),
                    RiskFactor(label: "Traffic conditions", detail: traffic.label, multiplier: traffic.value)
                ]
            )
        }

        let sightingsEffect = sightingsMultiplier(near: best.hotspot, sightings: sightings, now: date)
        let sightingsAdjustedScore = best.score * (sightingsEffect?.value ?? 1.0)

        // Everything except weather. Left unclamped here so the weather
        // multiplier below can't be swallowed by an early clamp to 100.
        let ruleBasedPercentExcludingWeather = max(0, sightingsAdjustedScore * 100)

        // Additional named factor: an on-device CoreML model (trained offline
        // on real multi-state crash records — see RiskMLModel.swift) predicts
        // a collision-risk probability from the same situational inputs.
        // This is blended with, not a replacement for, the rule-based score:
        // the individual rule-based factors above remain fully visible so the
        // "here's exactly how this number is computed" transparency holds.
        //
        // The model is queried at a FIXED "clear" weather reference rather
        // than at the driver's actual weather. This is deliberate. The
        // trained classifier predicts markedly *lower* collision probability
        // for fog/rain/snow than for clear conditions — not because bad
        // weather is safer, but because the overwhelming majority of driving
        // (and therefore of the crash records it learned from) happens in
        // clear weather, so raw event frequency swamps per-mile risk in the
        // training signal. Feeding it real weather made the final score go
        // *down* in fog, contradicting the app's own safety logic. Weather is
        // instead handled solely by `weatherMultiplier` above, which encodes
        // the visibility/reaction-time effect we actually mean. "clear" is
        // the right reference point because it's the modal training
        // condition, where the model is best calibrated.
        let mlProbability = RiskMLModel.predictProbability(
            hourOfDay: hour,
            month: month,
            distanceToCorridorMeters: best.distance,
            corridorBaseSeverity: baseWeight(for: best.hotspot.riskLevel),
            weatherCondition: .clear,
            species: best.hotspot.species
        )

        let blendedExcludingWeather: Double
        let mlFactor: RiskFactor?
        if let mlProbability {
            let mlPercent = mlProbability * 100
            blendedExcludingWeather = ruleBasedPercentExcludingWeather * 0.6 + mlPercent * 0.4
            mlFactor = RiskFactor(
                label: "ML model",
                detail: "\(Int(mlPercent.rounded()))% predicted (CoreML, weather-neutral, 40% weight)",
                multiplier: mlProbability
            )
        } else {
            blendedExcludingWeather = ruleBasedPercentExcludingWeather
            mlFactor = nil
        }

        // Applied last, to the blend as a whole. Because this multiplier is
        // >= 1.0 for every condition worse than clear and the base is
        // non-negative, worse weather can never lower the final score.
        let blendedPercent = blendedExcludingWeather * weatherEffect.value

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
        return RiskScore(percent: percent, basis: .corridor, nearestHotspot: best.hotspot, distanceMeters: best.distance, factors: factors)
    }
}
