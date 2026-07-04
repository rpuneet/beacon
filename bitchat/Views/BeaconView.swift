//
// BeaconView.swift
// bitchat
//
// Beacon view - location sharing for mutual favorites
//

import SwiftUI
import MapKit

struct BeaconView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @ObservedObject private var beaconService = BeaconService.shared
    @ObservedObject private var favoritesService = FavoritesPersistenceService.shared
    @ObservedObject private var locationManager = LocationStateManager.shared
    @ObservedObject private var auditLog = BeaconAuditLog.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFavoriteKey: Data?
    @State private var showSettings = false
    @State private var showFullTracking = false
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var isTracking: Bool { selectedFavoriteKey != nil }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ZStack(alignment: .bottom) {
                mapView
                if let location = selectedLocation {
                    trackingOverlay(location: location)
                }
            }

            if !isTracking {
                favoritesSection
            }
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 550)
        #endif
        .onAppear {
            if let loc = locationManager.currentLocation {
                mapRegion.center = loc.coordinate
            }
            locationManager.beginTrackingMode()
            if favoritesCount > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    beaconService.pingAllFavorites()
                }
            }
        }
        .onDisappear {
            locationManager.endTrackingMode()
            beaconService.stopTracking()
        }
        .sheet(isPresented: $showSettings) {
            BeaconSettingsView()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullTracking) {
            fullTrackingView
        }
        #else
        .sheet(isPresented: $showFullTracking) {
            fullTrackingView
        }
        #endif
    }

    @ViewBuilder
    private var fullTrackingView: some View {
        if let location = selectedLocation {
            TrackingView(peerLocation: location, peerName: selectedNickname) {
                showFullTracking = false
            }
        } else {
            // Peer location vanished mid-presentation; never strand the user
            // on an empty cover with no dismiss control
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("peer unavailable")
                        .font(.bitchatSystem(size: 16, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button("close") { showFullTracking = false }
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(.green)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            Text("beacon")
                .font(.bitchatSystem(size: 18, design: .monospaced))
                .foregroundColor(textColor)

            HStack(spacing: 6) {
                if beaconService.peersWithLocationCount > 0 {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Text("\(beaconService.peersWithLocationCount)/\(favoritesCount)")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Sharing indicator: we disclosed our location recently
            if auditLog.isActivelySharing {
                Button(action: { showSettings = true }) {
                    HStack(spacing: 3) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                        Text("\(auditLog.activeSharingPeers.count)")
                            .font(.bitchatSystem(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Beacon mode toggle (auto-ping every 10s)
            Button(action: { beaconService.isBeaconModeEnabled.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: beaconService.isBeaconModeEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 14))
                    if beaconService.isBeaconModeEnabled {
                        Text("ON")
                            .font(.bitchatSystem(size: 10, weight: .semibold, design: .monospaced))
                    }
                }
                .foregroundColor(beaconService.isBeaconModeEnabled ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(beaconService.isBeaconModeEnabled ? Color.green.opacity(0.2) : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Manual ping button
            Button(action: { beaconService.pingAllFavorites() }) {
                if beaconService.isPinging {
                    ProgressView().scaleEffect(0.7).frame(width: 28, height: 28)
                } else {
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(textColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(beaconService.isPinging)

            // Privacy settings
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(textColor)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(textColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Map

    private var mapView: some View {
        GeometryReader { geo in
            ZStack {
                #if os(iOS)
                CompassMapView(
                    region: $mapRegion,
                    annotations: mapAnnotations,
                    showsUserLocation: true,
                    fitCoordinates: fitCoordinatesForTracking,
                    onAnnotationTap: { key in
                        if selectedFavoriteKey == key {
                            stopTracking()
                        } else {
                            startTracking(key)
                        }
                    }
                )
                #else
                Map(coordinateRegion: $mapRegion, showsUserLocation: true, annotationItems: mapAnnotations) { item in
                    MapAnnotation(coordinate: item.coordinate) {
                        Circle()
                            .fill(item.transport == .ble ? Color.green : Color.purple)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                            )
                            .onTapGesture {
                                if selectedFavoriteKey == item.noiseKey {
                                    stopTracking()
                                } else {
                                    startTracking(item.noiseKey)
                                }
                            }
                    }
                }
                #endif

                // Off-screen peer indicators
                ForEach(offScreenIndicators(in: geo.size), id: \.noiseKey) { indicator in
                    offScreenArrow(indicator: indicator)
                        .position(indicator.position)
                }
            }
        }
    }

    // MARK: - Off-screen Indicators

    private struct OffScreenIndicator {
        let noiseKey: Data
        let nickname: String
        let position: CGPoint
        let angle: Double
        let transport: PeerLocation.TransportType
    }

    private func offScreenIndicators(in size: CGSize) -> [OffScreenIndicator] {
        guard let userLoc = locationManager.currentLocation else { return [] }

        let margin: CGFloat = 30
        var indicators: [OffScreenIndicator] = []

        for ann in mapAnnotations {
            // Check if annotation is in visible region
            let latDelta = mapRegion.span.latitudeDelta / 2
            let lonDelta = mapRegion.span.longitudeDelta / 2
            let minLat = mapRegion.center.latitude - latDelta
            let maxLat = mapRegion.center.latitude + latDelta
            let minLon = mapRegion.center.longitude - lonDelta
            let maxLon = mapRegion.center.longitude + lonDelta

            let isVisible = ann.coordinate.latitude >= minLat && ann.coordinate.latitude <= maxLat &&
                           ann.coordinate.longitude >= minLon && ann.coordinate.longitude <= maxLon

            if !isVisible {
                // Calculate angle from center to peer
                let dLat = ann.coordinate.latitude - mapRegion.center.latitude
                let dLon = ann.coordinate.longitude - mapRegion.center.longitude
                let angle = atan2(dLon, dLat)

                // Calculate position on edge
                let centerX = size.width / 2
                let centerY = size.height / 2
                let maxRadius = min(centerX, centerY) - margin

                var x = centerX + maxRadius * CGFloat(sin(angle))
                var y = centerY - maxRadius * CGFloat(cos(angle))

                // Clamp to edges
                x = max(margin, min(size.width - margin, x))
                y = max(margin, min(size.height - margin, y))

                indicators.append(OffScreenIndicator(
                    noiseKey: ann.noiseKey,
                    nickname: ann.nickname,
                    position: CGPoint(x: x, y: y),
                    angle: angle * 180 / .pi,
                    transport: ann.transport
                ))
            }
        }
        return indicators
    }

    private func offScreenArrow(indicator: OffScreenIndicator) -> some View {
        let color: Color = indicator.transport == .ble ? .green : .purple
        return ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 28, height: 28)
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
                .rotationEffect(.degrees(indicator.angle))
        }
        .onTapGesture {
            startTracking(indicator.noiseKey)
        }
    }

    private var mapAnnotations: [BeaconAnnotation] {
        filteredFavorites.compactMap { fav in
            guard let loc = getLocation(for: fav.noiseKey), let coord = loc.coordinate else { return nil }
            return BeaconAnnotation(noiseKey: fav.noiseKey, nickname: fav.nickname, coordinate: coord, transport: loc.transport)
        }
    }

    /// When tracking, fit both user and peer in the map
    private var fitCoordinatesForTracking: [CLLocationCoordinate2D]? {
        guard let peerCoord = selectedLocation?.coordinate,
              let myLoc = locationManager.currentLocation else { return nil }
        return [myLoc.coordinate, peerCoord]
    }

    // MARK: - Tracking Overlay

    private var selectedLocation: PeerLocation? {
        guard let key = selectedFavoriteKey else { return nil }
        return getLocation(for: key)
    }

    private var selectedNickname: String {
        guard let key = selectedFavoriteKey else { return "" }
        return favoritesService.favorites[key]?.peerNickname ?? "unknown"
    }

    private func trackingOverlay(location: PeerLocation) -> some View {
        HStack(spacing: 12) {
            // Proximity indicator
            proximityView(location: location)

            VStack(alignment: .leading, spacing: 4) {
                Text(selectedNickname)
                    .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)

                // RSSI / GPS info
                HStack(spacing: 8) {
                    if let rssi = location.peerRSSI {
                        Text("\(rssi)dBm").foregroundColor(.green)
                    }
                    if let acc = location.horizontalAccuracy {
                        Text("±\(Int(acc))m").foregroundColor(.orange)
                    }
                    Text("\(Int(Date().timeIntervalSince(location.timestamp)))s ago")
                        .foregroundColor(.secondary)
                }
                .font(.bitchatSystem(size: 11, design: .monospaced))
            }

            Spacer()

            // Expand into full-screen Find mode (compass + UWB + haptics)
            Button(action: { showFullTracking = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(textColor)
            }
            .buttonStyle(.plain)

            Button(action: stopTracking) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func proximityView(location: PeerLocation) -> some View {
        let level = proximityLevel(from: location)
        let color = proximityColor(level)

        return ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 56, height: 56)
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 56, height: 56)

            if level == .arrow, let angle = bearingToTarget(location) {
                // Show arrow when outside GPS accuracy
                Image(systemName: "arrow.up")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(color)
                    .rotationEffect(.degrees(angle))
            } else {
                // Show proximity text
                Text(proximityText(level))
                    .font(.bitchatSystem(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
        }
    }

    private enum ProximityLevel { case arrow, far, near, close, here }

    private func proximityLevel(from location: PeerLocation) -> ProximityLevel {
        // If we have GPS distance and we're outside accuracy range, show arrow
        if let distance = gpsDistance(to: location),
           let myAcc = locationManager.currentLocation?.horizontalAccuracy,
           let peerAcc = location.horizontalAccuracy {
            let combinedAccuracy = myAcc + peerAcc
            if distance > combinedAccuracy {
                return .arrow
            }
        }

        // Otherwise use RSSI for proximity
        guard let rssi = location.peerRSSI else { return .far }
        if rssi > -50 { return .here }
        if rssi > -65 { return .close }
        if rssi > -80 { return .near }
        return .far
    }

    private func proximityColor(_ level: ProximityLevel) -> Color {
        switch level {
        case .arrow: return .blue
        case .far: return .blue
        case .near: return .cyan
        case .close: return .orange
        case .here: return .green
        }
    }

    private func proximityText(_ level: ProximityLevel) -> String {
        switch level {
        case .arrow: return ""
        case .far: return "FAR"
        case .near: return "NEAR"
        case .close: return "CLOSE"
        case .here: return "HERE"
        }
    }

    private func gpsDistance(to location: PeerLocation) -> Double? {
        guard let myLoc = locationManager.currentLocation,
              let peerCoord = location.coordinate else { return nil }
        let my = CLLocation(latitude: myLoc.coordinate.latitude, longitude: myLoc.coordinate.longitude)
        let peer = CLLocation(latitude: peerCoord.latitude, longitude: peerCoord.longitude)
        return my.distance(from: peer)
    }

    private func bearingToTarget(_ location: PeerLocation) -> Double? {
        guard let myLoc = locationManager.currentLocation,
              let peerCoord = location.coordinate,
              let heading = locationManager.currentHeading else { return nil }

        let lat1 = myLoc.coordinate.latitude * .pi / 180
        let lat2 = peerCoord.latitude * .pi / 180
        let dLon = (peerCoord.longitude - myLoc.coordinate.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi

        return bearing - heading
    }

    // MARK: - Favorites Section

    private var favoritesSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("favorites")
                    .font(.bitchatSystem(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
                Text("\(filteredFavorites.count)")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredFavorites.isEmpty {
                        Text("no mutual favorites")
                            .font(.bitchatSystem(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(16)
                    } else {
                        ForEach(filteredFavorites, id: \.noiseKey) { fav in
                            favoriteRow(fav)
                        }
                    }
                }
            }
            .frame(height: 150)
        }
    }

    private func favoriteRow(_ fav: FavoriteDisplayItem) -> some View {
        let location = getLocation(for: fav.noiseKey)
        let hasLocation = location?.hasLocation == true

        return Button(action: { startTracking(fav.noiseKey) }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(hasLocation ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)

                Text(fav.nickname)
                    .font(.bitchatSystem(size: 13, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                if let loc = location, let rssi = loc.peerRSSI {
                    Text("\(rssi)dBm")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                } else {
                    Text("—")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var filteredFavorites: [FavoriteDisplayItem] {
        favoritesService.favorites.compactMap { (key, rel) in
            guard rel.isFavorite else { return nil }
            return FavoriteDisplayItem(noiseKey: key, nickname: rel.peerNickname ?? "unknown")
        }
        .sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
    }

    private var favoritesCount: Int {
        favoritesService.favorites.values.filter { $0.isFavorite }.count
    }

    private func getLocation(for key: Data) -> PeerLocation? {
        beaconService.peerLocations[PeerID(publicKey: key).id]
    }

    private func startTracking(_ key: Data) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedFavoriteKey = key
        }
        beaconService.startTracking(peerNoiseKey: key)
    }

    private func stopTracking() {
        beaconService.stopTracking()
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedFavoriteKey = nil
        }
    }
}

// MARK: - Types

struct FavoriteDisplayItem {
    let noiseKey: Data
    let nickname: String
}
