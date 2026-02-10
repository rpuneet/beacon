//
// TransportMetadata.swift
// bitchat
//
// Transport characteristics protocol for routing decisions and priority-based failover.
//

import Foundation

/// Connection status for a transport
enum TransportConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected(peerCount: Int)
    case degraded(reason: String)

    var isConnected: Bool {
        switch self {
        case .connected, .degraded:
            return true
        case .disconnected, .connecting:
            return false
        }
    }
}

/// Transport characteristics for routing decisions
protocol TransportMetadata: AnyObject {
    /// Human-readable transport name (e.g., "BLE Mesh", "Nostr Relay")
    var transportName: String { get }

    /// Priority for transport selection (higher = preferred)
    /// BLE Mesh: 100, WiFi Direct: 80, Private Server: 60, Public Relay: 40
    var priority: Int { get }

    /// Whether this transport requires internet connectivity
    var requiresInternet: Bool { get }

    /// Whether this is a direct P2P connection (vs relay-based)
    var isDirectConnection: Bool { get }

    /// Current connection status of this transport
    /// Note: Implementations should be thread-safe
    var connectionStatus: TransportConnectionStatus { get }
}

/// Combined protocol for transports that can be managed by TransportManager
typealias ManagedTransport = Transport & TransportMetadata

/// Diagnostic information for a transport
struct TransportDiagnostic: Identifiable {
    let id: String
    let transportName: String
    let priority: Int
    let status: TransportConnectionStatus
    let requiresInternet: Bool
    let isDirectConnection: Bool
    let reachablePeerCount: Int
    let lastUpdated: Date

    init(from transport: ManagedTransport, reachablePeerCount: Int) {
        self.id = transport.transportName
        self.transportName = transport.transportName
        self.priority = transport.priority
        self.status = transport.connectionStatus
        self.requiresInternet = transport.requiresInternet
        self.isDirectConnection = transport.isDirectConnection
        self.reachablePeerCount = reachablePeerCount
        self.lastUpdated = Date()
    }
}
