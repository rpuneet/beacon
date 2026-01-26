import BitLogger
import Foundation
import Combine

// Minimal Nostr transport conforming to Transport for offline sending
final class NostrTransport: Transport, @unchecked Sendable {
    // Provide BLE short peer ID for BitChat embedding
    var senderPeerID = PeerID(str: "")

    // Throttle READ receipts to avoid relay rate limits
    private struct QueuedRead {
        let receipt: ReadReceipt
        let peerID: PeerID
    }
    private var readQueue: [QueuedRead] = []
    private var isSendingReadAcks = false
    private let readAckInterval: TimeInterval = TransportConfig.nostrReadAckInterval
    private let keychain: KeychainManagerProtocol
    private let idBridge: NostrIdentityBridge

    // Reachability Cache (thread-safe)
    private var reachablePeers: Set<PeerID> = []
    private let queue = DispatchQueue(label: "nostr.transport.state", attributes: .concurrent)

    @MainActor
    init(keychain: KeychainManagerProtocol, idBridge: NostrIdentityBridge) {
        self.keychain = keychain
        self.idBridge = idBridge

        setupObservers()

        // Synchronously warm the cache to avoid startup race
        let favorites = FavoritesPersistenceService.shared.favorites
        SecureLogger.info("NostrTransport: Init - \(favorites.count) favorites loaded", category: .session)

        let reachable = favorites.values
            .filter { $0.peerNostrPublicKey != nil }
            .map { PeerID(publicKey: $0.peerNoisePublicKey) }

        SecureLogger.info("NostrTransport: Init - \(reachable.count) peers have npub (relay-reachable)", category: .session)
        for rel in favorites.values {
            let hasNpub = rel.peerNostrPublicKey != nil
            SecureLogger.debug("NostrTransport: Init - \(rel.peerNickname): npub=\(hasNpub ? rel.peerNostrPublicKey!.prefix(20) + "..." : "NONE")", category: .session)
        }

        queue.sync(flags: .barrier) {
            self.reachablePeers = Set(reachable)
        }
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

    private func refreshReachablePeers() {
        Task { @MainActor in
            let favorites = FavoritesPersistenceService.shared.favorites

            // Log detailed reachability info
            SecureLogger.debug("NostrTransport: Refreshing reachable peers from \(favorites.count) favorites", category: .session)
            for (_, rel) in favorites {
                let hasNpub = rel.peerNostrPublicKey != nil
                SecureLogger.debug("  - \(rel.peerNickname): mutual=\(rel.isMutual), hasNpub=\(hasNpub)", category: .session)
            }

            let reachable = favorites.values
                .filter { $0.peerNostrPublicKey != nil }
                .map { PeerID(publicKey: $0.peerNoisePublicKey) }

            SecureLogger.info("NostrTransport: \(reachable.count) peers reachable via relay", category: .session)

            self.queue.async(flags: .barrier) { [weak self] in
                self?.reachablePeers = Set(reachable)
            }
        }
    }

    // MARK: - Transport Protocol Conformance

    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    var myPeerID: PeerID { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used for Nostr */ }

    func startServices() { /* no-op */ }
    func stopServices() { /* no-op */ }
    func emergencyDisconnectAll() { /* no-op */ }

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    
    func isPeerReachable(_ peerID: PeerID) -> Bool {
        queue.sync {
            // Check if exact match
            if reachablePeers.contains(peerID) { return true }
            // Check for short ID match
            if peerID.isShort {
                return reachablePeers.contains(where: { $0.toShort() == peerID })
            }
            return false
        }
    }
    
    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID : String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) { /* no-op */ }
    
    // Nostr does not use Noise sessions here; return a cached placeholder to avoid reallocation
    private static var cachedNoiseService: NoiseEncryptionService?
    func getNoiseService() -> NoiseEncryptionService {
        if let noiseService = Self.cachedNoiseService {
            return noiseService
        }
        let noiseService = NoiseEncryptionService(keychain: keychain)
        Self.cachedNoiseService = noiseService
        return noiseService
    }

