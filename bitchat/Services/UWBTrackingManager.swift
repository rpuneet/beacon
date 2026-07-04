//
// UWBTrackingManager.swift
// bitchat
//
// Manages Ultra-Wideband (UWB) tracking sessions using Apple's Nearby Interaction framework.
// This is free and unencumbered software released into the public domain.
//

import BitFoundation
import Foundation
import Combine
import BitLogger

#if os(iOS)
import NearbyInteraction
import simd

// MARK: - Notification Names

extension NSNotification.Name {
    static let uwbRetryRequested = NSNotification.Name("UWBRetryRequested")
}

/// Manages UWB (Ultra-Wideband) tracking sessions for precision peer tracking.
/// Uses Apple's Nearby Interaction framework to measure distance and direction to nearby peers.
final class UWBTrackingManager: NSObject, ObservableObject {
    static let shared = UWBTrackingManager()

    // MARK: - Published State

    /// Whether UWB is supported on this device (requires U1 chip, iPhone 11+)
    @Published private(set) var isUWBSupported: Bool = false

    /// Active UWB sessions by peer ID
    @Published private(set) var activeSessions: [PeerID: UWBSessionState] = [:]

    // MARK: - Types

    /// State of a UWB session with a peer
    enum UWBSessionState: Equatable {
        case connecting                                          // Token exchange in progress
        case active(distance: Float?, direction: simd_float3?)   // Session active, receiving updates
        case suspended                                           // App backgrounded
        case failed(String)                                      // Session failed (error message)

        static func == (lhs: UWBSessionState, rhs: UWBSessionState) -> Bool {
            switch (lhs, rhs) {
            case (.connecting, .connecting): return true
            case (.suspended, .suspended): return true
            case let (.active(d1, dir1), .active(d2, dir2)):
                return d1 == d2 && dir1 == dir2
            case let (.failed(e1), .failed(e2)):
                return e1 == e2
            default: return false
            }
        }
    }

    // MARK: - Private State

    private var sessions: [PeerID: NISession] = [:]
    private var sessionToPeerID: [NISession: PeerID] = [:]
    private var pendingTokenRequests: Set<PeerID> = []  // Peers we've sent tokens to but haven't received response yet

    // Retry logic
    private var retryCount: [PeerID: Int] = [:]
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 2.0

    // MARK: - Initialization

    private override init() {
        super.init()
        checkUWBCapability()
    }

    // MARK: - Public API

    /// Check and cache UWB capability
    func checkUWBCapability() {
        isUWBSupported = NISession.isSupported
        SecureLogger.info("UWB capability check: supported=\(isUWBSupported)", category: .session)
    }

    /// Normalize PeerID to short format for consistent dictionary lookups
    private func normalizedPeerID(_ peerID: PeerID) -> PeerID {
        peerID.toShort()
    }

