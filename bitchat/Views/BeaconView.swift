//
// BeaconView.swift
// bitchat
//
// Track view - matches People section UI style
//

import SwiftUI
import MapKit

struct BeaconView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @StateObject private var viewModel = TrackingViewModel()
    @ObservedObject private var favoritesService = FavoritesPersistenceService.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFavoriteKey: Data?
    @State private var searchText: String = ""

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
            // Header (People section style)
            headerView

            // Map section
            mapSection

            // Favorites list (simple, no redundant counts)
            favoritesListView
        }
        .background(backgroundColor)
        .onAppear {
            startTracking()
        }
        .onDisappear {
            viewModel.trackingService.stopTracking()
            viewModel.trackingService.stopLocationAnnouncements()
        }
    }

    // MARK: - Header (People section style)

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("track")
                    .font(.bitchatSystem(size: 18, design: .monospaced))
                    .foregroundColor(textColor)

                Spacer()

                // Ping button (replaces QR icon position)
                Button(action: { viewModel.pingAll() }) {
                    Image(systemName: viewModel.isPinging ? "antenna.radiowaves.left.and.right" : "location.circle.fill")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(viewModel.isPinging ? .orange : textColor)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isPinging)

                // Close button
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }

            // Status line (like "#mesh 1 active")
            HStack(spacing: 6) {
                if viewModel.peersWithLocationCount > 0 {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
                Text("\(viewModel.peersWithLocationCount) online")
                    .foregroundColor(viewModel.peersWithLocationCount > 0 ? textColor : secondaryTextColor)
            }
            .font(.bitchatSystem(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(backgroundColor)
    }

    // MARK: - Map Section

    private var mapSection: some View {
        ZStack {
            Map(coordinateRegion: $viewModel.mapRegion,
                showsUserLocation: true,
                annotationItems: mapAnnotations) { item in
                MapAnnotation(coordinate: item.coordinate, anchorPoint: CGPoint(x: 0.5, y: 1.0)) {
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

            // Ping wave overlay
            if viewModel.isPinging {
                GeometryReader { geo in
                    MapPingWave(isAnimating: viewModel.isPinging)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }

            // Tracking popup overlay (when someone is selected)
            if let location = selectedLocation, location.hasLocation == true {
                VStack {
                    Spacer()
                    trackingPopup(nickname: selectedNickname, location: location)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Tracking Popup (minimal with colored icons)

    private func trackingPopup(nickname: String, location: PeerLocation) -> some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text(nickname)
                    .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        selectedFavoriteKey = nil
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Arrow + distance/accuracy
            HStack(spacing: 16) {
                // Direction arrow
                directionArrowView(location: location)

                VStack(alignment: .leading, spacing: 4) {
                    // Staleness
                    let staleness = Date().timeIntervalSince(location.timestamp)
                    let stalenessText = formatStaleness(staleness)

                    if let uwbDistance = location.uwbDistance {
                        Text(formatDistance(Double(uwbDistance)))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    } else if let accuracy = location.horizontalAccuracy {
                        Text("±\(Int(accuracy))m")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }

                    Text(stalenessText)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(staleness > 60 ? .orange : .secondary)
                }

                Spacer()
            }

            // Icons grid (colored icons + values only, no labels)
            iconsGridView(location: location)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func directionArrowView(location: PeerLocation) -> some View {
        let hasUWB = location.uwbDistance != nil
        let distance = location.uwbDistance.map { Double($0) } ?? 10.0
        let arrowColor = getHotColdColor(distance: distance, hasUWB: hasUWB)
        let directionAngle = getDirectionAngle(location: location)

        return ZStack {
            Circle()
                .fill(arrowColor.opacity(0.2))
                .frame(width: 56, height: 56)

            Circle()
                .stroke(arrowColor, lineWidth: 2)
                .frame(width: 56, height: 56)

            Image(systemName: hasUWB ? "arrow.up" : "location.fill")
                .font(.system(size: hasUWB ? 24 : 20, weight: .bold))
                .foregroundColor(arrowColor)
                .rotationEffect(.degrees(hasUWB ? directionAngle : 0))
        }
    }

    private func iconsGridView(location: PeerLocation) -> some View {
        let connectionIcon: String
        let connectionColor: Color
        switch location.transport {
        case .ble:
            connectionIcon = "antenna.radiowaves.left.and.right"
            connectionColor = .green
        case .relay:
            connectionIcon = "globe"
            connectionColor = .purple
        case .wifi:
            connectionIcon = "wifi"
            connectionColor = .blue
        }

        return HStack(spacing: 16) {
            // Connection type
            iconValueView(icon: connectionIcon, value: location.transport.rawValue.uppercased(), color: connectionColor)

            // Ping
            if location.pingMs > 0 {
                iconValueView(icon: "clock", value: "\(location.pingMs)ms", color: .orange)
            }

            // GPS
            if location.gpsEnabled {
                iconValueView(icon: "location", value: "ON", color: .green)
            }

            // Signal strength
            if let rssi = location.rssi {
                let signalColor: Color = rssi > -60 ? .green : (rssi > -70 ? .yellow : .red)
                iconValueView(icon: "wifi", value: "\(rssi)", color: signalColor)
            }

            Spacer()
        }
    }

    private func iconValueView(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text(value)
                .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    // MARK: - Favorites List (simple, no redundant counts)

    private var favoritesListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if filteredFavorites.isEmpty {
                    Text("no favorites")
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                } else {
                    ForEach(filteredFavorites, id: \.noiseKey) { fav in
                        favoriteRowView(fav: fav)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func favoriteRowView(fav: FavoriteMapItem) -> some View {
        let hasLocation = fav.location?.hasLocation == true
        let isSelected = selectedFavoriteKey == fav.noiseKey

        return Button(action: {
            withAnimation(.spring(response: 0.3)) {
                if selectedFavoriteKey == fav.noiseKey {
                    selectedFavoriteKey = nil
                } else {
                    selectFavorite(fav.noiseKey)
                }
            }
        }) {
            HStack(spacing: 4) {
                // Connection icon
                Image(systemName: connectionIcon(for: fav.location))
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(hasLocation ? textColor : secondaryTextColor)

                // Name
                Text(fav.nickname)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(hasLocation ? textColor : secondaryTextColor)

                // Online indicator
                if hasLocation {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                // Ping time or offline
                if hasLocation, let pingMs = fav.location?.pingMs, pingMs > 0 {
                    Text("\(pingMs)ms")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)

                    Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(secondaryTextColor)
                } else if !hasLocation {
                    Text("offline")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? textColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func connectionIcon(for location: PeerLocation?) -> String {
        guard let loc = location, loc.hasLocation == true else {
            return "circle.dashed"
        }
        if loc.uwbDistance != nil {
            return "wave.3.right"
        }
        switch loc.transport {
        case .ble:
            return "antenna.radiowaves.left.and.right"
        case .relay:
            return "globe"
        case .wifi:
            return "wifi"
        }
    }

    // MARK: - Helper Functions

    private func getHotColdColor(distance: Double, hasUWB: Bool) -> Color {
        if !hasUWB { return .green }
        if distance < 1 { return .red }
        if distance < 3 { return .orange }
        if distance < 10 { return .yellow }
        return .blue
    }

    private func getDirectionAngle(location: PeerLocation) -> Double {
        if let x = location.uwbDirectionX, let z = location.uwbDirectionZ {
            return Double(atan2(x, z)) * 180.0 / Double.pi
        }
        return 0
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance < 1 {
            return String(format: "%.0fcm", distance * 100)
        } else {
            return String(format: "%.1fm", distance)
        }
    }

    private func formatStaleness(_ seconds: TimeInterval) -> String {
        if seconds < 5 {
            return "just now"
        } else if seconds < 60 {
            return "\(Int(seconds))s ago"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m ago"
        } else {
            return "\(Int(seconds / 3600))h ago"
        }
    }

    // MARK: - Data

    private var allFavorites: [FavoriteMapItem] {
        favoritesService.favorites
            .filter { $0.value.isMutual }
            .map { (key, rel) in
                let location = getLocation(for: key)
                return FavoriteMapItem(
                    noiseKey: key,
                    nickname: rel.peerNickname,
                    location: location
                )
            }
            .sorted { $0.nickname < $1.nickname }
    }

    private var filteredFavorites: [FavoriteMapItem] {
        if searchText.isEmpty {
            return allFavorites
        }
        return allFavorites.filter {
            $0.nickname.lowercased().contains(searchText.lowercased())
        }
    }

    private var mapAnnotations: [FavoriteMapItem] {
        allFavorites.filter { $0.location?.hasLocation == true }
    }

    private func nickname(for noiseKey: Data) -> String {
        favoritesService.favorites[noiseKey]?.peerNickname ?? "Unknown"
    }

    private func getLocation(for noiseKey: Data) -> PeerLocation? {
        let hexKey = noiseKey.hexEncodedString()
        if let loc = viewModel.trackingService.peerLocations[hexKey] {
            return loc
        }
        let peerIDString = PeerID(publicKey: noiseKey).id
        return viewModel.trackingService.peerLocations[peerIDString]
    }

    // MARK: - Actions

    private func selectFavorite(_ noiseKey: Data) {
        selectedFavoriteKey = noiseKey

        if let location = getLocation(for: noiseKey),
           let coord = location.coordinate {
            viewModel.mapRegion.center = coord
            viewModel.mapRegion.span = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        }
    }

    private func startTracking() {
        viewModel.trackingService.configure(
            ble: chatViewModel.meshService,
            nostr: chatViewModel.nostrTransport
        )

        viewModel.locationManager.beginTrackingMode()
        viewModel.trackingService.startLocationAnnouncements()
        chatViewModel.refreshFavoriteNpubExchange()

        let favCount = favoritesService.favorites.values.filter { $0.isMutual }.count
        if favCount > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.pingAll()
            }
        }
    }
}

// MARK: - Supporting Views

struct FavoriteMapItem: Identifiable {
    let noiseKey: Data
    let nickname: String
    let location: PeerLocation?

    var id: Data { noiseKey }

    var coordinate: CLLocationCoordinate2D {
        location?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }
}

struct BeaconMapPin: View {
    let nickname: String
    let isSelected: Bool
    let hasUWB: Bool
    let transport: PeerLocation.TransportType

    private var pinColor: Color {
        hasUWB ? .blue : (transport == .ble ? .green : .purple)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: hasUWB ? "wave.3.right" : (transport == .ble ? "antenna.radiowaves.left.and.right" : "globe"))
                    .font(.system(size: 9))
                Text(nickname)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(pinColor.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: pinColor.opacity(0.5), radius: isSelected ? 8 : 4)

            Circle()
                .fill(pinColor)
                .frame(width: isSelected ? 24 : 18, height: isSelected ? 24 : 18)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

// MARK: - Sheet Wrapper

struct BeaconSheetView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        BeaconView()
            .environmentObject(chatViewModel)
    }
}

#Preview {
    BeaconSheetView()
}
