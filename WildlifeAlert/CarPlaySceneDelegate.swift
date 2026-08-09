import Foundation

// MARK: - CarPlay: placeholder scaffold only, NOT functional.
//
// This file intentionally contains no working CarPlay integration.
//
// CarPlay navigation apps require Apple's "CarPlay Navigation"
// entitlement (com.apple.developer.carplay-maps), which is granted
// through a manual request process in the Apple Developer portal — it is
// NOT something Xcode, xcodegen, or this codebase can enable on its own.
// That request has not been approved yet, so wiring up a real
// CPTemplateApplicationSceneDelegate here would produce a scene that
// fails to activate on-device/in CarPlay and could also complicate the
// existing iPhone target's build. Everything below is a structural stub
// so the shape of the eventual integration is visible in the codebase.
// It has zero CarPlay framework dependency and declares no scene
// configuration in Info.plist/project.yml, so it compiles harmlessly
// into the existing iPhone target without requiring any entitlement or
// affecting the app's normal (non-CarPlay) build/run in any way.
//
// Once the entitlement is granted, the real implementation would need:
//
// 1. Add `com.apple.developer.carplay-maps` to WildlifeAlert.entitlements
//    (via project.yml's `entitlements.properties`).
// 2. Add a CarPlay scene configuration to Info.plist
//    (UIApplicationSceneManifest > UISceneConfigurations >
//    CPTemplateApplicationSceneSessionRoleApplication), pointing at a
//    delegate class conforming to CPTemplateApplicationSceneDelegate.
// 3. Implement `templateApplicationScene(_:didConnect:to:)` /
//    `...didDisconnectInterfaceController:` to receive a
//    `CPInterfaceController` + `CPWindow` when CarPlay connects.
// 4. Build a `CPMapTemplate` as the root template, driven by the same
//    `RouteManager`/`DriveSimulator` state already in this app, so the
//    CarPlay screen mirrors the phone's active route.
// 5. Start a `CPNavigationSession` on that map template once a route is
//    active, and push `CPManeuver`/`CPTravelEstimates` updates using the
//    same tick callback `DriveSimulator.start(route:onTick:)` already
//    provides — the hotspot-alert logic in `AlertManager` can drive
//    `CPMapTemplate.showBanner` / `CPAlertTemplate` presentations from
//    the exact same `activeAlert` state already surfaced to the phone UI.
// 6. Mirror hotspot risk-level coloring (see `AppColors.riskFill`) onto
//    CarPlay's map overlay APIs where supported.
//
// None of the above is implemented here — this is a comment-documented
// placeholder only, per explicit scope for this build.
enum CarPlayIntegrationPlaceholder {
    /// Non-functional marker so the intent is discoverable from code
    /// search, not just this file's header comment.
    static let isImplemented = false
    static let blockedReason = "Requires Apple's CarPlay Navigation entitlement (com.apple.developer.carplay-maps), pending manual approval."
}