    /// Get or create a session for a specific peer and return its serialized discovery token
    /// This ensures we send the correct token that matches the session we'll use with this peer.
    /// - Parameter peerID: The peer we're getting the token for
    /// - Returns: Serialized NIDiscoveryToken data, or nil if UWB not supported
    func getMyTokenData(for peerID: PeerID) -> Data? {
        guard isUWBSupported else {
            SecureLogger.debug("UWB getMyTokenData: not supported", category: .session)
            return nil
        }

        let normalizedID = normalizedPeerID(peerID)

        // Get or create session for this peer
        let session: NISession
        if let existingSession = sessions[normalizedID] {
            session = existingSession
            SecureLogger.debug("UWB using existing session for peer", category: .session)
        } else {
            // Create new session for this peer
            session = NISession()
            session.delegate = self
            sessions[normalizedID] = session
            sessionToPeerID[session] = normalizedID
            // Mark as connecting so handleReceivedToken knows it's usable
            DispatchQueue.main.async {
                self.activeSessions[normalizedID] = .connecting
            }
            SecureLogger.info("UWB created new session for peer", category: .session)
        }

        guard let token = session.discoveryToken else {
            SecureLogger.warning("UWB session has no discovery token", category: .session)
            return nil
        }

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            SecureLogger.debug("UWB token serialized: \(data.count) bytes", category: .session)
            pendingTokenRequests.insert(normalizedID)
            return data
        } catch {
            SecureLogger.error("UWB token serialization failed: \(error)", category: .session)
            return nil
        }
    }

    /// Check if we need to send our UWB token to this peer
    /// - Parameter peerID: The peer to check
    /// - Returns: True if we should include our token in the next TrackRequest
    func shouldSendToken(to peerID: PeerID) -> Bool {
        guard isUWBSupported else { return false }
        let normalizedID = normalizedPeerID(peerID)
        // Send token if we don't have a running session with this peer
        if sessions[normalizedID] != nil {
            // If session exists, check if it's actually running/configured
            if case .active = activeSessions[normalizedID] {
                return false  // Already have an active session
            }
            if case .connecting = activeSessions[normalizedID] {
                return false  // Still waiting for session to establish
            }
        }
        return true  // No session or session not active, send token
    }

    /// Process a received UWB token from a peer and configure our session
    /// - Parameters:
    ///   - peerID: The peer who sent the token
    ///   - tokenData: Serialized NIDiscoveryToken data
    func handleReceivedToken(from peerID: PeerID, tokenData: Data) {
        SecureLogger.info("UWB received token from peer: \(tokenData.count) bytes", category: .session)

        guard isUWBSupported else {
            SecureLogger.warning("UWB received token but UWB not supported on this device", category: .session)
            return
        }

        let normalizedID = normalizedPeerID(peerID)

        // Deserialize the token
        do {
            guard let peerToken = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self,
                from: tokenData
            ) else {
                SecureLogger.error("UWB token deserialization returned nil", category: .session)
                DispatchQueue.main.async {
                    self.activeSessions[normalizedID] = .failed("Invalid token format")
                }
                return
            }

            SecureLogger.info("UWB token deserialized successfully", category: .session)

            let session: NISession

            // Check if we initiated the exchange (sent our token first)
            let weInitiated = pendingTokenRequests.contains(normalizedID)

            if weInitiated, let existingSession = sessions[normalizedID] {
                // We initiated - use our existing session (peer expects this session's token)
                session = existingSession
                SecureLogger.debug("UWB configuring our session (we initiated exchange)", category: .session)
                pendingTokenRequests.remove(normalizedID)
            } else {
                // Peer initiated - create new session (or replace old one)
                if let existingSession = sessions[normalizedID] {
                    SecureLogger.debug("UWB invalidating old session (peer initiated new exchange)", category: .session)
                    existingSession.invalidate()
                    sessionToPeerID.removeValue(forKey: existingSession)
                }
                pendingTokenRequests.remove(normalizedID)

                session = NISession()
                session.delegate = self
                sessions[normalizedID] = session
                sessionToPeerID[session] = normalizedID
                SecureLogger.info("UWB created new session (peer initiated)", category: .session)
            }

            // Configure and run the session with peer's token
            let config = NINearbyPeerConfiguration(peerToken: peerToken)
            session.run(config)
            SecureLogger.info("UWB session configured and running with peer token", category: .session)

            DispatchQueue.main.async {
                self.activeSessions[normalizedID] = .connecting
            }
        } catch {
            SecureLogger.error("UWB token deserialization failed: \(error)", category: .session)
            DispatchQueue.main.async {
                self.activeSessions[normalizedID] = .failed("Token error: \(error.localizedDescription)")
            }
        }
    }

    /// End the UWB session with a peer
    /// - Parameter peerID: The peer to end session with
    func endSession(with peerID: PeerID) {
        let normalizedID = normalizedPeerID(peerID)
        if let session = sessions[normalizedID] {
            session.invalidate()
            sessionToPeerID.removeValue(forKey: session)
        }
        sessions.removeValue(forKey: normalizedID)
        pendingTokenRequests.remove(normalizedID)

        DispatchQueue.main.async {
            self.activeSessions.removeValue(forKey: normalizedID)
        }
    }

    /// End all active UWB sessions
    func endAllSessions() {
        for (_, session) in sessions {
            session.invalidate()
        }
        sessions.removeAll()
        sessionToPeerID.removeAll()
        pendingTokenRequests.removeAll()

        DispatchQueue.main.async {
            self.activeSessions.removeAll()
        }
    }

    /// Get the current UWB distance to a peer (if available)
    /// - Parameter peerID: The peer to get distance for
    /// - Returns: Distance in meters, or nil if not available
    func getDistance(for peerID: PeerID) -> Float? {
        let normalizedID = normalizedPeerID(peerID)
        if case .active(let distance, _) = activeSessions[normalizedID] {
            return distance
        }
        return nil
    }

    /// Get the current UWB direction to a peer (if available)
    /// - Parameter peerID: The peer to get direction for
    /// - Returns: Direction vector, or nil if not available
    func getDirection(for peerID: PeerID) -> simd_float3? {
        let normalizedID = normalizedPeerID(peerID)
        if case .active(_, let direction) = activeSessions[normalizedID] {
            return direction
        }
        return nil
    }

    // MARK: - Private Methods

    private func peerIDForSession(_ session: NISession) -> PeerID? {
        return sessionToPeerID[session]
    }
}

// MARK: - NISessionDelegate

