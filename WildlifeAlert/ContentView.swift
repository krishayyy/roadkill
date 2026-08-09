import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var locationManager = LocationManager.shared
    @State private var alertManager = AlertManager()
    @State private var weatherManager = WeatherManager()
    @State private var searchModel = SearchCompleterModel()
    @State private var routeManager = RouteManager()
    @State private var driveSimulator = DriveSimulator()
    @State private var firestoreManager = FirestoreManager()

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var selectedDestination: MKMapItem?
    @State private var currentRisk: RiskScore?
    @State private var showRiskDetail = false
    @State private var weatherTickCounter = 0
    @State private var showReportSheet = false
    @State private var reportSpecies = "Deer"
    @State private var showReportConfirmation = false

    /// Stable per-install identifier attached to crowdsourced sighting
    /// reports, persisted so repeat reports from this device are attributable
    /// without collecting any personal data.
    private static let deviceID: UUID = {
        let key = "wildlifeAlert.deviceID"
        if let stored = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: key)
        return fresh
    }()

    private var displayLocation: CLLocation? {
        driveSimulator.simulatedLocation ?? locationManager.userLocation
    }

    /// Night driving is this app's core pitch (dusk/dawn/night is exactly
    /// when RiskEngine's time-of-day curve peaks), so the map defaults to
    /// a dark map style during night hours regardless of the system
    /// appearance — a driver in light mode at 9pm still gets the
    /// lower-glare, higher-contrast night map. Daytime hours simply follow
    /// the system appearance as before.
    private var isNightHours: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 20 || hour < 6
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                UserAnnotation()

                ForEach(firestoreManager.hotspots) { hotspot in
                    Annotation(hotspot.name, coordinate: hotspot.coordinate) {
                        HotspotMarker(hotspot: hotspot)
                    }
                    HotspotOverlay(hotspot: hotspot)
                }

                if let route = routeManager.route {
                    MapPolyline(route.polyline)
                        .stroke(.blue, lineWidth: 5)
                }

                if let simulated = driveSimulator.simulatedLocation {
                    Annotation("You", coordinate: simulated.coordinate) {
                        Image(systemName: "location.north.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)
                            .rotationEffect(.degrees(driveSimulator.heading))
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .environment(\.colorScheme, isNightHours ? .dark : systemColorScheme)
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 10) {
                if !driveSimulator.isDriving {
                    SearchBar(
                        text: $searchText,
                        isSearching: $isSearching,
                        results: searchModel.results,
                        onQueryChange: { query in
                            let region = locationManager.userLocation.map {
                                MKCoordinateRegion(center: $0.coordinate, span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
                            }
                            searchModel.update(query: query, region: region)
                        },
                        onSelect: { completion in
                            Task { await selectDestination(completion) }
                        }
                    )
                }

                if let alert = alertManager.activeAlert {
                    AlertBanner(alert: alert, onDismiss: { alertManager.dismissActiveAlert() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.spring, value: alertManager.activeAlert?.id)
                }

                Spacer()

                if let route = routeManager.route, !driveSimulator.isDriving {
                    VStack(spacing: 10) {
                        if let summary = routeManager.preTripSummary(hotspots: firestoreManager.hotspots) {
                            PreTripSummaryCard(summary: summary)
                        }
                        RoutePreviewCard(
                            destinationName: routeManager.destinationName ?? "Destination",
                            route: route,
                            onStart: { startDriving(route: route) },
                            onCancel: { routeManager.clear() }
                        )
                    }
                }

                if driveSimulator.isDriving {
                    DriveHUD(
                        risk: currentRisk,
                        weather: weatherManager.current,
                        progress: driveSimulator.progress,
                        showDetail: $showRiskDetail,
                        simulatedSpeedMetersPerSecond: $driveSimulator.speedMetersPerSecond,
                        onStop: stopDriving
                    )
                }

                if !driveSimulator.isDriving {
                    HStack {
                        Spacer()
                        Button {
                            showReportSheet = true
                        } label: {
                            Label("Report a sighting", systemImage: "pawprint.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brown)
                    }
                }
            }
            .padding(.top, 54)
            .padding(.horizontal)

            if showReportConfirmation {
                VStack {
                    Spacer()
                    Text("Sighting reported — thanks!")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
                .transition(.opacity)
            }
        }
        .task {
            // Hand the region monitor a live view of the corridor set so it
            // can re-select the nearest 19 as the driver moves. It falls back
            // to its own persisted cache on a cold, region-triggered launch
            // where Firestore hasn't answered yet.
            locationManager.regionMonitor.hotspotsProvider = { firestoreManager.hotspots }
            locationManager.requestPermission()
        }
        .sheet(isPresented: $showReportSheet) {
            ReportSightingSheet(
                species: $reportSpecies,
                onSubmit: { submitSighting() },
                onCancel: { showReportSheet = false }
            )
            .presentationDetents([.height(280)])
        }
        .onChange(of: firestoreManager.hotspots.count) { _, _ in
            guard let coordinate = displayLocation?.coordinate else { return }
            locationManager.regionMonitor.refreshIfNeeded(around: coordinate, force: true)
        }
        .onChange(of: locationManager.userLocation) { _, newLocation in
            guard let newLocation, !driveSimulator.isDriving else { return }
            recalculateRisk(at: newLocation)
            withAnimation {
                cameraPosition = .region(
                    MKCoordinateRegion(center: newLocation.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
                )
            }
        }
    }

    private func selectDestination(_ completion: MKLocalSearchCompletion) async {
        isSearching = false
        searchText = completion.title
        guard let mapItem = await routeManager.resolve(completion: completion) else { return }
        selectedDestination = mapItem
        guard let origin = locationManager.userLocation?.coordinate else { return }
        await routeManager.calculateRoute(from: origin, to: mapItem)
        if let route = routeManager.route {
            withAnimation {
                cameraPosition = .rect(route.polyline.boundingMapRect)
            }
        }
    }

    private func startDriving(route: MKRoute) {
        driveSimulator.start(route: route) { location in
            recalculateRisk(at: location)
            withAnimation(.linear(duration: 1)) {
                cameraPosition = .camera(
                    MapCamera(centerCoordinate: location.coordinate, distance: 900, heading: driveSimulator.heading, pitch: 60)
                )
            }
            weatherTickCounter += 1
            if weatherTickCounter % 15 == 0 {
                Task { await weatherManager.refresh(for: location) }
            }
        }
        Task { await weatherManager.refresh(for: route.polyline.coordinate.clLocation) }
    }

    private func stopDriving() {
        driveSimulator.stop()
        routeManager.clear()
        currentRisk = nil
    }

    private func recalculateRisk(at location: CLLocation) {
        let hotspots = firestoreManager.hotspots
        // Passing the route manager in is what lets AlertManager prefer
        // "is this corridor ahead of me on the road I'm actually driving"
        // over a raw compass-heading test.
        alertManager.evaluate(
            userLocation: location,
            hotspots: hotspots,
            routeProvider: routeManager
        )
        currentRisk = RiskEngine.score(
            at: location,
            date: Date(),
            hotspots: hotspots,
            weather: weatherManager.current,
            sightings: firestoreManager.recentSightings,
            routeExpectedSpeedMetersPerSecond: routeManager.expectedSpeedMetersPerSecond
        )
    }

    private func submitSighting() {
        showReportSheet = false
        let location = displayLocation ?? locationManager.userLocation
        guard let coordinate = location?.coordinate else { return }
        firestoreManager.reportSighting(coordinate: coordinate, species: reportSpecies, deviceID: Self.deviceID)
        withAnimation { showReportConfirmation = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { showReportConfirmation = false }
        }
    }
}

private extension CLLocationCoordinate2D {
    var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

#Preview {
    ContentView()
}
