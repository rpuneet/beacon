//
// TrackingSource.swift
// bitchat
//
// Enum representing the source of tracking data (GPS, UWB, BLE).
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

/// Represents the different tracking data sources available
enum TrackingSource: String, CaseIterable, Hashable {
    case gps = "GPS"      // GPS/GNSS location
    case uwb = "UWB"      // Ultra-Wideband (Nearby Interaction)
    case ble = "BLE"      // Bluetooth Low Energy (RSSI-based)
    case relay = "Relay"  // Internet relay (Nostr) - GPS only, no distance

    /// SF Symbol icon name for this tracking source
    var icon: String {
        switch self {
        case .gps: return "location.fill"
        case .uwb: return "wave.3.right"
        case .ble: return "antenna.radiowaves.left.and.right"
        case .relay: return "network"
        }
    }

    /// Color when this source is active
    var activeColor: Color {
        switch self {
        case .gps: return .green
        case .uwb: return .blue
        case .ble: return .orange
        case .relay: return .purple
        }
    }

    /// Typical accuracy of this tracking source
    var typicalAccuracy: String {
        switch self {
        case .gps: return "5-10m"
        case .uwb: return "~10cm"
        case .ble: return "~1-3m"
        case .relay: return "GPS only"
        }
    }

    /// Priority for distance display (higher = preferred)
    var priority: Int {
        switch self {
        case .uwb: return 3  // Best accuracy
        case .ble: return 2  // Good for close range
        case .gps: return 1  // GPS fallback
        case .relay: return 0  // Relay is last resort (no direct distance)
        }
    }
}
