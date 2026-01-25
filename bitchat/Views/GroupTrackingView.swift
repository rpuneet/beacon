//
// GroupTrackingView.swift
// bitchat
//
// Main UI for tracking multiple peers on a map
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Favorite Entry Model

/// Represents a mutual favorite for display, with optional location data
struct FavoriteEntry: Identifiable {
    let id: String
    let nickname: String
    let noiseKey: Data
    let location: PeerLocation?  // nil if no response yet

    var hasLocation: Bool { location?.hasLocation ?? false }
    var hasResponded: Bool { location != nil }
}

// MARK: - Main View

struct GroupTrackingView: View {
    @StateObject private var viewModel = TrackingViewModel()
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @ObservedObject private var favoritesService = FavoritesPersistenceService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var hasSetInitialRegion = false

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    // All annotation items for the map
    private var allAnnotationItems: [TrackingAnnotationItem] {
        var items: [TrackingAnnotationItem] = viewModel.peersWithLocation.map { .peer($0) }
        // Add user location for ping wave animation
        if let loc = viewModel.myLocation, viewModel.isPinging {
            items.append(.userPing(loc))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Map
            ZStack {
                mapContent

                // Selected peer detail overlay
                if let location = viewModel.selectedPeerLocation {
                    VStack {
                        Spacer()
                        PeerDetailSheet(location: location, nickname: nickname(for: location))
                            .padding()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // Overlay when no peer locations visible
                if viewModel.peersWithLocationCount == 0 {
                    loadingOverlay
                }
            }

            // Bottom peer list
            peerListView
        }
        .onAppear {
            startTracking()
        }
        .onDisappear {
            viewModel.trackingService.stopTracking()
        }
        .onChange(of: viewModel.peersWithLocation.count) { newCount in
            if !viewModel.userHasInteracted && newCount > 0 {
                viewModel.fitAllPeers()
            }
        }
        .task {
            // Wait for initial location
            for await _ in Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().values {
                if !hasSetInitialRegion, let loc = viewModel.myLocation {
                    viewModel.mapRegion.center = loc
                    hasSetInitialRegion = true
                    if !viewModel.peersWithLocation.isEmpty {
                        viewModel.fitAllPeers()
                    }
                    break
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 600)
        #endif
    }

    // MARK: - Subviews

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("tracking")
                    .font(.bitchatSystem(size: 18, design: .monospaced))
                    .foregroundColor(textColor)

                Spacer()

                // Ping button
                PingButton(isPinging: viewModel.isPinging) {
                    viewModel.pingAll()
                }

                // Close button
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }

            // Subtitle
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.yellow)
                Text("\(viewModel.peersWithLocationCount) visible")
                    .foregroundColor(.secondary)
            }
            .font(.bitchatSystem(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(backgroundColor)
    }

    /// Look up nickname for a peer from favorites
    private func nickname(for peerLocation: PeerLocation) -> String {
        let peerID = peerLocation.peerID
        let shortID = peerID.toShort()

        // Try direct lookup by short ID
        if let rel = favoritesService.getFavoriteStatus(forPeerID: shortID) {
            return rel.peerNickname
        }

        // Fallback: scan all favorites and match by derived short ID
        for (noiseKey, rel) in favoritesService.favorites {
            let favShortID = PeerID(publicKey: noiseKey)
            if favShortID.id == shortID.id || favShortID.bare == peerID.bare {
                return rel.peerNickname
            }
        }

        // Last resort: return short hex prefix
        return shortID.bare.prefix(8).description
    }

    @ViewBuilder
    private var mapContent: some View {
        Map(coordinateRegion: $viewModel.mapRegion, showsUserLocation: !viewModel.isPinging, annotationItems: allAnnotationItems) { item in
            MapAnnotation(coordinate: item.coordinate) {
                switch item {
                case .peer(let peerLocation):
                    PeerAnnotationView(
                        peer: peerLocation,
                        nickname: nickname(for: peerLocation),
                        isSelected: peerLocation.id == viewModel.selectedPeerID
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if viewModel.selectedPeerID == peerLocation.id {
                                viewModel.deselectPeer()
                            } else {
                                viewModel.selectPeer(peerLocation.id)
                            }
                        }
                    }

                case .userPing:
                    ZStack {
                        MapPingWave(isAnimating: viewModel.isPinging)
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 2)
                            )
                    }
                }
            }
        }
        .simultaneousGesture(
            DragGesture().onChanged { _ in
                viewModel.userHasInteracted = true
            }
        )
        .simultaneousGesture(
            MagnificationGesture().onChanged { _ in
                viewModel.userHasInteracted = true
            }
        )
    }

    private var hasFavorites: Bool {
        !favoritesService.mutualFavorites.isEmpty
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            if !hasFavorites {
                // No favorites message
                Image(systemName: "star")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
                Text("No mutual favorites")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(textColor)
                Text("Add favorites to track friends")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if viewModel.isPinging {
                // Pinging in progress
                ProgressView()
                    .tint(textColor)
                Text("Scanning...")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(textColor)
            } else {
                // Has favorites but no locations yet
                Image(systemName: "location.slash")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
                Text("No locations yet")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(textColor)
                Text("Tap ping to scan for friends")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(backgroundColor.opacity(0.9))
                .shadow(radius: 8)
        )
    }

    // All mutual favorites for the list (showing status even if no response yet)
    private var allMutualFavorites: [FavoriteEntry] {
        favoritesService.favorites.values
            .filter { $0.isMutual }
            .sorted { $0.peerNickname < $1.peerNickname }
            .map { rel in
                let peerIDString = PeerID(publicKey: rel.peerNoisePublicKey).id
                let location = viewModel.trackingService.peerLocations[peerIDString]
                return FavoriteEntry(
                    id: peerIDString,
                    nickname: rel.peerNickname,
                    noiseKey: rel.peerNoisePublicKey,
                    location: location
                )
            }
    }

    private var peerListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(allMutualFavorites) { entry in
                    FavoriteRowView(
                        entry: entry,
                        isPinging: viewModel.isPinging,
                        isSelected: entry.id == viewModel.selectedPeerID
                    )
                    .onTapGesture {
                        withAnimation {
                            if viewModel.selectedPeerID == entry.id {
                                viewModel.deselectPeer()
                            } else if entry.location?.hasLocation == true {
                                viewModel.selectPeer(entry.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .frame(maxHeight: 200)
        .background(backgroundColor)
    }

    // MARK: - Private Methods

    private func startTracking() {
        // Start location updates
        viewModel.locationManager.beginTrackingMode()

        // Refresh npub exchange for favorites
        chatViewModel.refreshFavoriteNpubExchange()

        // Configure tracking service
        viewModel.trackingService.configure(
            ble: chatViewModel.meshService,
            nostr: chatViewModel.nostrTransport
        )

        // Set initial map region
        if let loc = viewModel.myLocation {
            viewModel.mapRegion.center = loc
            hasSetInitialRegion = true
        }

        // Auto-ping if we have favorites
        if hasFavorites {
            // Small delay to let services initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.pingAll()
            }
        }
    }
}

// MARK: - Annotation Item

enum TrackingAnnotationItem: Identifiable {
    case peer(PeerLocation)
    case userPing(CLLocationCoordinate2D)

    var id: String {
        switch self {
        case .peer(let p): return p.id
        case .userPing: return "user-ping"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .peer(let p): return p.coordinate ?? CLLocationCoordinate2D()
        case .userPing(let loc): return loc
        }
    }
}

// MARK: - Peer Annotation View

struct PeerAnnotationView: View {
    let peer: PeerLocation
    let nickname: String
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 2) {
            // Nickname label
            HStack(spacing: 4) {
                Image(systemName: transportIcon)
                    .font(.system(size: 9))
                    .foregroundColor(transportColor)
                Text("@\(nickname)")
                    .font(.bitchatSystem(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(colorScheme == .dark ? .white : .black)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.7) : Color.white.opacity(0.9))
                    .shadow(radius: 2)
            )

            // Pin icon
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: isSelected ? 32 : 24))
                .foregroundColor(transportColor)
                .background(
                    Circle()
                        .fill(.white)
                        .frame(width: isSelected ? 28 : 20, height: isSelected ? 28 : 20)
                )

            // RTT badge
            if isSelected {
                Text("\(peer.pingMs)ms")
                    .font(.bitchatSystem(size: 9, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.7))
                    )
            }

            // Stale indicator
            if peer.isStale {
                Text("stale")
                    .font(.bitchatSystem(size: 8, design: .monospaced))
                    .foregroundColor(.orange)
            }
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }

    private var transportIcon: String {
        switch peer.transport {
        case .ble: return "antenna.radiowaves.left.and.right"
        case .relay: return "globe"
        case .wifi: return "wifi"
        }
    }

    private var transportColor: Color {
        switch peer.transport {
        case .ble: return .green
        case .relay: return .purple
        case .wifi: return .orange
        }
    }
}

