//
// HapticManager.swift
// bitchat
//
// Centralized haptic feedback manager for consistent tactile UX
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// Centralized manager for haptic feedback throughout the app
final class HapticManager {
    static let shared = HapticManager()

    #if os(iOS)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationFeedback = UINotificationFeedbackGenerator()
    private let selectionFeedback = UISelectionFeedbackGenerator()
    #endif

    private init() {
        #if os(iOS)
        // Prepare generators for low-latency feedback
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notificationFeedback.prepare()
        selectionFeedback.prepare()
        #endif
    }

    // MARK: - Ping Haptics

    /// Haptic feedback when ping is initiated
    func pingStarted() {
        #if os(iOS)
        impactMedium.impactOccurred(intensity: 1.0)
        #endif
    }

    /// Haptic feedback when a ping response is received
    func pingResponseReceived() {
        #if os(iOS)
        impactLight.impactOccurred(intensity: 0.6)
        #endif
    }

    /// Haptic feedback when ping completes
    /// - Parameter responseCount: Number of peers that responded
    func pingCompleted(responseCount: Int) {
        #if os(iOS)
        if responseCount > 0 {
            notificationFeedback.notificationOccurred(.success)
        } else {
            notificationFeedback.notificationOccurred(.warning)
        }
        #endif
    }

    // MARK: - Hot/Cold Haptics

    /// Haptic feedback when getting closer to peer (warmer)
    func warmer() {
        #if os(iOS)
        impactMedium.impactOccurred(intensity: 0.8)
        #endif
    }

    /// Haptic feedback when getting farther from peer (colder)
    func colder() {
        #if os(iOS)
        // Double-pulse for "cold" feedback
        impactLight.impactOccurred(intensity: 0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.impactLight.impactOccurred(intensity: 0.4)
        }
        #endif
    }

    // MARK: - General Haptics

    /// Light impact for general UI interactions
    func lightImpact() {
        #if os(iOS)
        impactLight.impactOccurred()
        #endif
    }

    /// Medium impact for more significant interactions
    func mediumImpact() {
        #if os(iOS)
        impactMedium.impactOccurred()
        #endif
    }

    /// Heavy impact for major actions
    func heavyImpact() {
        #if os(iOS)
        impactHeavy.impactOccurred()
        #endif
    }

    /// Selection feedback for picker/toggle changes
    func selection() {
        #if os(iOS)
        selectionFeedback.selectionChanged()
        #endif
    }

    /// Success notification
    func success() {
        #if os(iOS)
        notificationFeedback.notificationOccurred(.success)
        #endif
    }

    /// Warning notification
    func warning() {
        #if os(iOS)
        notificationFeedback.notificationOccurred(.warning)
        #endif
    }

    /// Error notification
    func error() {
        #if os(iOS)
        notificationFeedback.notificationOccurred(.error)
        #endif
    }
}
