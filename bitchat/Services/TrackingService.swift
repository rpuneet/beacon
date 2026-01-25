//
// TrackingService.swift
// bitchat
//
// Core tracking orchestration service for peer location tracking
// Persists last known locations for offline viewing
//

import Foundation
import Combine
import CoreLocation
import BitLogger

/// State of an active ping operation
enum TrackingPingState: Equatable {
    case idle
    case pinging(sent: Int, received: Int)
    case completed(received: Int, total: Int)
    case failed(String)
}

/// Core service for tracking peer locations
@MainActor
final class TrackingService: ObservableObject {
    static let shared = TrackingService()

    // MARK: - Persistence Keys
    private static let storageKey = "chat.bitchat.peerlocations"
    private static let keychainService = "chat.bitchat.tracking"

    // MARK: - Published State

    /// Current locations of all tracked peers (keyed by peerID string for persistence)
    @Published private(set) var peerLocations: [String: PeerLocation] = [:]

    /// Current ping state
    @Published private(set) var pingState: TrackingPingState = .idle

    /// When the last ping was sent
    @Published private(set) var lastPingTime: Date?

    // MARK: - Dependencies

    private weak var bleService: Transport?
    private weak var nostrTransport: NostrTransport?
    private let keychain: KeychainManagerProtocol

    /// UWB manager for precision tracking
    private var uwbManager: UWBTrackingManager { UWBTrackingManager.shared }

    /// Location manager for current device location
    private var locationManager: LocationStateManager { LocationStateManager.shared }

    // MARK: - Private State

    private var pingTimer: Timer?
    private var pingTargetCount: Int = 0
    private var receivedCount: Int = 0
    private var cancellables = Set<AnyCancellable>()

    // Per-request start times for accurate RTT calculation
    private var requestStartTimes: [Data: Date] = [:]

    // MARK: - Initialization