extension UWBTrackingManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peerID = peerIDForSession(session),
              let object = nearbyObjects.first else { return }

        let distStr = object.distance.map { String(format: "%.2fm", $0) } ?? "nil"
        let dirStr: String
        if let dir = object.direction {
            dirStr = String(format: "(x:%.2f, y:%.2f, z:%.2f)", dir.x, dir.y, dir.z)
        } else {
            dirStr = "nil (hold devices upright)"
        }
        SecureLogger.debug("UWB update: dist=\(distStr), dir=\(dirStr)", category: .session)

        DispatchQueue.main.async {
            self.activeSessions[peerID] = .active(
                distance: object.distance,
                direction: object.direction
            )
            // Reset retry count on successful connection
            self.retryCount.removeValue(forKey: peerID)
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peerID = peerIDForSession(session) else { return }

        let errorMessage: String
        let shouldRetry: Bool

        switch reason {
        case .peerEnded:
            errorMessage = "Peer ended session"
            shouldRetry = false  // Peer intentionally ended, don't retry
            SecureLogger.info("UWB session: peer ended", category: .session)
        case .timeout:
            errorMessage = "Session timed out"
            shouldRetry = true  // Timeout is recoverable
            SecureLogger.warning("UWB session: timeout", category: .session)
        @unknown default:
            errorMessage = "Session ended"
            shouldRetry = true
        }

        if shouldRetry {
            retrySession(for: peerID, reason: errorMessage)
        } else {
            DispatchQueue.main.async {
                self.activeSessions[peerID] = .failed(errorMessage)
                self.retryCount.removeValue(forKey: peerID)
            }
        }
    }

    /// Attempt to retry a UWB session with a peer
    private func retrySession(for peerID: PeerID, reason: String) {
        let currentRetries = retryCount[peerID] ?? 0

        if currentRetries >= maxRetries {
            SecureLogger.warning("UWB session: max retries reached for peer", category: .session)
            DispatchQueue.main.async {
                self.activeSessions[peerID] = .failed("\(reason) (max retries)")
                self.retryCount.removeValue(forKey: peerID)
            }
            return
        }

        retryCount[peerID] = currentRetries + 1
        SecureLogger.info("UWB session: scheduling retry \(currentRetries + 1)/\(maxRetries) for peer", category: .session)

        DispatchQueue.main.async {
            self.activeSessions[peerID] = .connecting
        }

        // Clean up old session
        if let oldSession = sessions[peerID] {
            oldSession.invalidate()
            sessionToPeerID.removeValue(forKey: oldSession)
            sessions.removeValue(forKey: peerID)
        }

        // Schedule retry after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self = self else { return }

            // Create fresh session
            let newSession = NISession()
            newSession.delegate = self
            self.sessions[peerID] = newSession
            self.sessionToPeerID[newSession] = peerID

            SecureLogger.info("UWB session: retry created new session for peer", category: .session)

            // Post notification to request new token exchange
            NotificationCenter.default.post(
                name: .uwbRetryRequested,
                object: nil,
                userInfo: ["peerID": peerID]
            )
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        guard let peerID = peerIDForSession(session) else { return }

        DispatchQueue.main.async {
            self.activeSessions[peerID] = .suspended
        }
    }

    func sessionSuspensionEnded(_ session: NISession) {
        guard let peerID = peerIDForSession(session) else { return }

        // Session will automatically resume, mark as connecting until we get data
        DispatchQueue.main.async {
            self.activeSessions[peerID] = .connecting
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let peerID = peerIDForSession(session) else { return }

        sessions.removeValue(forKey: peerID)
        sessionToPeerID.removeValue(forKey: session)

        DispatchQueue.main.async {
            self.activeSessions[peerID] = .failed(error.localizedDescription)
        }
    }
}

#elseif os(macOS)
import simd

// MARK: - macOS Stub

/// macOS stub for UWBTrackingManager
/// Note: Macs with M1+ chips have UWB hardware, but Apple's Nearby Interaction
/// framework is currently only available on iOS/watchOS (as of 2025).
/// This stub will be replaced with a real implementation when Apple adds macOS support.
final class UWBTrackingManager: ObservableObject {
    static let shared = UWBTrackingManager()

    /// Always false on macOS until Apple adds Nearby Interaction framework support
    @Published private(set) var isUWBSupported: Bool = false
    @Published private(set) var activeSessions: [PeerID: UWBSessionState] = [:]

    enum UWBSessionState: Equatable {
        case connecting
        case active(distance: Float?, direction: simd_float3?)
        case suspended
        case failed(String)
    }

    private init() {
        // Future: Check if NearbyInteraction becomes available on macOS
        // isUWBSupported = NISession.isSupported
    }

    func checkUWBCapability() { /* Nearby Interaction not available on macOS */ }
    func getMyTokenData(for peerID: PeerID) -> Data? { nil }
    func shouldSendToken(to peerID: PeerID) -> Bool { false }
    func handleReceivedToken(from peerID: PeerID, tokenData: Data) { /* no-op */ }
    func endSession(with peerID: PeerID) { /* no-op */ }
    func endAllSessions() { /* no-op */ }
    func getDistance(for peerID: PeerID) -> Float? { nil }
    func getDirection(for peerID: PeerID) -> simd_float3? { nil }
}
#endif
