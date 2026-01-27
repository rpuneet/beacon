//
// BeaconService.swift
// bitchat
//
// Core service for beacon peer location tracking using [PING]/[PONG] messages
//

import Foundation
import Combine
import CoreLocation
import BitLogger
import simd

/// State of an active ping operation
enum BeaconPingState: Equatable {
    case idle
    case pinging(sent: Int, received: Int)
    case completed(received: Int, total: Int)
    case failed(String)
}

/// Core service for beacon peer location tracking
@MainActor
final class BeaconService: ObservableObject {
    static let shared = BeaconService()

    // MARK: - Published State

    /// Current locations of all tracked peers (keyed by peerID string)
    @Published private(set) var peerLocations: [String: PeerLocation] = [:]

    /// Current ping state
    @Published private(set) var pingState: BeaconPingState = .idle

    /// When the last ping was sent
    @Published private(set) var lastPingTime: Date?

    // MARK: - Dependencies

    private weak var bleService: BLEService?
    private weak var nostrTransport: NostrTransport?

    /// UWB manager for precision tracking
    private var uwbManager: UWBTrackingManager { UWBTrackingManager.shared }

    /// Location manager for current device location
    private var locationManager: LocationStateManager { LocationStateManager.shared }

    /// Favorites service for mutual favorite checks
    private var favoritesService: FavoritesPersistenceService { FavoritesPersistenceService.shared }

    // MARK: - Private State

    /// Pending pings awaiting response: requestID -> (peerID, noiseKey, sentAt)
    private var pendingPings: [String: (peerID: PeerID, noiseKey: Data, sentAt: Date)] = [:]

    /// Timeout for ping responses
    private let pingTimeout: TimeInterval = 15.0

    /// Count tracking for current ping batch
    private var pingTargetCount: Int = 0
    private var receivedCount: Int = 0

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        // Subscribe to UWB session updates for distance changes
        uwbManager.$activeSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self = self else { return }
                for (peerID, state) in sessions {
                    if case .active(let distance, let direction) = state {
                        self.updateUWBDistance(for: peerID, distance: distance, direction: direction)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Configuration

    /// Configure the service with transport dependencies
    func configure(ble: BLEService, nostr: NostrTransport) {
        self.bleService = ble
        self.nostrTransport = nostr
        SecureLogger.info("BeaconService: Configured with BLE and Nostr transports", category: .session)
    }

    // MARK: - Public API

    /// Ping all mutual favorites
    func pingAllFavorites() {
        let mutualFavorites = getMutualFavorites()
        guard !mutualFavorites.isEmpty else {
            pingState = .failed("No mutual favorites to ping")
            return
        }

        pingTargetCount = mutualFavorites.count
        receivedCount = 0
        pingState = .pinging(sent: mutualFavorites.count, received: 0)
        lastPingTime = Date()

        SecureLogger.info("BeaconService: Pinging \(mutualFavorites.count) mutual favorites", category: .session)
        HapticManager.shared.pingStarted()

        for (peerID, noiseKey) in mutualFavorites {
            pingPeer(peerID, noisePublicKey: noiseKey)
        }

        // Set timeout for overall ping batch
        DispatchQueue.main.asyncAfter(deadline: .now() + pingTimeout) { [weak self] in
            self?.handlePingTimeout()
        }
    }

    /// Ping a specific peer
    func pingPeer(_ peerID: PeerID, noisePublicKey: Data) {
        let requestID = UUID().uuidString
        let content = "[PING]:\(requestID)"

        // Store pending ping for RTT calculation
        pendingPings[requestID] = (peerID: peerID, noiseKey: noisePublicKey, sentAt: Date())

        // Try BLE first, then Nostr relay
        if bleService?.isPeerConnected(peerID) == true {
            SecureLogger.debug("BeaconService: Sending PING to \(peerID.id.prefix(8)) via BLE", category: .session)
            bleService?.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)
        } else {
            SecureLogger.debug("BeaconService: Sending PING to \(peerID.id.prefix(8)) via Nostr relay", category: .session)
            nostrTransport?.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: requestID)
        }
    }

    // MARK: - Message Handling

