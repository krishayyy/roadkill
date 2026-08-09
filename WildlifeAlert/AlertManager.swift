import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Lookahead + direction-aware alert gating.
///
/// Two problems this fixes over the original containment-only logic:
///
/// 1. **Warning too late.** Firing only once the driver is *inside* a corridor
///    is a warning about a hazard they're already in. Alerts now fire on
///    time-to-arrival: roughly `lookaheadSeconds` before the corridor edge, so
///    at highway speed the driver hears it several hundred metres out and has
///    time to slow down.
/// 2. **Warning in the wrong direction.** The old code alerted purely on
///    distance, so you could be warned about a corridor you had just driven
///    through and were leaving. Alerts are now gated on actually approaching:
///    against the remaining route polyline when a route is active, and against
///    compass course otherwise.
///
/// Everything that made the original stingy about crying wolf is preserved
/// unchanged, because that was a deliberate design decision and drivers mute
/// apps that over-alert:
///
/// - a corridor fires only on a *new* entry into its alert envelope, or on a
///   genuine severity *escalation* while still engaged;
/// - dismissing the banner snoozes that specific corridor for 20 minutes;
/// - an escalation breaks through an active snooze, because the situation has
///   genuinely changed since the driver dismissed it.
@Observable
final class AlertManager {
    var activeAlert: HotspotAlert?

    // MARK: - Lookahead tuning

    /// How far ahead in *time* to warn. 25 s is long enough to lift off and
    /// scan the verge at highway speed, short enough that the warning still
    /// feels connected to the corridor rather than arriving out of nowhere.
    /// At 65 mph (29 m/s) this is ~725 m of lookahead; at 45 mph, ~500 m.
    static let lookaheadSeconds: TimeInterval = 25

    /// Floor for the lookahead distance. Also the entire envelope when speed
    /// is unknown or the driver is stopped — at which point "time to arrival"
    /// is undefined and near-containment behaviour is the honest answer.
    static let minimumLookaheadMeters: Double = 150

    /// Ceiling, so a fast-moving fix (or a bogus speed spike) can't turn the
    /// app into a proximity radar warning about corridors a kilometre-plus
    /// away that the driver may never reach.
    static let maximumLookaheadMeters: Double = 1200

    /// Below this, CoreLocation's speed is too noisy/irrelevant to derive a
    /// meaningful time-to-arrival from (walking pace or a stale fix).
    static let minimumUsableSpeed: Double = 1.5

    /// Half-angle of the "approaching" cone around the driver's course. 80°
    /// is generous on purpose: roads curve, and GPS course is noisy. It still
    /// rejects the case that matters — driving away from a corridor, where the
    /// bearing to it is 100°+ off the direction of travel.
    static let approachHalfAngleDegrees: Double = 80

    /// Snooze window once a corridor's banner is dismissed. Unchanged.
    private let snoozeDuration: TimeInterval = 20 * 60

    // MARK: - State

    /// What we've already announced for a corridor while the driver remains
    /// continuously engaged with it. Cleared once they leave its release
    /// envelope, so a later approach counts as new again.
    private struct Engagement {
        var level: Hotspot.RiskLevel
        /// Hysteresis: the distance at which this engagement is dropped.
        /// Held wider than the envelope that created it so a fluctuating speed
        /// (and therefore a fluctuating lookahead distance) can't make the
        /// same corridor disengage and re-fire repeatedly.
        var releaseDistance: Double
    }

    private var engagements: [String: Engagement] = [:]

    /// hotspot.id -> wall-clock time its snooze expires.
    private var snoozedUntil: [String: Date] = [:]

    private let voice = VoiceAlertPlayer()

    #if canImport(UIKit)
    // Prepared ahead of time so the actual trigger has minimal latency —
    // real device only, haptics are a no-op in the Simulator.
    private let notificationFeedback = UINotificationFeedbackGenerator()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
    #endif

