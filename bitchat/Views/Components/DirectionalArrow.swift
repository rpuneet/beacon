//
// DirectionalArrow.swift
// bitchat
//
// Compass-aware directional arrow that points toward a target location
//

import SwiftUI
import CoreLocation
import simd

struct DirectionalArrow: View {
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    let deviceHeading: Double  // Current compass heading (0 = North)

    // Optional UWB data (takes priority when available)
    var uwbDistance: Float? = nil
    var uwbDirection: simd_float3? = nil

    // Direction confidence from SignalFusion (0-1)
    var directionConfidence: Double = 1.0

    @Environment(\.colorScheme) private var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    // Color for UWB indicator
    private var uwbColor: Color {
        Color.blue
    }

    // Whether we're using UWB data
    private var isUsingUWB: Bool {
        uwbDistance != nil
    }

    // Check if peer is behind user (UWB z > 0 means peer is in front of phone screen, i.e., behind user)
    private var isPeerBehind: Bool {
        guard let uwbDir = uwbDirection else { return false }
        // z > 0.5 means peer is significantly behind user (in front of phone screen)
        return uwbDir.z > 0.5
    }

    // Computed arrow rotation based on UWB direction or GPS bearing
    private var arrowRotation: Double {
        if let uwbDir = uwbDirection {
            // Use UWB direction
            // UWB direction is a unit vector in device-relative coordinates:
            // +x = right, +y = up, +z = OUT of screen toward user
            // So peer IN FRONT of you (behind phone) has NEGATIVE z
            // We want: peer in front = 0°, peer right = 90°, peer behind = 180°
            // atan2(x, -z) gives correct angle from "forward" (behind phone)
            return atan2(Double(uwbDir.x), Double(-uwbDir.z)).radiansToDegrees
        } else {
            // Fall back to GPS bearing
            let bearing = calculateBearing(from: from, to: to)
            return bearing - deviceHeading
        }
    }

    // Computed distance text based on UWB or GPS
    private var distanceText: String {
        if let uwbDist = uwbDistance {
            return formatUWBDistance(uwbDist)
        } else {
            return formatGPSDistance(from: from, to: to)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Show "Behind you" indicator when peer is behind
            if isPeerBehind {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.turn.up.backward")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(uwbColor)

                    Text("Behind you")
                        .font(.bitchatSystem(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(uwbColor)
                }
            } else {
                // Arrow with confidence-based opacity
                Image(systemName: "location.north.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(isUsingUWB ? uwbColor : textColor)
                    .opacity(min(1.0, 0.4 + directionConfidence * 0.6))
                    .rotationEffect(.degrees(arrowRotation))
                    .animation(.easeInOut(duration: 0.2), value: arrowRotation)
            }

            HStack(spacing: 6) {
                Text(distanceText)
                    .font(.bitchatSystem(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(isUsingUWB ? uwbColor : textColor)

                if isUsingUWB {
                    // UWB indicator icon
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .font(.system(size: 14))
                        .foregroundColor(uwbColor)
                }
            }

            // Confidence indicator for lower confidence directions
            if directionConfidence < 0.8 && !isUsingUWB && !isPeerBehind {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(String(format: "%.0f%% confident", directionConfidence * 100))
                        .font(.bitchatSystem(size: 10, design: .monospaced))
                }
                .foregroundColor(textColor.opacity(0.5))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
    }

    /// Calculate bearing from one coordinate to another using spherical geometry
    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude.degreesToRadians
        let lat2 = to.latitude.degreesToRadians
        let dLon = (to.longitude - from.longitude).degreesToRadians

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x).radiansToDegrees

        // Normalize to 0-360
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Format UWB distance (higher precision for close range)
    private func formatUWBDistance(_ distance: Float) -> String {
        if distance < 1 {
            return String(format: "%.2f m", distance)
        } else if distance < 10 {
            return String(format: "%.1f m", distance)
        } else {
            return String(format: "%.0f m", distance)
        }
    }

    /// Format GPS distance between two coordinates
    private func formatGPSDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> String {
        let loc1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let loc2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let distance = loc1.distance(from: loc2)

        if distance < 10 {
            return String(format: "%.1f m", distance)
        } else if distance < 1000 {
            return String(format: "%.0f m", distance)
        } else {
            return String(format: "%.2f km", distance / 1000)
        }
    }
}

// MARK: - Angle Conversion Extensions

extension Double {
    var degreesToRadians: Double { self * .pi / 180 }
    var radiansToDegrees: Double { self * 180 / .pi }
}
