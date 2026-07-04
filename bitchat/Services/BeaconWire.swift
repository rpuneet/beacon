//
// BeaconWire.swift
// bitchat
//
// Pure encoding/decoding for the beacon wire format, extracted from
// BeaconService so the protocol is unit-testable:
//   [PING]:<requestID>:<rssi>:<lat,lon,alt,hacc,vacc>[:<uwbTokenBase64>]
//   [PONG]:<requestID>:<rssi>:<lat,lon,alt,hacc,vacc>[:<uwbTokenBase64>]
//

import Foundation

enum BeaconWire {
    static let pingPrefix = "[PING]:"
    static let pongPrefix = "[PONG]:"

    enum Kind {
        case ping
        case pong
    }

    struct Location: Equatable {
        let lat: Double
        let lon: Double
        let alt: Int
        let hacc: Int
        let vacc: Int
    }

    struct Message: Equatable {
        let kind: Kind
        let requestID: String
        let rssi: Int?
        let location: Location?
        /// Decoded UWB discovery token; nil when absent or malformed
        let uwbToken: Data?
        /// True when a token field was present but not valid base64
        let hasMalformedToken: Bool

        static func == (lhs: Message, rhs: Message) -> Bool {
            lhs.kind == rhs.kind && lhs.requestID == rhs.requestID &&
            lhs.rssi == rhs.rssi && lhs.location == rhs.location &&
            lhs.uwbToken == rhs.uwbToken && lhs.hasMalformedToken == rhs.hasMalformedToken
        }
    }

    // MARK: - Parsing

    static func parse(_ content: String) -> Message? {
        let kind: Kind
        if content.hasPrefix(pingPrefix) {
            kind = .ping
        } else if content.hasPrefix(pongPrefix) {
            kind = .pong
        } else {
            return nil
        }

        let parts = content.dropFirst(pingPrefix.count).split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 1, !parts[0].isEmpty else { return nil }

        let tokenStr = parts.count > 3 ? String(parts[3]) : ""
        let tokenData = tokenStr.isEmpty ? nil : Data(base64Encoded: tokenStr)

        return Message(
            kind: kind,
            requestID: String(parts[0]),
            rssi: parts.count > 1 ? Int(parts[1]) : nil,
            location: parts.count > 2 ? decodeLocation(String(parts[2])) : nil,
            uwbToken: tokenData,
            hasMalformedToken: !tokenStr.isEmpty && tokenData == nil
        )
    }

    static func decodeLocation(_ str: String) -> Location? {
        guard !str.isEmpty else { return nil }
        let parts = str.split(separator: ",")
        guard parts.count == 5,
              let lat = Double(parts[0]), let lon = Double(parts[1]),
              let alt = Int(parts[2]), let hacc = Int(parts[3]), let vacc = Int(parts[4]) else { return nil }
        return Location(lat: lat, lon: lon, alt: alt, hacc: hacc, vacc: vacc)
    }

    // MARK: - Encoding

    static func encodeLocation(_ location: Location) -> String {
        String(format: "%.6f,%.6f,%d,%d,%d", location.lat, location.lon, location.alt, location.hacc, location.vacc)
    }

    static func encode(kind: Kind, requestID: String, rssi: Int?, locationStr: String, uwbTokenBase64: String? = nil) -> String {
        let prefix = kind == .ping ? pingPrefix : pongPrefix
        let rssiStr = rssi.map(String.init) ?? ""
        let tokenField = uwbTokenBase64.map { ":" + $0 } ?? ""
        return "\(prefix)\(requestID):\(rssiStr):\(locationStr)\(tokenField)"
    }
}
