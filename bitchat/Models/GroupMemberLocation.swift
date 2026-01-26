//
// GroupMemberLocation.swift
// bitchat
//
// Model for tracking group member locations in the group tracking view
//

import Foundation
import CoreLocation
import SwiftUI

// MARK: - Member Status

/// Status of a group member based on ping response and location availability
enum MemberStatus: Equatable {
    case respondedToPing      // GREEN - Active, has location
    case connectedNoLocation  // RED - Connected but location off
    case offline              // GREY - Not reachable
    case noRelayKey           // GREY with special text - No Nostr key, must be nearby

    var color: Color {
        switch self {
        case .respondedToPing:
            return .green
        case .connectedNoLocation:
            return .red
        case .offline, .noRelayKey:
            return .gray
        }
    }

    var description: String {
        switch self {
        case .respondedToPing:
            return "Active"
        case .connectedNoLocation:
            return "Location Off"
        case .offline:
            return "Offline"
        case .noRelayKey:
            return "Nearby only"
        }
    }
}

// MARK: - Connection Type

/// Represents how a group member is connected
enum GroupConnectionType: Equatable {
    case ble(rssi: Int)   // Connected via BLE mesh with signal strength
    case relay            // Connected via Nostr relay (no direct connection)
    case offline          // Not currently reachable

    var isOnline: Bool {
        switch self {
        case .ble, .relay:
            return true
        case .offline:
            return false
        }
    }

    var description: String {
        switch self {
        case .ble(let rssi):
            return "BLE (\(rssi) dBm)"
        case .relay:
            return "Relay"
        case .offline:
            return "Offline"
        }
    }

    /// SF Symbol icon for this connection type
    var icon: String {
        switch self {
        case .ble:
            return "antenna.radiowaves.left.and.right"
        case .relay:
            return "globe"
        case .offline:
            return "wifi.slash"
        }
    }

    /// Color for map pin based on connection quality
    var pinColor: TrackingSource {
        switch self {
        case .ble:
            return .ble
        case .relay:
            return .relay
        case .offline:
            return .gps  // Use GPS color for offline (gray in this context)
        }
    }
}

// MARK: - Group Member Location

/// Represents a mutual favorite's location for group tracking
struct GroupMemberLocation: Identifiable, Equatable {
    /// Noise public key (unique identifier for the peer)
    let id: Data

    /// PeerID derived from Noise key
    let peerID: PeerID

    /// Display nickname
    let nickname: String

    /// Current GPS location (nil if unknown)
    let location: CLLocationCoordinate2D?

    /// GPS accuracy in meters
    let accuracy: Double?

    /// Fused distance estimate to this peer
    let distance: DistanceEstimate?

    /// Fused direction estimate to this peer
    let direction: DirectionEstimate?

    /// When location was last updated
    let lastUpdate: Date

    /// How the peer is connected
    let connectionType: GroupConnectionType

    /// Current status (for color-coded display)
    let status: MemberStatus

    /// When peer was last seen online (for offline display)
    let lastSeenAt: Date?

    /// Whether peer responded to current ping cycle
    let respondedToCurrentPing: Bool

    /// Round-trip time in milliseconds for ping response
    let rttMs: Int?

    /// Whether location data is stale (older than 10 seconds - 2x the 5s refresh interval)
    var isStale: Bool {
        Date().timeIntervalSince(lastUpdate) > 10
    }

    /// Whether we have valid location data
    var hasLocation: Bool {
        location != nil
    }

    /// Formatted distance string
    var formattedDistance: String? {
        distance?.formattedDistance
    }

