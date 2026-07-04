//
// PeerLocation.swift
// bitchat
//
// Data model for peer location information from beacon pings
//

import Foundation
import CoreLocation
import simd

/// A peer's last known location and signal data from a beacon PING/PONG
struct PeerLocation: Identifiable, Equatable {
    /// Short PeerID derived from the peer's Noise public key
    let id: String

    // MARK: - GPS Data
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?

    // MARK: - Signal Data
    let transport: TransportType
    let pingMs: Int  // Round-trip time
    let peerRSSI: Int?  // RSSI that peer sees for us

    // MARK: - Live UWB Ranging (updated from UWBTrackingManager)
    var uwbDistance: Float?
    // UWB direction stored as components so Equatable stays simple
    var uwbDirectionX: Float?
    var uwbDirectionY: Float?
    var uwbDirectionZ: Float?

    // MARK: - Metadata
    let timestamp: Date

    enum TransportType: String, Codable {
        case ble = "BLE"
        case relay = "Relay"
    }

    // MARK: - Computed Properties

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var uwbDirection: simd_float3? {
        guard let x = uwbDirectionX, let y = uwbDirectionY, let z = uwbDirectionZ else { return nil }
        return simd_float3(x, y, z)
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    // MARK: - Initializer

    init(
        id: String,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        horizontalAccuracy: Double?,
        transport: TransportType,
        pingMs: Int,
        peerRSSI: Int?,
        timestamp: Date
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.transport = transport
        self.pingMs = pingMs
        self.peerRSSI = peerRSSI
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
        lhs.transport == rhs.transport &&
        lhs.pingMs == rhs.pingMs &&
        lhs.peerRSSI == rhs.peerRSSI &&
        lhs.uwbDistance == rhs.uwbDistance &&
        lhs.uwbDirectionX == rhs.uwbDirectionX &&
        lhs.uwbDirectionY == rhs.uwbDirectionY &&
        lhs.uwbDirectionZ == rhs.uwbDirectionZ &&
        lhs.timestamp == rhs.timestamp
    }
}

// MARK: - Bearing

extension CLLocationCoordinate2D {
    /// Great-circle initial bearing to another coordinate, in degrees from true north
    func bearing(to other: CLLocationCoordinate2D) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        return atan2(y, x) * 180 / .pi
    }
}
