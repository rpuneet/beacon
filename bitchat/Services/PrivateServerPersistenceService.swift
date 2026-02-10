//
// PrivateServerPersistenceService.swift
// bitchat
//
// Persists private Nostr relay server configurations in Keychain.
//

import BitLogger
import Foundation
import Combine

/// Configuration for a private Nostr-compatible relay server
struct PrivateServerConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String              // User-friendly name (e.g., "Work Server")
    var url: String               // WebSocket URL (e.g., wss://relay.example.com)
    var authToken: String?        // Optional NIP-42 authentication token
    var isEnabled: Bool
    let addedAt: Date
    var lastUpdated: Date

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        authToken: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.authToken = authToken
        self.isEnabled = isEnabled
        self.addedAt = Date()
        self.lastUpdated = Date()
    }

    /// Validate the server URL
    var isValidURL: Bool {
        guard let url = URL(string: url) else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "wss" || scheme == "ws"
    }
}

/// Manages persistent storage of private relay server configurations
@MainActor
final class PrivateServerPersistenceService: ObservableObject {

    private static let storageKey = "chat.bitchat.privateServers"
    private static let keychainService = "chat.bitchat.privateServers"
    private let keychain: KeychainManagerProtocol

    @Published private(set) var servers: [PrivateServerConfig] = []

    static let shared = PrivateServerPersistenceService()

    init(keychain: KeychainManagerProtocol = KeychainManager()) {
        self.keychain = keychain
        loadServers()
    }

    // MARK: - Server Management

    /// Add a new server configuration
    func addServer(_ config: PrivateServerConfig) {
        guard !servers.contains(where: { $0.id == config.id }) else {
            SecureLogger.warning("PrivateServerPersistence: Server with ID \(config.id) already exists", category: .session)
            return
        }

        SecureLogger.info("PrivateServerPersistence: Adding server '\(config.name)' at \(config.url)", category: .session)
        servers.append(config)
        saveServers()
        notifyChange()
    }

    /// Update an existing server configuration
    func updateServer(_ config: PrivateServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else {
            SecureLogger.warning("PrivateServerPersistence: Server with ID \(config.id) not found", category: .session)
            return
        }

        var updated = config
        updated.lastUpdated = Date()
        servers[index] = updated
        saveServers()
        notifyChange()
        SecureLogger.info("PrivateServerPersistence: Updated server '\(config.name)'", category: .session)
    }

    /// Remove a server by ID
    func removeServer(_ serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            SecureLogger.warning("PrivateServerPersistence: Server with ID \(serverID) not found", category: .session)
            return
        }

        let removed = servers.remove(at: index)
        saveServers()
        notifyChange()
        SecureLogger.info("PrivateServerPersistence: Removed server '\(removed.name)'", category: .session)
    }

    /// Toggle server enabled state
    func toggleServerEnabled(_ serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }

        servers[index].isEnabled.toggle()
        servers[index].lastUpdated = Date()
        saveServers()
        notifyChange()
        SecureLogger.info("PrivateServerPersistence: Server '\(servers[index].name)' enabled: \(servers[index].isEnabled)", category: .session)
    }

    /// Get server by ID
    func server(withID id: UUID) -> PrivateServerConfig? {
        servers.first { $0.id == id }
    }

    /// Get all enabled servers
    var enabledServers: [PrivateServerConfig] {
        servers.filter { $0.isEnabled }
    }

    // MARK: - Persistence

    private func loadServers() {
        guard let data = keychain.load(key: Self.storageKey, service: Self.keychainService) else {
            SecureLogger.info("PrivateServerPersistence: No saved servers found", category: .session)
            return
        }

        do {
            let decoded = try JSONDecoder().decode([PrivateServerConfig].self, from: data)
            servers = decoded
            SecureLogger.info("PrivateServerPersistence: Loaded \(decoded.count) servers", category: .session)
        } catch {
            SecureLogger.error("PrivateServerPersistence: Failed to decode servers: \(error)", category: .session)
        }
    }

    private func saveServers() {
        do {
            let data = try JSONEncoder().encode(servers)
            keychain.save(key: Self.storageKey, data: data, service: Self.keychainService, accessible: nil)
        } catch {
            SecureLogger.error("PrivateServerPersistence: Failed to encode servers: \(error)", category: .session)
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .privateServerConfigChanged, object: nil)
    }
}