    // MARK: - Public API

    /// Dismiss/acknowledge the current banner. Snoozes that corridor for
    /// `snoozeDuration` and clears the active banner immediately.
    func dismissActiveAlert() {
        guard let alert = activeAlert else { return }
        snoozedUntil[alert.hotspot.id] = Date().addingTimeInterval(snoozeDuration)
        activeAlert = nil
    }

    /// Distance corresponding to `lookaheadSeconds` at the given speed,
    /// clamped. `speed` is metres/second, or nil when CoreLocation reports an
    /// invalid reading (-1).
    static func lookaheadDistance(speedMetersPerSecond speed: Double?) -> Double {
        guard let speed, speed >= minimumUsableSpeed else { return minimumLookaheadMeters }
        return min(maximumLookaheadMeters, max(minimumLookaheadMeters, speed * lookaheadSeconds))
    }

    func evaluate(
        userLocation: CLLocation,
        hotspots: [Hotspot],
        routeProvider: RouteApproachProvider? = nil
    ) {
        let now = Date()
        let coordinate = userLocation.coordinate
        let speed: Double? = userLocation.speed >= 0 ? userLocation.speed : nil
        let lookahead = Self.lookaheadDistance(speedMetersPerSecond: speed)

        var best: HotspotAlert?
        var bestDistance = Double.greatestFiniteMagnitude
        var presentIDs: Set<String> = []

        for hotspot in hotspots {
            presentIDs.insert(hotspot.id)

            // Distance to the corridor's *geometry* — the nearest point on the
            // road-segment polyline when the hotspot has one, otherwise the
            // centroid. This is the one place the circle/polyline difference
            // is resolved; everything below is geometry-agnostic.
            let geometry = hotspot.nearestGeometryPoint(to: coordinate)
            let straightLineToEntry = max(0, geometry.distance - hotspot.radiusMeters)
            let isInside = geometry.distance <= hotspot.radiusMeters
            let envelope = hotspot.radiusMeters + lookahead

            // Hysteresis first: drop a stale engagement before deciding
            // anything else about this corridor.
            if let engagement = engagements[hotspot.id], geometry.distance > engagement.releaseDistance {
                engagements.removeValue(forKey: hotspot.id)
            }

            guard geometry.distance <= envelope else { continue }

            // --- Direction gate ---------------------------------------------
            let routeApproach = routeProvider?.approach(to: hotspot, from: coordinate)
            var distanceToEntry = straightLineToEntry
            var usedRouteDistance = false
            let approaching: Bool

            if isInside || geometry.distance <= Self.coreZoneRadius(for: hotspot) {
                // Already in (or effectively on top of) the corridor. Bearing
                // to "the nearest point of a thing you are standing in" is
                // degenerate and GPS course is noisiest at low separation, so
                // direction is not used to suppress here — being inside a
                // known corridor is itself the hazard.
                approaching = true
                distanceToEntry = 0
            } else if let routeApproach {
                approaching = routeApproach.isAhead
                if routeApproach.isAhead {
                    // Along-route distance is what the driver will actually
                    // travel, which can be well over the straight-line figure
                    // on a curving road. Using it keeps the spoken distance
                    // honest.
                    distanceToEntry = routeApproach.distanceToEntryMeters
                    usedRouteDistance = true
                }
            } else {
                approaching = isApproaching(
                    course: userLocation.course,
                    from: coordinate,
                    toward: geometry.coordinate
                )
            }

            guard approaching else { continue }

            // Re-apply the lookahead budget against the along-route distance
            // when we have one: a corridor 400 m away as the crow flies but
            // 3 km ahead by road is not yet worth warning about.
            guard isInside || distanceToEntry <= lookahead else { continue }

            let alert = HotspotAlert(
                hotspot: hotspot,
                distanceToEntryMeters: distanceToEntry,
                secondsToEntry: speed.flatMap { $0 >= Self.minimumUsableSpeed ? distanceToEntry / $0 : nil },
                isInside: isInside,
                usedRouteDistance: usedRouteDistance
            )

            // --- Anti-false-urgency gating (unchanged semantics) -------------
            let previous = engagements[hotspot.id]
            let isNewEntry = previous == nil
            let isEscalation = previous.map { Self.severityRank(hotspot.riskLevel) > Self.severityRank($0.level) } ?? false

            engagements[hotspot.id] = Engagement(
                level: hotspot.riskLevel,
                releaseDistance: envelope * 1.25 + 100
            )

            if isEscalation {
                // An escalation is significant enough to break through an
                // existing snooze — the situation has genuinely changed since
                // the driver dismissed the earlier banner.
                snoozedUntil.removeValue(forKey: hotspot.id)
            }

            let snoozed = isSnoozed(hotspot, now: now)

            if (isNewEntry || isEscalation) && !snoozed {
                fireHaptic(for: hotspot.riskLevel)
                voice.speak(alert.spokenWarning)
            }

            // The visible banner shows the most imminent non-snoozed corridor,
            // and keeps showing it for as long as it's still being approached.
            if !snoozed && distanceToEntry < bestDistance {
                bestDistance = distanceToEntry
                best = alert
            }
        }

        // Corridors that disappeared from the data set entirely shouldn't keep
        // occupying engagement state.
        for id in engagements.keys where !presentIDs.contains(id) {
            engagements.removeValue(forKey: id)
        }

        activeAlert = best
    }

