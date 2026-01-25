//
// TrackingView.swift
// bitchat
//
// Real-time peer tracking view with map, directional arrow, and connection info
//

import SwiftUI
import CoreLocation
import simd

struct TrackingEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let pingMs: Int?
    let rssi: Int?
    let hasGPS: Bool
}

struct TrackingView: View {
    let fingerprint: String  // Persistent identity - survives reconnections
    let initialPeerID: PeerID  // Initial peerID (may change on reconnection)
    let nickname: String
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var locationManager = LocationStateManager.shared
    @ObservedObject private var uwbManager = UWBTrackingManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    // Peer tracking data
    @State private var pingMs: Int?
    @State private var rssi: Int?
    @State private var peerLatitude: Double?
    @State private var peerLongitude: Double?
    @State private var peerAltitude: Double?
    @State private var peerHorizontalAccuracy: Double?
    @State private var peerVerticalAccuracy: Double?
    @State private var peerGpsEnabled: Bool = true
    @State private var peerUwbSupported: Bool = false
    @State private var history: [TrackingEntry] = []
    @State private var isPeerOnline = false
    @State private var currentPeerID: PeerID?
    @State private var isUsingRelay = false  // Tracking via internet relay instead of BLE

    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    // My location from LocationStateManager
    private var myLocation: CLLocationCoordinate2D? {
        guard let loc = locationManager.currentLocation else { return nil }
        return loc.coordinate
    }

    private var myAccuracy: Double? {
        locationManager.currentLocation?.horizontalAccuracy
    }

