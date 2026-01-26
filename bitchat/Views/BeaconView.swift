//
// BeaconView.swift
// bitchat
//
// Integrated favorites + map view for Beacon tracking
//

import SwiftUI
import MapKit

struct BeaconView: View {
    @StateObject private var viewModel = TrackingViewModel()
    @ObservedObject private var favoritesService = FavoritesPersistenceService.shared
    @Environment(\.colorScheme) private var colorScheme

    @Binding var isExpanded: Bool
    let onOpenChat: (PeerID) -> Void

    @State private var selectedFavoriteKey: Data?
    @State private var mapHeight: CGFloat = 250

    private var beaconGreen: Color {
        Color(red: 0.2, green: 0.8, blue: 0.4)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            if isExpanded {
                // Map
                mapSection
                    .transition(.asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal: .push(from: .bottom).combined(with: .opacity)
                    ))

                Divider()

                // Favorites list
                favoritesListView
            }
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 16 : 12))
        .shadow(color: .black.opacity(0.1), radius: isExpanded ? 12 : 4, y: 2)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isExpanded)
        .onAppear {
            if isExpanded {
                startTracking()
            }
        }
        .onChange(of: isExpanded) { expanded in
            if expanded {
                startTracking()
            } else {
                viewModel.trackingService.stopTracking()
                viewModel.trackingService.stopLocationAnnouncements()
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 10) {
                // Beacon icon
                ZStack {
                    Circle()
                        .fill(beaconGreen.opacity(0.15))
                        .frame(width: 36, height: 36)

                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(beaconGreen)
                }

                // Title
                VStack(alignment: .leading, spacing: 1) {
                    Text("Beacon")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)

                    Text("\(mutualFavoritesCount) friends")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Status / Expand indicator
                HStack(spacing: 8) {
                    if viewModel.isPinging {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if viewModel.peersWithLocationCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("\(viewModel.peersWithLocationCount) online")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
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
            if viewModel.isPinging, let userLoc = viewModel.myLocation {
                GeometryReader { geo in
                    MapPingWave(isAnimating: viewModel.isPinging)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }

            // Controls overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()

                    // Ping button
                    Button(action: { viewModel.pingAll() }) {
                        Image(systemName: viewModel.isPinging ? "antenna.radiowaves.left.and.right" : "location.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(beaconGreen)
                            .clipShape(Circle())
                            .shadow(color: beaconGreen.opacity(0.4), radius: 8, y: 4)
                    }
                    .disabled(viewModel.isPinging)
                    .padding(12)
                }
            }
        }
        .frame(height: mapHeight)
    }

    // MARK: - Favorites List

    private var favoritesListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(allFavorites, id: \.noiseKey) { fav in
                    BeaconFavoriteRow(
                        nickname: fav.nickname,
                        location: fav.location,
                        isSelected: selectedFavoriteKey == fav.noiseKey,
                        isPinging: viewModel.isPinging,
                        onTrack: {
                            selectFavorite(fav.noiseKey)
                        },
                        onMessage: {
                            let peerID = PeerID(publicKey: fav.noiseKey)
                            onOpenChat(peerID)
                        }
                    )

                    if fav.noiseKey != allFavorites.last?.noiseKey {
                        Divider().padding(.leading, 60)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 200)
    }

    // MARK: - Data

    private var mutualFavoritesCount: Int {
        favoritesService.favorites.values.filter { $0.isMutual }.count
    }

    private var allFavorites: [FavoriteMapItem] {
        favoritesService.favorites
            .filter { $0.value.isMutual }
            .map { (key, rel) in
                let peerIDString = PeerID(publicKey: key).id
                let location = viewModel.trackingService.peerLocations[peerIDString]
                return FavoriteMapItem(
                    noiseKey: key,
                    nickname: rel.peerNickname,
                    location: location
                )
            }
            .sorted { $0.nickname < $1.nickname }
    }

    private var mapAnnotations: [FavoriteMapItem] {
        allFavorites.filter { $0.location?.hasLocation == true }
    }

    private func nickname(for noiseKey: Data) -> String {
        favoritesService.favorites[noiseKey]?.peerNickname ?? "Unknown"
    }

    // MARK: - Actions

    private func selectFavorite(_ noiseKey: Data) {
        selectedFavoriteKey = noiseKey

        // Zoom to this person on map
        let peerIDString = PeerID(publicKey: noiseKey).id
        if let location = viewModel.trackingService.peerLocations[peerIDString],
           let coord = location.coordinate {
            withAnimation(.easeInOut(duration: 0.3)) {
                viewModel.mapRegion.center = coord
                viewModel.mapRegion.span = MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            }
        }
    }

    private func startTracking() {
        viewModel.locationManager.beginTrackingMode()
        viewModel.trackingService.startLocationAnnouncements()

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

// MARK: - Favorite Row

struct BeaconFavoriteRow: View {
    let nickname: String
    let location: PeerLocation?
    let isSelected: Bool
    let isPinging: Bool
    let onTrack: () -> Void
    let onMessage: () -> Void

    private var hasLocation: Bool {
        location?.hasLocation == true
    }

    private var trackingMethod: String {
        if let loc = location {
            if loc.uwbDistance != nil {
                return "UWB"
            } else if loc.transport == .ble {
                return "BLE"
            } else {
                return "GPS"
            }
        }
        return ""
    }

    private var statusColor: Color {
        if hasLocation {
            return .green
        } else if location != nil {
            return .orange
        } else {
            return .gray
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(String(nickname.prefix(1)).uppercased())
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundColor(statusColor)
                    )

                Circle()
                    .fill(statusColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(nickname)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    if hasLocation {
                        Text(trackingMethod)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor)
                            .clipShape(Capsule())

                        if let pingMs = location?.pingMs, pingMs > 0 {
                            Text("\(pingMs)ms")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    } else if isPinging {
                        Text("Searching...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Tap to locate")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                // Track button
                Button(action: onTrack) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16))
                        .foregroundColor(hasLocation ? .green : .gray)
                        .frame(width: 36, height: 36)
                        .background(Color.green.opacity(hasLocation ? 0.15 : 0.05))
                        .clipShape(Circle())
                }
                .disabled(!hasLocation)

                // Message button
                Button(action: onMessage) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                        .frame(width: 36, height: 36)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.green.opacity(0.1) : Color.clear)
        .cornerRadius(10)
        .contentShape(Rectangle())
    }
}

// MARK: - Sheet Wrapper

struct BeaconSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isExpanded = true
    let onOpenChat: (PeerID) -> Void

    var body: some View {
        NavigationStack {
            BeaconView(isExpanded: $isExpanded, onOpenChat: onOpenChat)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
    }
}

#Preview {
    BeaconSheetView { peerID in
        print("Open chat with \(peerID)")
    }
}
