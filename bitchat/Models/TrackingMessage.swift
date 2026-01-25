//
// TrackingMessage.swift
// bitchat
//
// Models for mesh-based tracking: request/response for GPS, ping, and UWB measurement.
// This is free and unencumbered software released into the public domain.
//

import Foundation

// MARK: - Track Request

/// Request sent to peer to get their tracking data (GPS + optional UWB token)
/// Ping is measured from request send to response receive.
/// RSSI is measured locally when response arrives.
/// UWB token is included on first request to initiate Nearby Interaction session.
struct TrackRequest {
    let id: String              // UUID for correlation
    let timestamp: UInt64       // ms since epoch when sent (for debugging)
    let uwbToken: Data?         // Optional: our NIDiscoveryToken for UWB (nil if not supported or already exchanged)

    init(id: String = UUID().uuidString, uwbToken: Data? = nil) {
        self.id = id
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        self.uwbToken = uwbToken
    }

    private init(id: String, timestamp: UInt64, uwbToken: Data?) {
        self.id = id
        self.timestamp = timestamp
        self.uwbToken = uwbToken
    }

    /// Binary format: [16 bytes UUID] [8 bytes timestamp] [1 byte hasUWB] [2 bytes token length if hasUWB] [token data if hasUWB]
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUUID(id)
        data.appendUInt64(timestamp)

        if let token = uwbToken, !token.isEmpty {
            data.appendUInt8(1) // hasUWB = true
            data.appendUInt16(UInt16(token.count))
            data.append(token)
        } else {
            data.appendUInt8(0) // hasUWB = false
        }

        return data
    }

    static func fromBinaryData(_ data: Data) -> TrackRequest? {
        guard data.count >= 25 else { return nil } // 16 (UUID) + 8 (timestamp) + 1 (hasUWB)
        var offset = 0
        guard let id = data.readUUID(at: &offset),
              let timestamp = data.readUInt64(at: &offset),
              let hasUWB = data.readUInt8(at: &offset) else { return nil }

        var uwbToken: Data? = nil
        if hasUWB == 1 {
            guard data.count >= 27, // Need at least 2 more bytes for length
                  let tokenLength = data.readUInt16(at: &offset) else { return nil }
            guard data.count >= 27 + Int(tokenLength) else { return nil }
            uwbToken = data.subdata(in: offset..<(offset + Int(tokenLength)))
        }

        return TrackRequest(id: id, timestamp: timestamp, uwbToken: uwbToken)
    }
}

// MARK: - Track Response

/// Response with peer's GPS data and optional UWB token
/// Note: RSSI and ping are measured locally by the requester, not included here.
/// UWB token is included if peer supports UWB and requester sent their token.
struct TrackResponse {
    let requestID: String           // Correlates to request
    let gpsEnabled: Bool            // Whether GPS is enabled on peer
    let latitude: Double?           // nil if GPS disabled
    let longitude: Double?
    let altitude: Double?           // Altitude in meters
    let horizontalAccuracy: Double? // Horizontal accuracy in meters
    let verticalAccuracy: Double?   // Vertical accuracy in meters
    let uwbSupported: Bool          // Whether peer supports UWB
    let uwbToken: Data?             // Peer's NIDiscoveryToken (nil if not supported or already exchanged)

    /// Create response when GPS is disabled and no UWB
    static func disabled(requestID: String) -> TrackResponse {
        TrackResponse(
            requestID: requestID,
            gpsEnabled: false,
            latitude: nil,
            longitude: nil,
            altitude: nil,
            horizontalAccuracy: nil,
            verticalAccuracy: nil,
            uwbSupported: false,
            uwbToken: nil
        )
    }

    /// Binary format: [16 bytes UUID] [1 byte flags] [GPS data if enabled] [UWB token if present]
    /// Flags: bit 0 = gpsEnabled, bit 1 = uwbSupported, bit 2 = hasUwbToken
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUUID(requestID)

        // Encode flags
        var flags: UInt8 = 0
        if gpsEnabled { flags |= 0x01 }
        if uwbSupported { flags |= 0x02 }
        if uwbToken != nil && !uwbToken!.isEmpty { flags |= 0x04 }
        data.appendUInt8(flags)

        // GPS data
        if gpsEnabled {
            data.appendDouble(latitude ?? 0)
            data.appendDouble(longitude ?? 0)
            data.appendDouble(altitude ?? 0)
            data.appendDouble(horizontalAccuracy ?? -1)
            data.appendDouble(verticalAccuracy ?? -1)
        }

        // UWB token
        if let token = uwbToken, !token.isEmpty {
            data.appendUInt16(UInt16(token.count))
            data.append(token)
        }

        return data
    }

    static func fromBinaryData(_ data: Data) -> TrackResponse? {
        guard data.count >= 17 else { return nil } // 16 (UUID) + 1 (flags)
        var offset = 0

        guard let requestID = data.readUUID(at: &offset),
              let flags = data.readUInt8(at: &offset) else { return nil }

        let gpsEnabled = (flags & 0x01) != 0
        let uwbSupported = (flags & 0x02) != 0
        let hasUwbToken = (flags & 0x04) != 0

        // Parse GPS data if enabled
        var latitude: Double? = nil
        var longitude: Double? = nil
        var altitude: Double? = nil
        var horizontalAccuracy: Double? = nil
        var verticalAccuracy: Double? = nil

        if gpsEnabled {
            // Need additional 40 bytes for location data (5 doubles)
            guard data.count >= offset + 40,
                  let lat = data.readDouble(at: &offset),
                  let lon = data.readDouble(at: &offset),
                  let alt = data.readDouble(at: &offset),
                  let hAcc = data.readDouble(at: &offset),
                  let vAcc = data.readDouble(at: &offset) else { return nil }

            latitude = lat
            longitude = lon
            altitude = alt
            horizontalAccuracy = hAcc >= 0 ? hAcc : nil
            verticalAccuracy = vAcc >= 0 ? vAcc : nil
        }

        // Parse UWB token if present
        var uwbToken: Data? = nil
        if hasUwbToken {
            guard data.count >= offset + 2,
                  let tokenLength = data.readUInt16(at: &offset) else { return nil }
            guard data.count >= offset + Int(tokenLength) else { return nil }
            uwbToken = data.subdata(in: offset..<(offset + Int(tokenLength)))
        }

        return TrackResponse(
            requestID: requestID,
            gpsEnabled: gpsEnabled,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            uwbSupported: uwbSupported,
            uwbToken: uwbToken
        )
    }
}

// MARK: - Data Extension for Double

extension Data {
    mutating func appendDouble(_ value: Double) {
        var bits = value.bitPattern
        Swift.withUnsafeBytes(of: &bits) { self.append(contentsOf: $0) }
    }

    func readDouble(at offset: inout Int) -> Double? {
        guard offset + 8 <= self.count else { return nil }
        let bytes = Data(self[offset..<offset + 8])
        offset += 8
        guard bytes.count == 8 else { return nil }
        let bits = bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        return Double(bitPattern: bits)
    }
}
