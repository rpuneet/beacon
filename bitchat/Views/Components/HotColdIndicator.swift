//
// HotColdIndicator.swift
// bitchat
//
// Visual and haptic feedback for hot/cold distance tracking
// Used when direction confidence is too low to show a directional arrow
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Hot/Cold Feedback Manager

/// Provides haptic feedback based on distance changes
/// Uses centralized HapticManager for consistent feedback
final class HotColdFeedbackManager {
    static let shared = HotColdFeedbackManager()

    // Per-peer state storage to prevent reset when view is recreated
    private var peerDistances: [Data: Double] = [:]
    private var lastFeedbackTime: Date = .distantPast
    private let minFeedbackInterval: TimeInterval = 0.3  // Prevent haptic spam

    private init() {}

    /// Update with new distance and trigger appropriate haptic feedback
    /// - Parameters:
    ///   - distance: Current distance in meters
    ///   - peerKey: Optional peer identifier for per-peer state persistence
    /// - Returns: The temperature change direction (if any)
    @discardableResult
    func update(distance: Double, peerKey: Data? = nil) -> TemperatureChange {
        let lastDistance: Double?
        if let key = peerKey {
            lastDistance = peerDistances[key]
            peerDistances[key] = distance
        } else {
            lastDistance = nil
        }

        guard let last = lastDistance else { return .none }

        let delta = distance - last

        // Ignore small changes (noise threshold)
        if abs(delta) < 0.5 { return .none }

        // Rate limit haptic feedback
        let now = Date()
        guard now.timeIntervalSince(lastFeedbackTime) >= minFeedbackInterval else {
            return delta < 0 ? .warmer : .colder
        }
        lastFeedbackTime = now

        // Use centralized HapticManager
        if delta < 0 {
            HapticManager.shared.warmer()
            return .warmer
        } else {
            HapticManager.shared.colder()
            return .colder
        }
    }

    /// Reset tracking for a specific peer
    func reset(peerKey: Data? = nil) {
        if let key = peerKey {
            peerDistances.removeValue(forKey: key)
        } else {
            peerDistances.removeAll()
        }
    }

    /// Reset all tracking
    func resetAll() {
        peerDistances.removeAll()
    }

    enum TemperatureChange {
        case warmer
        case colder
        case none
    }
}

// MARK: - Hot/Cold Indicator View

struct HotColdIndicator: View {
    let currentDistance: Double
    let confidence: Double
    var peerKey: Data? = nil  // For per-peer state persistence
    var hasMovement: Bool = false  // Whether there's been recent movement

    @Environment(\.colorScheme) private var colorScheme
    @State private var temperatureState: HotColdFeedbackManager.TemperatureChange = .none
    @State private var pulseScale: CGFloat = 1.0

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var temperatureColor: Color {
        switch temperatureState {
        case .warmer:
            return .orange
        case .colder:
            return .cyan
        case .none:
            return textColor
        }
    }

    private var temperatureIcon: String {
        switch temperatureState {
        case .warmer:
            return "flame.fill"
        case .colder:
            return "snowflake"
        case .none:
            // Use different icon based on whether we have movement
            return hasMovement ? "figure.walk" : "location.magnifyingglass"
        }
    }

    private var temperatureText: String {
        switch temperatureState {
        case .warmer:
            return "Getting closer"
        case .colder:
            return "Moving away"
        case .none:
            // Improved text based on context
            if hasMovement {
                return "Tracking..."
            } else {
                return "Waiting for location..."
            }
        }
    }

    private var distanceText: String {
        if currentDistance < 10 {
            return String(format: "%.1f m", currentDistance)
        } else if currentDistance < 1000 {
            return String(format: "%.0f m", currentDistance)
        } else {
            return String(format: "%.2f km", currentDistance / 1000)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Pulsing indicator
            ZStack {
                // Outer pulse ring
                Circle()
                    .stroke(temperatureColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 60, height: 60)
                    .scaleEffect(pulseScale)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: pulseScale
                    )

                // Inner circle with icon
                Circle()
                    .fill(temperatureColor.opacity(0.2))
                    .frame(width: 48, height: 48)

                Image(systemName: temperatureIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(temperatureColor)
            }

            // Temperature text
            Text(temperatureText)
                .font(.bitchatSystem(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(temperatureColor)

            // Distance
            Text(distanceText)
                .font(.bitchatSystem(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(textColor)

            // Confidence indicator
            if confidence < 0.8 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text("Low confidence")
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
        .onAppear {
            pulseScale = 1.1
        }
        .onChange(of: currentDistance) { newDistance in
            temperatureState = HotColdFeedbackManager.shared.update(distance: newDistance, peerKey: peerKey)
        }
        .onDisappear {
            HotColdFeedbackManager.shared.reset(peerKey: peerKey)
        }
    }
}
