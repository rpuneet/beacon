//
// SignalFusion.swift
// bitchat
//
// Priority-based signal fusion for distance/direction estimation
// UWB > GPS (when viable) > BLE proximity tier > Imprecise GPS
//

import Foundation
import CoreLocation
import simd

// MARK: - Distance Estimation

/// Represents a fused distance estimate from tracking sources
struct DistanceEstimate {
    let meters: Double
    let confidence: Double  // 0-1
    let sources: Set<TrackingSource>
    let isProximityTier: Bool  // true if BLE tier (not precise distance)

    init(meters: Double, confidence: Double, sources: Set<TrackingSource>, isProximityTier: Bool = false) {
        self.meters = meters
        self.confidence = confidence
        self.sources = sources
        self.isProximityTier = isProximityTier
    }

    /// Returns a formatted distance string
    var formattedDistance: String {
        if isProximityTier {
            // For BLE proximity tiers, show descriptive text
            return proximityDescription
        }
        if meters < 10 {
            return String(format: "%.1f m", meters)
        } else if meters < 1000 {
            return String(format: "%.0f m", meters)
        } else {
            return String(format: "%.2f km", meters / 1000)
        }
    }

    /// Descriptive proximity for BLE-only estimates
    private var proximityDescription: String {
        switch meters {
        case ..<2: return "< 2m"
        case ..<5: return "~2-5m"
        case ..<10: return "~5-10m"
        case ..<20: return "~10-20m"
        default: return "nearby"
        }
    }

    /// Primary source used for the estimate
    var primarySource: TrackingSource? {
        sources.max(by: { $0.priority < $1.priority })
    }
}

// MARK: - BLE Proximity Tier

/// BLE RSSI-based proximity tiers (not precise distances)
enum BLEProximityTier: Comparable {
    case immediate    // < 2m, RSSI > -55
    case near         // 2-5m, RSSI -55 to -65
    case medium       // 5-10m, RSSI -65 to -75
    case far          // 10-20m, RSSI -75 to -85
    case veryFar      // > 20m, RSSI < -85

    /// Rough distance midpoint for this tier (for UI only, not precise)
    var estimatedMeters: Double {
        switch self {
        case .immediate: return 1.0
        case .near: return 3.5
        case .medium: return 7.5
        case .far: return 15.0
        case .veryFar: return 25.0
        }
    }

    /// Confidence for this proximity tier
    var confidence: Double {
        switch self {
        case .immediate: return 0.5  // Strong signal = more reliable
        case .near: return 0.45
        case .medium: return 0.4
        case .far: return 0.3
        case .veryFar: return 0.2  // Weak signal = least reliable
        }
    }

    /// Create tier from RSSI value
    static func from(rssi: Int) -> BLEProximityTier {
        if rssi > -55 {
            return .immediate
        } else if rssi > -65 {
            return .near
        } else if rssi > -75 {
            return .medium
        } else if rssi > -85 {
            return .far
        } else {
            return .veryFar
        }
    }
}

// MARK: - Direction Estimation

/// Represents a fused direction estimate
struct DirectionEstimate {
    let bearingDegrees: Double?  // nil if unknown
    let confidence: Double       // 0-1
    let source: TrackingSource?

    /// Whether direction is confident enough to show arrow
    var shouldShowArrow: Bool {
        confidence > 0.6 && bearingDegrees != nil
    }

    static let unknown = DirectionEstimate(bearingDegrees: nil, confidence: 0, source: nil)
}

// MARK: - Signal Fusion Engine

/// Priority-based signal fusion for optimal distance/direction estimation
///
/// ## Priority Order (exclusive - first available wins):
/// 1. **UWB** - Centimeter accuracy, use exclusively when available
/// 2. **GPS (viable)** - When distance > 3× combined accuracy, GPS is reliable
/// 3. **BLE Proximity** - When GPS isn't precise enough, use RSSI tiers
/// 4. **GPS (fallback)** - Imprecise GPS as last resort
///
/// ## Key Principles:
/// - Don't mix sources - choose the best one for the situation
/// - UWB is always best at close range
/// - GPS viability depends on distance/accuracy ratio
/// - BLE RSSI is too noisy for precise distance; use tiers instead
struct SignalFusion {

    // MARK: - Distance Fusion (Priority-Based)

