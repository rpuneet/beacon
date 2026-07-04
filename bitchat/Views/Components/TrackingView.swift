//
// TrackingView.swift
// bitchat
//
// Full-screen tracking view with centered direction arrow
// Shows direction, distance (UWB/BLE/GPS), and haptic feedback
//

import SwiftUI
import CoreLocation

struct TrackingView: View {
    let peerLocation: PeerLocation
    let peerName: String
    let onDismiss: () -> Void

    @ObservedObject private var locationManager = LocationStateManager.shared
    @State private var proximityLevel: ProximityLevel = .unknown
    @State private var lastHapticLevel: ProximityLevel = .unknown

    // Found! detection: sustained close proximity triggers a celebration
    private static let foundDistanceMeters: Float = 3.0
    private static let foundRSSIThreshold = -40
    private static let foundSustainedSeconds: TimeInterval = 5.0
    @State private var foundZoneEntry: Date?
    @State private var hasTriggeredFound = false
    @State private var showFoundCelebration = false

    enum ProximityLevel: Int, Comparable {
        case unknown = 0
        case far = 1
        case medium = 2
        case near = 3
        case veryNear = 4
        case here = 5

        static func < (lhs: ProximityLevel, rhs: ProximityLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var color: Color {
            switch self {
            case .unknown: return .gray
            case .far: return .blue
            case .medium: return .cyan
            case .near: return .yellow
            case .veryNear: return .orange
            case .here: return .green
            }
        }

        var label: String {
            switch self {
            case .unknown: return "Searching..."
            case .far: return "Far"
            case .medium: return "Getting Closer"
            case .near: return "Near"
            case .veryNear: return "Very Near"
            case .here: return "Here!"
            }
        }
    }

    private var bearing: Double {
        guard let myLoc = locationManager.currentLocation,
              let peerCoord = peerLocation.coordinate else { return 0 }

        let lat1 = myLoc.coordinate.latitude * .pi / 180
        let lat2 = peerCoord.latitude * .pi / 180
        let dLon = (peerCoord.longitude - myLoc.coordinate.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        return atan2(y, x) * 180 / .pi
    }

    /// Arrow rotation adjusted for device heading
    private var arrowRotation: Double {
        let deviceHeading = locationManager.currentHeading ?? 0
        return bearing - deviceHeading
    }

    /// Distance to peer in meters
    private var distanceMeters: Double? {
        // Prefer UWB if available
        if let uwbDist = peerLocation.uwbDistance {
            return Double(uwbDist)
        }

        // Fall back to GPS
        guard let myLoc = locationManager.currentLocation,
              let peerCoord = peerLocation.coordinate else { return nil }

        let peerLoc = CLLocation(latitude: peerCoord.latitude, longitude: peerCoord.longitude)
        return myLoc.distance(from: peerLoc)
    }

    /// GPS accuracy - if we're within this, we should use BLE/UWB instead
    private var gpsAccuracy: Double {
        locationManager.currentLocation?.horizontalAccuracy ?? 100
    }

    /// Whether we're close enough that GPS isn't reliable
    private var useProximityMode: Bool {
        guard let dist = distanceMeters else { return true }
        return dist < max(gpsAccuracy, 50)  // Within 50m or GPS accuracy
    }

    /// Distance display string
    private var distanceText: String {
        if let uwbDist = peerLocation.uwbDistance {
            if uwbDist < 1 {
                return String(format: "%.0f cm", uwbDist * 100)
            } else {
                return String(format: "%.1f m", uwbDist)
            }
        }

        if useProximityMode {
            return proximityLevel.label
        }

        guard let dist = distanceMeters else { return "—" }
        if dist < 1000 {
            return String(format: "%.0f m", dist)
        } else {
            return String(format: "%.1f km", dist / 1000)
        }
    }

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.gray)
                    }

                    Spacer()

                    Text("Tracking \(peerName)")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // Placeholder for symmetry
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding()

                Spacer()

                // Main tracking area
                if useProximityMode {
                    // Proximity circle mode (BLE/UWB)
                    proximityCircleView
                } else {
                    // Direction arrow mode (GPS)
                    directionArrowView
                }

                Spacer()

