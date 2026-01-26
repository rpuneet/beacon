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
    @State private var showingTrackingDetail: Bool = false
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
        #if os(iOS)
        .sheet(isPresented: $showingTrackingDetail) {
            if let key = selectedFavoriteKey,
               let location = getLocation(for: key) {
                TrackingDetailView(
                    nickname: nickname(for: key),
                    location: location,
                    onDismiss: { showingTrackingDetail = false }
                )
            }
        }
        #endif
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
                        selectFavorite(item.noiseKey)
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

            // Ping button overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { viewModel.pingAll() }) {
                        Image(systemName: viewModel.isPinging ? "antenna.radiowaves.left.and.right" : "location.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(beaconGreen)
                            .clipShape(Circle())
                            .shadow(color: beaconGreen.opacity(0.4), radius: 8, y: 4)
                    }
                    .disabled(viewModel.isPinging)
                    .padding(16)
                }
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
                                    selectFavorite(fav.noiseKey)
                                    #if os(iOS)
                                    if fav.location?.hasLocation == true {
                                        showingTrackingDetail = true
                                    }
                                    #endif
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

                // Status indicator
                if viewModel.isPinging {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("pinging...")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
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

                    // Tap to find indicator
                    Text("tap to find")
                        .font(.bitchatSystem(size: 10, design: .monospaced))
                        .foregroundColor(secondaryTextColor.opacity(0.7))
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

// MARK: - Tracking Detail View

#if os(iOS)
struct TrackingDetailView: View {
    let nickname: String
    let location: PeerLocation
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var hasUWB: Bool {
        location.uwbDistance != nil
    }

    private var directionAngle: Double {
        if let x = location.uwbDirectionX, let z = location.uwbDirectionZ {
            return Double(atan2(x, z)) * 180.0 / Double.pi
        }
        return 0
    }

    private var distanceText: String {
        if let d = location.uwbDistance {
            if d < 1 {
                return String(format: "%.0f cm", d * 100)
            } else {
                return String(format: "%.1f m", d)
            }
        }
        return "Unknown"
    }

    private var hotColdColor: Color {
        guard let d = location.uwbDistance else { return .gray }
        if d < 1 { return .red }        // Very close - HOT
        if d < 3 { return .orange }     // Close - WARM
        if d < 10 { return .yellow }    // Medium - COOL
        return .blue                     // Far - COLD
    }

    private var hotColdText: String {
        guard let d = location.uwbDistance else { return "No Signal" }
        if d < 1 { return "🔥 HOT" }
        if d < 3 { return "🌡️ WARM" }
        if d < 10 { return "❄️ COOL" }
        return "🧊 COLD"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Direction arrow (for UWB)
                if hasUWB {
                    ZStack {
                        // Background circle with hot/cold color
                        Circle()
                            .fill(hotColdColor.opacity(0.2))
                            .frame(width: 200, height: 200)

                        Circle()
                            .stroke(hotColdColor, lineWidth: 4)
                            .frame(width: 200, height: 200)

                        // Direction arrow
                        Image(systemName: "arrow.up")
                            .font(.system(size: 80, weight: .bold))
                            .foregroundColor(hotColdColor)
                            .rotationEffect(.degrees(directionAngle))
                    }
                    .padding(.top, 32)

                    // Hot/Cold indicator
                    Text(hotColdText)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(hotColdColor)

                    // Distance
                    Text(distanceText)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                } else {
                    // GPS only - show compass direction
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 100))
                        .foregroundColor(.green)
                        .padding(.top, 32)

                    Text("GPS Location")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Connection details
                VStack(spacing: 12) {
                    DetailRow(label: "Connection", value: location.transport.rawValue.uppercased())
                    if location.pingMs > 0 {
                        DetailRow(label: "Ping", value: "\(location.pingMs) ms")
                    }
                    if location.gpsEnabled {
                        DetailRow(label: "GPS", value: "Enabled")
                    }
                    if let acc = location.horizontalAccuracy {
                        DetailRow(label: "Accuracy", value: String(format: "±%.0f m", acc))
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle(nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
#endif

// MARK: - Sheet Wrapper

#if os(iOS)
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
#endif
