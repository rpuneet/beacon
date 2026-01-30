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

    private init() {}

    // MARK: - Configuration

    func configure(ble: BLEService) {
        self.bleService = ble
        SecureLogger.info("[Beacon] Configured", category: .session)
    }

    // MARK: - Beacon Mode (auto-ping every 30s)

    private func startBeaconMode() {
        SecureLogger.info("[Beacon] Mode ON", category: .session)
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

        let connectedPeers = ble.getConnectedPeersWithNoiseKeys()
        let connectedFavorites = connectedPeers.filter { favoritesService.favorites[$0.noiseKey]?.isFavorite == true }

        guard !connectedFavorites.isEmpty else {
            SecureLogger.info("[Beacon] No favorites in range", category: .session)
            pingState = .failed("No favorites in range")
            return
        }

        pendingPings.removeAll()
        pingTargetCount = connectedFavorites.count
        receivedCount = 0
        pingState = .pinging(sent: pingTargetCount, received: 0)

        SecureLogger.info("[Beacon] Pinging \(connectedFavorites.count) favorites", category: .session)
        HapticManager.shared.pingStarted()

        let locationData = encodeLocation()

        for (peerID, noiseKey) in connectedFavorites {
            let requestID = UUID().uuidString.prefix(8).description
            // Format: [PING]:ID:rssi:lat,lon,alt,hacc,vacc
            let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
            let content = "[PING]:\(requestID):\(rssi):\(locationData)"

            pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
            ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)

            let nick = favoritesService.favorites[noiseKey]?.peerNickname ?? peerID.id.prefix(8).description
            SecureLogger.info("[Beacon] PING → \(nick)", category: .session)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.finishPingIfNeeded()
        }
    }

    // MARK: - Handle Incoming Messages

    @discardableResult
    func handlePrivateMessage(from peerID: PeerID, senderNoiseKey: Data?, content: String, transport: PeerLocation.TransportType) -> Bool {
        if content.hasPrefix("[PING]:") {
            handlePing(from: peerID, senderNoiseKey: senderNoiseKey, content: content, transport: transport)
            return true
        } else if content.hasPrefix("[PONG]:") {
            handlePong(from: peerID, content: content, transport: transport)
            return true
        }
        return false
    }

    // MARK: - Handle PING

    private func handlePing(from peerID: PeerID, senderNoiseKey: Data?, content: String, transport: PeerLocation.TransportType) {
        // Format: [PING]:ID:rssi:lat,lon,alt,hacc,vacc
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 1 else {
            SecureLogger.warning("[Beacon] Invalid PING", category: .session)
            return
        }

        let requestID = String(parts[0])
        let rssiStr = parts.count > 1 ? String(parts[1]) : ""
        let locationStr = parts.count > 2 ? String(parts[2]) : ""

        // Only respond to favorites
        guard let noiseKey = senderNoiseKey,
              let favorite = favoritesService.favorites[noiseKey],
              favorite.isFavorite else {
            SecureLogger.info("[Beacon] PING from non-favorite, ignoring", category: .session)
            return
        }

        let nick = favorite.peerNickname ?? peerID.id.prefix(8).description
        SecureLogger.info("[Beacon] PING ← \(nick)", category: .session)

        // Store sender's location
        if let location = decodeLocation(locationStr) {
            let senderPeerID = PeerID(publicKey: noiseKey)
            let rssi = Int(rssiStr)
            storePeerLocation(
                peerID: senderPeerID,
                lat: location.lat,
                lon: location.lon,
                alt: location.alt,
                hacc: location.hacc,
                vacc: location.vacc,
                rssi: rssi,
                transport: transport,
                pingMs: 0
            )
        }

        // Send PONG back
        sendPong(to: peerID, requestID: requestID)
    }

    // MARK: - Handle PONG

    private func handlePong(from peerID: PeerID, content: String, transport: PeerLocation.TransportType) {
        // Format: [PONG]:ID:rssi:lat,lon,alt,hacc,vacc
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 1 else {
            SecureLogger.warning("[Beacon] Invalid PONG", category: .session)
            return
        }

        let requestID = String(parts[0])
        let rssiStr = parts.count > 1 ? String(parts[1]) : ""
        let locationStr = parts.count > 2 ? String(parts[2]) : ""

        guard let pending = pendingPings.removeValue(forKey: requestID) else {
            SecureLogger.warning("[Beacon] PONG for unknown request", category: .session)
            return
        }

        let rtt = Int(Date().timeIntervalSince(pending.sentAt) * 1000)
        let noiseKeyPeerID = PeerID(publicKey: pending.noiseKey)
        let nick = favoritesService.favorites[pending.noiseKey]?.peerNickname ?? peerID.id.prefix(8).description

        // Store location
        if let location = decodeLocation(locationStr) {
            let rssi = Int(rssiStr)
            storePeerLocation(
                peerID: noiseKeyPeerID,
                lat: location.lat,
                lon: location.lon,
                alt: location.alt,
                hacc: location.hacc,
                vacc: location.vacc,
                rssi: rssi,
                transport: transport,
                pingMs: rtt
            )

            SecureLogger.info("[Beacon] PONG ← \(nick) @ \(String(format: "%.4f", location.lat)),\(String(format: "%.4f", location.lon)) (RTT: \(rtt)ms)", category: .session)

            // Wave animation
            lastPongReceived = (coordinate: CLLocationCoordinate2D(latitude: location.lat, longitude: location.lon), id: UUID())
        } else {
            SecureLogger.info("[Beacon] PONG ← \(nick) (no GPS, RTT: \(rtt)ms)", category: .session)
        }

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

        let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
        let locationData = encodeLocation()
        let content = "[PONG]:\(requestID):\(rssi):\(locationData)"

        ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
        SecureLogger.info("[Beacon] PONG → \(peerID.id.prefix(8))", category: .session)
    }

    // MARK: - Location Encoding/Decoding
    // Format: lat,lon,alt,hacc,vacc (empty if no GPS)

    private func encodeLocation() -> String {
        guard locationManager.isLocationEnabled,
              let loc = locationManager.currentLocation else {
            return ""
        }

        let lat = String(format: "%.6f", loc.coordinate.latitude)
        let lon = String(format: "%.6f", loc.coordinate.longitude)
        let alt = Int(loc.altitude)
        let hacc = Int(loc.horizontalAccuracy)
        let vacc = Int(loc.verticalAccuracy)

        return "\(lat),\(lon),\(alt),\(hacc),\(vacc)"
    }

    private func decodeLocation(_ str: String) -> (lat: Double, lon: Double, alt: Int, hacc: Int, vacc: Int)? {
        guard !str.isEmpty else { return nil }

        let parts = str.split(separator: ",")
        guard parts.count == 5,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]),
              let alt = Int(parts[2]),
              let hacc = Int(parts[3]),
              let vacc = Int(parts[4]) else {
            return nil
        }

        return (lat: lat, lon: lon, alt: alt, hacc: hacc, vacc: vacc)
    }

    private func storePeerLocation(
        peerID: PeerID,
        lat: Double,
        lon: Double,
        alt: Int,
        hacc: Int,
        vacc: Int,
        rssi: Int?,
        transport: PeerLocation.TransportType,
        pingMs: Int
    ) {
        peerLocations[peerID.id] = PeerLocation(
            peerIDString: peerID.id,
            gpsEnabled: true,
            latitude: lat,
            longitude: lon,
            altitude: Double(alt),
            horizontalAccuracy: Double(hacc),
            transport: transport,
            pingMs: pingMs,
            peerRSSI: rssi,
            uwbSupported: false,
            uwbToken: nil,
            timestamp: Date()
        )
    }

    // MARK: - Helpers

    private func finishPingIfNeeded() {
        guard case .pinging = pingState else { return }
        pendingPings.removeAll()
        pingState = .completed(received: receivedCount, total: pingTargetCount)
        HapticManager.shared.pingCompleted(responseCount: receivedCount)
        SecureLogger.info("[Beacon] Complete: \(receivedCount)/\(pingTargetCount)", category: .session)

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