                // Distance info
                VStack(spacing: 8) {
                    Text(distanceText)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(proximityLevel.color)

                    if peerLocation.uwbDistance != nil {
                        Label("UWB Precision", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if useProximityMode {
                        Label("Bluetooth Signal", systemImage: "dot.radiowaves.right")
                            .font(.caption)
                            .foregroundColor(.blue)
                    } else {
                        Label("GPS Estimate", systemImage: "location.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if let rssi = peerLocation.peerRSSI {
                        Text("Signal: \(rssi) dBm")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            locationManager.startHeadingUpdates()
            updateProximityLevel()
        }
        .onDisappear {
            locationManager.stopHeadingUpdates()
        }
        .onChange(of: peerLocation.peerRSSI) { _ in
            updateProximityLevel()
        }
        .onChange(of: peerLocation.uwbDistance) { _ in
            updateProximityLevel()
        }
        .foundCelebration(isPresented: $showFoundCelebration, peerName: peerName)
    }

    // MARK: - Direction Arrow View

    private var directionArrowView: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                .frame(width: 250, height: 250)

            // Cardinal directions
            ForEach(["N", "E", "S", "W"], id: \.self) { dir in
                Text(dir)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .offset(y: -135)
                    .rotationEffect(.degrees(cardinalOffset(dir)))
            }
            .rotationEffect(.degrees(-(locationManager.currentHeading ?? 0)))

            // Direction arrow
            Image(systemName: "location.north.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
                .rotationEffect(.degrees(arrowRotation))
                .animation(.easeInOut(duration: 0.3), value: arrowRotation)
        }
    }

    // MARK: - Proximity Circle View

    private var proximityCircleView: some View {
        ZStack {
            // Pulsing circles
            ForEach(0..<3) { i in
                Circle()
                    .stroke(proximityLevel.color.opacity(0.3 - Double(i) * 0.1), lineWidth: 3)
                    .frame(width: CGFloat(150 + i * 50), height: CGFloat(150 + i * 50))
                    .scaleEffect(proximityLevel >= .near ? 1.1 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.0)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.2),
                        value: proximityLevel
                    )
            }

            // Center circle with icon
            Circle()
                .fill(proximityLevel.color.opacity(0.2))
                .frame(width: 120, height: 120)

            Circle()
                .stroke(proximityLevel.color, lineWidth: 4)
                .frame(width: 120, height: 120)

            if peerLocation.uwbDistance != nil {
                // UWB - show precise direction if available
                if let dir = peerLocation.uwbDirection {
                    let angle = atan2(dir.x, dir.z) * 180 / .pi
                    Image(systemName: "arrow.up")
                        .font(.system(size: 50, weight: .bold))
                        .foregroundColor(proximityLevel.color)
                        .rotationEffect(.degrees(Double(angle)))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(proximityLevel.color)
                }
            } else {
                // BLE - show signal icon
                Image(systemName: signalIcon)
                    .font(.system(size: 50))
                    .foregroundColor(proximityLevel.color)
            }
        }
    }

    private var signalIcon: String {
        switch proximityLevel {
        case .unknown: return "questionmark.circle"
        case .far: return "wifi.exclamationmark"
        case .medium: return "wifi"
        case .near, .veryNear: return "dot.radiowaves.up.forward"
        case .here: return "person.crop.circle.fill.badge.checkmark"
        }
    }

    private func cardinalOffset(_ dir: String) -> Double {
        switch dir {
        case "N": return 0
        case "E": return 90
        case "S": return 180
        case "W": return 270
        default: return 0
        }
    }

    // MARK: - Proximity Calculation

    private func updateProximityLevel() {
        let newLevel: ProximityLevel

        // UWB is most accurate
        if let uwbDist = peerLocation.uwbDistance {
            if uwbDist < 0.5 { newLevel = .here }
            else if uwbDist < 2 { newLevel = .veryNear }
            else if uwbDist < 5 { newLevel = .near }
            else if uwbDist < 15 { newLevel = .medium }
            else { newLevel = .far }
        }
        // Fall back to RSSI
        else if let rssi = peerLocation.peerRSSI {
            // RSSI: -30 = very close, -90 = far
            if rssi > -40 { newLevel = .here }
            else if rssi > -55 { newLevel = .veryNear }
            else if rssi > -65 { newLevel = .near }
            else if rssi > -75 { newLevel = .medium }
            else { newLevel = .far }
        }
        else {
            newLevel = .unknown
        }

        proximityLevel = newLevel

        // Haptic feedback when level changes
        if newLevel != lastHapticLevel && newLevel != .unknown {
            triggerHaptic(for: newLevel)
            lastHapticLevel = newLevel
        }

        checkFoundCondition()
    }

    /// Trigger the celebration after the peer stays within the found zone
    /// (UWB < 3 m, or very strong RSSI) for a sustained period.
    private func checkFoundCondition() {
        let inZone: Bool
        if let uwbDist = peerLocation.uwbDistance {
            inZone = uwbDist < Self.foundDistanceMeters
        } else if let rssi = peerLocation.peerRSSI {
            inZone = rssi > Self.foundRSSIThreshold
        } else {
            inZone = false
        }

        guard inZone else {
            foundZoneEntry = nil
            return
        }

        let entry = foundZoneEntry ?? Date()
        foundZoneEntry = entry

        if !hasTriggeredFound && Date().timeIntervalSince(entry) >= Self.foundSustainedSeconds {
            hasTriggeredFound = true
            withAnimation(.easeIn(duration: 0.3)) {
                showFoundCelebration = true
            }
        }
    }

    private func triggerHaptic(for level: ProximityLevel) {
        #if os(iOS)
        switch level {
        case .here:
            HapticManager.shared.success()
        case .veryNear:
            HapticManager.shared.impact(.heavy)
        case .near:
            HapticManager.shared.impact(.medium)
        case .medium:
            HapticManager.shared.impact(.light)
        case .far, .unknown:
            break
        }
        #endif
    }
}