    // MARK: - Gating helpers

    /// Inside this distance we stop letting heading suppress the alert. Scaled
    /// off the corridor's own size, with a 75 m floor so a narrow road-segment
    /// buffer doesn't leave a zone where GPS bearing noise decides whether a
    /// driver gets warned.
    static func coreZoneRadius(for hotspot: Hotspot) -> Double {
        max(hotspot.radiusMeters * 0.35, 75)
    }

    /// True when the driver's course points within `approachHalfAngleDegrees`
    /// of the corridor.
    ///
    /// Fails *open* on an invalid course (CoreLocation reports -1 before it
    /// has a movement-derived heading, e.g. a fresh fix or a stationary
    /// device): an unverifiable direction must never silence a safety warning.
    private func isApproaching(
        course: CLLocationDirection,
        from origin: CLLocationCoordinate2D,
        toward target: CLLocationCoordinate2D
    ) -> Bool {
        guard course >= 0 else { return true }
        let bearingToHotspot = GeoMath.bearing(from: origin, to: target)
        return GeoMath.angleDifference(course, bearingToHotspot) <= Self.approachHalfAngleDegrees
    }

    private func isSnoozed(_ hotspot: Hotspot, now: Date) -> Bool {
        guard let until = snoozedUntil[hotspot.id] else { return false }
        if now >= until {
            snoozedUntil.removeValue(forKey: hotspot.id)
            return false
        }
        return true
    }

    /// Ordinal used to detect "meaningful escalation" (moderate -> high ->
    /// severe), not just any state change.
    private static func severityRank(_ level: Hotspot.RiskLevel) -> Int {
        switch level {
        case .moderate: return 0
        case .high: return 1
        case .severe: return 2
        }
    }

    /// Real device only — the Simulator has no Taptic Engine, so this is a
    /// silent no-op there, which is expected, not a bug.
    private func fireHaptic(for level: Hotspot.RiskLevel) {
        #if canImport(UIKit)
        switch level {
        case .severe:
            // Sharpest, most attention-grabbing cue for the highest-stakes case.
            notificationFeedback.notificationOccurred(.warning)
            impactFeedback.impactOccurred(intensity: 1.0)
        case .high:
            impactFeedback.impactOccurred(intensity: 0.8)
        case .moderate:
            impactFeedback.impactOccurred(intensity: 0.5)
        }
        #endif
    }
}
