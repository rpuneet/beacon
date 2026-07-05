//
// BeaconView.swift
// bitchat
//
// Beacon view - location sharing for mutual favorites
//

import BitFoundation
import SwiftUI
import MapKit

struct BeaconView: View {
    /// Root mode: the map is the app's home screen — hamburger instead of
    /// a dismiss button (set by BeaconAppRoot).
    var isRootMode = false
    var onMenuTap: (() -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil

    @ObservedObject private var beaconService = BeaconService.shared
    @ObservedObject private var favoritesService = FavoritesPersistenceService.shared
    @ObservedObject private var locationManager = LocationStateManager.shared
    @ObservedObject private var auditLog = BeaconAuditLog.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFavoriteKey: Data?
    @State private var showSettings = false
    @State private var showFullTracking = false
    @State private var recenterTrigger = 0
    @State private var favoritesExpanded = false
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var isTracking: Bool { selectedFavoriteKey != nil }

    private var favoritesSheetHeight: CGFloat { favoritesExpanded ? 300 : 96 }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapView
                .ignoresSafeArea()

            if locationManager.permissionState == .denied || locationManager.permissionState == .restricted {
                locationPermissionBanner
            }

            if let location = selectedLocation {
                trackingOverlay(location: location)
            } else {
                favoritesSheet
            }
        }
        .overlay(alignment: .top) {
            headerView
        }
        .overlay(alignment: .bottomTrailing) {
            if !isTracking {
                recenterButton
            }
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 550)
        #endif
        .onAppear {
            #if DEBUG
            // Screenshot automation: -beacon.autoOpenSettings lands on the privacy sheet
            if ProcessInfo.processInfo.arguments.contains("-beacon.autoOpenSettings") {
                showSettings = true
            }
            #endif
            if let loc = locationManager.currentLocation {
                mapRegion.center = loc.coordinate
            }
            // Requests location permission if not yet determined; beginTrackingMode
            // alone silently no-ops without authorization
            locationManager.enableLocationChannels()
            locationManager.beginTrackingMode()
            if favoritesCount > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    beaconService.pingAllFavorites()
                }
            }
        }
        .onChange(of: locationManager.permissionState) { state in
            if state == .authorized {
                locationManager.beginTrackingMode()
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
        HStack(spacing: 8) {
            if isRootMode {
                Button(action: { onMenuTap?() }) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
            }

            Text("beacon")
                .font(.bitchatSystem(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(textColor)

            if favoritesCount > 0 {
                Text("\(beaconService.peersWithLocationCount)/\(favoritesCount) located")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
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
                    .frame(height: 24)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            // Beacon mode: a labeled state, never mystery iconography
            Button(action: { beaconService.isBeaconModeEnabled.toggle() }) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(beaconService.isBeaconModeEnabled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(beaconService.isBeaconModeEnabled ? "beaconing" : "off")
                        .font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    beaconService.isBeaconModeEnabled ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundColor(beaconService.isBeaconModeEnabled ? .green : .secondary)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            // Manual ping
            Button(action: { beaconService.pingAllFavorites() }) {
                Group {
                    if beaconService.isPinging {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "wave.3.right.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(textColor)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(beaconService.isPinging)

            if !isRootMode {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    /// Snap the map back to the user after panning away
    private var recenterButton: some View {
        Button(action: { recenterTrigger += 1 }) {
            Image(systemName: "location.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundColor(textColor)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.bottom, favoritesSheetHeight + 20)
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
                    recenterTrigger: recenterTrigger,
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
                        VStack(spacing: 4) {
                            Circle()
                                .fill(BeaconProfile.peerColor(nickname: item.nickname))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Text(String(item.nickname.prefix(1)).uppercased())
                                        .font(.bitchatSystem(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                )
                                .overlay(
                                    Circle().stroke(item.transport == .ble ? Color.green : Color.purple, lineWidth: 2)
                                )
                            Text(item.nickname)
                                .font(.bitchatSystem(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.65))
                                .cornerRadius(8)
                        }
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

    /// Coordinates the map should scale to show: user + tracked peer while
    /// tracking, or user + all located peers while browsing.
    private var fitCoordinatesForTracking: [CLLocationCoordinate2D]? {
        guard let myLoc = locationManager.currentLocation else { return nil }
        if let peerCoord = selectedLocation?.coordinate {
            return [myLoc.coordinate, peerCoord]
        }
        let peerCoords = mapAnnotations.map(\.coordinate)
        guard !peerCoords.isEmpty else { return nil }
        return [myLoc.coordinate] + peerCoords
    }

    // MARK: - Location Permission Banner

    private var locationPermissionBanner: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "location.slash.fill")
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("location is off")
                        .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                    Text("beacon can't show you or share your position")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("settings") { openSystemLocationSettings() }
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.blue)
                    .buttonStyle(.plain)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func openSystemLocationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
        #endif
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
        return myLoc.coordinate.bearing(to: peerCoord) - heading
    }

    // MARK: - Favorites Sheet

    /// Floating bottom sheet over the map: grabber, identity rows, and an
    /// empty state that tells new users what to actually do.
    private var favoritesSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 10)

            HStack {
                Text("friends")
                    .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
                if !filteredFavorites.isEmpty {
                    Text("\(filteredFavorites.count)")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            if filteredFavorites.isEmpty {
                emptyFavoritesState
            } else if favoritesExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredFavorites, id: \.noiseKey) { fav in
                            favoriteRow(fav)
                        }
                    }
                }
            } else {
                // Peek: avatar chips row
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(filteredFavorites, id: \.noiseKey) { fav in
                            Button(action: { startTracking(fav.noiseKey) }) {
                                identityBubble(nickname: fav.nickname, size: 34,
                                               located: getLocation(for: fav.noiseKey)?.hasLocation == true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: favoritesSheetHeight, alignment: .top)
        .background(.ultraThinMaterial)
        .clipShape(TopRoundedShape(radius: 20))
        .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { favoritesExpanded.toggle() } }
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        favoritesExpanded = value.translation.height < 0
                    }
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: favoritesExpanded)
    }

    private var emptyFavoritesState: some View {
        VStack(spacing: 10) {
            Text("friends appear here")
                .font(.bitchatSystem(size: 13, design: .monospaced))
            Text("favorite someone in chat — when they favorite you back, you can find each other")
                .font(.bitchatSystem(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if isRootMode {
                Button(action: { onOpenChat?() }) {
                    Text("open #mesh")
                        .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(textColor.opacity(0.15), in: Capsule())
                        .foregroundColor(textColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear { favoritesExpanded = true }
    }

    /// One visual token per person: identity-colored circle with initial,
    /// matching the map pin renderer.
    private func identityBubble(nickname: String, size: CGFloat, located: Bool) -> some View {
        ZStack {
            Circle()
                .fill(BeaconProfile.peerColor(nickname: nickname))
                .frame(width: size, height: size)
            Text(String(nickname.prefix(1)).uppercased())
                .font(.bitchatSystem(size: size * 0.42, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .overlay(
            Circle().stroke(located ? Color.green : Color.secondary.opacity(0.4), lineWidth: 2)
        )
        .opacity(located ? 1 : 0.55)
    }

    private func favoriteRow(_ fav: FavoriteDisplayItem) -> some View {
        let location = getLocation(for: fav.noiseKey)
        let located = location?.hasLocation == true

        return Button(action: { startTracking(fav.noiseKey) }) {
            HStack(spacing: 12) {
                identityBubble(nickname: fav.nickname, size: 32, located: located)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fav.nickname)
                        .font(.bitchatSystem(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text(proximityWord(for: location))
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(located ? .green : .secondary)
                }

                Spacer()

                if let rssi = location?.peerRSSI {
                    Text("\(rssi)dBm")
                        .font(.bitchatSystem(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Human word first; raw telemetry is the secondary detail
    private func proximityWord(for location: PeerLocation?) -> String {
        guard let location, location.hasLocation else { return "no location yet" }
        switch proximityLevel(from: location) {
        case .here: return "right here"
        case .close: return "very close"
        case .near: return "nearby"
        case .far, .arrow:
            if let seconds = location.timestamp.timeIntervalSinceNow as TimeInterval?, -seconds < 120 {
                return "on the map"
            }
            return "on the map · a while ago"
        }
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

/// Top-corners-only rounding, available on all deployment targets
/// (UnevenRoundedRectangle needs iOS 16.4 / macOS 13.3).
struct TopRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                    radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                    radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
