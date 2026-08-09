import CoreLocation
import Foundation

/// A corridor the driver is actively approaching (or is inside), together with
/// the numbers that justify warning about it right now.
///
/// This replaces the bare `Hotspot` the banner used to show: a warning that
/// can't say *how far away* the corridor is isn't actionable, and "ahead" with
/// no number is exactly the kind of vague urgency that trains drivers to
/// ignore an app.
struct HotspotAlert: Identifiable {
    let hotspot: Hotspot
    /// Metres until the driver crosses into the corridor. 0 when already
    /// inside. When a route is active this is measured *along the route*, not
    /// as the crow flies, so it matches what the driver will actually travel.
    let distanceToEntryMeters: CLLocationDistance
    /// Seconds until entry at the current speed; nil when CoreLocation has no
    /// valid speed (reported as -1) or the driver is essentially stationary.
    let secondsToEntry: TimeInterval?
    /// True when the driver is already within the corridor.
    let isInside: Bool
    /// True when `distanceToEntryMeters` came from the active route rather
    /// than a straight-line estimate.
    let usedRouteDistance: Bool

    var id: String { hotspot.id }

    /// Compact distance string for the banner, in the units a US driver reads
    /// on road signs.
    var distanceText: String {
        if isInside { return "You're in it now" }
        let feet = distanceToEntryMeters * 3.28084
        if feet < 1000 {
            let rounded = max(100, (feet / 100).rounded() * 100)
            return "\(Int(rounded)) ft"
        }
        return String(format: "%.1f mi", distanceToEntryMeters / 1609.34)
    }

    /// "in 24 s" style ETA, or nil when speed is unknown.
    var etaText: String? {
        guard !isInside, let secondsToEntry, secondsToEntry.isFinite, secondsToEntry >= 1 else { return nil }
        return "\(Int(secondsToEntry.rounded())) s"
    }

    /// One-line summary under the headline, e.g.
    /// "High risk • 1,300 ft • 22 s • LEE County Deer Corridor".
    var subtitle: String {
        var parts = ["\(hotspot.riskLevel.rawValue) risk", distanceText]
        if let etaText { parts.append(etaText) }
        parts.append(hotspot.name)
        return parts.joined(separator: " \u{2022} ")
    }

    /// Spoken copy. Deliberately leads with the species and the distance,
    /// because that's what a driver can act on in the two seconds they'll
    /// actually be listening.
    var spokenWarning: String {
        let level = hotspot.riskLevel.rawValue.lowercased()
        if isInside {
            return "Caution. Entering \(hotspot.species) crossing zone. \(level) risk."
        }
        return "Caution. \(hotspot.species) crossing zone \(Self.spokenDistance(distanceToEntryMeters)). \(level) risk."
    }

    /// Distances a voice can say naturally — nobody wants to hear
    /// "in one thousand three hundred and forty two feet".
    static func spokenDistance(_ meters: CLLocationDistance) -> String {
        let feet = meters * 3.28084
        if feet < 800 {
            let rounded = max(100, (feet / 100).rounded() * 100)
            return "in \(Int(rounded)) feet"
        }
        let miles = meters / 1609.34
        if miles < 0.38 { return "in a quarter mile" }
        if miles < 0.75 { return "in a half mile" }
        if miles < 1.25 { return "in a mile" }
        return String(format: "in %.1f miles", miles)
    }
}

/// Where a corridor sits relative to the driver *on the route they're
/// actually following*, which is strictly better information than a compass
/// heading: a road that curves away still counts as "approaching" if the route
/// runs into the corridor a mile from here.
struct RouteApproach {
    /// Distance along the remaining route until the corridor is entered.
    /// Meaningless when `isAhead` is false.
    let distanceToEntryMeters: CLLocationDistance
    /// False when the corridor is behind the driver on this route, or the
    /// route never passes through it at all.
    let isAhead: Bool
}

/// Implemented by `RouteManager`. Kept as a protocol so `AlertManager` has no
/// dependency on MapKit and stays testable with a stub.
protocol RouteApproachProvider: AnyObject {
    /// Returns nil when there's no usable route context (no route, or the
    /// driver is too far off it to project onto it meaningfully), in which
    /// case the caller falls back to compass heading.
    func approach(to hotspot: Hotspot, from coordinate: CLLocationCoordinate2D) -> RouteApproach?
}
