//
// TransportManager.swift
// bitchat
//
// Orchestrates all transports with priority-based routing and automatic failover.
//

import BitLogger
import Foundation
import Combine

/// Manages multiple transports and provides smart routing based on priority and reachability
@MainActor
final class TransportManager: ObservableObject {
    static let shared = TransportManager()

    // MARK: - Published State

    @Published private(set) var transports: [any ManagedTransport] = []
    @Published private(set) var diagnostics: [TransportDiagnostic] = []

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var privateServerTransports: [UUID: PrivateServerTransport] = [:]

    // MARK: - Initialization

    private init() {
        // Observe private server config changes
        NotificationCenter.default.addObserver(
            forName: .privateServerConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncPrivateServers()
            }
        }
    }

    // MARK: - Transport Registration

    /// Register a transport with the manager
    func register(_ transport: any ManagedTransport) {
        guard !transports.contains(where: { $0.transportName == transport.transportName }) else {
            SecureLogger.warning("TransportManager: Transport '\(transport.transportName)' already registered", category: .session)
            return
        }
        transports.append(transport)
        transports.sort { $0.priority > $1.priority }
        updateDiagnostics()
        SecureLogger.info("TransportManager: Registered transport '\(transport.transportName)' with priority \(transport.priority)", category: .session)
    }

    /// Unregister a transport from the manager
    func unregister(_ transport: any ManagedTransport) {
        transports.removeAll { $0.transportName == transport.transportName }
        updateDiagnostics()
        SecureLogger.info("TransportManager: Unregistered transport '\(transport.transportName)'", category: .session)
    }

    // MARK: - Transport Selection

    /// Get the best available transport for a peer (highest priority that can reach the peer)
    func bestTransport(for peerID: PeerID) -> (any Transport)? {
        for transport in transports {
            if transport.isPeerReachable(peerID) {
                SecureLogger.debug("TransportManager: Best transport for \(peerID.id.prefix(8)) is '\(transport.transportName)'", category: .session)
                return transport
            }
        }
        SecureLogger.debug("TransportManager: No transport available for \(peerID.id.prefix(8))", category: .session)
        return nil
    }

    /// Check if a peer is reachable via any registered transport
    func isPeerReachable(_ peerID: PeerID) -> Bool {
        transports.contains { $0.isPeerReachable(peerID) }
    }

    /// Get all transports that can reach a specific peer
    func transportsForPeer(_ peerID: PeerID) -> [any ManagedTransport] {
        transports.filter { $0.isPeerReachable(peerID) }
    }

    /// Get transport by name
    func transport(named name: String) -> (any ManagedTransport)? {
        transports.first { $0.transportName == name }
    }

    // MARK: - Private Server Management

    /// Add a new private server configuration
    func addPrivateServer(_ config: PrivateServerConfig) {
        PrivateServerPersistenceService.shared.addServer(config)
        // syncPrivateServers() will be called via notification
    }

    /// Remove a private server by ID
    func removePrivateServer(_ serverID: UUID) {
        // Stop and remove the transport if running
        if let transport = privateServerTransports[serverID] {
            transport.stopServices()
            unregister(transport)
            privateServerTransports.removeValue(forKey: serverID)
        }
        PrivateServerPersistenceService.shared.removeServer(serverID)
    }

    /// Update a private server configuration
    func updatePrivateServer(_ config: PrivateServerConfig) {
        PrivateServerPersistenceService.shared.updateServer(config)
        // syncPrivateServers() will be called via notification
    }

    /// Sync private server transports with persisted configuration
    private func syncPrivateServers() {
        let configs = PrivateServerPersistenceService.shared.servers

        // Remove transports for deleted servers
        let configIDs = Set(configs.map { $0.id })
        for serverID in privateServerTransports.keys {
            if !configIDs.contains(serverID) {
                if let transport = privateServerTransports[serverID] {
                    transport.stopServices()
                    unregister(transport)
                    privateServerTransports.removeValue(forKey: serverID)
                    SecureLogger.info("TransportManager: Removed private server transport for deleted config", category: .session)
                }
            }
        }

        // Add/update transports for new/changed servers
        for config in configs where config.isEnabled {
            if let existingTransport = privateServerTransports[config.id] {
                // Update existing transport if config changed
                existingTransport.updateConfig(config)
            } else {
                // Create new transport
                let transport = PrivateServerTransport(config: config)
                privateServerTransports[config.id] = transport
                register(transport)
                transport.startServices()
                SecureLogger.info("TransportManager: Created private server transport for '\(config.name)'", category: .session)
            }
        }

        // Disable transports for disabled servers
        for config in configs where !config.isEnabled {
            if let transport = privateServerTransports[config.id] {
                transport.stopServices()
                unregister(transport)
                privateServerTransports.removeValue(forKey: config.id)
                SecureLogger.info("TransportManager: Disabled private server transport for '\(config.name)'", category: .session)
            }
        }
    }

    // MARK: - Diagnostics

    /// Update diagnostic information for all transports
    func updateDiagnostics() {
        diagnostics = transports.map { transport in
            // Count reachable peers for this transport
            // This is a simplified count - could be enhanced
            let peerCount: Int
            switch transport.connectionStatus {
            case .connected(let count):
                peerCount = count
            default:
                peerCount = 0
            }
            return TransportDiagnostic(from: transport, reachablePeerCount: peerCount)
        }
    }

    /// Get diagnostic for a specific transport
    func diagnostic(for transportName: String) -> TransportDiagnostic? {
        diagnostics.first { $0.transportName == transportName }
    }

    // MARK: - Lifecycle

    /// Start all registered transports
    func startAllTransports() {
        for transport in transports {
            transport.startServices()
        }
        SecureLogger.info("TransportManager: Started \(transports.count) transports", category: .session)
    }

    /// Stop all registered transports
    func stopAllTransports() {
        for transport in transports {
            transport.stopServices()
        }
        SecureLogger.info("TransportManager: Stopped \(transports.count) transports", category: .session)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let privateServerConfigChanged = Notification.Name("PrivateServerConfigChanged")
}