    // Peer location
    private var peerLocation: CLLocationCoordinate2D? {
        guard let lat = peerLatitude, let lon = peerLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Connection quality from RSSI and online status
    private var connectionQuality: ConnectionQuality {
        ConnectionQuality(rssi: rssi, isOnline: isPeerOnline)
    }

    // Distance between me and peer (GPS-based)
    private var gpsDistanceMeters: Double? {
        guard let myLoc = myLocation, let peerLoc = peerLocation else { return nil }
        let loc1 = CLLocation(latitude: myLoc.latitude, longitude: myLoc.longitude)
        let loc2 = CLLocation(latitude: peerLoc.latitude, longitude: peerLoc.longitude)
        return loc1.distance(from: loc2)
    }

    // UWB distance to peer (if available)
    private var uwbDistanceMeters: Float? {
        guard let peerID = currentPeerID else { return nil }
        return uwbManager.getDistance(for: peerID)
    }

    // UWB direction to peer (if available)
    private var uwbDirectionVector: simd_float3? {
        guard let peerID = currentPeerID else { return nil }
        return uwbManager.getDirection(for: peerID)
    }

    // BLE-estimated distance using SignalFusion
    private var bleEstimatedDistance: Double? {
        guard let rssiValue = rssi else { return nil }
        return SignalFusion.estimateDistanceFromRSSI(rssi: rssiValue)
    }

    // Combined GPS accuracy (both my accuracy and peer's accuracy)
    private var combinedGPSAccuracy: Double? {
        guard let myAcc = myAccuracy, let peerAcc = peerHorizontalAccuracy else {
            // If only one is available, use it with a buffer
            return peerHorizontalAccuracy ?? myAccuracy.map { $0 * 1.5 }
        }
        return SignalFusion.combinedGPSAccuracy(myAccuracy: myAcc, theirAccuracy: peerAcc)
    }

    // Fused distance estimate using priority-based selection (not weighted average)
    private var fusedDistance: DistanceEstimate? {
        SignalFusion.fuseDistanceWithRSSI(
            uwb: uwbDistanceMeters.map { Double($0) },
            bleRSSI: rssi,
            bleEstimatedDistance: nil,  // Don't use pre-estimated BLE distance
            gps: gpsDistanceMeters,
            gpsAccuracy: combinedGPSAccuracy
        )
    }

    // Fused direction estimate with confidence
    private var fusedDirection: DirectionEstimate {
        // Calculate GPS bearing if we have both locations
        let gpsBearing: Double? = {
            guard let myLoc = myLocation, let peerLoc = peerLocation else { return nil }
            return SignalFusion.gpsBearing(from: myLoc, to: peerLoc)
        }()

        return SignalFusion.fuseDirection(
            uwbVector: uwbDirectionVector,
            gpsBearing: gpsBearing,
            gpsDistance: gpsDistanceMeters,
            gpsAccuracy: combinedGPSAccuracy
        )
    }

    // Best available distance (for compatibility with existing code)
    private var bestDistance: (meters: Double, source: TrackingSource)? {
        guard let fused = fusedDistance, let primary = fused.primarySource else { return nil }
        return (fused.meters, primary)
    }

    // Formatted distance text with source
    private var distanceText: String? {
        fusedDistance?.formattedDistance
    }

    // Whether to show directional arrow (based on confidence)
    private var shouldShowDirectionalArrow: Bool {
        fusedDirection.shouldShowArrow
    }

    // Active tracking sources
    private var activeSources: Set<TrackingSource> {
        var sources = Set<TrackingSource>()

        // GPS is active if we have peer location
        if peerLocation != nil && peerGpsEnabled {
            sources.insert(.gps)
        }

        // UWB is active if we have UWB distance data
        // Use getDistance() which normalizes PeerID for consistent lookup
        if uwbDistanceMeters != nil {
            sources.insert(.uwb)
        }

        // BLE is active if peer is online via mesh (we have RSSI)
        if rssi != nil {
            sources.insert(.ble)
        }

        // Relay is active if tracking via internet relay (no BLE)
        if isUsingRelay && isPeerOnline {
            sources.insert(.relay)
        }

        return sources
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Main content - Map with arrow overlay
            ZStack {
                // Map
                TrackingMapView(
                    myLocation: myLocation,
                    myAccuracy: myAccuracy,
                    peerLocation: peerLocation,
                    peerAccuracy: peerHorizontalAccuracy,
                    connectionQuality: connectionQuality,
                    peerNickname: nickname
                )

                // Directional arrow or hot/cold indicator overlay (bottom center)
                // On macOS, heading is not available so we show hot/cold indicator instead
                #if os(iOS)
                if let myLoc = myLocation,
                   let peerLoc = peerLocation,
                   let heading = locationManager.currentHeading {
                    VStack {
                        Spacer()
                        if shouldShowDirectionalArrow {
                            // Show directional arrow when confident
                            DirectionalArrow(
                                from: myLoc,
                                to: peerLoc,
                                deviceHeading: heading,
                                uwbDistance: uwbDistanceMeters,
                                uwbDirection: uwbDirectionVector,
                                directionConfidence: fusedDirection.confidence
                            )
                            .padding(.bottom, 20)
                        } else if let fused = fusedDistance {
                            // Show hot/cold indicator when direction is unknown
                            HotColdIndicator(
                                currentDistance: fused.meters,
                                confidence: fused.confidence
                            )
                            .padding(.bottom, 20)
                        }
                    }
                }
                #elseif os(macOS)
                // macOS: Show hot/cold indicator when we have distance (no compass heading available)
                if let _ = myLocation,
                   let _ = peerLocation,
                   let fused = fusedDistance {
                    VStack {
                        Spacer()
                        HotColdIndicator(
                            currentDistance: fused.meters,
                            confidence: fused.confidence
                        )
                        .padding(.bottom, 20)
                    }
                }
                #endif

                // Waiting overlay only when peer is offline and we have no tracking data
                if !isPeerOnline && bestDistance == nil {
                    waitingOverlay
                }
            }
            #if os(macOS)
            .frame(minHeight: 300)  // Ensure map has minimum height on macOS sheets
            #endif

            // Info panel at bottom
            infoPanel
        }
        .background(backgroundColor)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 500)  // Minimum sheet size for macOS
        #endif
        .onAppear {
            locationManager.beginTrackingMode()
            fetchTrackingData()
        }
        .onDisappear {
            locationManager.endTrackingMode()
            // End UWB session when leaving tracking view
            if let peerID = currentPeerID {
                uwbManager.endSession(with: peerID)
            }
        }
        .onReceive(timer) { _ in
            fetchTrackingData()
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.bitchatSystem(size: 14))
                    .foregroundColor(textColor)
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 6) {
                // Connection type indicator (icon only) - on side of nickname
                if isUsingRelay {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)
                } else if isPeerOnline {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 14))
                        .foregroundColor(textColor)
                }
                Text("@\(nickname)")
                    .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.bitchatSystem(size: 14, weight: .semibold))
                    .foregroundColor(textColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(backgroundColor)
    }

    // Contextual waiting text
    private var waitingText: String {
        if !isPeerOnline {
            return "Connecting to peer..."
        } else if peerLocation == nil && !peerGpsEnabled {
            return "Peer has location disabled"
        } else if peerLocation == nil {
            return "Waiting for peer location..."
        } else {
            return "Tracking..."
        }
    }

    // Waiting icon based on state
    private var waitingIcon: String {
        if !isPeerOnline {
            return "antenna.radiowaves.left.and.right"
        } else if !peerGpsEnabled {
            return "location.slash"
        } else {
            return "location.magnifyingglass"
        }
    }

    private var waitingOverlay: some View {
        VStack(spacing: 12) {
            if isPeerOnline && !peerGpsEnabled {
                // Peer has location disabled - show different icon
                Image(systemName: waitingIcon)
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
            } else {
                // Connecting or waiting for location
                ZStack {
                    ProgressView()
                        .tint(textColor)

                    // Pulse animation
                    Circle()
                        .stroke(textColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 50, height: 50)
                        .scaleEffect(isPeerOnline ? 1.2 : 1.0)
                        .opacity(isPeerOnline ? 0 : 0.5)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPeerOnline)
                }
            }

            Text(waitingText)
                .font(.bitchatSystem(size: 14, design: .monospaced))
                .foregroundColor(isPeerOnline && !peerGpsEnabled ? .orange : textColor)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(backgroundColor.opacity(0.9))
                .shadow(radius: 8)
        )
    }

    private var infoPanel: some View {
        VStack(spacing: 8) {
            Divider()

            // Tracking source indicators
            TrackingSourceIndicators(activeSources: activeSources)
                .padding(.horizontal)
                .padding(.top, 4)

            HStack(spacing: 16) {
                // Connection status
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionQuality.color)
                        .frame(width: 10, height: 10)
                    Text(connectionQuality.description)
                        .font(.bitchatSystem(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(textColor)
                }

                Spacer()

                // Ping
                if let ping = pingMs {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundColor(textColor.opacity(0.7))
                        Text("\(ping) ms")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(textColor)
                    }
                }

                // RSSI
                if let rssiValue = rssi {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundColor(textColor.opacity(0.7))
                        Text("\(rssiValue) dBm")
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(textColor)
                    }
                }
            }
            .padding(.horizontal)

            // Distance and accuracy
            HStack(spacing: 16) {
                if let distance = distanceText, let (_, source) = bestDistance {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 10))
                            .foregroundColor(source.activeColor.opacity(0.7))
                        Text(distance)
                            .font(.bitchatSystem(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(source.activeColor)
                        // Show source badge
                        TrackingSourceBadge(source: source)
                    }
                }

                Spacer()

                if let peerAcc = peerHorizontalAccuracy, peerAcc > 0 {
                    Text("Peer accuracy: \u{00B1}\(Int(peerAcc))m")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.6))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(backgroundColor)
    }

    // MARK: - Data Fetching

    private func fetchTrackingData() {
        // Try to find current peerID for this fingerprint (may change on reconnection)
        let peerIDToUse: PeerID
        var useBLE = false
        var useRelay = false

        // Store Noise key for relay tracking
        var noiseKeyForRelay: Data?

        // Debug: Log tracking attempt
        print("[Tracking] Fetching data for fingerprint: \(fingerprint.prefix(16))..., initialPeerID: \(initialPeerID.id.prefix(16))")

        if let foundPeerID = viewModel.getPeerID(for: fingerprint) {
            peerIDToUse = foundPeerID
            currentPeerID = foundPeerID

            // Debug: Check peer formats
            let shortID = foundPeerID.toShort()
            print("[Tracking] Found peer - peerID: \(foundPeerID.id.prefix(16)), shortID: \(shortID.id.prefix(16)), isShort: \(foundPeerID.isShort)")

            useBLE = viewModel.meshService.isPeerReachable(foundPeerID)
            print("[Tracking] isPeerReachable(\(foundPeerID.id.prefix(16))): \(useBLE)")

            // Check Nostr reachability by looking up favorite status via Noise key
            var nostrReachable = false
            if let peer = viewModel.unifiedPeerService.getPeer(by: foundPeerID) {
                let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: peer.noisePublicKey)
                nostrReachable = favoriteStatus?.isMutual == true && favoriteStatus?.peerNostrPublicKey != nil
                if nostrReachable {
                    noiseKeyForRelay = peer.noisePublicKey
                }
                print("[Tracking] Peer found in unified service - noiseKey: \(peer.noisePublicKey.hexEncodedString().prefix(16))...")
            } else {
                print("[Tracking] Peer NOT found in unified service for peerID: \(foundPeerID)")
            }

            // If BLE not available, check if Nostr relay is available
            if !useBLE && nostrReachable {
                useRelay = true
                print("[Tracking] Found peer by fingerprint, using relay (BLE not available)")
            } else {
                print("[Tracking] Found peer by fingerprint - BLE: \(useBLE), Nostr: \(nostrReachable), peerID: \(foundPeerID.id.prefix(16))...")
            }
        } else if viewModel.meshService.isPeerReachable(initialPeerID) {
            peerIDToUse = initialPeerID
            currentPeerID = initialPeerID
            useBLE = true
            print("[Tracking] Using initial peerID - BLE reachable")
        } else if let lastKnown = currentPeerID, viewModel.meshService.isPeerReachable(lastKnown) {
            peerIDToUse = lastKnown
            useBLE = true
            print("[Tracking] Using last known peerID - BLE reachable")
        } else if viewModel.nostrTransport.isPeerReachable(initialPeerID) {
            // BLE not available, but peer is reachable via Nostr relay
            peerIDToUse = initialPeerID
            currentPeerID = initialPeerID
            useRelay = true
            print("[Tracking] Using relay transport - BLE not available")
        } else {
            print("[Tracking] Peer not found - fingerprint: \(fingerprint.prefix(8)), initialPeerID: \(initialPeerID.id.prefix(16)), BLE: \(viewModel.meshService.isPeerReachable(initialPeerID)), Relay: \(viewModel.nostrTransport.isPeerReachable(initialPeerID))")
            isPeerOnline = false
            isUsingRelay = false
            return
        }

        isPeerOnline = true
        isUsingRelay = useRelay

        // Choose transport based on availability
        if useBLE {
            // Use BLE mesh (can also get RSSI and UWB)
            viewModel.meshService.sendTrackRequest(to: peerIDToUse) { result in
                handleTrackResult(result)
            }
        } else if useRelay, let noiseKey = noiseKeyForRelay {
            // Use Nostr relay (GPS only, no RSSI/UWB)
            viewModel.nostrTransport.sendTrackRequest(to: peerIDToUse, noisePublicKey: noiseKey) { result in
                handleTrackResult(result)
            }
        }
    }

    private func handleTrackResult(_ result: Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) {
        DispatchQueue.main.async { [self] in
            switch result {
            case .success(let (response, newPingMs, newRssi)):
                pingMs = newPingMs
                rssi = newRssi  // Will be nil for relay tracking
                peerGpsEnabled = response.gpsEnabled
                peerUwbSupported = response.uwbSupported
                peerLatitude = response.latitude
                peerLongitude = response.longitude
                peerAltitude = response.altitude
                peerHorizontalAccuracy = response.horizontalAccuracy
                peerVerticalAccuracy = response.verticalAccuracy

                // Debug logging for GPS - show exact values and whether peerLocation will be valid
                let hasValidCoords = response.latitude != nil && response.longitude != nil
                print("[Tracking] Response - GPS enabled: \(response.gpsEnabled), lat: \(String(format: "%.6f", response.latitude ?? 0)), lon: \(String(format: "%.6f", response.longitude ?? 0)), accuracy: \(response.horizontalAccuracy ?? -1), hasValidCoords: \(hasValidCoords)")

                // Debug logging for UWB
                print("[Tracking] Response - UWB supported: \(response.uwbSupported), token: \(response.uwbToken?.count ?? 0) bytes")

                // Process UWB token if present and we have a valid peerID
                // This ensures UWB session is established even if BLEService missed it
                if let peerID = currentPeerID, let uwbToken = response.uwbToken, !uwbToken.isEmpty {
                    print("[Tracking] Processing UWB token from response")
                    uwbManager.handleReceivedToken(from: peerID, tokenData: uwbToken)
                }

                // Log current UWB state
                if let peerID = currentPeerID {
                    let uwbDist = uwbManager.getDistance(for: peerID)
                    let uwbState = uwbManager.activeSessions[peerID.toShort()]
                    print("[Tracking] UWB state for peer: distance=\(uwbDist ?? -1), state=\(String(describing: uwbState))")
                }

                // Add to history (keep last 20)
                let entry = TrackingEntry(
                    timestamp: Date(),
                    pingMs: newPingMs,
                    rssi: newRssi,
                    hasGPS: response.gpsEnabled && response.latitude != nil
                )
                history.append(entry)
                if history.count > 20 {
                    history.removeFirst()
                }

            case .failure(let error):
                print("[Tracking] Request failed: \(error)")
            }
        }
    }
}
