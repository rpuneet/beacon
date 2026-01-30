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
    @StateObject private var viewModel = BeaconViewModel()
    @ObservedObject private var favoritesService = FavoritesPersistenceService.shared
    @ObservedObject private var locationManager = LocationStateManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFavoriteKey: Data?
    @State private var pongWaves: [PongWaveItem] = []
    @State private var lastPongId: UUID?

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.gray : Color.secondary
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private var selectedLocation: PeerLocation? {
        guard let key = selectedFavoriteKey else { return nil }
        return getLocation(for: key)
    }

    private var selectedNickname: String {
        guard let key = selectedFavoriteKey else { return "" }
        return nickname(for: key)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Map (takes available space)
            mapView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Selected peer detail (if any)
            if let location = selectedLocation {
                trackingDetailView(nickname: selectedNickname, location: location)
            }

            // Favorites list (fixed height section)
            favoritesSection
        }
        .background(backgroundColor)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 550)
        #endif
        .onAppear {
            startBeacon()
        }
        .onDisappear {
            viewModel.locationManager.endTrackingMode()
            viewModel.stopBeaconMode()
        }
        .onChange(of: locationManager.currentLocation) { newLocation in
            if let loc = newLocation, !viewModel.userHasInteracted {
                withAnimation(.easeInOut(duration: 0.5)) {
                    viewModel.mapRegion.center = loc.coordinate
                }
            }
        }
        .onChange(of: viewModel.lastPongWave?.id) { newId in
            // Add new PONG wave when received
            if let newId = newId, newId != lastPongId,
               let wave = viewModel.lastPongWave {
                lastPongId = newId
                let waveItem = PongWaveItem(coordinate: wave.coordinate)
                pongWaves.append(waveItem)

                // Remove wave after animation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    pongWaves.removeAll { $0.id == waveItem.id }
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

            // Status
            HStack(spacing: 6) {
                if viewModel.peersWithLocationCount > 0 {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
                Text("\(viewModel.peersWithLocationCount)/\(viewModel.favoritesCount)")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }

            Spacer()

            #if os(iOS)
            // Compass heading toggle (iOS only - macOS has no compass)
            Button(action: { viewModel.followsHeading.toggle() }) {
                Image(systemName: viewModel.followsHeading ? "location.north.fill" : "location.north")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.followsHeading ? .blue : secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Toggle compass mode")
            #endif

            // Beacon mode toggle (auto-ping every 30s)
            Button(action: { viewModel.toggleBeaconMode() }) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isBeaconModeEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 14))
                    if viewModel.isBeaconModeEnabled {
                        Text("ON")
                            .font(.bitchatSystem(size: 10, weight: .semibold, design: .monospaced))
                    }
                }
                .foregroundColor(viewModel.isBeaconModeEnabled ? .green : secondaryTextColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(viewModel.isBeaconModeEnabled ? Color.green.opacity(0.2) : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help(viewModel.isBeaconModeEnabled ? "Auto-ping ON (every 30s)" : "Enable auto-ping")

            // Manual ping button
            Button(action: { viewModel.pingAll() }) {
                if viewModel.isPinging {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(textColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isPinging)
            .help("Ping now")

            // Close button
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
        .background(backgroundColor)
    }

    // MARK: - Map View

    private var mapView: some View {
        ZStack {
            #if os(iOS)
            // Use CompassMapView for heading support on iOS
            CompassMapView(
                region: $viewModel.mapRegion,
                annotations: compassAnnotations,
                showsUserLocation: true,
                followsHeading: viewModel.followsHeading,
                onAnnotationTap: { noiseKey in
                    withAnimation(.spring(response: 0.3)) {
                        if selectedFavoriteKey == noiseKey {
                            selectedFavoriteKey = nil
                        } else {
                            selectFavorite(noiseKey)
                        }
                    }
                },
                onMapInteraction: {
                    viewModel.userHasInteracted = true
                }
            )
            #else
            // Use regular Map on macOS
            Map(coordinateRegion: $viewModel.mapRegion,
                showsUserLocation: true,
                annotationItems: mapAnnotations + pongWaveAnnotations) { item in
                MapAnnotation(coordinate: item.coordinate, anchorPoint: CGPoint(x: 0.5, y: 0.5)) {
                    if item.isPongWave {
                        PongResponseWave(trigger: true, color: .green)
                            .allowsHitTesting(false)
                    } else {
                        BeaconMapPin(
                            nickname: nickname(for: item.noiseKey),
                            isSelected: selectedFavoriteKey == item.noiseKey,
                            hasUWB: item.location?.uwbDistance != nil,
                            transport: item.location?.transport ?? .relay
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3)) {
                                if selectedFavoriteKey == item.noiseKey {
                                    selectedFavoriteKey = nil
                                } else {
                                    selectFavorite(item.noiseKey)
                                }
                            }
                        }
                    }
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { _ in
                        viewModel.userHasInteracted = true
                    }
            )
            #endif

            // Ping wave overlay (centered on user)
            if viewModel.isPinging {
                MapPingWave(isAnimating: viewModel.isPinging)
                    .allowsHitTesting(false)
            }
        }
    }

    #if os(iOS)
    /// Annotations for CompassMapView
    private var compassAnnotations: [BeaconAnnotation] {
        mapAnnotations.filter { !$0.isPongWave }.map { item in
            BeaconAnnotation(
                noiseKey: item.noiseKey,
                nickname: item.nickname,
                coordinate: item.coordinate,
                isSelected: selectedFavoriteKey == item.noiseKey,
                hasUWB: item.location?.uwbDistance != nil,
                transport: item.location?.transport ?? .relay,
                isPongWave: false
            )
        }
    }
    #endif

    /// Convert pong waves to map annotation items
    private var pongWaveAnnotations: [FavoriteMapItem] {
        pongWaves.map { wave in
            FavoriteMapItem(
                noiseKey: Data(),  // Empty for wave items
                nickname: "",
                coordinate: wave.coordinate,
                location: nil,
                isPongWave: true,
                waveId: wave.id
            )
        }
    }

    // MARK: - Tracking Detail

    private func trackingDetailView(nickname: String, location: PeerLocation) -> some View {
        HStack(spacing: 12) {
            // Direction indicator
            directionArrowView(location: location)

            VStack(alignment: .leading, spacing: 4) {
                Text(nickname)
                    .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)

                // GPS accuracy or dash
                if location.hasLocation {
                    if let accuracy = location.horizontalAccuracy {
                        Text("GPS ±\(Int(accuracy))m")
                            .font(.bitchatSystem(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("GPS —")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Stats row: Transport + RSSI | Latency | UWB
                HStack(spacing: 10) {
                    // Transport: BLE with RSSI or Globe for relay
                    HStack(spacing: 3) {
                        if location.transport == .ble {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.green)
                            if let rssi = location.peerRSSI {
                                Text("\(rssi)dBm")
                                    .foregroundColor(.green)
                            }
                        } else {
                            Image(systemName: "globe")
                                .foregroundColor(.purple)
                        }
                    }

                    // Latency
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                            .foregroundColor(.orange)
                        Text(location.pingMs > 0 ? "\(location.pingMs)ms" : "—")
                            .foregroundColor(.orange)
                    }

                    // UWB status
                    HStack(spacing: 3) {
                        Image(systemName: "wave.3.forward")
                            .foregroundColor(location.uwbDistance != nil ? .green : .secondary)
                        if let uwbDistance = location.uwbDistance {
                            Text(formatDistance(Double(uwbDistance)))
                                .foregroundColor(.green)
                                .fontWeight(.semibold)
                        } else if location.uwbSupported {
                            Text("ready")
                                .foregroundColor(.secondary)
                        } else {
                            Text("—")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .font(.bitchatSystem(size: 10, design: .monospaced))

                // Staleness
                let staleness = Date().timeIntervalSince(location.timestamp)
                Text(formatStaleness(staleness))
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                    .foregroundColor(staleness > 60 ? .orange : .secondary)
            }

            Spacer()

            Button(action: {
                withAnimation { selectedFavoriteKey = nil }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(textColor.opacity(0.08))
    }

    private func directionArrowView(location: PeerLocation) -> some View {
        let hasUWB = location.uwbDistance != nil
        let distance = location.uwbDistance.map { Double($0) } ?? gpsDistance(to: location) ?? 100.0
        let arrowColor = getHotColdColor(distance: distance, hasUWB: hasUWB)
        let directionAngle = getDirectionAngle(location: location)
        let hasDirection = hasUWB || (location.hasLocation && locationManager.currentLocation != nil)

        return ZStack {
            Circle()
                .fill(arrowColor.opacity(0.2))
                .frame(width: 56, height: 56)

            Circle()
                .stroke(arrowColor, lineWidth: 2)
                .frame(width: 56, height: 56)

            // Always show arrow if we have direction data
            Image(systemName: "arrow.up")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(arrowColor)
                .rotationEffect(.degrees(hasDirection ? directionAngle : 0))
                .opacity(hasDirection ? 1.0 : 0.3)

            // Distance label
            if hasUWB, let uwbDist = location.uwbDistance {
                Text(formatDistance(Double(uwbDist)))
                    .font(.bitchatSystem(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(arrowColor)
                    .offset(y: 32)
            } else if let gpsDist = gpsDistance(to: location) {
                Text(formatDistance(gpsDist))
                    .font(.bitchatSystem(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                    .offset(y: 32)
            }
        }
    }

    /// Calculate GPS distance to peer
    private func gpsDistance(to location: PeerLocation) -> Double? {
        guard let myLoc = locationManager.currentLocation,
              let peerCoord = location.coordinate else { return nil }
        let myCoord = CLLocation(latitude: myLoc.coordinate.latitude, longitude: myLoc.coordinate.longitude)
        let peerLoc = CLLocation(latitude: peerCoord.latitude, longitude: peerCoord.longitude)
        return myCoord.distance(from: peerLoc)
    }

    // MARK: - Favorites Section

    private var favoritesSection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("favorites")
                    .font(.bitchatSystem(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
                Text("\(filteredFavorites.count)")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(backgroundColor)

            Divider()

            // Favorites list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredFavorites.isEmpty {
                        Text("no mutual favorites")
                            .font(.bitchatSystem(size: 13, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(filteredFavorites, id: \.noiseKey) { fav in
                            favoriteRow(fav)
                        }
                    }
                }
            }
            .frame(height: 150)
            .background(backgroundColor)
        }
    }

    // MARK: - Favorite Row

    private func favoriteRow(_ favorite: FavoriteDisplayItem) -> some View {
        let location = getLocation(for: favorite.noiseKey)
        let isSelected = selectedFavoriteKey == favorite.noiseKey
        let hasLocation = location?.hasLocation == true

        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isSelected {
                    selectedFavoriteKey = nil
                } else {
                    selectFavorite(favorite.noiseKey)
                }
            }
        }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(hasLocation ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)

                Text(favorite.nickname)
                    .font(.bitchatSystem(size: 13, design: .monospaced))
                    .foregroundColor(isSelected ? textColor : .primary)
                    .lineLimit(1)

                Spacer()

                if let loc = location {
                    if let uwbDistance = loc.uwbDistance {
                        Text(formatDistance(Double(uwbDistance)))
                            .font(.bitchatSystem(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                    } else if loc.hasLocation {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
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
            .background(isSelected ? textColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var mapAnnotations: [FavoriteMapItem] {
        filteredFavorites.compactMap { fav in
            if let loc = getLocation(for: fav.noiseKey), let coord = loc.coordinate {
                return FavoriteMapItem(noiseKey: fav.noiseKey, nickname: fav.nickname, coordinate: coord, location: loc)
            }
            return nil
        }
    }

    private var filteredFavorites: [FavoriteDisplayItem] {
        favoritesService.favorites.compactMap { (key, relationship) in
            guard relationship.isFavorite else { return nil }
            let nick = relationship.peerNickname ?? "unknown"
            return FavoriteDisplayItem(noiseKey: key, nickname: nick)
        }
        .sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
    }

    private func nickname(for noiseKey: Data) -> String {
        favoritesService.favorites[noiseKey]?.peerNickname ?? "unknown"
    }

    private func getLocation(for noiseKey: Data) -> PeerLocation? {
        let peerID = PeerID(publicKey: noiseKey)
        return viewModel.beaconService.peerLocations[peerID.id]
    }

    private func selectFavorite(_ noiseKey: Data) {
        selectedFavoriteKey = noiseKey
        if let location = getLocation(for: noiseKey), let coord = location.coordinate {
            withAnimation(.easeInOut(duration: 0.3)) {
                viewModel.mapRegion.center = coord
            }
        }
    }

    private func startBeacon() {
        viewModel.locationManager.beginTrackingMode()

        if let loc = locationManager.currentLocation {
            viewModel.mapRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }

        let favCount = favoritesService.favorites.values.filter { $0.isFavorite }.count
        if favCount > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.pingAll()
            }
        }
    }

    // MARK: - Formatting

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1 {
            return String(format: "%.0f cm", meters * 100)
        } else if meters < 1000 {
            return String(format: "%.1f m", meters)
        } else {
            return String(format: "%.1f km", meters / 1000)
        }
    }

    private func formatStaleness(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "now" }
        else if seconds < 60 { return "\(Int(seconds))s" }
        else if seconds < 3600 { return "\(Int(seconds / 60))m" }
        else { return "\(Int(seconds / 3600))h" }
    }

    private func getHotColdColor(distance: Double, hasUWB: Bool) -> Color {
        guard hasUWB else { return .blue }
        if distance < 1 { return .red }
        if distance < 3 { return .orange }
        if distance < 5 { return .yellow }
        return .blue
    }

    private func getDirectionAngle(location: PeerLocation) -> Double {
        // Prefer UWB direction if available
        if let direction = location.uwbDirection {
            return Double(atan2(direction.x, direction.z)) * 180 / .pi
        }

        // Fall back to GPS bearing
        guard let myLoc = locationManager.currentLocation,
              let peerCoord = location.coordinate else { return 0 }

        return calculateBearing(
            from: myLoc.coordinate,
            to: peerCoord
        )
    }

    /// Calculate bearing from one coordinate to another (in degrees, 0 = North)
    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        let bearing = atan2(y, x) * 180 / .pi
        return bearing  // Returns -180 to 180
    }
}

// MARK: - Supporting Types

struct FavoriteDisplayItem: Identifiable {
    let noiseKey: Data
    let nickname: String
    var id: Data { noiseKey }
}

struct FavoriteMapItem: Identifiable {
    let noiseKey: Data
    let nickname: String
    let coordinate: CLLocationCoordinate2D
    let location: PeerLocation?
    let isPongWave: Bool
    let waveId: UUID?

    init(noiseKey: Data, nickname: String, coordinate: CLLocationCoordinate2D, location: PeerLocation?, isPongWave: Bool = false, waveId: UUID? = nil) {
        self.noiseKey = noiseKey
        self.nickname = nickname
        self.coordinate = coordinate
        self.location = location
        self.isPongWave = isPongWave
        self.waveId = waveId
    }

    var id: String {
        if let waveId = waveId {
            return "wave-\(waveId.uuidString)"
        }
        return noiseKey.hexEncodedString()
    }
}

// MARK: - Map Pin View

struct BeaconMapPin: View {
    let nickname: String
    let isSelected: Bool
    let hasUWB: Bool
    let transport: PeerLocation.TransportType

    private var pinColor: Color {
        if hasUWB { return .orange }
        switch transport {
        case .ble: return .green
        case .relay: return .purple
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(pinColor)
                    .frame(width: isSelected ? 36 : 28, height: isSelected ? 36 : 28)
                    .shadow(color: pinColor.opacity(0.5), radius: isSelected ? 6 : 3)

                Image(systemName: hasUWB ? "wave.3.right" : "person.fill")
                    .font(.system(size: isSelected ? 16 : 12, weight: .semibold))
                    .foregroundColor(.white)
            }

            if isSelected {
                Text(nickname)
                    .font(.bitchatSystem(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

#Preview {
    BeaconView()
}
