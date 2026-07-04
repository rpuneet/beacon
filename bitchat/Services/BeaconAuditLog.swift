//
// BeaconAuditLog.swift
// bitchat
//
// Records every Beacon location disclosure so the user can always see
// who received their location, when, and at what precision.
//

import Foundation
import Combine
import BitLogger

struct BeaconAuditEvent: Codable, Identifiable, Equatable {
    enum EventType: String, Codable {
        case locationSent
        case locationReceived
        case pingDenied
        case trackingStarted
        case trackingStopped

        var displayName: String {
            switch self {
            case .locationSent: return "location sent"
            case .locationReceived: return "location received"
            case .pingDenied: return "ping denied"
            case .trackingStarted: return "tracking started"
            case .trackingStopped: return "tracking stopped"
            }
        }

        var systemImage: String {
            switch self {
            case .locationSent: return "location.fill"
            case .locationReceived: return "location.circle"
            case .pingDenied: return "hand.raised.fill"
            case .trackingStarted: return "scope"
            case .trackingStopped: return "scope"
            }
        }
    }

    let id: UUID
    let timestamp: Date
    let type: EventType
    let peerFingerprint: String
    let peerName: String
    let precision: String?

    init(type: EventType, peerFingerprint: String, peerName: String, precision: String? = nil, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.type = type
        self.peerFingerprint = peerFingerprint
        self.peerName = peerName
        self.precision = precision
    }
}

@MainActor
final class BeaconAuditLog: ObservableObject {
    static let shared = BeaconAuditLog()

    @Published private(set) var events: [BeaconAuditEvent] = []

    private static let storageKey = "beacon.auditLog"
    private static let maxEvents = 500
    private static let maxAge: TimeInterval = 30 * 24 * 3600  // 30 days
    /// Window in which a sent location counts as "actively sharing"
    static let activeSharingWindow: TimeInterval = 5 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Recording

    func record(_ type: BeaconAuditEvent.EventType, peerFingerprint: String, peerName: String, precision: String? = nil) {
        events.append(BeaconAuditEvent(type: type, peerFingerprint: peerFingerprint, peerName: peerName, precision: precision))
        prune()
        save()
    }

    func clearAll() {
        events.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Queries

    /// Peers we disclosed our location to within the active window, most recent first.
    var activeSharingPeers: [(fingerprint: String, name: String, lastSent: Date)] {
        let cutoff = Date().addingTimeInterval(-Self.activeSharingWindow)
        var latest: [String: (name: String, lastSent: Date)] = [:]
        for event in events where event.type == .locationSent && event.timestamp > cutoff {
            if let existing = latest[event.peerFingerprint], existing.lastSent >= event.timestamp { continue }
            latest[event.peerFingerprint] = (event.peerName, event.timestamp)
        }
        return latest
            .map { (fingerprint: $0.key, name: $0.value.name, lastSent: $0.value.lastSent) }
            .sorted { $0.lastSent > $1.lastSent }
    }

    var isActivelySharing: Bool { !activeSharingPeers.isEmpty }

    /// Events from the last 24 hours, newest first.
    var recentEvents: [BeaconAuditEvent] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return events.filter { $0.timestamp > cutoff }.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Persistence

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        events.removeAll { $0.timestamp < cutoff }
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            events = try JSONDecoder().decode([BeaconAuditEvent].self, from: data)
            prune()
        } catch {
            SecureLogger.error("[Beacon] Failed to decode audit log, history lost: \(error)", category: .session)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(events)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            SecureLogger.error("[Beacon] Failed to persist audit log: \(error)", category: .session)
        }
    }
}
