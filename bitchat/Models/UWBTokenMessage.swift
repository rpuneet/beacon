//
// UWBTokenMessage.swift
// bitchat
//
// UWB (Ultra-Wideband) error types for precision tracking.
// This is free and unencumbered software released into the public domain.
//

import Foundation

// MARK: - UWB Error Types

/// Errors that can occur during UWB (Nearby Interaction) tracking
enum UWBError: Error, LocalizedError {
    case notSupported           // Device lacks U1 chip
    case peerNotSupported       // Peer lacks U1 chip
    case tokenExchangeFailed    // Network error during exchange
    case sessionFailed(Error)   // NISession error
    case timeout                // Token exchange timeout
    case outOfRange             // Peer beyond ~15m
    case invalidToken           // Token data is corrupted or invalid

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "UWB not supported on this device"
        case .peerNotSupported:
            return "Peer device does not support UWB"
        case .tokenExchangeFailed:
            return "Failed to exchange UWB tokens"
        case .sessionFailed(let error):
            return "UWB session failed: \(error.localizedDescription)"
        case .timeout:
            return "UWB token exchange timed out"
        case .outOfRange:
            return "Peer is out of UWB range (~15m)"
        case .invalidToken:
            return "Invalid UWB token received"
        }
    }
}
