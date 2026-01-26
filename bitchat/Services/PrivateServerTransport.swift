//
// PrivateServerTransport.swift
// bitchat
//
// Transport implementation for user's private Nostr-compatible relay servers.
// Priority 60 (above Public Relay at 40, below WiFi Direct at 80).
//

import BitLogger
import Foundation
import Combine

/// Transport for connecting to a user's private Nostr-compatible relay server
final class PrivateServerTransport: NSObject, Transport, TransportMetadata, @unchecked Sendable {

    // MARK: - Configuration

    private var config: PrivateServerConfig
    private let keychain: KeychainManagerProtocol
    private let idBridge: NostrIdentityBridge

    // MARK: - Transport State

    var senderPeerID = PeerID(str: "")
    private var reachablePeers: Set<PeerID> = []
    private let queue = DispatchQueue(label: "privateServer.transport.state", attributes: .concurrent)

    // MARK: - WebSocket Connection

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnectedToRelay = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let baseReconnectDelay: TimeInterval = 2.0

    // MARK: - Pending Operations

    private var pendingTrackRequests: [String: (peerID: PeerID, sentAt: Date, completion: (Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) -> Void)] = [:]
    private let trackQueue = DispatchQueue(label: "privateServer.transport.tracking", attributes: .concurrent)

    // MARK: - Initialization

