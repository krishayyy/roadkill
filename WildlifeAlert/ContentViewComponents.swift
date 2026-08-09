import CoreLocation
import MapKit
import SwiftUI

// Presentation-only subviews extracted out of ContentView so both files stay
// well under the 500-line ceiling. Behaviour is unchanged apart from
// AlertBanner, which now shows the distance/ETA the lookahead logic computes.

struct HotspotMarker: View {
    let hotspot: Hotspot

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(AppColors.riskForeground(hotspot.riskLevel))
            .padding(6)
            .background(AppColors.riskFill(hotspot.riskLevel), in: Circle())
    }
}

/// Renders a corridor on the map: a buffered road-segment polygon when the
/// hotspot carries real road geometry, and the original circle when it
/// doesn't. Severity theming is identical in both cases.
struct HotspotOverlay: MapContent {
    let hotspot: Hotspot

    var body: some MapContent {
        if let path = hotspot.pathPoints, !hotspot.bufferPolygon.isEmpty {
            // The polygon carries the real-world buffer width (a MapPolyline's
            // stroke is measured in screen points, so it can't).
            MapPolygon(coordinates: hotspot.bufferPolygon)
                .foregroundStyle(AppColors.mapOverlayFill(hotspot.riskLevel))
                .stroke(AppColors.mapOverlayStroke(hotspot.riskLevel), lineWidth: 1.5)

            // Centreline on top, so the road itself stays legible when the
            // buffer is thin or the map is zoomed out.
            MapPolyline(coordinates: path)
                .stroke(AppColors.mapOverlayStroke(hotspot.riskLevel).opacity(0.9), lineWidth: 3)
        } else {
            MapCircle(center: hotspot.coordinate, radius: hotspot.radiusMeters)
                .foregroundStyle(AppColors.mapOverlayFill(hotspot.riskLevel))
                .stroke(AppColors.mapOverlayStroke(hotspot.riskLevel), lineWidth: 1.5)
        }
    }
}

struct AlertBanner: View {
    let alert: HotspotAlert
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(AppColors.riskForeground(alert.hotspot.riskLevel))

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(AppColors.riskForeground(alert.hotspot.riskLevel))
                Text(alert.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.riskForeground(alert.hotspot.riskLevel).opacity(0.85))
                    .lineLimit(2)
            }

            Spacer()

            // Visible acknowledge/dismiss affordance — snoozes this
            // specific hotspot so it won't immediately re-fire while the
            // driver is still passing through its radius.
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppColors.riskForeground(alert.hotspot.riskLevel).opacity(0.9))
            }
            .accessibilityLabel("Dismiss alert")
        }
        .padding()
        .background(AppColors.riskFill(alert.hotspot.riskLevel), in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8)
    }

    private var headline: String {
        alert.isInside
            ? "In \(alert.hotspot.species) crossing zone"
            : "\(alert.hotspot.species) crossing in \(alert.distanceText)"
    }
}

struct SearchBar: View {
    @Binding var text: String
    @Binding var isSearching: Bool
    let results: [MKLocalSearchCompletion]
    let onQueryChange: (String) -> Void
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search destination", text: $text)
                    .onChange(of: text) { _, newValue in
                        isSearching = !newValue.isEmpty
                        onQueryChange(newValue)
                    }
                if !text.isEmpty {
                    Button {
                        text = ""
                        isSearching = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

            if isSearching && !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results.prefix(5), id: \.self) { result in
                        Button {
                            onSelect(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).foregroundStyle(.primary)
                                Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        Divider()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 4)
            }
        }
        .shadow(radius: 6)
    }
}

struct RoutePreviewCard: View {
    let destinationName: String
    let route: MKRoute
    let onStartLive: () -> Void
    let onStartSimulated: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationName).font(.headline)
                    Text("\(formattedDistance) \u{2022} \(formattedDuration)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
            }

            // Real GPS is the primary path — this is the mode that actually
            // uses the phone's location while you drive. Simulation exists
            // for testing/demoing alert behavior without a car, and is
            // visually secondary so nobody picks it by default in real use.
            Button(action: onStartLive) {
                Label("Start Driving", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)

            Button(action: onStartSimulated) {
                Label("Simulate This Drive", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 8)
    }

    private var formattedDistance: String {
        let miles = route.distance / 1609.34
        return String(format: "%.1f mi", miles)
    }

    private var formattedDuration: String {
        let minutes = Int(route.expectedTravelTime / 60)
        return "\(minutes) min"
    }
}

