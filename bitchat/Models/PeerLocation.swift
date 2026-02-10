//
// PeerLocation.swift
// bitchat
//
// Data model for peer location information from tracking
//

import Foundation
import CoreLocation
import simd

/// Represents a peer's location and connection information from a tracking response
struct PeerLocation: Identifiable, Equatable, Codable {
    let id: String  // PeerID.id for Codable compatibility
    let peerIDString: String  // Store as string for Codable

    // MARK: - GPS Data
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let gpsEnabled: Bool

    // MARK: - Signal Data
    let transport: TransportType
    let pingMs: Int
    let rssi: Int?

    // MARK: - UWB Data
    let uwbDistance: Float?
    // UWB direction stored as components (simd_float3 not Codable)
    let uwbDirectionX: Float?
    let uwbDirectionY: Float?
    let uwbDirectionZ: Float?

    // MARK: - Metadata
    let timestamp: Date

    /// Transport type for the tracking response
    enum TransportType: String, Codable {
        case ble = "BLE"
        case relay = "Relay"
        case wifi = "WiFi"
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

    /// Whether the location data is stale (older than 60 seconds)
    var isStale: Bool { Date().timeIntervalSince(timestamp) > 60 }

    // MARK: - Factory Initializer

    /// Create from a TrackResponse
    init(
        peerID: PeerID,
        response: TrackResponse,
        transport: TransportType,
        pingMs: Int,
        rssi: Int?,
        uwbDistance: Float?,
        uwbDirection: simd_float3?
    ) {
        self.id = peerID.id
        self.peerIDString = peerID.id

        // GPS data
        if response.gpsEnabled, let lat = response.latitude, let lon = response.longitude {
            self.latitude = lat
            self.longitude = lon
        } else {
            self.latitude = nil
            self.longitude = nil
        }
        self.altitude = response.altitude
        self.horizontalAccuracy = response.horizontalAccuracy
        self.verticalAccuracy = response.verticalAccuracy
        self.gpsEnabled = response.gpsEnabled

        // Signal data
        self.transport = transport
        self.pingMs = pingMs
        self.rssi = rssi

        // UWB data
        self.uwbDistance = uwbDistance
        self.uwbDirectionX = uwbDirection?.x
        self.uwbDirectionY = uwbDirection?.y
        self.uwbDirectionZ = uwbDirection?.z

        self.timestamp = Date()
    }

    /// Create from persisted data (for loading cached locations)
    init(
        peerIDString: String,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        horizontalAccuracy: Double?,
        verticalAccuracy: Double?,
        gpsEnabled: Bool,
        transport: TransportType,
        pingMs: Int,
        rssi: Int?,
        uwbDistance: Float?,
        uwbDirection: simd_float3?,
        timestamp: Date
    ) {
        self.id = peerIDString
        self.peerIDString = peerIDString
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.gpsEnabled = gpsEnabled
        self.transport = transport
        self.pingMs = pingMs
        self.rssi = rssi
        self.uwbDistance = uwbDistance
        self.uwbDirectionX = uwbDirection?.x
        self.uwbDirectionY = uwbDirection?.y
        self.uwbDirectionZ = uwbDirection?.z
        self.timestamp = timestamp
    }

    /// Create from a LocationAnnounce (passive periodic broadcast)
    init(peerID: PeerID, announce: LocationAnnounce, transport: TransportType) {
        self.id = peerID.id
        self.peerIDString = peerID.id

        if announce.gpsEnabled, let lat = announce.latitude, let lon = announce.longitude {
            self.latitude = lat
            self.longitude = lon
        } else {
            self.latitude = nil
            self.longitude = nil
        }
        self.altitude = announce.altitude
        self.horizontalAccuracy = announce.horizontalAccuracy
        self.verticalAccuracy = nil
        self.gpsEnabled = announce.gpsEnabled

        self.transport = transport
        self.pingMs = 0  // No ping for announcements
        self.rssi = nil

        self.uwbDistance = nil
        self.uwbDirectionX = nil
        self.uwbDirectionY = nil
        self.uwbDirectionZ = nil

        self.timestamp = Date(timeIntervalSince1970: Double(announce.timestamp) / 1000.0)
    }

    // MARK: - Equatable

    static func == (lhs: PeerLocation, rhs: PeerLocation) -> Bool {
        lhs.id == rhs.id &&
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude &&
        lhs.transport == rhs.transport &&
        lhs.pingMs == rhs.pingMs &&
        lhs.rssi == rhs.rssi &&
        lhs.timestamp == rhs.timestamp
    }
}