    /// Fuse distance sources using priority-based selection (not weighted average)
    ///
    /// - Parameters:
    ///   - uwb: UWB distance in meters (centimeter precision)
    ///   - ble: BLE RSSI value (NOT distance - we'll tier it)
    ///   - gps: GPS distance in meters
    ///   - gpsAccuracy: Combined GPS accuracy (sqrt(myAcc² + theirAcc²))
    /// - Returns: Distance estimate from the best available source
    static func fuseDistance(
        uwb: Double?,
        ble: Double?,
        gps: Double?,
        gpsAccuracy: Double?
    ) -> DistanceEstimate? {
        // Legacy compatibility: if ble is passed as estimated distance, convert back to tier
        // New code should use fuseDistanceWithRSSI instead
        return fuseDistanceWithRSSI(
            uwb: uwb,
            bleRSSI: nil,  // Legacy path - ble was pre-estimated
            bleEstimatedDistance: ble,
            gps: gps,
            gpsAccuracy: gpsAccuracy
        )
    }

    /// Fuse distance sources using priority-based selection
    ///
    /// - Parameters:
    ///   - uwb: UWB distance in meters (centimeter precision)
    ///   - bleRSSI: Raw BLE RSSI value (we'll tier it, not estimate distance)
    ///   - bleEstimatedDistance: Legacy pre-estimated BLE distance (for compatibility)
    ///   - gps: GPS distance in meters
    ///   - gpsAccuracy: Combined GPS accuracy (sqrt(myAcc² + theirAcc²))
    /// - Returns: Distance estimate from the best available source
    static func fuseDistanceWithRSSI(
        uwb: Double?,
        bleRSSI: Int?,
        bleEstimatedDistance: Double? = nil,
        gps: Double?,
        gpsAccuracy: Double?
    ) -> DistanceEstimate? {

        // PRIORITY 1: UWB (exclusive when available)
        // UWB has centimeter accuracy - nothing else comes close
        if let uwbDistance = uwb, uwbDistance > 0 {
            return DistanceEstimate(
                meters: uwbDistance,
                confidence: 0.95,
                sources: [.uwb]
            )
        }

        // PRIORITY 2: GPS (when viable)
        // GPS is "viable" when distance is significantly larger than accuracy
        // Rule: distance > 3 × accuracy means ~5% relative error, which is acceptable
        if let gpsDistance = gps, gpsDistance > 0,
           let accuracy = gpsAccuracy, accuracy > 0 {

            let isGPSViable = gpsDistance > (3.0 * accuracy)

            if isGPSViable {
                // GPS is reliable - use it exclusively
                // Confidence scales with distance/accuracy ratio
                let ratio = gpsDistance / accuracy
                let confidence = min(0.9, 0.5 + (ratio / 20.0))  // 0.5-0.9 range

                return DistanceEstimate(
                    meters: gpsDistance,
                    confidence: confidence,
                    sources: [.gps]
                )
            }
        }

        // PRIORITY 3: BLE Proximity Tier (when GPS not viable)
        // BLE RSSI is too noisy for precise distance estimation
        // Use proximity tiers instead of calculated distance
        if let rssi = bleRSSI {
            let tier = BLEProximityTier.from(rssi: rssi)

            return DistanceEstimate(
                meters: tier.estimatedMeters,
                confidence: tier.confidence,
                sources: [.ble],
                isProximityTier: true
            )
        }

        // Legacy: if we have pre-estimated BLE distance, use it with low confidence
        if let bleDistance = bleEstimatedDistance, bleDistance > 0, bleDistance < 30 {
            // Convert to tier-like confidence (low because RSSI estimation is unreliable)
            let confidence: Double
            switch bleDistance {
            case ..<5: confidence = 0.45
            case ..<15: confidence = 0.35
            default: confidence = 0.25
            }

            return DistanceEstimate(
                meters: bleDistance,
                confidence: confidence,
                sources: [.ble],
                isProximityTier: true
            )
        }

        // PRIORITY 4: Imprecise GPS (fallback)
        // We have GPS but it's not precise enough for the distance
        // Show it anyway with low confidence
        if let gpsDistance = gps, gpsDistance > 0 {
            return DistanceEstimate(
                meters: gpsDistance,
                confidence: 0.3,  // Low confidence for imprecise GPS
                sources: [.gps]
            )
        }

        return nil
    }

    // MARK: - Direction Fusion

