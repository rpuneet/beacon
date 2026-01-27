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
        }
        .onChange(of: locationManager.currentLocation) { newLocation in
            if let loc = newLocation, !viewModel.userHasInteracted {
                withAnimation(.easeInOut(duration: 0.5)) {
                    viewModel.mapRegion.center = loc.coordinate
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
                Text("\(viewModel.peersWithLocationCount) online")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }

            Spacer()

            // Ping button
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
            .gesture(
                DragGesture()
                    .onChanged { _ in
                        viewModel.userHasInteracted = true
                    }
            )

            // Ping wave overlay
            if viewModel.isPinging {
                MapPingWave(isAnimating: viewModel.isPinging)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Tracking Detail

    private func trackingDetailView(nickname: String, location: PeerLocation) -> some View {
        HStack(spacing: 12) {
            // Direction indicator
            directionArrowView(location: location)

            VStack(alignment: .leading, spacing: 2) {
                Text(nickname)
                    .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)

                if let uwbDistance = location.uwbDistance {
                    Text(formatDistance(Double(uwbDistance)))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                } else if let accuracy = location.horizontalAccuracy {
                    Text("±\(Int(accuracy))m")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Staleness + connection info
                HStack(spacing: 8) {
                    let staleness = Date().timeIntervalSince(location.timestamp)
                    Text(formatStaleness(staleness))
                        .foregroundColor(staleness > 60 ? .orange : .secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    Image(systemName: location.transport == .ble ? "antenna.radiowaves.left.and.right" : "globe")
                        .foregroundColor(location.transport == .ble ? .green : .purple)

                    if location.pingMs > 0 {
                        Text("\(location.pingMs)ms")
                            .foregroundColor(.orange)
                    }
                }
                .font(.bitchatSystem(size: 11, design: .monospaced))
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
        let distance = location.uwbDistance.map { Double($0) } ?? 10.0
        let arrowColor = getHotColdColor(distance: distance, hasUWB: hasUWB)
        let directionAngle = getDirectionAngle(location: location)

        return ZStack {
            Circle()
                .fill(arrowColor.opacity(0.2))
                .frame(width: 44, height: 44)

            Circle()
                .stroke(arrowColor, lineWidth: 2)
                .frame(width: 44, height: 44)

            Image(systemName: hasUWB ? "arrow.up" : "location.fill")
                .font(.system(size: hasUWB ? 18 : 16, weight: .bold))
                .foregroundColor(arrowColor)
                .rotationEffect(.degrees(hasUWB ? directionAngle : 0))
        }
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
            guard relationship.isMutual else { return nil }
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

        let favCount = favoritesService.favorites.values.filter { $0.isMutual }.count
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
        guard let direction = location.uwbDirection else { return 0 }
        return Double(atan2(direction.x, direction.z)) * 180 / .pi
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
    var id: Data { noiseKey }
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
