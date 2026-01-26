//
// BeaconView.swift
// bitchat
//
// Full-screen beacon tracking view with map and friend list drawer
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
    @State private var drawerExpanded: Bool = false
    @State private var searchText: String = ""

    private var beaconGreen: Color {
        Color(red: 0.2, green: 0.8, blue: 0.4)
    }

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.gray : Color.secondary
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    // Selected friend's location for overlay
    private var selectedLocation: PeerLocation? {
        guard let key = selectedFavoriteKey else { return nil }
        return getLocation(for: key)
    }

    private var selectedNickname: String {
        guard let key = selectedFavoriteKey else { return "" }
        return nickname(for: key)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Map section
                mapSection
                    .frame(height: drawerExpanded ? geometry.size.height * 0.4 : geometry.size.height * 0.65)

                // Drawer section
                drawerSection
            }
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

            // Top controls overlay (Close + Ping)
            VStack {
                HStack {
                    // Close button
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Status indicator
                    if viewModel.isPinging {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("pinging...")
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    } else if viewModel.peersWithLocationCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("\(viewModel.peersWithLocationCount) online")
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }

                    Spacer()

                    // Ping button
                    Button(action: { viewModel.pingAll() }) {
                        Image(systemName: viewModel.isPinging ? "antenna.radiowaves.left.and.right" : "location.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(beaconGreen)
                            .clipShape(Circle())
                            .shadow(color: beaconGreen.opacity(0.4), radius: 4, y: 2)
                    }
                    .disabled(viewModel.isPinging)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Spacer()

                // Tracking overlay (when someone is selected)
                if let location = selectedLocation, location.hasLocation == true {
                    trackingOverlay(nickname: selectedNickname, location: location)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Tracking Overlay (replaces sheet)

    private func trackingOverlay(nickname: String, location: PeerLocation) -> some View {
        VStack(spacing: 0) {
            // Header with close
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
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Direction indicator or hot/cold
            if let uwbDistance = location.uwbDistance {
                // UWB available - show direction arrow and hot/cold
                uwbTrackingView(location: location, distance: Double(uwbDistance))
            } else {
                // GPS only - show hot/cold based on accuracy or simple indicator
                gpsTrackingView(location: location)
            }

            // Details grid
            trackingDetailsGrid(location: location)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func uwbTrackingView(location: PeerLocation, distance: Double) -> some View {
        let hotColdColor = getHotColdColor(distance: distance)
        let hotColdText = getHotColdText(distance: distance)
        let directionAngle = getDirectionAngle(location: location)

        return HStack(spacing: 16) {
            // Direction arrow
            ZStack {
                Circle()
                    .fill(hotColdColor.opacity(0.2))
                    .frame(width: 60, height: 60)

                Circle()
                    .stroke(hotColdColor, lineWidth: 3)
                    .frame(width: 60, height: 60)

                Image(systemName: "arrow.up")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(hotColdColor)
                    .rotationEffect(.degrees(directionAngle))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(hotColdText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(hotColdColor)

                Text(formatDistance(distance))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func gpsTrackingView(location: PeerLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(beaconGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text("GPS Location")
                    .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)

                if let accuracy = location.horizontalAccuracy {
                    Text("±\(Int(accuracy))m accuracy")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func trackingDetailsGrid(location: PeerLocation) -> some View {
        let details: [(String, String, String)] = {
            var items: [(String, String, String)] = []

            // Connection type
            let connectionIcon: String
            switch location.transport {
            case .ble:
                connectionIcon = "antenna.radiowaves.left.and.right"
            case .relay:
                connectionIcon = "globe"
            case .wifi:
                connectionIcon = "wifi"
            }
            items.append((connectionIcon, "Connection", location.transport.rawValue.uppercased()))

            // Ping
            if location.pingMs > 0 {
                items.append(("clock", "Ping", "\(location.pingMs)ms"))
            }

            // GPS status
            if location.gpsEnabled {
                items.append(("location", "GPS", "Enabled"))
            }

            // RSSI (signal strength)
            if let rssi = location.rssi {
                let signalStrength: String
                if rssi > -50 {
                    signalStrength = "Excellent"
                } else if rssi > -60 {
                    signalStrength = "Good"
                } else if rssi > -70 {
                    signalStrength = "Fair"
                } else {
                    signalStrength = "Weak"
                }
                items.append(("wifi", "Signal", "\(signalStrength) (\(rssi)dBm)"))
            }

            return items
        }()

        return LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 8) {
            ForEach(details, id: \.1) { icon, label, value in
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.bitchatSystem(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(value)
                            .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Drawer Section (People-style UI)

    private var drawerSection: some View {
        VStack(spacing: 0) {
            // Drawer handle
            drawerHandle

            // Header (People-style)
            drawerHeader

            // Search bar (when expanded)
            if drawerExpanded {
                searchBar
            }

            // Friend list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if filteredFavorites.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(filteredFavorites, id: \.noiseKey) { fav in
                            BeaconFriendRow(
                                nickname: fav.nickname,
                                location: fav.location,
                                isSelected: selectedFavoriteKey == fav.noiseKey,
                                textColor: textColor,
                                secondaryTextColor: secondaryTextColor,
                                colorScheme: colorScheme,
                                onTap: {
                                    withAnimation(.spring(response: 0.3)) {
                                        if selectedFavoriteKey == fav.noiseKey {
                                            selectedFavoriteKey = nil
                                        } else {
                                            selectFavorite(fav.noiseKey)
                                        }
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .background(backgroundColor)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: drawerExpanded)
    }

    private var drawerHandle: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.gray.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                drawerExpanded.toggle()
            }
        }
    }

    private var drawerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("beacon")
                    .font(.bitchatSystem(size: 18, design: .monospaced))
                    .foregroundColor(textColor)

                Spacer()
            }

            // Active count (like "#mesh 1 active")
            HStack(spacing: 6) {
                if viewModel.peersWithLocationCount > 0 {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
                Text("\(mutualFavoritesCount) friends")
                    .foregroundColor(beaconGreen)
                if viewModel.peersWithLocationCount > 0 {
                    Text("\(viewModel.peersWithLocationCount) online")
                        .foregroundColor(secondaryTextColor)
                }
            }
            .font(.bitchatSystem(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(secondaryTextColor)

            TextField("search friends...", text: $searchText)
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundColor(textColor)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(secondaryTextColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("no mutual favorites nearby")
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(secondaryTextColor)
                .padding(.horizontal, 16)
                .padding(.top, 12)
        }
    }

    // MARK: - Helper Functions

    private func getHotColdColor(distance: Double) -> Color {
        if distance < 1 { return .red }        // Very close - HOT
        if distance < 3 { return .orange }     // Close - WARM
        if distance < 10 { return .yellow }    // Medium - COOL
        return .blue                            // Far - COLD
    }

    private func getHotColdText(distance: Double) -> String {
        if distance < 1 { return "HOT" }
        if distance < 3 { return "WARM" }
        if distance < 10 { return "COOL" }
        return "COLD"
    }

    private func getDirectionAngle(location: PeerLocation) -> Double {
        if let x = location.uwbDirectionX, let z = location.uwbDirectionZ {
            return Double(atan2(x, z)) * 180.0 / Double.pi
        }
        return 0
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance < 1 {
            return String(format: "%.0f cm", distance * 100)
        } else {
            return String(format: "%.1f m", distance)
        }
    }

    // MARK: - Data

    private var mutualFavoritesCount: Int {
        favoritesService.favorites.values.filter { $0.isMutual }.count
    }

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
        // Try normalized key first (hex string)
        let hexKey = noiseKey.hexEncodedString()
        if let loc = viewModel.trackingService.peerLocations[hexKey] {
            return loc
        }
        // Try peer ID string
        let peerIDString = PeerID(publicKey: noiseKey).id
        return viewModel.trackingService.peerLocations[peerIDString]
    }

    // MARK: - Actions

    private func selectFavorite(_ noiseKey: Data) {
        selectedFavoriteKey = noiseKey

        // Zoom to this person on map
        if let location = getLocation(for: noiseKey),
           let coord = location.coordinate {
            viewModel.mapRegion.center = coord
            viewModel.mapRegion.span = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        }
    }

    private func startTracking() {
        // Configure tracking service with transports
        viewModel.trackingService.configure(
            ble: chatViewModel.meshService,
            nostr: chatViewModel.nostrTransport
        )

        viewModel.locationManager.beginTrackingMode()
        viewModel.trackingService.startLocationAnnouncements()

        // Refresh npub exchange
        chatViewModel.refreshFavoriteNpubExchange()

        // Auto-ping if we have favorites
        if mutualFavoritesCount > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.pingAll()
            }
        }
    }
}

// MARK: - Map Item

struct FavoriteMapItem: Identifiable {
    let noiseKey: Data
    let nickname: String
    let location: PeerLocation?

    var id: Data { noiseKey }

    var coordinate: CLLocationCoordinate2D {
        location?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }
}

// MARK: - Map Pin

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
            // Name + tracking method
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

            // Pin
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

// MARK: - Friend Row (People-style with tracking info)

struct BeaconFriendRow: View {
    let nickname: String
    let location: PeerLocation?
    let isSelected: Bool
    let textColor: Color
    let secondaryTextColor: Color
    let colorScheme: ColorScheme
    let onTap: () -> Void

    private var hasLocation: Bool {
        location?.hasLocation == true
    }

    private var hasUWB: Bool {
        location?.uwbDistance != nil
    }

    private var connectionIcon: String {
        if hasUWB {
            return "wave.3.right"
        } else if let loc = location {
            switch loc.transport {
            case .ble:
                return "antenna.radiowaves.left.and.right"
            case .relay:
                return "globe"
            case .wifi:
                return "wifi"
            }
        }
        return "circle.dashed"
    }

    private var iconColor: Color {
        if !hasLocation {
            return secondaryTextColor
        }
        if hasUWB {
            return .blue
        }
        if location?.transport == .ble {
            return textColor
        }
        return .purple
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                // Connection icon (like antenna icon in People)
                Image(systemName: connectionIcon)
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(iconColor)

                // Nickname
                Text(nickname)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(hasLocation ? textColor : secondaryTextColor)

                // Online indicator (like verified badge in People)
                if hasLocation {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                // Tracking details
                if hasLocation {
                    HStack(spacing: 6) {
                        // UWB distance
                        if let distance = location?.uwbDistance {
                            Text(String(format: "%.1fm", distance))
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                                .foregroundColor(.blue)
                        }

                        // Ping time
                        if let pingMs = location?.pingMs, pingMs > 0 {
                            Text("\(pingMs)ms")
                                .font(.bitchatSystem(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                        }
                    }

                    // Selection indicator
                    Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(secondaryTextColor)
                } else {
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