/// Pre-trip retention hook: shown once a route is picked, before the driver
/// hits "Start Driving", so there's a reason to open the app before a drive
/// rather than only react to alerts mid-drive. Summarizes how many known
/// hotspots this specific route passes near (by severity) and whether
/// current traffic conditions along it mean elevated or reduced overall risk.
struct PreTripSummaryCard: View {
    let summary: PreTripSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.brown)
                Text("Wildlife risk on this route")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if summary.totalCount == 0 {
                Text("No known wildlife corridors along this route")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(severityBreakdownText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: summary.trafficIsElevated ? "car.fill" : "car.rear.and.tire.marks")
                    .foregroundStyle(summary.trafficIsElevated ? .orange : .green)
                    .font(.caption)
                Text(summary.trafficLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 6)
    }

    private var severityBreakdownText: String {
        var parts: [String] = []
        if summary.severeCount > 0 { parts.append("\(summary.severeCount) severe") }
        if summary.highCount > 0 { parts.append("\(summary.highCount) high") }
        if summary.moderateCount > 0 { parts.append("\(summary.moderateCount) moderate") }
        let breakdown = parts.joined(separator: ", ")
        let corridorWord = summary.totalCount == 1 ? "corridor" : "corridors"
        return "\(breakdown) \(corridorWord) on this route"
    }
}

struct DriveHUD: View {
    let risk: RiskScore?
    let weather: WeatherSnapshot?
    /// nil when driving live on real GPS — there's no route-completion
    /// percentage to show without a simulated position walking the polyline.
    let progress: Double?
    @Binding var showDetail: Bool
    /// Only meaningful in simulation mode — a testing control for demoing
    /// the "Traffic conditions" factor. In live mode this is ignored and a
    /// read-only real speed reading is shown instead.
    @Binding var simulatedSpeedMetersPerSecond: Double
    let isLive: Bool
    let liveSpeedMetersPerSecond: Double?
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let progress {
                    ProgressView(value: progress)
                        .tint(.blue)
                } else {
                    // Live GPS drive: no simulated position walking the
                    // route, so show that this is a real, open-ended drive
                    // rather than a fake percent-complete bar.
                    Label("Live GPS", systemImage: "location.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Spacer()
                Button(action: onStop) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
            }

            Button {
                withAnimation { showDetail.toggle() }
            } label: {
                HStack {
                    riskGauge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isAmbient ? "Area conditions" : "Collision risk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(risk?.percent ?? 0)%")
                            .font(.title2.bold())
                            .foregroundStyle(riskColor)
                        // Named right under the number, not buried in the
                        // expandable detail: the whole point is that this
                        // percentage must never be mistaken for a
                        // corridor-backed one.
                        if isAmbient {
                            Text("No corridor data here")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let weather {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(weather.conditionLabel).font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(weather.temperatureF))\u{00B0}F")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.weatherChipForeground)
                        }
                    }
                    Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showDetail, let risk {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(risk.factors) { factor in
                        HStack {
                            Text(factor.label).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(factor.detail).font(.caption).multilineTextAlignment(.trailing)
                        }
                    }
                }

                Divider()
                if isLive {
                    // Real GPS drive: show the phone's actual reported
                    // speed, read-only — there's nothing to simulate here.
                    // CLLocation reports -1 when speed is invalid (e.g. no
                    // recent fix), which is shown honestly as "—" rather
                    // than a fake 0 mph.
                    HStack {
                        Text("Current speed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let liveSpeedMetersPerSecond, liveSpeedMetersPerSecond >= 0 {
                            Text("\(Int((liveSpeedMetersPerSecond * 2.23694).rounded())) mph")
                                .font(.caption.weight(.semibold))
                        } else {
                            Text("—").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // Testing/verification control for the simulated drive:
                    // lets you drop the simulated speed to demonstrate the
                    // "Traffic conditions" factor above reacting to a real,
                    // changing input rather than a fixed constant.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Simulated speed").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int((simulatedSpeedMetersPerSecond * 2.23694).rounded())) mph")
                                .font(.caption.weight(.semibold))
                        }
                        Slider(value: $simulatedSpeedMetersPerSecond, in: 0...35)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 8)
    }

    private var riskGauge: some View {
        ZStack {
            Circle().stroke(AppColors.gaugeTrack, lineWidth: 6)
            Circle()
                .trim(from: 0, to: Double(risk?.percent ?? 0) / 100)
                .stroke(riskColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 40, height: 40)
    }

    private var isAmbient: Bool {
        risk?.basis == .ambient
    }

    private var riskColor: Color {
        isAmbient ? AppColors.ambientGaugeColor : AppColors.gaugeColor(percent: risk?.percent ?? 0)
    }
}

struct ReportSightingSheet: View {
    @Binding var species: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private let options = ["Deer", "Elk", "Moose"]

    var body: some View {
        VStack(spacing: 20) {
            Text("Report a wildlife sighting")
                .font(.headline)
                .padding(.top, 20)

            Picker("Species", selection: $species) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Text("This shares your current location with the crowdsourced sightings feed to help warn other drivers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                Button("Submit", action: onSubmit)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            Spacer()
        }
    }
}