// MARK: - Peer Detail Sheet

struct PeerDetailSheet: View {
    let location: PeerLocation
    let nickname: String
    @Environment(\.colorScheme) private var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Circle()
                    .fill(location.hasLocation ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)

                Text("@\(nickname)")
                    .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)

                Spacer()

                Text(location.transport.rawValue)
                    .font(.bitchatSystem(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
            }

            // Location info
            if location.hasLocation {
                HStack(spacing: 16) {
                    // Coordinates
                    if let coord = location.coordinate {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lat: \(String(format: "%.4f", coord.latitude))")
                            Text("Lon: \(String(format: "%.4f", coord.longitude))")
                        }
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.8))
                    }

                    Spacer()

                    // Accuracy
                    if let acc = location.horizontalAccuracy {
                        HStack(spacing: 4) {
                            Image(systemName: "scope")
                                .font(.system(size: 12))
                            Text("\(Int(acc))m")
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                        }
                        .foregroundColor(textColor)
                    }
                }
            } else {
                Text("Location disabled")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Connection info
            HStack(spacing: 16) {
                // Ping
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12))
                    Text("\(location.pingMs)ms")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                }
                .foregroundColor(.green)

                // RSSI
                if let rssi = location.rssi {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.system(size: 12))
                        Text("\(rssi) dBm")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                    }
                    .foregroundColor(textColor)
                }

                // UWB
                if let distance = location.uwbDistance {
                    HStack(spacing: 4) {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 12))
                        Text(String(format: "%.2fm", distance))
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                    }
                    .foregroundColor(.blue)
                }

                Spacer()

                // Timestamp
                Text(location.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                    .foregroundColor(location.isStale ? .orange : textColor.opacity(0.5))
            }

            // Stale warning
            if location.isStale {
                Label("Stale data", systemImage: "exclamationmark.triangle")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color.black.opacity(0.9) : Color.white.opacity(0.95))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
    }
}

