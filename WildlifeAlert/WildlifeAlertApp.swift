import SwiftUI
import UIKit

@main
struct WildlifeAlertApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Exists purely to get a `CLLocationManager` delegate attached during launch.
///
/// iOS relaunches a terminated app to deliver a region-boundary crossing and
/// hands the event to whatever location-manager delegate is registered shortly
/// after launch. Waiting for SwiftUI to build `ContentView` is a race the app
/// can lose, which would mean silently dropping exactly the background warning
/// this whole feature exists to deliver.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = LocationManager.shared
        return true
    }
}