    /// Time since last update
    var timeSinceUpdate: String {
        let interval = Date().timeIntervalSince(lastUpdate)
        if interval < 5 {
            return "now"
        } else if interval < 60 {
            return "\(Int(interval))s ago"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else {
            return "\(Int(interval / 3600))h ago"
        }
    }

    /// Formatted last seen time for offline members
    var lastSeenText: String? {
        guard let lastSeen = lastSeenAt else { return nil }
        let interval = Date().timeIntervalSince(lastSeen)
        if interval < 60 {
            return "Last seen \(Int(interval))s ago"
        } else if interval < 3600 {
            return "Last seen \(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "Last seen \(Int(interval / 3600))h ago"
        } else {
            return "Last seen \(Int(interval / 86400))d ago"
        }
    }

    /// Create a copy with ping status reset
    func withPingReset() -> GroupMemberLocation {
        GroupMemberLocation(
            id: id,
            peerID: peerID,
            nickname: nickname,
            location: location,
            accuracy: accuracy,
            distance: distance,
            direction: direction,
            lastUpdate: lastUpdate,
            connectionType: connectionType,
            status: hasLocation ? .respondedToPing : (connectionType.isOnline ? .connectedNoLocation : .offline),
            lastSeenAt: lastSeenAt,
            respondedToCurrentPing: false,
            rttMs: nil
        )
    }

    // MARK: - Equatable

    static func == (lhs: GroupMemberLocation, rhs: GroupMemberLocation) -> Bool {
        lhs.id == rhs.id &&
        lhs.nickname == rhs.nickname &&
        lhs.location?.latitude == rhs.location?.latitude &&
        lhs.location?.longitude == rhs.location?.longitude &&
        lhs.accuracy == rhs.accuracy &&
        lhs.lastUpdate == rhs.lastUpdate &&
        lhs.connectionType == rhs.connectionType &&
        lhs.status == rhs.status &&
        lhs.respondedToCurrentPing == rhs.respondedToCurrentPing &&
        lhs.rttMs == rhs.rttMs
    }

    // MARK: - Factory Methods

    /// Create an offline member entry (no location data yet)
    static func offline(
        noiseKey: Data,
        peerID: PeerID,
        nickname: String
    ) -> GroupMemberLocation {
        GroupMemberLocation(
            id: noiseKey,
            peerID: peerID,
            nickname: nickname,
            location: nil,
            accuracy: nil,
            distance: nil,
            direction: nil,
            lastUpdate: .distantPast,
            connectionType: .offline,
            status: .offline,
            lastSeenAt: nil,
            respondedToCurrentPing: false,
            rttMs: nil
        )
    }

    /// Create from a track response
    static func fromTrackResponse(
        _ response: TrackResponse,
        noiseKey: Data,
        peerID: PeerID,
        nickname: String,
        connectionType: GroupConnectionType,
        myLocation: CLLocationCoordinate2D?,
        myAccuracy: Double?,
        rssi: Int?,
        status: MemberStatus = .offline,
        rttMs: Int? = nil,
        respondedToCurrentPing: Bool = false
    ) -> GroupMemberLocation {
        let location: CLLocationCoordinate2D?
        if let lat = response.latitude, let lon = response.longitude {
            location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            location = nil
        }

        // Calculate fused distance if we have both locations
        let distance: DistanceEstimate?
        let direction: DirectionEstimate?

        if let myLoc = myLocation, let peerLoc = location {
            let gpsDistance = SignalFusion.gpsDistance(from: myLoc, to: peerLoc)

            // Calculate combined GPS accuracy for proper viability check
            let combinedAccuracy: Double?
            if let myAcc = myAccuracy, let peerAcc = response.horizontalAccuracy {
                combinedAccuracy = SignalFusion.combinedGPSAccuracy(myAccuracy: myAcc, theirAccuracy: peerAcc)
            } else {
                // Use peer accuracy with buffer if my accuracy unknown
                combinedAccuracy = response.horizontalAccuracy.map { $0 * 1.5 }
            }

            // Use priority-based fusion with raw RSSI (not pre-estimated distance)
            distance = SignalFusion.fuseDistanceWithRSSI(
                uwb: nil,  // UWB not available in group tracking
                bleRSSI: rssi,
                bleEstimatedDistance: nil,
                gps: gpsDistance,
                gpsAccuracy: combinedAccuracy
            )

            let bearing = SignalFusion.gpsBearing(from: myLoc, to: peerLoc)
            direction = SignalFusion.fuseDirection(
                uwbVector: nil,
                gpsBearing: bearing,
                gpsDistance: gpsDistance,
                gpsAccuracy: combinedAccuracy
            )
        } else {
            distance = nil
            direction = nil
        }

        return GroupMemberLocation(
            id: noiseKey,
            peerID: peerID,
            nickname: nickname,
            location: location,
            accuracy: response.horizontalAccuracy,
            distance: distance,
            direction: direction,
            lastUpdate: Date(),
            connectionType: connectionType,
            status: status,
            lastSeenAt: connectionType.isOnline ? Date() : nil,
            respondedToCurrentPing: respondedToCurrentPing,
            rttMs: rttMs
        )
    }
}