    @MainActor
    init(config: PrivateServerConfig, keychain: KeychainManagerProtocol = KeychainManager(), idBridge: NostrIdentityBridge? = nil) {
        self.config = config
        self.keychain = keychain
        // Use provided idBridge or try to get from ChatViewModel (will be set later if nil)
        self.idBridge = idBridge ?? NostrIdentityBridge(keychain: keychain)
        super.init()
        setupObservers()
        refreshReachablePeers()
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshReachablePeers()
        }
    }

    /// Update configuration (e.g., when user edits settings)
    func updateConfig(_ newConfig: PrivateServerConfig) {
        let urlChanged = config.url != newConfig.url
        config = newConfig

        if urlChanged {
            // Reconnect if URL changed
            disconnect()
            if config.isEnabled {
                connect()
            }
        }
    }

    // MARK: - TransportMetadata

    var transportName: String { "Private Server: \(config.name)" }

    var priority: Int { 60 }  // Above public relay (40), below WiFi Direct (80)

    var requiresInternet: Bool { true }

    var isDirectConnection: Bool { false }

    nonisolated var connectionStatus: TransportConnectionStatus {
        if isConnectedToRelay {
            let peerCount = queue.sync { reachablePeers.count }
            return .connected(peerCount: peerCount)
        } else if reconnectAttempts > 0 {
            return .connecting
        } else {
            return .disconnected
        }
    }

    // MARK: - Transport Protocol

    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just([]).eraseToAnyPublisher()
    }

    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    var myPeerID: PeerID { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used */ }

    func startServices() {
        SecureLogger.info("PrivateServerTransport: Starting services for '\(config.name)'", category: .session)
        connect()
    }

    func stopServices() {
        SecureLogger.info("PrivateServerTransport: Stopping services for '\(config.name)'", category: .session)
        disconnect()
    }

    func emergencyDisconnectAll() {
        disconnect()
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        guard isConnectedToRelay else { return false }
        return queue.sync {
            if reachablePeers.contains(peerID) { return true }
            if peerID.isShort {
                return reachablePeers.contains(where: { $0.toShort() == peerID })
            }
            return false
        }
    }

    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID: String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) { /* no-op */ }

    private static var cachedNoiseService: NoiseEncryptionService?
    func getNoiseService() -> NoiseEncryptionService {
        if let noiseService = Self.cachedNoiseService {
            return noiseService
        }
        let noiseService = NoiseEncryptionService(keychain: keychain)
        Self.cachedNoiseService = noiseService
        return noiseService
    }

    // MARK: - Messaging

    func sendMessage(_ content: String, mentions: [String]) { /* no-op for private messages only */ }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        Task { @MainActor in
            guard isConnectedToRelay else {
                SecureLogger.warning("PrivateServerTransport: Cannot send PM - not connected to '\(config.name)'", category: .session)
                return
            }

            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? idBridge.getCurrentNostrIdentity() else {
                SecureLogger.warning("PrivateServerTransport: Cannot resolve recipient for PM", category: .session)
                return
            }

            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(
                content: content,
                messageID: messageID,
                recipientPeerID: peerID,
                senderPeerID: senderPeerID
            ) else {
                SecureLogger.error("PrivateServerTransport: Failed to embed PM packet", category: .session)
                return
            }

            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        // Implement read receipt sending similar to NostrTransport
        // For now, delegate to public relay
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        Task { @MainActor in
            guard isConnectedToRelay else { return }

            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? idBridge.getCurrentNostrIdentity() else { return }

            let content = isFavorite ? "[FAVORITED]:\(senderIdentity.npub)" : "[UNFAVORITED]:\(senderIdentity.npub)"

            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(
                content: content,
                messageID: UUID().uuidString,
                recipientPeerID: peerID,
                senderPeerID: senderPeerID
            ) else { return }

            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    func sendBroadcastAnnounce() { /* no-op */ }
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) { /* no-op for now */ }

    // MARK: - Tracking

    func sendTrackRequest(to peerID: PeerID, completion: @escaping (Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) -> Void) {
        Task { @MainActor in
            guard isConnectedToRelay else {
                completion(.failure(TrackingError.peerNotConnected))
                return
            }

            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? idBridge.getCurrentNostrIdentity() else {
                completion(.failure(TrackingError.peerNotConnected))
                return
            }

            sendTrackRequestToHex(recipientHex: recipientHex, peerID: peerID, senderIdentity: senderIdentity, completion: completion)
        }
    }

    private func sendTrackRequestToHex(
        recipientHex: String,
        peerID: PeerID,
        senderIdentity: NostrIdentity,
        completion: @escaping (Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) -> Void
    ) {
        let request = TrackRequest(uwbToken: nil)

        // Store pending request
        trackQueue.async(flags: .barrier) { [weak self] in
            self?.pendingTrackRequests[request.id] = (peerID: peerID, sentAt: Date(), completion: completion)
        }

        // Set timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.trackQueue.async(flags: .barrier) {
                if let pending = self?.pendingTrackRequests.removeValue(forKey: request.id) {
                    DispatchQueue.main.async {
                        pending.completion(.failure(TrackingError.timeout))
                    }
                }
            }
        }

        // Encode and send track request
        guard let encoded = NostrEmbeddedBitChat.encodeTrackRequestForNostr(
            request: request,
            recipientPeerID: peerID,
            senderPeerID: senderPeerID
        ) else {
            completion(.failure(TrackingError.notSupported))
            return
        }

        sendWrappedMessage(content: encoded, recipientHex: recipientHex, senderIdentity: senderIdentity)
    }

    // MARK: - WebSocket Connection

    private func connect() {
        guard config.isValidURL, let url = URL(string: config.url) else {
            SecureLogger.error("PrivateServerTransport: Invalid URL '\(config.url)'", category: .session)
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300

        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        SecureLogger.info("PrivateServerTransport: Connecting to '\(config.url)'", category: .session)
        receiveMessage()
    }

    private func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnectedToRelay = false
        reconnectAttempts = 0
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()
            case .failure(let error):
                SecureLogger.error("PrivateServerTransport: WebSocket error: \(error)", category: .session)
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            // Parse Nostr relay message
            parseRelayMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseRelayMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseRelayMessage(_ text: String) {
        // Parse Nostr relay response (["EVENT", subscriptionId, event] or ["OK", eventId, success, message])
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let messageType = json.first as? String else { return }

        switch messageType {
        case "EVENT":
            // Handle incoming event
            if json.count >= 3, let eventDict = json[2] as? [String: Any] {
                handleIncomingEvent(eventDict)
            }
        case "OK":
            // Message acknowledged
            break
        case "EOSE":
            // End of stored events
            break
        case "NOTICE":
            if json.count >= 2, let notice = json[1] as? String {
                SecureLogger.info("PrivateServerTransport: Relay notice: \(notice)", category: .session)
            }
        default:
            break
        }
    }

    private func handleIncomingEvent(_ eventDict: [String: Any]) {
        // Delegate to the common Nostr event handling infrastructure
        // This would parse gift-wrapped messages and deliver to delegate
        // For now, log the event
        SecureLogger.debug("PrivateServerTransport: Received event from '\(config.name)'", category: .session)
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            SecureLogger.warning("PrivateServerTransport: Max reconnect attempts reached for '\(config.name)'", category: .session)
            return
        }

        reconnectAttempts += 1
        let delay = baseReconnectDelay * pow(2.0, Double(reconnectAttempts - 1))

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.config.isEnabled else { return }
            SecureLogger.info("PrivateServerTransport: Reconnecting to '\(self.config.name)' (attempt \(self.reconnectAttempts))", category: .session)
            self.connect()
        }
    }

    // MARK: - Helper Methods

    private func refreshReachablePeers() {
        Task { @MainActor in
            let favorites = FavoritesPersistenceService.shared.favorites
            let reachable = favorites.values
                .filter { $0.peerNostrPublicKey != nil }
                .map { PeerID(publicKey: $0.peerNoisePublicKey) }

            queue.async(flags: .barrier) { [weak self] in
                self?.reachablePeers = Set(reachable)
            }
        }
    }

    @MainActor
    private func resolveRecipientNpub(for peerID: PeerID) -> String? {
        if let noiseKey = Data(hexString: peerID.id) {
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey) {
                return fav.peerNostrPublicKey
            }
        }
        if peerID.id.count == 16 {
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID) {
                return fav.peerNostrPublicKey
            }
        }
        return nil
    }

    private func npubToHex(_ npub: String) -> String? {
        // Convert npub to hex (bech32 decode)
        do {
            let (hrp, data) = try Bech32.decode(npub)
            guard hrp == "npub" else { return nil }
            return data.hexEncodedString()
        } catch {
            SecureLogger.error("PrivateServerTransport: failed to decode npub -> hex: \(error)", category: .session)
            return nil
        }
    }

    private func sendWrappedMessage(content: String, recipientHex: String, senderIdentity: NostrIdentity) {
        guard let webSocket = webSocket else { return }

        Task {
            do {
                // Create gift-wrapped event using existing NostrProtocol
                guard let event = try? NostrProtocol.createPrivateMessage(
                    content: content,
                    recipientPubkey: recipientHex,
                    senderIdentity: senderIdentity
                ) else {
                    SecureLogger.error("PrivateServerTransport: Failed to create gift wrap", category: .session)
                    return
                }

                // Encode event to JSON
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let eventData = try encoder.encode(event)
                guard let eventJSON = String(data: eventData, encoding: .utf8) else {
                    SecureLogger.error("PrivateServerTransport: Failed to encode event", category: .session)
                    return
                }

                // Send to relay
                let message = "[\"EVENT\",\(eventJSON)]"
                try await webSocket.send(.string(message))
                SecureLogger.debug("PrivateServerTransport: Sent message to '\(config.name)'", category: .session)
            } catch {
                SecureLogger.error("PrivateServerTransport: Failed to send message: \(error)", category: .session)
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension PrivateServerTransport: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        SecureLogger.info("PrivateServerTransport: Connected to '\(config.name)'", category: .session)
        isConnectedToRelay = true
        reconnectAttempts = 0

        // Send authentication if required
        if let authToken = config.authToken, !authToken.isEmpty {
            sendAuth(token: authToken)
        }

        // Subscribe to our events
        subscribeToEvents()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        SecureLogger.info("PrivateServerTransport: Disconnected from '\(config.name)' (code: \(closeCode.rawValue))", category: .session)
        isConnectedToRelay = false
        scheduleReconnect()
    }

    private func sendAuth(token: String) {
        // Send NIP-42 authentication if supported by the relay
        SecureLogger.debug("PrivateServerTransport: Sending auth to '\(config.name)'", category: .session)
        // Implementation depends on relay's auth requirements
    }

    private func subscribeToEvents() {
        Task { @MainActor in
            guard let senderIdentity = try? idBridge.getCurrentNostrIdentity() else { return }
            guard let hexPubkey = npubToHex(senderIdentity.npub) else { return }

            // Subscribe to gift-wrapped events addressed to us
            let subscriptionID = "bitchat-\(config.id.uuidString.prefix(8))"
            let filter: [String: Any] = [
                "kinds": [1059],  // Gift-wrapped DM
                "#p": [hexPubkey],
                "limit": 100
            ]

            guard let filterJSON = try? JSONSerialization.data(withJSONObject: filter),
                  let filterString = String(data: filterJSON, encoding: .utf8) else { return }

            let reqMessage = "[\"REQ\",\"\(subscriptionID)\",\(filterString)]"

            do {
                try await webSocket?.send(.string(reqMessage))
                SecureLogger.debug("PrivateServerTransport: Subscribed to events on '\(config.name)'", category: .session)
            } catch {
                SecureLogger.error("PrivateServerTransport: Failed to subscribe: \(error)", category: .session)
            }
        }
    }
}