    // Public broadcast not supported over Nostr here
    func sendMessage(_ content: String, mentions: [String]) { /* no-op */ }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        Task { @MainActor in
            // Debug: Log which guard conditions pass/fail
            let recipientNpub = resolveRecipientNpub(for: peerID)
            let recipientHex = recipientNpub.flatMap { npubToHex($0) }
            let senderIdentity = try? idBridge.getCurrentNostrIdentity()

            SecureLogger.debug("NostrTransport: sendPrivateMessage to \(peerID.id.prefix(16)) - npub: \(recipientNpub != nil), hex: \(recipientHex != nil), identity: \(senderIdentity != nil)", category: .session)

            guard let recipientNpub = recipientNpub,
                  let recipientHex = recipientHex,
                  let senderIdentity = senderIdentity else {
                SecureLogger.warning("NostrTransport: cannot send PM - missing: npub=\(recipientNpub == nil), hex=\(recipientHex == nil), identity=\(senderIdentity == nil)", category: .session)
                return
            }
            SecureLogger.debug("NostrTransport: preparing PM to \(recipientNpub.prefix(16))… id=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed PM packet", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        // Enqueue and process with throttling to avoid relay rate limits
        // Use barrier to synchronize access to readQueue
        queue.async(flags: .barrier) { [weak self] in
            self?.readQueue.append(QueuedRead(receipt: receipt, peerID: peerID))
            self?.processReadQueueIfNeeded()
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? idBridge.getCurrentNostrIdentity() else { return }
            let content = isFavorite ? "[FAVORITED]:\(senderIdentity.npub)" : "[UNFAVORITED]:\(senderIdentity.npub)"
            SecureLogger.debug("NostrTransport: preparing FAVORITE(\(isFavorite)) to \(recipientNpub.prefix(16))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: UUID().uuidString, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed favorite notification", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    func sendBroadcastAnnounce() { /* no-op for Nostr */ }

    // MARK: - Tracking

    // Pending track requests for response correlation
    private var pendingTrackRequests: [String: (peerID: PeerID, sentAt: Date, completion: (Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) -> Void)] = [:]
    private let trackQueue = DispatchQueue(label: "nostr.transport.tracking", attributes: .concurrent)

    func sendTrackRequest(to peerID: PeerID, completion: @escaping (Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) -> Void) {
        Task { @MainActor in
            let recipientNpub = resolveRecipientNpub(for: peerID)
            let recipientHex = recipientNpub.flatMap { npubToHex($0) }
            let senderIdentity = try? idBridge.getCurrentNostrIdentity()

            SecureLogger.debug("NostrTransport: sendTrackRequest to \(peerID.id.prefix(16)) - npub: \(recipientNpub != nil), hex: \(recipientHex != nil), identity: \(senderIdentity != nil)", category: .session)

            guard let recipientNpub = recipientNpub,
                  let recipientHex = recipientHex,
                  let _ = senderIdentity else {
                SecureLogger.warning("NostrTransport: cannot send TrackRequest - missing: npub=\(recipientNpub == nil), hex=\(recipientHex == nil), identity=\(senderIdentity == nil)", category: .session)
                completion(.failure(TrackingError.peerNotConnected))
                return
            }

            sendTrackRequestToHex(recipientHex: recipientHex, peerID: peerID, completion: completion)
        }
    }

    /// Send track request using the peer's Noise public key directly (avoids short ID format mismatch)
    func sendTrackRequest(to peerID: PeerID, noisePublicKey: Data, completion: @escaping (Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) -> Void) {
        Task { @MainActor in
            // Look up npub directly from favorites using the Noise key
            let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
            let recipientNpub = favoriteStatus?.peerNostrPublicKey
            let recipientHex = recipientNpub.flatMap { npubToHex($0) }
            let senderIdentity = try? idBridge.getCurrentNostrIdentity()

            SecureLogger.info("NostrTransport: sendTrackRequest(noiseKey) to \(peerID.id.prefix(16)) - npub=\(recipientNpub ?? "NONE") hex=\(recipientHex?.prefix(16) ?? "NONE")", category: .session)

            guard let _ = favoriteStatus,
                  let recipientNpub = recipientNpub,
                  let recipientHex = recipientHex,
                  let _ = senderIdentity else {
                SecureLogger.warning("NostrTransport: cannot send TrackRequest(noiseKey) - missing: fav=\(favoriteStatus == nil), npub=\(recipientNpub == nil), hex=\(recipientHex == nil), identity=\(senderIdentity == nil)", category: .session)
                completion(.failure(TrackingError.peerNotConnected))
                return
            }

            sendTrackRequestToHex(recipientHex: recipientHex, peerID: peerID, completion: completion)
        }
    }

    private func sendTrackRequestToHex(recipientHex: String, peerID: PeerID, completion: @escaping (Result<(response: TrackResponse, pingMs: Int, rssi: Int?), Error>) -> Void) {
        Task { @MainActor in
            guard let senderIdentity = try? idBridge.getCurrentNostrIdentity() else {
                completion(.failure(TrackingError.peerNotConnected))
                return
            }

            // Create track request (no UWB over relay - that requires physical proximity)
            let request = TrackRequest(uwbToken: nil)

            SecureLogger.debug("NostrTransport: preparing TrackRequest to \(recipientHex.prefix(16))… id=\(request.id.prefix(8))…", category: .session)

            guard let embedded = NostrEmbeddedBitChat.encodeTrackRequestForNostr(
                request: request,
                recipientPeerID: peerID,
                senderPeerID: senderPeerID
            ) else {
                SecureLogger.error("NostrTransport: failed to embed TrackRequest packet", category: .session)
                completion(.failure(TrackingError.notSupported))
                return
            }

            // Store pending request for response correlation (record send time)
            let sentAt = Date()
            trackQueue.async(flags: .barrier) { [weak self] in
                self?.pendingTrackRequests[request.id] = (peerID: peerID, sentAt: sentAt, completion: completion)
                let count = self?.pendingTrackRequests.count ?? 0
                SecureLogger.debug("📍 NostrTransport: Stored pending TrackRequest id=\(request.id.prefix(8))… total pending=\(count)", category: .session)
            }

            // Send the message FIRST
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)

            // THEN schedule timeout (15 seconds for relay - longer than BLE due to internet latency)
            // This prevents false timeouts from the timeout firing before the message is even sent
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                self?.trackQueue.async(flags: .barrier) {
                    if let pending = self?.pendingTrackRequests.removeValue(forKey: request.id) {
                        DispatchQueue.main.async {
                            pending.completion(.failure(TrackingError.timeout))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Location Announcements

    /// Send periodic location announcement via Nostr relay
    @MainActor
    func sendLocationAnnounce(_ announce: LocationAnnounce, to peerID: PeerID, noisePublicKey: Data) {
        guard let recipientNpub = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)?.peerNostrPublicKey,
              let recipientHex = npubToHex(recipientNpub) else {
            SecureLogger.debug("NostrTransport: Cannot send location announce - no npub for peer", category: .session)
            return
        }

        // Encode as Nostr message with LOCATION: prefix
        let payload = "LOCATION:\(announce.toBinaryData().base64EncodedString())"

        Task { @MainActor in
            guard let identity = try? idBridge.getCurrentNostrIdentity() else {
                SecureLogger.warning("NostrTransport: Cannot send location announce - no identity", category: .session)
                return
            }
            sendWrappedMessage(content: payload, recipientHex: recipientHex, senderIdentity: identity, registerPending: false)
            SecureLogger.debug("📍 Sent location announce via relay to \(peerID.id.prefix(8))", category: .session)
        }
    }

    /// Handle incoming location announcement (called when parsing Nostr messages)
    func handleLocationAnnounce(from senderPeerID: PeerID, announce: LocationAnnounce) {
        Task { @MainActor in
            TrackingService.shared.handleLocationAnnounce(from: senderPeerID, announce: announce, transport: .relay)
        }
    }

    /// Handle incoming TrackResponse from peer (called by ChatViewModel when processing Nostr messages)
    func handleTrackResponse(_ response: TrackResponse) {
        let hasLocation = response.gpsEnabled && response.latitude != nil
        SecureLogger.info("📍 NostrTransport: handleTrackResponse requestID=\(response.requestID.prefix(8))… hasLocation=\(hasLocation)", category: .session)

        trackQueue.async(flags: .barrier) { [weak self] in
            // Log current pending requests for debugging
            let pendingCount = self?.pendingTrackRequests.count ?? 0
            let pendingIDs = self?.pendingTrackRequests.keys.map { $0.prefix(8) }.joined(separator: ", ") ?? "none"
            SecureLogger.debug("📍 NostrTransport: \(pendingCount) pending requests: [\(pendingIDs)]", category: .session)

            guard let pending = self?.pendingTrackRequests.removeValue(forKey: response.requestID) else {
                SecureLogger.warning("📍 NostrTransport: received TrackResponse with no pending request: \(response.requestID.prefix(8))…", category: .session)
                return
            }
            let pingMs = Int(Date().timeIntervalSince(pending.sentAt) * 1000)
            SecureLogger.info("📍 NostrTransport: TrackResponse matched! RTT=\(pingMs)ms for peer=\(pending.peerID.id.prefix(16))", category: .session)
            // No RSSI available over relay (that requires BLE)
            DispatchQueue.main.async {
                pending.completion(.success((response: response, pingMs: pingMs, rssi: nil)))
            }
        }
    }

    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? idBridge.getCurrentNostrIdentity() else { return }
            SecureLogger.debug("NostrTransport: preparing DELIVERED ack id=\(messageID.prefix(8))…", category: .session)
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .delivered, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed DELIVERED ack", category: .session)
                return
            }
            sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }
}

// MARK: - Geohash Helpers

extension NostrTransport {

    // MARK: Geohash ACK helpers
    func sendDeliveryAckGeohash(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        Task { @MainActor in
            SecureLogger.debug("GeoDM: send DELIVERED mid=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: messageID, senderPeerID: senderPeerID) else { return }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
        }
    }

    func sendReadReceiptGeohash(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        Task { @MainActor in
            SecureLogger.debug("GeoDM: send READ mid=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID, senderPeerID: senderPeerID) else { return }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
        }
    }

    // MARK: Geohash DMs (per-geohash identity)
    func sendPrivateMessageGeohash(content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String) {
        Task { @MainActor in
            guard !recipientHex.isEmpty else { return }
            SecureLogger.debug("GeoDM: send PM mid=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: content, messageID: messageID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed geohash PM packet", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
        }
    }
}

// MARK: - Private Helpers

extension NostrTransport {
    /// Converts npub bech32 string to hex pubkey
    @MainActor
    private func npubToHex(_ npub: String) -> String? {
        do {
            let (hrp, data) = try Bech32.decode(npub)
            guard hrp == "npub" else { return nil }
            return data.hexEncodedString()
        } catch {
            SecureLogger.error("NostrTransport: failed to decode npub -> hex: \(error)", category: .session)
            return nil
        }
    }

    /// Creates and sends a gift-wrapped private message event
    @MainActor
    private func sendWrappedMessage(content: String, recipientHex: String, senderIdentity: NostrIdentity, registerPending: Bool = false) {
        let relayStatus = NostrRelayManager.shared.humanReadableStatus
        SecureLogger.info("NostrTransport: sendWrappedMessage - relay status: \(relayStatus), recipientHex (full): \(recipientHex)", category: .session)

        guard let event = try? NostrProtocol.createPrivateMessage(content: content, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
            SecureLogger.error("NostrTransport: failed to build Nostr event", category: .session)
            return
        }
        if registerPending {
            NostrRelayManager.registerPendingGiftWrap(id: event.id)
        }
        SecureLogger.debug("NostrTransport: sending event \(event.id.prefix(16))… to relays", category: .session)
        NostrRelayManager.shared.sendEvent(event)
    }

    /// Must be called within a barrier on `queue`
    private func processReadQueueIfNeeded() {
        guard !isSendingReadAcks else { return }
        guard !readQueue.isEmpty else { return }
        isSendingReadAcks = true
        let item = readQueue.removeFirst()
        sendReadAckItem(item)
    }

    /// Sends a single read ack item (called after extraction from queue within barrier)
    private func sendReadAckItem(_ item: QueuedRead) {
        Task { @MainActor in
            defer { scheduleNextReadAck() }
            guard let recipientNpub = resolveRecipientNpub(for: item.peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? idBridge.getCurrentNostrIdentity() else { return }
            SecureLogger.debug("NostrTransport: preparing READ ack id=\(item.receipt.originalMessageID.prefix(8))…", category: .session)
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .readReceipt, messageID: item.receipt.originalMessageID, recipientPeerID: item.peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed READ ack", category: .session)
                return
            }
            sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    private func scheduleNextReadAck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + readAckInterval) { [weak self] in
            self?.queue.async(flags: .barrier) { [weak self] in
                self?.isSendingReadAcks = false
                self?.processReadQueueIfNeeded()
            }
        }
    }

    @MainActor
    private func resolveRecipientNpub(for peerID: PeerID) -> String? {
        SecureLogger.debug("NostrTransport: resolveRecipientNpub for peerID=\(peerID.id.prefix(16)), idLen=\(peerID.id.count)", category: .session)

        // Try to parse as Noise key (full hex)
        if let noiseKey = Data(hexString: peerID.id) {
            let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
            SecureLogger.debug("NostrTransport: lookup by noiseKey - found: \(fav != nil), hasNpub: \(fav?.peerNostrPublicKey != nil)", category: .session)
            if let npub = fav?.peerNostrPublicKey {
                return npub
            }
        }

        // Try to lookup by short peerID
        if peerID.id.count == 16 {
            let fav = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID)
            SecureLogger.debug("NostrTransport: lookup by shortPeerID - found: \(fav != nil), hasNpub: \(fav?.peerNostrPublicKey != nil)", category: .session)
            if let npub = fav?.peerNostrPublicKey {
                SecureLogger.info("NostrTransport: RESOLVED recipient npub from favorites: \(npub)", category: .session)
                return npub
            }
        }

        SecureLogger.warning("NostrTransport: could not resolve npub for peerID=\(peerID.id.prefix(16))", category: .session)
        return nil
    }
}

// MARK: - TransportMetadata Conformance

extension NostrTransport: TransportMetadata {
    var transportName: String { "Public Relay" }

    var priority: Int { 40 }  // Lowest priority - public relay fallback

    var requiresInternet: Bool { true }

    var isDirectConnection: Bool { false }

    nonisolated var connectionStatus: TransportConnectionStatus {
        // Use reachable peers count as a proxy for connection status
        // This avoids MainActor requirement while providing useful info
        let peerCount = queue.sync { reachablePeers.count }
        if peerCount > 0 {
            return .connected(peerCount: peerCount)
        } else {
            return .disconnected
        }
    }
}