    /// Fuse direction from UWB vector and/or GPS bearing
    /// - Parameters:
    ///   - uwbVector: UWB direction vector (device-relative coordinates)
    ///   - gpsBearing: GPS bearing in degrees
    ///   - gpsDistance: GPS distance in meters (direction more accurate at longer range)
    ///   - gpsAccuracy: Combined GPS accuracy
    /// - Returns: Direction estimate with confidence
    static func fuseDirection(
        uwbVector: simd_float3?,
        gpsBearing: Double?,
        gpsDistance: Double?,
        gpsAccuracy: Double? = nil
    ) -> DirectionEstimate {
        // PRIORITY 1: UWB direction (very accurate at close range)
        // UWB direction is a unit vector in device-relative coordinates:
        // +x = right, +y = up, +z = OUT of screen toward user
        // Peer IN FRONT of you (behind phone) has NEGATIVE z
        if let v = uwbVector, v.z < 0 {
            // atan2(x, -z) gives angle from "forward" direction
            let angle = atan2(Double(v.x), Double(-v.z)) * 180 / .pi
            return DirectionEstimate(bearingDegrees: angle, confidence: 0.95, source: .uwb)
        }

        // PRIORITY 2: GPS bearing (only useful when distance >> accuracy)
        // At short distances, GPS accuracy makes bearing unreliable
        if let bearing = gpsBearing,
           let dist = gpsDistance, dist > 0 {

            // Determine minimum distance for reliable bearing
            let accuracy = gpsAccuracy ?? 10.0
            let minDistanceForBearing = max(20.0, 3.0 * accuracy)

            if dist > minDistanceForBearing {
                // Confidence scales with distance relative to accuracy
                let ratio = dist / accuracy
                let confidence = min(0.85, 0.4 + (ratio / 30.0))
                return DirectionEstimate(bearingDegrees: bearing, confidence: confidence, source: .gps)
            }
        }

        // Unknown direction (BLE cannot provide direction)
        return .unknown
    }

    // MARK: - BLE Proximity (Not Distance)

    /// Get BLE proximity tier from RSSI
    /// Use this instead of estimating precise distance from RSSI
    static func bleProximityTier(rssi: Int) -> BLEProximityTier {
        BLEProximityTier.from(rssi: rssi)
    }

    /// Legacy: Estimate distance from BLE RSSI using path loss model
    /// WARNING: This is inherently unreliable. Prefer bleProximityTier() instead.
    ///
    /// Issues with RSSI-to-distance:
    /// - Path loss exponent varies wildly (2.0 free space, 3-4 indoors)
    /// - Body blocking can add 10-20 dB attenuation
    /// - Antenna orientation matters
    /// - Multipath interference causes rapid fluctuations
    ///
    /// - Parameters:
    ///   - rssi: Received signal strength in dBm
    ///   - txPower: Transmit power at 1 meter (default -59 dBm)
    ///   - pathLossExponent: Path loss exponent (2.5 is more realistic than 2.0)
    /// - Returns: Estimated distance in meters, or nil if unreliable
    static func estimateDistanceFromRSSI(
        rssi: Int,
        txPower: Double = -59,
        pathLossExponent: Double = 2.5  // Changed from 2.0 (free space) to 2.5 (more realistic)
    ) -> Double? {
        guard rssi < 0 else { return nil }

        let distance = pow(10, (txPower - Double(rssi)) / (10 * pathLossExponent))

        // Cap at reasonable BLE range
        // RSSI-based distance is unreliable beyond ~15m
        return distance < 30 ? distance : nil
    }

    // MARK: - GPS Distance Calculation

    /// Calculate distance between two coordinates
    static func gpsDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return loc1.distance(from: loc2)
    }

    /// Calculate combined GPS accuracy from two accuracy values
    /// Combined uncertainty = sqrt(accuracy1² + accuracy2²)
    static func combinedGPSAccuracy(myAccuracy: Double, theirAccuracy: Double) -> Double {
        sqrt(myAccuracy * myAccuracy + theirAccuracy * theirAccuracy)
    }

    /// Check if GPS is viable for distance estimation
    /// GPS is viable when distance > 3 × combined accuracy
    static func isGPSViable(distance: Double, combinedAccuracy: Double) -> Bool {
        distance > (3.0 * combinedAccuracy)
    }

    /// Calculate bearing between two coordinates
    static func gpsBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi

        // Normalize to 0-360
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
}
