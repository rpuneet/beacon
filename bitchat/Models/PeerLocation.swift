//
// PeerLocation.swift
// bitchat
//
// Data model for peer location information from beacon pings
//

import BitFoundation
import Foundation
import CoreLocation
import simd

// MARK: - Peer Location

/// Represents a peer's location and connection information from a beacon ping response
struct PeerLocation: Identifiable, Equatable {
    let id: String  // PeerID.id
    let peerIDString: String

    // MARK: - GPS Data
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?
    let gpsEnabled: Bool

    // MARK: - Signal Data
    let transport: TransportType
    let pingMs: Int  // Round-trip time
    let peerRSSI: Int?  // RSSI that peer sees for us

    // MARK: - UWB Data
    let uwbSupported: Bool
    let uwbToken: Data?
    var uwbDistance: Float?  // Updated by UWBTrackingManager
    // UWB direction stored as components (simd_float3 not Codable)
    var uwbDirectionX: Float?
    var uwbDirectionY: Float?
    var uwbDirectionZ: Float?

    // MARK: - Metadata
    let timestamp: Date

    /// Transport type for the beacon response
    enum TransportType: String, Codable {
        case ble = "BLE"
        case relay = "Relay"
    }

    // MARK: - Computed Properties

    /// Get the PeerID from stored string
    var peerID: PeerID { PeerID(str: peerIDString) }

    /// Get coordinate if available
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Get UWB direction vector if available
    var uwbDirection: simd_float3? {
        guard let x = uwbDirectionX, let y = uwbDirectionY, let z = uwbDirectionZ else { return nil }
        return simd_float3(x, y, z)
    }

    /// Whether the peer has valid location data
    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Whether the location data is stale (older than 5 minutes)
    var isStale: Bool { Date().timeIntervalSince(timestamp) > 300 }

    /// Whether UWB data is available
    var hasUWB: Bool { uwbSupported && uwbToken != nil }

    // MARK: - Initializer

    /// Create with explicit values
    init(
        peerIDString: String,
        gpsEnabled: Bool,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        horizontalAccuracy: Double?,
        transport: TransportType,
        pingMs: Int,
        peerRSSI: Int?,
        uwbSupported: Bool,
        uwbToken: Data?,
        timestamp: Date
    ) {
        self.id = peerIDString
        self.peerIDString = peerIDString
        self.gpsEnabled = gpsEnabled
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.transport = transport
        self.pingMs = pingMs
        self.peerRSSI = peerRSSI
        self.uwbSupported = uwbSupported
        self.uwbToken = uwbToken
        self.uwbDistance = nil
        self.uwbDirectionX = nil
        self.uwbDirectionY = nil
        self.uwbDirectionZ = nil
        self.timestamp = timestamp
    }

    // MARK: - Mutating Methods

    /// Update UWB distance from ranging session
    mutating func updateUWBDistance(_ distance: Float, direction: simd_float3?) {
        self.uwbDistance = distance
        self.uwbDirectionX = direction?.x
        self.uwbDirectionY = direction?.y
        self.uwbDirectionZ = direction?.z
    }

    // MARK: - Equatable

    static func == (lhs: PeerLocation, rhs: PeerLocation) -> Bool {
        lhs.id == rhs.id &&
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude &&
        lhs.gpsEnabled == rhs.gpsEnabled &&
        lhs.transport == rhs.transport &&
        lhs.pingMs == rhs.pingMs &&
        lhs.peerRSSI == rhs.peerRSSI &&
        lhs.uwbSupported == rhs.uwbSupported &&
        lhs.uwbDistance == rhs.uwbDistance &&
        lhs.timestamp == rhs.timestamp
    }
}
