import CoreLocation
import Foundation

/// A crowdsourced wildlife sighting read back from Firestore, used to close
/// the feedback loop: sightings people report actually influence the risk
/// score shown to other drivers, not just sit in the `sightings` collection
/// unused.
struct Sighting: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let species: String
    let timestamp: Date
}
