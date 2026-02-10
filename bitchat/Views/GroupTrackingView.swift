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
    @State private var cachedAnnotations: [TrackingAnnotationItem] = []
    @State private var lastAnnotationUpdate: Date = .distantPast

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
            viewModel.trackingService.startLocationAnnouncements()
        }
        .onDisappear {
            viewModel.trackingService.stopTracking()
            viewModel.trackingService.stopLocationAnnouncements()
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
                // Beacon branding
                HStack(spacing: 8) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.linearGradient(
                            colors: [Color(red: 0.2, green: 0.8, blue: 0.4), Color(red: 0.1, green: 0.6, blue: 0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("bitchat")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Beacon")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                }

                Spacer()

                // Ping button
                PingButton(isPinging: viewModel.isPinging) {
                    viewModel.pingAll()
                }

                // Close button
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Status bar
            HStack(spacing: 12) {
                // Friends visible
                Label("\(viewModel.peersWithLocationCount) friends", systemImage: "person.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(viewModel.peersWithLocationCount > 0 ? .green : .secondary)

                // Connection status
                if viewModel.isPinging {
                    Label("Scanning...", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
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
        Map(coordinateRegion: $viewModel.mapRegion, showsUserLocation: true, annotationItems: cachedAnnotations) { item in
            MapAnnotation(coordinate: item.coordinate, anchorPoint: CGPoint(x: 0.5, y: 1.0)) {
                switch item {
                case .peer(let peerLocation):
                    SimplePeerPin(
                        nickname: nickname(for: peerLocation),
                        isSelected: peerLocation.id == viewModel.selectedPeerID,
                        transport: peerLocation.transport
                    )
                    .onTapGesture {
                        if viewModel.selectedPeerID == peerLocation.id {
                            viewModel.deselectPeer()
                        } else {
                            viewModel.selectPeer(peerLocation.id)
                        }
                    }

                case .userPing:
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                }
            }
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            updateAnnotationsIfNeeded()
        }
        .onAppear {
            updateAnnotationsIfNeeded()
        }
        .gesture(
            DragGesture().onChanged { _ in
                viewModel.userHasInteracted = true
            }
        )
    }

    private func updateAnnotationsIfNeeded() {
        let newItems: [TrackingAnnotationItem] = viewModel.peersWithLocation.map { .peer($0) }
        if newItems.count != cachedAnnotations.count {
            cachedAnnotations = newItems
        }
    }

    private var hasFavorites: Bool {
        !favoritesService.mutualFavorites.isEmpty
    }

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            if !hasFavorites {
                // No favorites - onboarding
                Image(systemName: "person.2.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.linearGradient(
                        colors: [Color(red: 0.2, green: 0.8, blue: 0.4), Color(red: 0.1, green: 0.6, blue: 0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                Text("Add Friends to Track")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Add mutual favorites in chat to see them on the map")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

            } else if viewModel.isPinging {
                // Scanning animation
                ZStack {
                    Circle()
                        .stroke(.green.opacity(0.3), lineWidth: 3)
                        .frame(width: 60, height: 60)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(.green, lineWidth: 3)
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))

                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                }

                Text("Finding friends...")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)

                Text("Via Bluetooth & Internet")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

            } else {
                // Has favorites but no locations
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text("Friends Not Found")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Tap the ping button to locate your friends")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: { viewModel.pingAll() }) {
                    Label("Find Friends", systemImage: "location.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(.green)
                        )
                }
                .padding(.top, 4)
            }
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
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
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("Friends")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(allMutualFavorites.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(allMutualFavorites) { entry in
                        FavoriteRowView(
                            entry: entry,
                            isPinging: viewModel.isPinging,
                            isSelected: entry.id == viewModel.selectedPeerID
                        )
                        .onTapGesture {
                            if viewModel.selectedPeerID == entry.id {
                                viewModel.deselectPeer()
                            } else if entry.location?.hasLocation == true {
                                viewModel.selectPeer(entry.id)
                            }
                        }

                        if entry.id != allMutualFavorites.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: 180)
        .background(.ultraThinMaterial)
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

// MARK: - Simple Peer Pin (Lightweight)

struct SimplePeerPin: View {
    let nickname: String
    let isSelected: Bool
    let transport: PeerLocation.TransportType
    let isRecent: Bool

    @State private var isPulsing = false

    private var pinColor: Color {
        switch transport {
        case .ble: return .green
        case .relay: return .purple
        case .wifi: return .orange
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            // Nickname badge
            Text(nickname)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(pinColor.opacity(0.9))
                        .shadow(color: pinColor.opacity(0.5), radius: isSelected ? 8 : 4)
                )

            // Pin with pulse
            ZStack {
                // Pulse ring for recent updates
                if isRecent {
                    Circle()
                        .stroke(pinColor.opacity(0.5), lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .scaleEffect(isPulsing ? 1.5 : 1.0)
                        .opacity(isPulsing ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: isPulsing)
                }

                // Main pin
                Circle()
                    .fill(pinColor)
                    .frame(width: isSelected ? 28 : 22, height: isSelected ? 28 : 22)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

                // Transport icon
                Image(systemName: transport == .ble ? "antenna.radiowaves.left.and.right" : "globe")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .onAppear {
            if isRecent {
                isPulsing = true
            }
        }
    }
}

extension SimplePeerPin {
    init(nickname: String, isSelected: Bool, transport: PeerLocation.TransportType) {
        self.nickname = nickname
        self.isSelected = isSelected
        self.transport = transport
        self.isRecent = false
    }
}

// MARK: - Peer Annotation View (Full Featured)

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

    var body: some View {
        HStack(spacing: 12) {
            // Avatar with status
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(avatarColor.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(entry.nickname.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(avatarColor)
                    )

                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }

            // Name and status
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.nickname)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    if let loc = entry.location {
                        // Transport
                        Image(systemName: loc.transport == .ble ? "antenna.radiowaves.left.and.right" : "globe")
                            .font(.system(size: 10))
                        Text(loc.transport == .ble ? "Nearby" : "Remote")
                            .font(.system(size: 12))

                        if loc.pingMs > 0 {
                            Text("•")
                            Text("\(loc.pingMs)ms")
                                .font(.system(size: 12, design: .monospaced))
                        }
                    } else if isPinging {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10))
                        Text("Searching...")
                            .font(.system(size: 12))
                    } else {
                        Text("Tap to find")
                            .font(.system(size: 12))
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            // Location indicator
            if entry.hasLocation {
                Image(systemName: "location.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.green)
            } else if isPinging {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "location.slash")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.green.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
    }

    private var avatarColor: Color {
        if entry.hasLocation {
            return entry.location?.transport == .ble ? .green : .purple
        } else {
            return .gray
        }
    }

    private var statusColor: Color {
        if entry.hasLocation {
            return .green
        } else if entry.hasResponded {
            return .orange
        } else {
            return .gray
        }
    }
}
