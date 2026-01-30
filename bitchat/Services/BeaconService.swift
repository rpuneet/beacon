//
// BeaconService.swift
// bitchat
//
// Simple beacon service for location sharing between favorites over mesh
//

import Foundation
import Combine
import CoreLocation
import BitLogger
import simd

/// State of ping operation
enum BeaconPingState: Equatable {
    case idle
    case pinging(sent: Int, received: Int)
    case completed(received: Int, total: Int)
    case failed(String)
}

/// Beacon service - sends PING to favorites, receives PONG with location
@MainActor
final class BeaconService: ObservableObject {
    static let shared = BeaconService()

    // MARK: - Published State

    @Published private(set) var peerLocations: [String: PeerLocation] = [:]
    @Published private(set) var pingState: BeaconPingState = .idle
    @Published private(set) var lastPongReceived: (coordinate: CLLocationCoordinate2D, id: UUID)?

    @Published var isBeaconModeEnabled: Bool = false {
        didSet {
            if isBeaconModeEnabled {
                startBeaconMode()
            } else {
                stopBeaconMode()
            }
        }
    }

    // MARK: - Private State

    private weak var bleService: BLEService?
    private var beaconTimer: Timer?
    private var pendingPings: [String: (noiseKey: Data, sentAt: Date)] = [:]
    private var pingTargetCount = 0
    private var receivedCount = 0

    private var locationManager: LocationStateManager { .shared }
    private var favoritesService: FavoritesPersistenceService { .shared }
    private var uwbManager: UWBTrackingManager { .shared }

    private init() {}

    // MARK: - Configuration

    func configure(ble: BLEService) {
        self.bleService = ble
        SecureLogger.info("[Beacon] Configured", category: .session)
    }

    // MARK: - Beacon Mode (auto-ping every 30s)

