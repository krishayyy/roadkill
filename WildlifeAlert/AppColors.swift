import SwiftUI
import UIKit

/// Semantic, dark-mode-aware colors for WildlifeAlert.
///
/// Night driving (dusk/dawn/night) is the app's core use case — it's
/// literally when RiskEngine's own time-of-day curve peaks — so every
/// risk-relevant surface here is tuned as an explicit light/dark pair
/// rather than relying on default system colors, which were untested in
/// dark mode before this pass. Colors are defined as dynamic `UIColor`s
/// (light/dark trait pairs) rather than plain `Color` literals so they
/// resolve correctly regardless of where `colorScheme` is read from.
enum AppColors {
    // MARK: - Risk banner / marker colors (moderate / high / severe)

    /// Background fill for the alert banner and hotspot map markers.
    /// Dark-mode variants are deepened (not just system materials) so
    /// white banner text keeps strong contrast against them at night,
    /// while light-mode variants stay bright and unmistakable in daylight.
    static func riskFill(_ level: Hotspot.RiskLevel) -> Color {
        let dynamic: UIColor
        switch level {
        case .moderate:
            dynamic = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.62, green: 0.50, blue: 0.02, alpha: 1.0)   // deep amber, readable at night
                    : UIColor(red: 0.98, green: 0.78, blue: 0.20, alpha: 1.0)   // bright yellow, daylight
            }
        case .high:
            dynamic = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.72, green: 0.36, blue: 0.06, alpha: 1.0)
                    : UIColor(red: 0.96, green: 0.52, blue: 0.14, alpha: 1.0)
            }
        case .severe:
            dynamic = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.70, green: 0.14, blue: 0.14, alpha: 1.0)
                    : UIColor(red: 0.87, green: 0.20, blue: 0.20, alpha: 1.0)
            }
        }
        return Color(uiColor: dynamic)
    }

    /// Foreground text/icon color to use on top of `riskFill`. White holds
    /// up on all three levels/both appearances given the deepened dark
    /// variants above; kept as its own function so a future palette tweak
    /// (e.g. moderate needing dark text) only needs to change one place.
    static func riskForeground(_ level: Hotspot.RiskLevel) -> Color {
        .white
    }

    /// Map overlay circle stroke/fill — slightly desaturated vs. the
    /// banner so many overlapping circles don't turn the map into a wall
    /// of color, but still distinguishable per level in both appearances.
    static func mapOverlayStroke(_ level: Hotspot.RiskLevel) -> Color {
        riskFill(level)
    }

    static func mapOverlayFill(_ level: Hotspot.RiskLevel) -> Color {
        riskFill(level).opacity(0.18)
    }

    // MARK: - Risk gauge (numeric percent, independent of hotspot level)

    static func gaugeColor(percent: Int) -> Color {
        let dynamic: UIColor
        switch percent {
        case 0..<25:
            dynamic = UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.20, green: 0.62, blue: 0.30, alpha: 1.0)
                : UIColor(red: 0.22, green: 0.70, blue: 0.36, alpha: 1.0) }
        case 25..<55:
            dynamic = UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.62, green: 0.50, blue: 0.02, alpha: 1.0)
                : UIColor(red: 0.90, green: 0.72, blue: 0.10, alpha: 1.0) }
        case 55..<80:
            dynamic = UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.72, green: 0.36, blue: 0.06, alpha: 1.0)
                : UIColor(red: 0.94, green: 0.50, blue: 0.14, alpha: 1.0) }
        default:
            dynamic = UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.70, green: 0.14, blue: 0.14, alpha: 1.0)
                : UIColor(red: 0.87, green: 0.20, blue: 0.20, alpha: 1.0) }
        }
        return Color(uiColor: dynamic)
    }

    static var gaugeTrack: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.12) })
    }

    // MARK: - Card / chip surfaces
    // These lean on system materials (.ultraThinMaterial / .thinMaterial)
    // for the blur, which already adapt automatically, but text/icons
    // drawn on top use these explicit tints so contrast doesn't degrade
    // over a bright road photo behind a thin material at night.

    static var cardBorder: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.06) })
    }

    static var weatherChipForeground: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.95, alpha: 1.0)
            : UIColor(white: 0.10, alpha: 1.0) })
    }
}
