//
// BeaconService.swift
// bitchat
//
// Simple beacon service for location sharing between favorites over mesh
//

import BitFoundation
import Foundation
import Combine
import CoreLocation
import simd
import BitLogger

/// Beacon service - sends PING to favorites, receives PONG with location.
///
/// Wire format (compact text over encrypted private messages):
///   [PING]:<requestID>:<rssi>:<lat,lon,alt,hacc,vacc>[:<uwbTokenBase64>]
///   [PONG]:<requestID>:<rssi>:<lat,lon,alt,hacc,vacc>[:<uwbTokenBase64>]
/// The location field is coarsened per BeaconSettings before sending, and the
/// optional UWB token enables Nearby Interaction ranging while tracking.
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
    private var trackingPeerNoiseKey: Data?
    private var trackedPeerWasConnected = true
    private var pendingPings: [String: (noiseKey: Data, sentAt: Date)] = [:]
    private var lastSentAudit: [String: Date] = [:]
    private var lastPingHaptic: [String: Date] = [:]
    private var lastUWBFailureLogged: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Unanswered pings older than this are dropped (and logged)
    private static let pendingPingMaxAge: TimeInterval = 10
    /// Outgoing disclosures are audited at most once per peer per window,
    /// so 1 Hz tracking pings don't flood the audit log
    private static let sentAuditThrottle: TimeInterval = 60

    private var locationManager: LocationStateManager { .shared }
    private var favoritesService: FavoritesPersistenceService { .shared }
    private var settings: BeaconSettings { .shared }
    private var auditLog: BeaconAuditLog { .shared }
    private var uwbManager: UWBTrackingManager { .shared }

    private init() {
        loadLastKnownLocations()
    }

    // MARK: - Configuration

    func configure(ble: BLEService) {
        self.bleService = ble
        subscribeToUWBUpdates()
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
        trackingPeerNoiseKey = peerNoiseKey
        trackedPeerWasConnected = true
        auditLog.record(.trackingStarted, peerFingerprint: PeerID(publicKey: peerNoiseKey).id, peerName: peerName(for: peerNoiseKey))
        pingSinglePeer(noiseKey: peerNoiseKey)
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingSinglePeer(noiseKey: peerNoiseKey) }
        }
        RunLoop.current.add(trackingTimer!, forMode: .common)
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let noiseKey = trackingPeerNoiseKey {
            auditLog.record(.trackingStopped, peerFingerprint: PeerID(publicKey: noiseKey).id, peerName: peerName(for: noiseKey))
            uwbManager.endSession(with: PeerID(publicKey: noiseKey))
            trackingPeerNoiseKey = nil
        }
    }

    private func pingSinglePeer(noiseKey: Data) {
        guard let ble = bleService else { return }
        let connectedPeers = ble.getConnectedPeersWithNoiseKeys()
        guard let (peerID, _) = connectedPeers.first(where: { $0.noiseKey == noiseKey }) else {
            if trackedPeerWasConnected {
                trackedPeerWasConnected = false
                SecureLogger.warning("[Beacon] Tracked peer out of range", category: .session)
            }
            return
        }
        trackedPeerWasConnected = true

        let requestID = UUID().uuidString.prefix(8).description
        let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
        // Tracking mode wants UWB precision: offer our discovery token
        let token = uwbTokenField(for: noiseKey, forceExchange: false)
        let locationStr = encodeLocation(for: noiseKey)
        let content = "[PING]:\(requestID):\(rssi):\(locationStr)\(token)"

        prunePendingPings()
        pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
        ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)
        auditLocationSent(noiseKey: noiseKey, locationStr: locationStr)
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

        prunePendingPings()
        for (peerID, noiseKey) in connectedFavorites {
            let requestID = UUID().uuidString.prefix(8).description
            let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
            let locationStr = encodeLocation(for: noiseKey)
            let content = "[PING]:\(requestID):\(rssi):\(locationStr)"

            pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
            ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)
            auditLocationSent(noiseKey: noiseKey, locationStr: locationStr)
            SecureLogger.info("[Beacon] PING → \(peerID.id.prefix(8))", category: .session)
        }

        // Timeout after 5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.isPinging = false
            self?.prunePendingPings()
        }
    }

    /// Drop unanswered pings so the pending table can't grow unboundedly
    /// against an unresponsive peer (1 Hz tracking would leak forever).
    private func prunePendingPings() {
        let cutoff = Date().addingTimeInterval(-Self.pendingPingMaxAge)
        let stale = pendingPings.filter { $0.value.sentAt < cutoff }
        guard !stale.isEmpty else { return }
        for key in stale.keys { pendingPings.removeValue(forKey: key) }
        SecureLogger.info("[Beacon] \(stale.count) ping(s) went unanswered", category: .session)
    }

    /// Audit an outgoing location disclosure, throttled per peer.
    private func auditLocationSent(noiseKey: Data, locationStr: String) {
        guard !locationStr.isEmpty else { return }
        let fingerprint = PeerID(publicKey: noiseKey).id
        if let last = lastSentAudit[fingerprint], Date().timeIntervalSince(last) < Self.sentAuditThrottle {
            return
        }
        lastSentAudit[fingerprint] = Date()
        let precision = settings.effectivePrecision(for: noiseKey)
        auditLog.record(.locationSent, peerFingerprint: fingerprint, peerName: peerName(for: noiseKey), precision: precision.displayName)
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
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return }

        let requestID = String(parts[0])
        let rssiStr = parts.count > 1 ? String(parts[1]) : ""
        let locationStr = parts.count > 2 ? String(parts[2]) : ""
        let tokenStr = parts.count > 3 ? String(parts[3]) : ""

        // Only favorites may ping us at all
        guard let noiseKey = senderNoiseKey,
              let favorite = favoritesService.favorites[noiseKey],
              favorite.isFavorite else { return }

        SecureLogger.info("[Beacon] PING ← \(peerID.id.prefix(8))", category: .session)

        // "Ping → they vibrate": let the pinged person feel it, throttled so
        // 1 Hz tracking pings don't buzz continuously
        let senderFingerprint = PeerID(publicKey: noiseKey).id
        if lastPingHaptic[senderFingerprint].map({ Date().timeIntervalSince($0) > 10 }) ?? true {
            lastPingHaptic[senderFingerprint] = Date()
            HapticManager.shared.pingStarted()
        }

        let tokenData = tokenStr.isEmpty ? nil : Data(base64Encoded: tokenStr)
        if !tokenStr.isEmpty && tokenData == nil {
            SecureLogger.error("[Beacon] Malformed UWB token in PING from \(peerID.id.prefix(8))", category: .session)
        }

        // Store sender's location (their disclosure, so always accepted)
        if let location = decodeLocation(locationStr) {
            storePeerLocation(
                noiseKey: noiseKey,
                lat: location.lat, lon: location.lon,
                alt: location.alt, hacc: location.hacc, vacc: location.vacc,
                rssi: Int(rssiStr), transport: transport, pingMs: 0,
                uwbTokenPresent: tokenData != nil
            )
            auditLog.record(.locationReceived, peerFingerprint: PeerID(publicKey: noiseKey).id, peerName: peerName(for: noiseKey))
        }

        // Our disclosure is gated by privacy policy; deny silently (no PONG)
        // so a denied peer can't probe our presence.
        guard settings.canShare(with: noiseKey, isFavorite: favorite.isFavorite, isMutual: favorite.isMutual) else {
            auditLog.record(.pingDenied, peerFingerprint: PeerID(publicKey: noiseKey).id, peerName: peerName(for: noiseKey))
            SecureLogger.info("[Beacon] PING denied by privacy policy", category: .session)
            return
        }

        // Peer offered a UWB token: start ranging and reciprocate in the PONG
        var includeToken = false
        if let tokenData {
            uwbManager.handleReceivedToken(from: PeerID(publicKey: noiseKey), tokenData: tokenData)
            includeToken = true
        }

        sendPong(to: peerID, noiseKey: noiseKey, requestID: requestID, includeUWBToken: includeToken)
    }

    // MARK: - Handle PONG

    private func handlePong(from peerID: PeerID, content: String, transport: PeerLocation.TransportType) {
        let parts = content.dropFirst(7).split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 1 else { return }

        let requestID = String(parts[0])
        let rssiStr = parts.count > 1 ? String(parts[1]) : ""
        let locationStr = parts.count > 2 ? String(parts[2]) : ""
        let tokenStr = parts.count > 3 ? String(parts[3]) : ""

        guard let pending = pendingPings.removeValue(forKey: requestID) else {
            SecureLogger.debug("[Beacon] Unsolicited PONG from \(peerID.id.prefix(8)) dropped", category: .session)
            return
        }

        let rtt = Int(Date().timeIntervalSince(pending.sentAt) * 1000)
        SecureLogger.info("[Beacon] PONG ← \(peerID.id.prefix(8)) RTT:\(rtt)ms", category: .session)

        isPinging = false
        HapticManager.shared.pingResponseReceived()

        var validTokenReceived = false
        if !tokenStr.isEmpty {
            if let tokenData = Data(base64Encoded: tokenStr) {
                uwbManager.handleReceivedToken(from: PeerID(publicKey: pending.noiseKey), tokenData: tokenData)
                validTokenReceived = true
            } else {
                SecureLogger.error("[Beacon] Malformed UWB token in PONG from \(peerID.id.prefix(8))", category: .session)
            }
        }

        if let location = decodeLocation(locationStr) {
            storePeerLocation(
                noiseKey: pending.noiseKey,
                lat: location.lat, lon: location.lon,
                alt: location.alt, hacc: location.hacc, vacc: location.vacc,
                rssi: Int(rssiStr), transport: transport, pingMs: rtt,
                uwbTokenPresent: validTokenReceived
            )
            auditLog.record(.locationReceived, peerFingerprint: PeerID(publicKey: pending.noiseKey).id, peerName: peerName(for: pending.noiseKey))
        }
    }

    // MARK: - Send PONG

    private func sendPong(to peerID: PeerID, noiseKey: Data, requestID: String, includeUWBToken: Bool) {
        guard let ble = bleService else { return }
        let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
        let token = includeUWBToken ? uwbTokenField(for: noiseKey, forceExchange: true) : ""
        let locationStr = encodeLocation(for: noiseKey)
        let content = "[PONG]:\(requestID):\(rssi):\(locationStr)\(token)"
        ble.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
        SecureLogger.info("[Beacon] PONG → \(peerID.id.prefix(8))", category: .session)

        if locationStr.isEmpty {
            SecureLogger.info("[Beacon] PONG sent without location (enabled=\(locationManager.isLocationEnabled), hasFix=\(locationManager.currentLocation != nil))", category: .session)
        } else {
            auditLocationSent(noiseKey: noiseKey, locationStr: locationStr)
        }
    }

    // MARK: - Location Encoding/Decoding

    /// Encode our location for a specific peer, applying privacy policy and
    /// precision coarsening. Empty string when nothing may be disclosed.
    private func encodeLocation(for noiseKey: Data) -> String {
        guard locationManager.isLocationEnabled,
              let loc = locationManager.currentLocation else { return "" }

        let favorite = favoritesService.favorites[noiseKey]
        guard settings.canShare(with: noiseKey,
                                isFavorite: favorite?.isFavorite ?? false,
                                isMutual: favorite?.isMutual ?? false) else { return "" }

        let level = settings.effectivePrecision(for: noiseKey)
        let coarse = BeaconSettings.coarsen(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            to: level
        )
        // Altitude is omitted at coarse precision (it would leak floor-level detail)
        let altitude = level == .exact ? Int(loc.altitude) : 0
        let verticalAccuracy = level == .exact ? Int(loc.verticalAccuracy) : -1
        return String(format: "%.6f,%.6f,%d,%d,%d",
                      coarse.latitude, coarse.longitude,
                      altitude, Int(coarse.horizontalAccuracy), verticalAccuracy)
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
                                   rssi: Int?, transport: PeerLocation.TransportType, pingMs: Int,
                                   uwbTokenPresent: Bool = false) {
        let peerID = PeerID(publicKey: noiseKey)
        var location = PeerLocation(
            peerIDString: peerID.id, gpsEnabled: true,
            latitude: lat, longitude: lon, altitude: Double(alt), horizontalAccuracy: Double(hacc),
            transport: transport, pingMs: pingMs, peerRSSI: rssi,
            uwbSupported: uwbTokenPresent, uwbToken: nil, timestamp: Date()
        )
        // Carry over live UWB ranging so a GPS refresh doesn't blank it out
        if let existing = peerLocations[peerID.id], let distance = existing.uwbDistance {
            location.updateUWBDistance(distance, direction: existing.uwbDirection)
        }
        peerLocations[peerID.id] = location
        saveLastKnownLocations()
    }

    // MARK: - Last-Known Location Persistence

    /// Snapshot persisted so favorites still appear on the map after an app
    /// restart (grey/stale until they respond again).
    private struct LocationSnapshot: Codable {
        let peerID: String
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let transport: String
        let timestamp: Date
    }

    private static let lastKnownKey = "beacon.lastKnownLocations"
    private static let lastKnownMaxAge: TimeInterval = 7 * 24 * 3600

    private func saveLastKnownLocations() {
        let snapshots = peerLocations.values.compactMap { loc -> LocationSnapshot? in
            guard let lat = loc.latitude, let lon = loc.longitude else { return nil }
            return LocationSnapshot(
                peerID: loc.peerIDString, latitude: lat, longitude: lon,
                altitude: loc.altitude ?? 0, horizontalAccuracy: loc.horizontalAccuracy ?? 0,
                transport: loc.transport.rawValue, timestamp: loc.timestamp
            )
        }
        do {
            let data = try JSONEncoder().encode(snapshots)
            UserDefaults.standard.set(data, forKey: Self.lastKnownKey)
        } catch {
            SecureLogger.error("[Beacon] Failed to persist last-known locations: \(error)", category: .session)
        }
    }

    private func loadLastKnownLocations() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastKnownKey) else { return }
        do {
            let snapshots = try JSONDecoder().decode([LocationSnapshot].self, from: data)
            let cutoff = Date().addingTimeInterval(-Self.lastKnownMaxAge)
            for snap in snapshots where snap.timestamp > cutoff {
                peerLocations[snap.peerID] = PeerLocation(
                    peerIDString: snap.peerID, gpsEnabled: true,
                    latitude: snap.latitude, longitude: snap.longitude,
                    altitude: snap.altitude, horizontalAccuracy: snap.horizontalAccuracy,
                    transport: PeerLocation.TransportType(rawValue: snap.transport) ?? .ble,
                    pingMs: 0, peerRSSI: nil,
                    uwbSupported: false, uwbToken: nil, timestamp: snap.timestamp
                )
            }
        } catch {
            SecureLogger.error("[Beacon] Failed to load last-known locations: \(error)", category: .session)
        }
    }

    // MARK: - UWB

    /// Build the optional `:<tokenBase64>` message suffix for a peer.
    /// `forceExchange` bypasses the session-state check (used when replying to
    /// a peer-initiated exchange or after a retry request).
    private func uwbTokenField(for noiseKey: Data, forceExchange: Bool) -> String {
        let peerID = PeerID(publicKey: noiseKey)
        guard forceExchange || uwbManager.shouldSendToken(to: peerID) else { return "" }
        guard let tokenData = uwbManager.getMyTokenData(for: peerID) else { return "" }
        return ":" + tokenData.base64EncodedString()
    }

    private func subscribeToUWBUpdates() {
        guard cancellables.isEmpty else { return }

        uwbManager.$activeSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.applyUWBSessions(sessions)
            }
            .store(in: &cancellables)

        #if os(iOS)
        NotificationCenter.default.publisher(for: .uwbRetryRequested)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let peerID = notification.userInfo?["peerID"] as? PeerID,
                      let noiseKey = self.trackingPeerNoiseKey,
                      PeerID(publicKey: noiseKey) == peerID else { return }
                self.sendUWBRetryPing(noiseKey: noiseKey)
            }
            .store(in: &cancellables)
        #endif
    }

    private func applyUWBSessions(_ sessions: [PeerID: UWBTrackingManager.UWBSessionState]) {
        for (peerID, state) in sessions {
            switch state {
            case .active(let distance, let direction):
                lastUWBFailureLogged.removeValue(forKey: peerID.id)
                guard let distance, let existing = peerLocations[peerID.id] else { continue }
                var location = existing
                location.updateUWBDistance(distance, direction: direction)
                peerLocations[peerID.id] = location
            case .failed(let message):
                // Surface the failure instead of dropping it (once per message)
                if lastUWBFailureLogged[peerID.id] != message {
                    lastUWBFailureLogged[peerID.id] = message
                    SecureLogger.warning("[Beacon] UWB session failed for \(peerID.id.prefix(8)): \(message)", category: .session)
                }
            case .connecting, .suspended:
                break
            }
        }
    }

    /// Re-offer our token after the UWB session dropped (fresh session, fresh token).
    private func sendUWBRetryPing(noiseKey: Data) {
        guard let ble = bleService else { return }
        let connectedPeers = ble.getConnectedPeersWithNoiseKeys()
        guard let (peerID, _) = connectedPeers.first(where: { $0.noiseKey == noiseKey }) else { return }

        let requestID = UUID().uuidString.prefix(8).description
        let rssi = ble.getRSSI(for: peerID).map { String($0) } ?? ""
        let token = uwbTokenField(for: noiseKey, forceExchange: true)
        guard !token.isEmpty else { return }

        let locationStr = encodeLocation(for: noiseKey)
        pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
        ble.sendPrivateMessage("[PING]:\(requestID):\(rssi):\(locationStr)\(token)",
                               to: peerID, recipientNickname: "", messageID: requestID)
        auditLocationSent(noiseKey: noiseKey, locationStr: locationStr)
    }

    // MARK: - Helpers

    private func peerName(for noiseKey: Data) -> String {
        favoritesService.favorites[noiseKey]?.peerNickname ?? String(PeerID(publicKey: noiseKey).id.prefix(8))
    }

    var peersWithLocationCount: Int {
        peerLocations.values.filter { $0.hasLocation }.count
    }

    func clearLocations() {
        peerLocations.removeAll()
        uwbManager.endAllSessions()
    }
}