    private func startBeaconMode() {
        SecureLogger.info("[Beacon] Mode ON - pinging every 30s", category: .session)
        pingAllFavorites()
        beaconTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingAllFavorites() }
        }
    }

    private func stopBeaconMode() {
        SecureLogger.info("[Beacon] Mode OFF", category: .session)
        beaconTimer?.invalidate()
        beaconTimer = nil
    }

    // MARK: - Ping All Favorites

    func pingAllFavorites() {
        guard let ble = bleService else {
            pingState = .failed("No BLE service")
            return
        }

        // Get connected peers that are favorites
        let connectedPeers = ble.getConnectedPeersWithNoiseKeys()
        let connectedFavorites = connectedPeers.filter { favoritesService.favorites[$0.noiseKey]?.isFavorite == true }

        guard !connectedFavorites.isEmpty else {
            SecureLogger.info("[Beacon] No favorites in BLE range", category: .session)
            pingState = .failed("No favorites in range")
            return
        }

        // Reset state
        pendingPings.removeAll()
        pingTargetCount = connectedFavorites.count
        receivedCount = 0
        pingState = .pinging(sent: pingTargetCount, received: 0)

        SecureLogger.info("[Beacon] Pinging \(connectedFavorites.count) favorites", category: .session)
        HapticManager.shared.pingStarted()

        // Build my location data
        let myNoiseKey = ble.getNoiseService().getStaticPublicKeyData()
        let myLocation = buildLocationData(for: nil)

        // Send PING to each favorite
        for (peerID, noiseKey) in connectedFavorites {
            let requestID = UUID().uuidString.prefix(8).description
            let content = "[PING]:\(requestID):\(myNoiseKey.hexEncodedString()):\(myLocation)"

            pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
            ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)

            let nick = favoritesService.favorites[noiseKey]?.peerNickname ?? peerID.id.prefix(8).description
            SecureLogger.info("[Beacon] PING → \(nick)", category: .session)
        }

        // Timeout after 15s
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.finishPingIfNeeded()
        }
    }

    // MARK: - Handle Incoming Messages

    /// Returns true if message was handled (PING or PONG)
    @discardableResult
    func handlePrivateMessage(from peerID: PeerID, content: String, transport: PeerLocation.TransportType) -> Bool {
        if content.hasPrefix("[PING]:") {
            handlePing(from: peerID, content: content, transport: transport)
            return true
        } else if content.hasPrefix("[PONG]:") {
            handlePong(from: peerID, content: content, transport: transport)
            return true
        }
        return false
    }

    // MARK: - Handle PING

    private func handlePing(from peerID: PeerID, content: String, transport: PeerLocation.TransportType) {
        // Parse: [PING]:requestID:senderNoiseKey:locationBase64
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 2)
        guard parts.count >= 2 else {
            SecureLogger.warning("[Beacon] Invalid PING format", category: .session)
            return
        }

        let requestID = String(parts[0])
        let senderNoiseKeyHex = String(parts[1])
        let locationBase64 = parts.count > 2 ? String(parts[2]) : nil

        guard let senderNoiseKey = Data(hexString: senderNoiseKeyHex) else {
            SecureLogger.warning("[Beacon] Invalid noise key in PING", category: .session)
            return
        }

        // Only respond to favorites
        guard let favorite = favoritesService.favorites[senderNoiseKey], favorite.isFavorite else {
            SecureLogger.info("[Beacon] PING from non-favorite, ignoring", category: .session)
            return
        }

        let nick = favorite.peerNickname ?? senderNoiseKeyHex.prefix(8).description
        SecureLogger.info("[Beacon] PING ← \(nick)", category: .session)

        // Store sender's location (bidirectional)
        if let locationBase64 = locationBase64, let locationData = PongResponseData.fromBase64(locationBase64) {
            let senderPeerID = PeerID(publicKey: senderNoiseKey)
            peerLocations[senderPeerID.id] = PeerLocation(
                peerID: senderPeerID,
                response: locationData,
                transport: transport,
                pingMs: 0
            )
            SecureLogger.info("[Beacon] Stored \(nick)'s location", category: .session)
        }

        // Send PONG back
        sendPong(to: peerID, requestID: requestID)
    }

    // MARK: - Handle PONG

    private func handlePong(from peerID: PeerID, content: String, transport: PeerLocation.TransportType) {
        // Parse: [PONG]:requestID:locationBase64
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            SecureLogger.warning("[Beacon] Invalid PONG format", category: .session)
            return
        }

        let requestID = String(parts[0])
        let locationBase64 = String(parts[1])

        guard let pending = pendingPings.removeValue(forKey: requestID) else {
            SecureLogger.warning("[Beacon] PONG for unknown request", category: .session)
            return
        }

        guard let locationData = PongResponseData.fromBase64(locationBase64) else {
            SecureLogger.warning("[Beacon] Failed to parse PONG location", category: .session)
            return
        }

        let rtt = Int(Date().timeIntervalSince(pending.sentAt) * 1000)
        let noiseKeyPeerID = PeerID(publicKey: pending.noiseKey)
        let nick = favoritesService.favorites[pending.noiseKey]?.peerNickname ?? peerID.id.prefix(8).description

        // Store location
        let location = PeerLocation(
            peerID: noiseKeyPeerID,
            response: locationData,
            transport: transport,
            pingMs: rtt
        )
        peerLocations[noiseKeyPeerID.id] = location

        SecureLogger.info("[Beacon] PONG ← \(nick) (RTT: \(rtt)ms)", category: .session)

        // Wave animation
        if let coord = location.coordinate {
            lastPongReceived = (coordinate: coord, id: UUID())
        }

        // UWB ranging
        if let uwbToken = location.uwbToken, location.uwbSupported {
            uwbManager.handleReceivedToken(from: noiseKeyPeerID, tokenData: uwbToken)
        }

        // Update state
        receivedCount += 1
        pingState = .pinging(sent: pingTargetCount, received: receivedCount)
        HapticManager.shared.pingResponseReceived()

        if receivedCount >= pingTargetCount {
            finishPingIfNeeded()
        }
    }

    // MARK: - Send PONG

    private func sendPong(to peerID: PeerID, requestID: String) {
        guard let ble = bleService else { return }

        let locationBase64 = buildLocationData(for: peerID)
        let content = "[PONG]:\(requestID):\(locationBase64)"

        ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
        SecureLogger.info("[Beacon] PONG → \(peerID.id.prefix(8))", category: .session)
    }

    // MARK: - Helpers

    private func buildLocationData(for peerID: PeerID?) -> String {
        let location = locationManager.currentLocation
        let uwbToken = peerID.flatMap { uwbManager.getMyTokenData(for: $0) }
        let rssi = peerID.flatMap { bleService?.getRSSI(for: $0) }

        let data = PongResponseData.build(
            gpsEnabled: locationManager.isLocationEnabled,
            location: location,
            uwbSupported: uwbManager.isUWBSupported,
            uwbToken: uwbToken,
            rssiForRequester: rssi
        )
        return data.toBase64() ?? ""
    }

    private func finishPingIfNeeded() {
        guard case .pinging = pingState else { return }
        pendingPings.removeAll()
        pingState = .completed(received: receivedCount, total: pingTargetCount)
        HapticManager.shared.pingCompleted(responseCount: receivedCount)
        SecureLogger.info("[Beacon] Complete: \(receivedCount)/\(pingTargetCount) responded", category: .session)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if case .completed = self?.pingState {
                self?.pingState = .idle
            }
        }
    }

    // MARK: - Public Queries

    var peersWithLocationCount: Int {
        peerLocations.values.filter { $0.hasLocation }.count
    }

    var isPinging: Bool {
        if case .pinging = pingState { return true }
        return false
    }

    func clearLocations() {
        peerLocations.removeAll()
    }
}