    private init(keychain: KeychainManagerProtocol = KeychainManager()) {
        self.keychain = keychain

        // Load persisted locations
        loadPersistedLocations()

        // Observe favorite status changes to refresh member list
        NotificationCenter.default.publisher(for: .favoriteStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPeerList()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: - Public API

    /// Configure the service with transport dependencies
    func configure(ble: Transport, nostr: NostrTransport) {
        self.bleService = ble
        self.nostrTransport = nostr
        SecureLogger.info("TrackingService: Configured with BLE and Nostr transports", category: .session)
    }

    /// Send ping to specific peers (or all mutual favorites if empty)
    func sendPing(to peers: [PeerID] = []) {
        let targets = peers.isEmpty ? getMutualFavorites() : peers
        guard !targets.isEmpty else {
            pingState = .failed("No peers to ping")
            return
        }

        // Cancel any existing ping
        pingTimer?.invalidate()
        pingTimer = nil

        pingTargetCount = targets.count
        receivedCount = 0
        pingState = .pinging(sent: targets.count, received: 0)
        lastPingTime = Date()
        requestStartTimes.removeAll()

        SecureLogger.info("TrackingService: Sending ping to \(targets.count) peers", category: .session)

        // Trigger haptic feedback
        HapticManager.shared.pingStarted()

        // Collect relay requests for staggered sending
        var relayRequests: [(peerID: PeerID, noiseKey: Data)] = []

        for peerID in targets {
            // Check if peer is reachable via BLE
            let bleReachable = bleService?.isPeerReachable(peerID) ?? false

            if bleReachable {
                // BLE requests can be sent immediately
                requestStartTimes[peerID.noiseKey ?? Data()] = Date()
                pingViaBLE(peerID)
            } else if let noiseKey = getNoiseKey(for: peerID) {
                // Queue for staggered relay sending
                relayRequests.append((peerID: peerID, noiseKey: noiseKey))
            } else {
                // Peer not reachable
                SecureLogger.debug("TrackingService: Peer \(peerID.id.prefix(16)) not reachable", category: .session)
            }
        }

        // Stagger relay requests 500ms apart to avoid rate limiting
        for (index, request) in relayRequests.enumerated() {
            let delay = Double(index) * 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.requestStartTimes[request.noiseKey] = Date()
                self.pingViaRelay(request.peerID, noisePublicKey: request.noiseKey)
            }
        }

        // Set 5 second TTL for ping completion
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completePing()
            }
        }
    }

    /// Stop active pinging but keep cached locations
    func stopTracking() {
        pingTimer?.invalidate()
        pingTimer = nil
        pingState = .idle
        requestStartTimes.removeAll()
        // Note: We do NOT clear peerLocations - keep last known locations
        SecureLogger.info("TrackingService: Stopped tracking (locations preserved)", category: .session)
    }

    /// Clear all cached locations
    func clearCachedLocations() {
        peerLocations.removeAll()
        savePersistedLocations()
        SecureLogger.info("TrackingService: Cleared all cached locations", category: .session)
    }

    // MARK: - Private Methods

    private func pingViaBLE(_ peerID: PeerID) {
        guard let ble = bleService else {
            SecureLogger.warning("TrackingService: BLE service not available", category: .session)
            return
        }

        SecureLogger.debug("TrackingService: Sending BLE ping to \(peerID.id.prefix(16))", category: .session)

        ble.sendTrackRequest(to: peerID) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handlePingResult(result, peerID: peerID, transport: .ble)
            }
        }
    }

    private func pingViaRelay(_ peerID: PeerID, noisePublicKey: Data) {
        guard let nostr = nostrTransport else {
            SecureLogger.warning("TrackingService: Nostr transport not available", category: .session)
            return
        }

        SecureLogger.debug("TrackingService: Sending relay ping to \(peerID.id.prefix(16))", category: .session)

        nostr.sendTrackRequest(to: peerID, noisePublicKey: noisePublicKey) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handlePingResult(result, peerID: peerID, transport: .relay)
            }
        }
    }

    private func handlePingResult(
        _ result: Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>,
        peerID: PeerID,
        transport: PeerLocation.TransportType
    ) {
        switch result {
        case .success(let (response, pingMs, rssi)):
            // Get UWB data if available
            let uwbDistance = uwbManager.getDistance(for: peerID)
            let uwbDirection = uwbManager.getDirection(for: peerID)

            let location = PeerLocation(
                peerID: peerID,
                response: response,
                transport: transport,
                pingMs: pingMs,
                rssi: rssi,
                uwbDistance: uwbDistance,
                uwbDirection: uwbDirection
            )

            // Store by string key for persistence
            peerLocations[peerID.id] = location

            // Persist updated locations
            savePersistedLocations()

            // Update ping state
            receivedCount += 1
            pingState = .pinging(sent: pingTargetCount, received: receivedCount)

            // Trigger haptic
            HapticManager.shared.pingResponseReceived()

            SecureLogger.info("TrackingService: Received response from \(peerID.id.prefix(16)) via \(transport.rawValue) - pingMs: \(pingMs)", category: .session)

            // Check if all responses received
            if receivedCount >= pingTargetCount {
                completePing()
            }

        case .failure(let error):
            SecureLogger.debug("TrackingService: Ping failed for \(peerID.id.prefix(16)): \(error)", category: .session)
        }
    }

    private func completePing() {
        guard case .pinging = pingState else { return }

        pingTimer?.invalidate()
        pingTimer = nil

        pingState = .completed(received: receivedCount, total: pingTargetCount)

        SecureLogger.info("TrackingService: Ping completed - \(receivedCount)/\(pingTargetCount) responded", category: .session)

        // Trigger completion haptic
        HapticManager.shared.pingCompleted(responseCount: receivedCount)

        // Auto-reset to idle after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            Task { @MainActor [weak self] in
                if case .completed = self?.pingState {
                    self?.pingState = .idle
                }
            }
        }
    }

    // MARK: - Persistence

    private func savePersistedLocations() {
        let locations = Array(peerLocations.values)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(locations)
            keychain.save(
                key: Self.storageKey,
                data: data,
                service: Self.keychainService,
                accessible: nil
            )
            SecureLogger.debug("TrackingService: Saved \(locations.count) locations to cache", category: .session)
        } catch {
            SecureLogger.error("TrackingService: Failed to save locations: \(error)", category: .session)
        }
    }

    private func loadPersistedLocations() {
        guard let data = keychain.load(key: Self.storageKey, service: Self.keychainService) else {
            SecureLogger.debug("TrackingService: No cached locations found", category: .session)
            return
        }

        do {
            let decoder = JSONDecoder()
            let locations = try decoder.decode([PeerLocation].self, from: data)

            // Filter out stale locations (older than 24 hours)
            let validLocations = locations.filter {
                Date().timeIntervalSince($0.timestamp) < 86400
            }

            for location in validLocations {
                peerLocations[location.id] = location
            }

            SecureLogger.info("TrackingService: Loaded \(validLocations.count) cached locations", category: .session)
        } catch {
            SecureLogger.error("TrackingService: Failed to load locations: \(error)", category: .session)
        }
    }

    // MARK: - Helpers

    private func getMutualFavorites() -> [PeerID] {
        FavoritesPersistenceService.shared.favorites.values
            .filter { $0.isMutual }
            .map { PeerID(publicKey: $0.peerNoisePublicKey) }
    }

    private func getNoiseKey(for peerID: PeerID) -> Data? {
        // Try to get the full noise key from the peerID
        if let noiseKey = peerID.noiseKey {
            return noiseKey
        }

        // Look up from favorites by short peer ID
        for (key, rel) in FavoritesPersistenceService.shared.favorites {
            if PeerID(publicKey: key) == peerID {
                // Also check they have a Nostr key for relay
                if rel.peerNostrPublicKey != nil {
                    return key
                }
            }
        }
        return nil
    }

    private func refreshPeerList() {
        // Remove peers who are no longer mutual favorites
        let mutualKeys = FavoritesPersistenceService.shared.mutualFavorites
        let idsToRemove = peerLocations.keys.filter { peerIDString in
            let peerID = PeerID(str: peerIDString)
            guard let noiseKey = peerID.noiseKey else { return true }
            return !mutualKeys.contains(noiseKey)
        }
        for id in idsToRemove {
            peerLocations.removeValue(forKey: id)
        }
        if !idsToRemove.isEmpty {
            savePersistedLocations()
        }
    }
}
