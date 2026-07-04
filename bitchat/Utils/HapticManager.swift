//
// HapticManager.swift
// bitchat
//
// Centralized haptic feedback for the beacon feature (no-op on macOS)
//

import Foundation
#if os(iOS)
import UIKit
#endif

final class HapticManager {
    static let shared = HapticManager()

    #if os(iOS)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationFeedback = UINotificationFeedbackGenerator()
    #endif

    private init() {
        #if os(iOS)
        // Prepare generators for low-latency feedback
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notificationFeedback.prepare()
        #endif
    }

    /// Haptic when a peer pings us ("ping → they vibrate")
    func pingStarted() {
        #if os(iOS)
        impactMedium.impactOccurred(intensity: 1.0)
        #endif
    }

    /// Haptic when a ping response is received
    func pingResponseReceived() {
        #if os(iOS)
        impactLight.impactOccurred(intensity: 0.6)
        #endif
    }

    /// Success notification (Found! celebration, arrival)
    func success() {
        #if os(iOS)
        notificationFeedback.notificationOccurred(.success)
        #endif
    }

    enum ImpactStyle {
        case light, medium, heavy
    }

    /// Impact feedback for proximity-level changes
    func impact(_ style: ImpactStyle) {
        #if os(iOS)
        switch style {
        case .light: impactLight.impactOccurred()
        case .medium: impactMedium.impactOccurred()
        case .heavy: impactHeavy.impactOccurred()
        }
        #endif
    }
}