    /// Handle incoming private message - check if it's a beacon [PING] or [PONG]
    /// Returns true if the message was handled (should not be displayed in chat)
    @discardableResult
    func handlePrivateMessage(from peerID: PeerID, content: String, transport: PeerLocation.TransportType) -> Bool {
        if content.hasPrefix("[PING]:") {
            let requestID = String(content.dropFirst(7))
            handlePingRequest(from: peerID, requestID: requestID, transport: transport)
            return true
        } else if content.hasPrefix("[PONG]:") {
            // Format: [PONG]:requestID:base64data
            let parts = content.dropFirst(7).split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let requestID = String(parts[0])
                let base64Data = String(parts[1])
                handlePongResponse(from: peerID, requestID: requestID, base64Data: base64Data, transport: transport)
            }
            return true
        }
        return false
    }

    // MARK: - Private: Ping Handling

    private func handlePingRequest(from peerID: PeerID, requestID: String, transport: PeerLocation.TransportType) {
        // CRITICAL: Only respond to mutual favorites
        guard isMutualFavorite(peerID) else {
            SecureLogger.warning("BeaconService: Ignoring PING from non-mutual-favorite \(peerID.id.prefix(8))", category: .session)
            return
        }

        SecureLogger.info("BeaconService: Received PING from \(peerID.id.prefix(8)), requestID: \(requestID.prefix(8))", category: .session)

        // Notify UI that we received a ping
        HapticManager.shared.pingResponseReceived()

        // Build response with current location, UWB token, and RSSI
        buildAndSendPongResponse(to: peerID, requestID: requestID, transport: transport)
    }

    private func buildAndSendPongResponse(to peerID: PeerID, requestID: String, transport: PeerLocation.TransportType) {
        // Request fresh location
        locationManager.requestFreshLocation { [weak self] location in
            guard let self = self else { return }

            Task { @MainActor in
                // Get UWB token if supported (create session for this peer)
                let uwbToken = self.uwbManager.getMyTokenData(for: peerID)

                // Get RSSI we see for the requester (only for BLE)
                let rssi: Int? = transport == .ble ? self.bleService?.getRSSI(for: peerID) : nil

                // Build response
                let response = PongResponseData.build(
                    gpsEnabled: self.locationManager.isLocationEnabled,
                    location: location,
                    uwbSupported: self.uwbManager.isUWBSupported,
                    uwbToken: uwbToken,
                    rssiForRequester: rssi
                )

                guard let base64Response = response.toBase64() else {
                    SecureLogger.error("BeaconService: Failed to encode PONG response", category: .session)
                    return
                }

                let content = "[PONG]:\(requestID):\(base64Response)"

                // Send via same transport we received on
                if transport == .ble {
                    self.bleService?.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
                } else {
                    self.nostrTransport?.sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
                }

                SecureLogger.info("BeaconService: Sent PONG to \(peerID.id.prefix(8)), gps=\(response.gps.enabled), uwb=\(response.uwb.supported)", category: .session)
            }
        }
    }

    private func handlePongResponse(from peerID: PeerID, requestID: String, base64Data: String, transport: PeerLocation.TransportType) {
        // Find and remove pending ping
        guard let pending = pendingPings.removeValue(forKey: requestID) else {
            SecureLogger.warning("BeaconService: Received PONG for unknown request \(requestID.prefix(8))", category: .session)
            return
        }

        // Calculate round-trip time
        let pingMs = Int(Date().timeIntervalSince(pending.sentAt) * 1000)

        // Parse response
        guard let response = PongResponseData.fromBase64(base64Data) else {
            SecureLogger.error("BeaconService: Failed to parse PONG from \(peerID.id.prefix(8))", category: .session)
            return
        }

        SecureLogger.info("BeaconService: Received PONG from \(peerID.id.prefix(8)), RTT=\(pingMs)ms, gps=\(response.gps.enabled), uwb=\(response.uwb.supported)", category: .session)

        // Create PeerLocation
        let location = PeerLocation(
            peerID: peerID,
            response: response,
            transport: transport,
            pingMs: pingMs
        )

        // Store location
        peerLocations[peerID.id] = location

        // Start UWB ranging if token available
        if let uwbToken = location.uwbToken, location.uwbSupported {
            uwbManager.handleReceivedToken(from: peerID, tokenData: uwbToken)
        }

        // Update ping state
        receivedCount += 1
        pingState = .pinging(sent: pingTargetCount, received: receivedCount)

        // Haptic feedback
        HapticManager.shared.pingResponseReceived()

        // Check if all responses received
        if receivedCount >= pingTargetCount {
            completePing()
        }
    }

    private func handlePingTimeout() {
        guard case .pinging = pingState else { return }

        // Clear any remaining pending pings
        pendingPings.removeAll()

        completePing()
    }

    private func completePing() {
        pingState = .completed(received: receivedCount, total: pingTargetCount)
        HapticManager.shared.pingCompleted(responseCount: receivedCount)

        // Reset state after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if case .completed = self?.pingState {
                self?.pingState = .idle
            }
        }
    }

    // MARK: - Private: UWB Updates

    private func updateUWBDistance(for peerID: PeerID, distance: Float?, direction: simd_float3?) {
        guard var location = peerLocations[peerID.id], let dist = distance else { return }
        location.updateUWBDistance(dist, direction: direction)
        peerLocations[peerID.id] = location
    }

    // MARK: - Private: Helpers

    private func getMutualFavorites() -> [(PeerID, Data)] {
        var result: [(PeerID, Data)] = []

        for (noiseKey, relationship) in favoritesService.favorites {
            guard relationship.isMutual else { continue }
            let peerID = PeerID(publicKey: noiseKey)
            result.append((peerID, noiseKey))
        }

        return result
    }

    private func isMutualFavorite(_ peerID: PeerID) -> Bool {
        // Check by short ID
        let shortID = peerID.toShort()
        for (noiseKey, rel) in favoritesService.favorites {
            if rel.isMutual && PeerID(publicKey: noiseKey).toShort().id == shortID.id {
                return true
            }
        }
        return false
    }

    private func getNoiseKey(for peerID: PeerID) -> Data? {
        let shortID = peerID.toShort()
        for (noiseKey, _) in favoritesService.favorites {
            if PeerID(publicKey: noiseKey).toShort().id == shortID.id {
                return noiseKey
            }
        }
        return nil
    }

    // MARK: - Public: State Queries

    /// Get location for a specific peer
    func getLocation(for peerID: PeerID) -> PeerLocation? {
        peerLocations[peerID.id]
    }

    /// Get all peers with valid locations
    var peersWithLocation: [PeerLocation] {
        peerLocations.values.filter { $0.hasLocation }
    }

    /// Count of peers with valid locations
    var peersWithLocationCount: Int {
        peersWithLocation.count
    }

    /// Whether a ping is currently in progress
    var isPinging: Bool {
        if case .pinging = pingState { return true }
        return false
    }

    /// Clear all stored locations
    func clearLocations() {
        peerLocations.removeAll()
        // Note: UWB sessions will clean up automatically when the manager is deallocated or times out
    }
}