// MARK: - Peer Row View

struct PeerRowView: View {
    let location: PeerLocation
    let isPinging: Bool
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Connection icon
            Image(systemName: connectionIcon)
                .font(.system(size: 14))
                .foregroundColor(textColor)
                .frame(width: 20)

            // Nickname
            Text(location.peerID.bare)
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(textColor)

            // Lock icon
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(textColor.opacity(0.5))

            Spacer()

            // RTT
            Text("\(location.pingMs)ms")
                .font(.bitchatSystem(size: 11, design: .monospaced))
                .foregroundColor(.green)

            // Stale indicator
            if location.isStale {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            // Status indicator
            Circle()
                .fill(location.hasLocation ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            // Star
            Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundColor(.yellow)
        }
        .padding(.vertical, 8)
        .background(isSelected ? textColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    private var connectionIcon: String {
        switch location.transport {
        case .ble: return "antenna.radiowaves.left.and.right"
        case .relay: return "globe"
        case .wifi: return "wifi"
        }
    }
}

// MARK: - Favorite Row View

struct FavoriteRowView: View {
    let entry: FavoriteEntry
    let isPinging: Bool
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 14))
                .foregroundColor(statusColor)
                .frame(width: 20)

            // Nickname
            Text(entry.nickname)
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(entry.hasResponded ? textColor : textColor.opacity(0.5))

            // Lock icon (only if responded via encrypted channel)
            if entry.hasResponded {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(textColor.opacity(0.5))
            }

            Spacer()

            // Connection info (if responded)
            if let loc = entry.location {
                // RTT
                Text("\(loc.pingMs)ms")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.green)

                // Transport badge
                Text(loc.transport.rawValue)
                    .font(.bitchatSystem(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )

                // Stale indicator
                if loc.isStale {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            } else if isPinging {
                // Waiting for response
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                // Not responding
                Text("offline")
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Location status dot
            Circle()
                .fill(locationStatusColor)
                .frame(width: 8, height: 8)

            // Favorite star
            Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundColor(.yellow)
        }
        .padding(.vertical, 8)
        .background(isSelected ? textColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    private var statusIcon: String {
        if entry.hasLocation {
            return entry.location?.transport == .ble
                ? "antenna.radiowaves.left.and.right"
                : "globe"
        } else if entry.hasResponded {
            return "location.slash"
        } else {
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        if entry.hasLocation {
            return entry.location?.transport == .ble ? .green : .purple
        } else if entry.hasResponded {
            return .orange
        } else {
            return .gray
        }
    }

    private var locationStatusColor: Color {
        if entry.hasLocation {
            return .green
        } else if entry.hasResponded && !(entry.location?.gpsEnabled ?? true) {
            return .orange  // GPS disabled
        } else if entry.hasResponded {
            return .gray  // Responded but no location
        } else {
            return .gray.opacity(0.5)  // Not responded
        }
    }
}
