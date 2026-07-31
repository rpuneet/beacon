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
        // Tracking mode wants UWB precision: offer our discovery token
        let locationStr = encodeLocation(for: noiseKey)
        let content = BeaconWire.encode(
            kind: .ping, requestID: requestID, rssi: ble.getRSSI(for: peerID),
            locationStr: locationStr, uwbTokenBase64: uwbTokenBase64(for: noiseKey, forceExchange: false)
        )

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
            let locationStr = encodeLocation(for: noiseKey)
            let content = BeaconWire.encode(kind: .ping, requestID: requestID,
                                            rssi: ble.getRSSI(for: peerID), locationStr: locationStr)

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
        guard let message = BeaconWire.parse(content) else {
            // Consume malformed beacon-prefixed messages so they never render as chat
            if content.hasPrefix(BeaconWire.pingPrefix) || content.hasPrefix(BeaconWire.pongPrefix) {
                SecureLogger.warning("[Beacon] Malformed beacon message from \(peerID.id.prefix(8)) dropped", category: .session)
                return true
            }
            return false
        }
        switch message.kind {
        case .ping:
            handlePing(from: peerID, senderNoiseKey: senderNoiseKey, message: message, transport: transport)
        case .pong:
            handlePong(from: peerID, message: message, transport: transport)
        }
        return true
    }

    // MARK: - Handle PING

    private func handlePing(from peerID: PeerID, senderNoiseKey: Data?, message: BeaconWire.Message, transport: PeerLocation.TransportType) {
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

        if message.hasMalformedToken {
            SecureLogger.error("[Beacon] Malformed UWB token in PING from \(peerID.id.prefix(8))", category: .session)
        }

        // Store sender's location (their disclosure, so always accepted)
        if let location = message.location {
            storePeerLocation(noiseKey: noiseKey, location: location, rssi: message.rssi,
                              transport: transport, pingMs: 0)
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
        if let tokenData = message.uwbToken {
            uwbManager.handleReceivedToken(from: PeerID(publicKey: noiseKey), tokenData: tokenData)
            includeToken = true
        }

        sendPong(to: peerID, noiseKey: noiseKey, requestID: message.requestID, includeUWBToken: includeToken)
    }

    // MARK: - Handle PONG

    private func handlePong(from peerID: PeerID, message: BeaconWire.Message, transport: PeerLocation.TransportType) {
        guard let pending = pendingPings.removeValue(forKey: message.requestID) else {
            SecureLogger.debug("[Beacon] Unsolicited PONG from \(peerID.id.prefix(8)) dropped", category: .session)
            return
        }

        let rtt = Int(Date().timeIntervalSince(pending.sentAt) * 1000)
        SecureLogger.info("[Beacon] PONG ← \(peerID.id.prefix(8)) RTT:\(rtt)ms", category: .session)

        isPinging = false
        HapticManager.shared.pingResponseReceived()

        if message.hasMalformedToken {
            SecureLogger.error("[Beacon] Malformed UWB token in PONG from \(peerID.id.prefix(8))", category: .session)
        }
        if let tokenData = message.uwbToken {
            uwbManager.handleReceivedToken(from: PeerID(publicKey: pending.noiseKey), tokenData: tokenData)
        }

        if let location = message.location {
            storePeerLocation(noiseKey: pending.noiseKey, location: location, rssi: message.rssi,
                              transport: transport, pingMs: rtt)
            auditLog.record(.locationReceived, peerFingerprint: PeerID(publicKey: pending.noiseKey).id, peerName: peerName(for: pending.noiseKey))
        }
    }

    // MARK: - Send PONG

    private func sendPong(to peerID: PeerID, noiseKey: Data, requestID: String, includeUWBToken: Bool) {
        guard let ble = bleService else { return }
        let locationStr = encodeLocation(for: noiseKey)
        let content = BeaconWire.encode(
            kind: .pong, requestID: requestID, rssi: ble.getRSSI(for: peerID), locationStr: locationStr,
            uwbTokenBase64: includeUWBToken ? uwbTokenBase64(for: noiseKey, forceExchange: true) : nil
        )
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
        return BeaconWire.encodeLocation(BeaconWire.Location(
            lat: coarse.latitude, lon: coarse.longitude,
            alt: level == .exact ? Int(loc.altitude) : 0,
            hacc: Int(coarse.horizontalAccuracy),
            vacc: level == .exact ? Int(loc.verticalAccuracy) : -1
        ))
    }

    private func storePeerLocation(noiseKey: Data, location loc: BeaconWire.Location,
                                   rssi: Int?, transport: PeerLocation.TransportType, pingMs: Int) {
        let peerID = PeerID(publicKey: noiseKey)
        var location = PeerLocation(
            id: peerID.id,
            latitude: loc.lat, longitude: loc.lon, altitude: Double(loc.alt), horizontalAccuracy: Double(loc.hacc),
            transport: transport, pingMs: pingMs, peerRSSI: rssi, timestamp: Date()
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
                peerID: loc.id, latitude: lat, longitude: lon,
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
                    id: snap.peerID,
                    latitude: snap.latitude, longitude: snap.longitude,
                    altitude: snap.altitude, horizontalAccuracy: snap.horizontalAccuracy,
                    transport: PeerLocation.TransportType(rawValue: snap.transport) ?? .ble,
                    pingMs: 0, peerRSSI: nil, timestamp: snap.timestamp
                )
            }
        } catch {
            SecureLogger.error("[Beacon] Failed to load last-known locations: \(error)", category: .session)
        }
    }

    // MARK: - UWB

    /// Our discovery token as base64, when an exchange is warranted.
    /// `forceExchange` bypasses the session-state check (used when replying to
    /// a peer-initiated exchange or after a retry request).
    private func uwbTokenBase64(for noiseKey: Data, forceExchange: Bool) -> String? {
        let peerID = PeerID(publicKey: noiseKey)
        guard forceExchange || uwbManager.shouldSendToken(to: peerID) else { return nil }
        return uwbManager.getMyTokenData(for: peerID)?.base64EncodedString()
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
        guard let token = uwbTokenBase64(for: noiseKey, forceExchange: true) else { return }

        let locationStr = encodeLocation(for: noiseKey)
        pendingPings[requestID] = (noiseKey: noiseKey, sentAt: Date())
        ble.sendPrivateMessage(BeaconWire.encode(kind: .ping, requestID: requestID,
                                                 rssi: ble.getRSSI(for: peerID), locationStr: locationStr,
                                                 uwbTokenBase64: token),
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

    #if DEBUG
    /// Seed mutual favorites + map pins for screenshot / UX review runs.
    /// Launch with `-beacon.screenshotMode`. Does not persist beyond process
    /// lifetime for locations; favorites are real UserDefaults writes so wipe
    /// the sim between demos if needed.
    private struct DemoPeer {
        let name: String
        let dLat: Double
        let dLon: Double
        let transport: PeerLocation.TransportType
        let pingMs: Int
        let rssi: Int?
        let uwb: Float?   // simulated UWB distance (m) for Find-mode UX; nil = no UWB
    }

    /// The concert: most of your favorites are here in the venue (a tight BLE
    /// cluster, a few already within UWB range) and some are across town on
    /// relay/Nostr. Deterministic keys so re-runs don't pile up duplicates.
    private static let demoScene: [DemoPeer] = [
        // — inside the venue (6, BLE) — spread ~60–150m so pins stay readable —
        DemoPeer(name: "maya", dLat:  0.00090, dLon:  0.00070, transport: .ble, pingMs: 22, rssi: -48, uwb: 3.2),
        DemoPeer(name: "rio",  dLat: -0.00105, dLon:  0.00050, transport: .ble, pingMs: 28, rssi: -53, uwb: 7.8),
        DemoPeer(name: "ash",  dLat: -0.00075, dLon: -0.00065, transport: .ble, pingMs: 31, rssi: -58, uwb: 12.6),
        DemoPeer(name: "noa",  dLat: -0.00040, dLon:  0.00110, transport: .ble, pingMs: 26, rssi: -55, uwb: 5.1),
        DemoPeer(name: "jun",  dLat:  0.00055, dLon: -0.00095, transport: .ble, pingMs: 40, rssi: -62, uwb: nil),
        DemoPeer(name: "kai",  dLat:  0.00120, dLon: -0.00030, transport: .ble, pingMs: 45, rssi: -66, uwb: nil),
        // — across town, over relay/Nostr (4) —
        DemoPeer(name: "sam",  dLat:  0.0061,  dLon:  0.0042,  transport: .relay, pingMs: 180, rssi: nil, uwb: nil),
        DemoPeer(name: "theo", dLat:  0.0039,  dLon: -0.0069,  transport: .relay, pingMs: 240, rssi: nil, uwb: nil),
        DemoPeer(name: "zoe",  dLat: -0.0052,  dLon: -0.0048,  transport: .relay, pingMs: 210, rssi: nil, uwb: nil),
        DemoPeer(name: "ivy",  dLat: -0.0075,  dLon:  0.0031,  transport: .relay, pingMs: 320, rssi: nil, uwb: nil),
    ]

    private var demoSceneInstalled = false
    private var demoSeedAttempts = 0

    private static func demoNoiseKey(_ index: Int) -> Data {
        var keyBytes = [UInt8](repeating: 0xBE, count: 32)
        keyBytes[31] = UInt8(index + 1)
        return Data(keyBytes)
    }

    /// Seed the concert scene, merging alongside any real peers (e.g. a nearby
    /// Mac). Retries until the device's real location is known so the pins land
    /// around the user instead of a fallback city.
    func installScreenshotDemoScene() {
        guard ProcessInfo.processInfo.arguments.contains("-beacon.screenshotMode") else { return }
        guard !demoSceneInstalled else { return }

        guard let coordinate = LocationStateManager.shared.currentLocation?.coordinate else {
            demoSeedAttempts += 1
            guard demoSeedAttempts <= 20 else {   // ~10s of 0.5s retries, then give up
                SecureLogger.warning("[Beacon] Demo scene: no location after retries", category: .session)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.installScreenshotDemoScene()
            }
            return
        }

        demoSceneInstalled = true
        for (index, demo) in Self.demoScene.enumerated() {
            let noiseKey = Self.demoNoiseKey(index)
            let peerID = PeerID(publicKey: noiseKey)

            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: noiseKey,
                peerNickname: demo.name
            )
            FavoritesPersistenceService.shared.updatePeerFavoritedUs(
                peerNoisePublicKey: noiseKey,
                favorited: true,
                peerNickname: demo.name
            )

            var location = PeerLocation(
                id: peerID.id,
                latitude: coordinate.latitude + demo.dLat,
                longitude: coordinate.longitude + demo.dLon,
                altitude: 10,
                horizontalAccuracy: demo.transport == .ble ? 12 : 65,
                transport: demo.transport,
                pingMs: demo.pingMs,
                peerRSSI: demo.rssi,
                timestamp: Date().addingTimeInterval(Double(-index * 12))
            )
            if let uwb = demo.uwb {
                // Roughly forward-and-slightly-right so the Find-mode arrow points somewhere real
                location.updateUWBDistance(uwb, direction: simd_float3(0.25, 0.0, -0.97))
            }
            peerLocations[peerID.id] = location
        }
        isBeaconModeEnabled = true
        SecureLogger.info("[Beacon] Installed concert demo scene (\(Self.demoScene.count) peers)", category: .session)
    }

    /// Remove the demo favorites + pins (launch with `-beacon.wipeDemo`).
    func removeScreenshotDemoScene() {
        for index in Self.demoScene.indices {
            let noiseKey = Self.demoNoiseKey(index)
            peerLocations.removeValue(forKey: PeerID(publicKey: noiseKey).id)
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey)
        }
        SecureLogger.info("[Beacon] Removed concert demo scene", category: .session)
    }
    #endif

}
