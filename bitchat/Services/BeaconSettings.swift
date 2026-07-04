//
// BeaconSettings.swift
// bitchat
//
// Privacy settings for the Beacon feature: global sharing toggle,
// mutual-favorites enforcement, location precision, and per-friend overrides.
//

import Foundation
import Combine

/// Controls who can receive our location via Beacon and at what precision.
@MainActor
final class BeaconSettings: ObservableObject {
    static let shared = BeaconSettings()

    // MARK: - Precision

    /// How precisely we disclose our location. Coarser levels snap coordinates
    /// to a grid cell center so the exact position is never transmitted.
    enum PrecisionLevel: String, CaseIterable, Codable, Identifiable {
        case exact
        case approximate  // ~1 km grid
        case city         // ~5 km grid

        var id: String { rawValue }

        /// Grid size in degrees (nil = no coarsening)
        var gridDegrees: Double? {
            switch self {
            case .exact: return nil
            case .approximate: return 0.01
            case .city: return 0.05
            }
        }

        /// Reported accuracy floor in meters, matching the grid size
        var accuracyFloorMeters: Double {
            switch self {
            case .exact: return 0
            case .approximate: return 1_100
            case .city: return 5_500
            }
        }

        var displayName: String {
            switch self {
            case .exact: return "exact"
            case .approximate: return "~1 km"
            case .city: return "~5 km"
            }
        }
    }

    /// Per-friend override, keyed by Noise public key
    struct PeerOverride: Codable, Equatable {
        var isAllowed: Bool
        var precision: PrecisionLevel?

        static let `default` = PeerOverride(isAllowed: true, precision: nil)
    }

    // MARK: - Published Settings

    @Published var isSharingEnabled: Bool {
        didSet { defaults.set(isSharingEnabled, forKey: Keys.sharingEnabled) }
    }

    /// When true (default), only mutual favorites receive our location —
    /// matching the privacy promise in the Beacon docs.
    @Published var requireMutualFavorites: Bool {
        didSet { defaults.set(requireMutualFavorites, forKey: Keys.requireMutual) }
    }

    @Published var precision: PrecisionLevel {
        didSet { defaults.set(precision.rawValue, forKey: Keys.precision) }
    }

    @Published private(set) var overrides: [String: PeerOverride] {
        didSet { persistOverrides() }
    }

    // MARK: - Storage

    private enum Keys {
        static let sharingEnabled = "beacon.sharingEnabled"
        static let requireMutual = "beacon.requireMutualFavorites"
        static let precision = "beacon.precision"
        static let overrides = "beacon.peerOverrides"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isSharingEnabled = defaults.object(forKey: Keys.sharingEnabled) as? Bool ?? true
        self.requireMutualFavorites = defaults.object(forKey: Keys.requireMutual) as? Bool ?? true
        if let raw = defaults.string(forKey: Keys.precision), let level = PrecisionLevel(rawValue: raw) {
            self.precision = level
        } else {
            self.precision = .exact
        }
        if let data = defaults.data(forKey: Keys.overrides),
           let decoded = try? JSONDecoder().decode([String: PeerOverride].self, from: data) {
            self.overrides = decoded
        } else {
            self.overrides = [:]
        }
    }

    private func persistOverrides() {
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Keys.overrides)
        }
    }

    // MARK: - Per-Friend API

    func override(for noiseKey: Data) -> PeerOverride {
        overrides[noiseKey.hexEncodedString()] ?? .default
    }

    func setAllowed(_ allowed: Bool, for noiseKey: Data) {
        var entry = override(for: noiseKey)
        entry.isAllowed = allowed
        overrides[noiseKey.hexEncodedString()] = entry
    }

    func setPrecision(_ level: PrecisionLevel?, for noiseKey: Data) {
        var entry = override(for: noiseKey)
        entry.precision = level
        overrides[noiseKey.hexEncodedString()] = entry
    }

    // MARK: - Policy

    /// Whether our location may be disclosed to this peer.
    func canShare(with noiseKey: Data, isFavorite: Bool, isMutual: Bool) -> Bool {
        guard isSharingEnabled else { return false }
        guard isFavorite else { return false }
        if requireMutualFavorites && !isMutual { return false }
        return override(for: noiseKey).isAllowed
    }

    /// Precision to use for this peer (per-friend override wins over global).
    func effectivePrecision(for noiseKey: Data) -> PrecisionLevel {
        override(for: noiseKey).precision ?? precision
    }

    // MARK: - Coarsening

    /// Snap a coordinate to the center of its grid cell for the given precision.
    /// Returns the coordinate unchanged for `.exact`. The reported accuracy is
    /// raised to at least the grid size so receivers render an honest circle.
    static func coarsen(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        to level: PrecisionLevel
    ) -> (latitude: Double, longitude: Double, horizontalAccuracy: Double) {
        guard let grid = level.gridDegrees else {
            return (latitude, longitude, horizontalAccuracy)
        }
        let lat = (floor(latitude / grid) + 0.5) * grid
        let lon = (floor(longitude / grid) + 0.5) * grid
        let acc = max(horizontalAccuracy, level.accuracyFloorMeters)
        return (lat, lon, acc)
    }
}
