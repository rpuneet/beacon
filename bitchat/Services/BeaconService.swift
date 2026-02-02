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

/// Beacon service - sends PING to favorites, receives PONG with location
@MainActor
final class BeaconService: ObservableObject {
    static let shared = BeaconService()

    // MARK: - Published State

    @Published private(set) var peerLocations: [String: PeerLocation] = [:]
    @Published private(set) var isPinging: Bool = false
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
    private var trackingTimer: Timer?
    private var pendingPings: [String: (noiseKey: Data, sentAt: Date)] = [:]

    private var locationManager: LocationStateManager { .shared }
    private var favoritesService: FavoritesPersistenceService { .shared }

    private init() {}

    // MARK: - Configuration

    func configure(ble: BLEService) {
        self.bleService = ble
        SecureLogger.info("[Beacon] Configured", category: .session)
    }

    // MARK: - Beacon Mode (auto-ping every 10s)

    private func startBeaconMode() {
        SecureLogger.info("[Beacon] Mode ON", category: .session)
        pingAllFavorites()
        beaconTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingAllFavorites() }
        }
        // Keep timer alive in background
        RunLoop.current.add(beaconTimer!, forMode: .common)
    }

    private func stopBeaconMode() {
        SecureLogger.info("[Beacon] Mode OFF", category: .session)
        beaconTimer?.invalidate()
        beaconTimer = nil
    }

    // MARK: - Tracking Mode (ping single peer every 1s)

    func startTracking(peerNoiseKey: Data) {
        stopTracking()
        SecureLogger.info("[Beacon] Tracking started", category: .session)
        pingSinglePeer(noiseKey: peerNoiseKey)
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingSinglePeer(noiseKey: peerNoiseKey) }
        }
        RunLoop.current.add(trackingTimer!, forMode: .common)
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func pingSinglePeer(noiseKey: Data) {
        guard let ble = bleService else { return }
        let connectedPeers = ble.getConnectedPeersWithNoiseKeys()
        guard let (peerID, _) = connectedPeers.first(where: { $0.noiseKey == noiseKey }) else { return }

        let requestID = UUID().uuidString.prefix(8).description
        let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
        let content = "[PING]:\(requestID):\(rssi):\(encodeLocation())"

        pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
        ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)
    }

    // MARK: - Ping All Favorites

    func pingAllFavorites() {
        guard let ble = bleService else { return }

        let connectedPeers = ble.getConnectedPeersWithNoiseKeys()
        let connectedFavorites = connectedPeers.filter { favoritesService.favorites[$0.noiseKey]?.isFavorite == true }

        guard !connectedFavorites.isEmpty else {
            SecureLogger.info("[Beacon] No favorites in range", category: .session)
            return
        }

        isPinging = true
        let locationData = encodeLocation()

        for (peerID, noiseKey) in connectedFavorites {
            let requestID = UUID().uuidString.prefix(8).description
            let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
            let content = "[PING]:\(requestID):\(rssi):\(locationData)"

            pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
            ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)
            SecureLogger.info("[Beacon] PING → \(peerID.id.prefix(8))", category: .session)
        }

        // Timeout after 5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.isPinging = false
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
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return }

        let requestID = String(parts[0])
        let rssiStr = parts.count > 1 ? String(parts[1]) : ""
        let locationStr = parts.count > 2 ? String(parts[2]) : ""

        // Only respond to favorites
        guard let noiseKey = senderNoiseKey,
              let favorite = favoritesService.favorites[noiseKey],
              favorite.isFavorite else { return }

        SecureLogger.info("[Beacon] PING ← \(peerID.id.prefix(8))", category: .session)

        // Store sender's location (so we update when they ping us)
        if let location = decodeLocation(locationStr) {
            storePeerLocation(
                noiseKey: noiseKey,
                lat: location.lat, lon: location.lon,
                alt: location.alt, hacc: location.hacc, vacc: location.vacc,
                rssi: Int(rssiStr), transport: transport, pingMs: 0
            )
        }

        // Send PONG back
        sendPong(to: peerID, requestID: requestID)
    }

    // MARK: - Handle PONG

    private func handlePong(from peerID: PeerID, content: String, transport: PeerLocation.TransportType) {
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return }

        let requestID = String(parts[0])
        let rssiStr = parts.count > 1 ? String(parts[1]) : ""
        let locationStr = parts.count > 2 ? String(parts[2]) : ""

        guard let pending = pendingPings.removeValue(forKey: requestID) else { return }

        let rtt = Int(Date().timeIntervalSince(pending.sentAt) * 1000)
        SecureLogger.info("[Beacon] PONG ← \(peerID.id.prefix(8)) RTT:\(rtt)ms", category: .session)

        isPinging = false
        HapticManager.shared.pingResponseReceived()

        if let location = decodeLocation(locationStr) {
            storePeerLocation(
                noiseKey: pending.noiseKey,
                lat: location.lat, lon: location.lon,
                alt: location.alt, hacc: location.hacc, vacc: location.vacc,
                rssi: Int(rssiStr), transport: transport, pingMs: rtt
            )
        }
    }

    // MARK: - Send PONG

    private func sendPong(to peerID: PeerID, requestID: String) {
        guard let ble = bleService else { return }
        let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
        let content = "[PONG]:\(requestID):\(rssi):\(encodeLocation())"
        ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
        SecureLogger.info("[Beacon] PONG → \(peerID.id.prefix(8))", category: .session)
    }

    // MARK: - Location Encoding/Decoding

    private func encodeLocation() -> String {
        guard locationManager.isLocationEnabled,
              let loc = locationManager.currentLocation else { return "" }
        return String(format: "%.6f,%.6f,%d,%d,%d",
                      loc.coordinate.latitude, loc.coordinate.longitude,
                      Int(loc.altitude), Int(loc.horizontalAccuracy), Int(loc.verticalAccuracy))
    }

    private func decodeLocation(_ str: String) -> (lat: Double, lon: Double, alt: Int, hacc: Int, vacc: Int)? {
        guard !str.isEmpty else { return nil }
        let parts = str.split(separator: ",")
        guard parts.count == 5,
              let lat = Double(parts[0]), let lon = Double(parts[1]),
              let alt = Int(parts[2]), let hacc = Int(parts[3]), let vacc = Int(parts[4]) else { return nil }
        return (lat, lon, alt, hacc, vacc)
    }

    private func storePeerLocation(noiseKey: Data, lat: Double, lon: Double, alt: Int, hacc: Int, vacc: Int,
                                   rssi: Int?, transport: PeerLocation.TransportType, pingMs: Int) {
        let peerID = PeerID(publicKey: noiseKey)
        peerLocations[peerID.id] = PeerLocation(
            peerIDString: peerID.id, gpsEnabled: true,
            latitude: lat, longitude: lon, altitude: Double(alt), horizontalAccuracy: Double(hacc),
            transport: transport, pingMs: pingMs, peerRSSI: rssi,
            uwbSupported: false, uwbToken: nil, timestamp: Date()
        )
    }

    // MARK: - Helpers

    var peersWithLocationCount: Int {
        peerLocations.values.filter { $0.hasLocation }.count
    }

    func clearLocations() {
        peerLocations.removeAll()
    }
}
