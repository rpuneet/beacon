//
// PingWaveAnimation.swift
// bitchat
//
// Expanding wave animation for ping button
// Shows 5 concentric circles expanding outward with staggered timing
//

import SwiftUI

struct PingWaveAnimation: View {
    let isAnimating: Bool
    let color: Color

    // 5 waves for 5-second ping
    @State private var waveScales: [CGFloat] = [0.3, 0.3, 0.3, 0.3, 0.3]
    @State private var waveOpacities: [Double] = [0.0, 0.0, 0.0, 0.0, 0.0]

    private let baseSize: CGFloat = 44
    private let maxScale: CGFloat = 3.0
    private let waveDuration: Double = 1.0
    private let waveDelay: Double = 1.0  // 1 second between waves

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: baseSize, height: baseSize)
                    .scaleEffect(waveScales[index])
                    .opacity(waveOpacities[index])
            }
        }
        .onChange(of: isAnimating) { newValue in
            if newValue {
                startAnimation()
            } else {
                resetAnimation()
            }
        }
        .onAppear {
            if isAnimating {
                startAnimation()
            }
        }
    }

    private func startAnimation() {
        // Reset all waves
        for i in 0..<5 {
            waveScales[i] = 0.3
            waveOpacities[i] = 0.0
        }

        // Start each wave with 1-second delay
        for i in 0..<5 {
            let delay = Double(i) * waveDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isAnimating else { return }
                // Fade in
                withAnimation(.easeIn(duration: 0.1)) {
                    waveOpacities[i] = 0.8
                }
                // Expand and fade out
                withAnimation(.easeOut(duration: waveDuration)) {
                    waveScales[i] = maxScale
                }
                withAnimation(.easeOut(duration: waveDuration).delay(0.2)) {
                    waveOpacities[i] = 0
                }
            }
        }
    }

    private func resetAnimation() {
        withAnimation(.easeInOut(duration: 0.2)) {
            for i in 0..<5 {
                waveScales[i] = 0.3
                waveOpacities[i] = 0
            }
        }
    }
}

// MARK: - Ping Button (Simple - just disables during ping)

struct PingButton: View {
    let isPinging: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var buttonColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinging ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isPinging ? buttonColor.opacity(0.5) : buttonColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(buttonColor.opacity(isPinging ? 0.1 : 0.15))
                )
        }
        .buttonStyle(.plain)
        .disabled(isPinging)
        .accessibilityLabel(isPinging ? "Pinging..." : "Send Ping")
    }
}

// MARK: - Map Ping Wave (for user location on map)

struct MapPingWave: View {
    let isAnimating: Bool

    // 8 waves for continuous radar effect
    private let waveCount = 8
    @State private var waveScales: [CGFloat] = Array(repeating: 1.0, count: 8)
    @State private var waveOpacities: [Double] = Array(repeating: 0.0, count: 8)
    @State private var animationTimer: Timer?

    private let maxScale: CGFloat = 15.0  // Much larger for map visibility
    private let waveDuration: Double = 2.5  // Slower, longer waves
    private let waveDelay: Double = 0.6  // Staggered start

    var body: some View {
        ZStack {
            ForEach(0..<waveCount, id: \.self) { index in
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.green, Color.green.opacity(0.3)],
                            startPoint: .center,
                            endPoint: .trailing
                        ),
                        lineWidth: max(1, 4 - CGFloat(index) * 0.3)
                    )
                    .frame(width: 24, height: 24)
                    .scaleEffect(waveScales[index])
                    .opacity(waveOpacities[index])
            }
        }
        .onChange(of: isAnimating) { newValue in
            if newValue {
                startContinuousAnimation()
            } else {
                stopAnimation()
            }
        }
        .onAppear {
            if isAnimating {
                startContinuousAnimation()
            }
        }
        .onDisappear {
            stopAnimation()
        }
    }

    private func startContinuousAnimation() {
        // Reset
        for i in 0..<waveCount {
            waveScales[i] = 1.0
            waveOpacities[i] = 0.0
        }

        // Initial wave burst
        triggerWaveBurst()

        // Repeat every 5 seconds while animating
        animationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            guard isAnimating else { return }
            triggerWaveBurst()
        }
    }

    private func triggerWaveBurst() {
        for i in 0..<waveCount {
            let delay = Double(i) * waveDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isAnimating else { return }

                // Reset this wave
                waveScales[i] = 1.0
                waveOpacities[i] = 0.0

                // Fade in quickly
                withAnimation(.easeIn(duration: 0.15)) {
                    waveOpacities[i] = 0.7
                }

                // Expand smoothly
                withAnimation(.easeOut(duration: waveDuration)) {
                    waveScales[i] = maxScale
                }

                // Fade out as it expands
                withAnimation(.easeOut(duration: waveDuration * 0.8).delay(waveDuration * 0.2)) {
                    waveOpacities[i] = 0
                }
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil

        withAnimation(.easeOut(duration: 0.3)) {
            for i in 0..<waveCount {
                waveScales[i] = 1.0
                waveOpacities[i] = 0
            }
        }
    }
}

// MARK: - RTT Badge

struct RTTBadge: View {
    let rttMs: Int
    let isPinging: Bool  // Keep visible during entire ping

    @State private var isVisible = false
    @State private var flashScale: CGFloat = 1.0

    var body: some View {
        Text("\(rttMs)ms")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.green)
            )
            .scaleEffect(flashScale)
            .opacity(isVisible ? 1.0 : 0.0)
            .onChange(of: rttMs) { _ in
                // Flash on new RTT value
                flashAnimation()
            }
            .onChange(of: isPinging) { newValue in
                if newValue {
                    // Show when ping starts
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isVisible = true
                    }
                } else {
                    // Hide after ping ends (with delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            isVisible = false
                        }
                    }
                }
            }
    }

    private func flashAnimation() {
        // Quick scale up then down for "flash" effect
        withAnimation(.easeOut(duration: 0.1)) {
            flashScale = 1.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                flashScale = 1.0
            }
        }
    }
}

// MARK: - Status Flash Overlay

/// Overlay that flashes green when a ping response is received
struct PingResponseFlash: View {
    let showFlash: Bool

    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .fill(Color.green.opacity(0.3))
            .opacity(opacity)
            .onChange(of: showFlash) { newValue in
                if newValue {
                    // Flash green
                    withAnimation(.easeIn(duration: 0.1)) {
                        opacity = 1.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.4)) {
                            opacity = 0
                        }
                    }
                }
            }
    }
}

#Preview {
    VStack(spacing: 40) {
        // Ping wave animation
        PingWaveAnimation(isAnimating: true, color: .green)
            .frame(width: 150, height: 150)

        // Ping button (idle)
        PingButton(isPinging: false) {
            print("Ping!")
        }

        // Ping button (pinging)
        PingButton(isPinging: true) {
            print("Ping!")
        }

        // RTT Badge
        RTTBadge(rttMs: 245, isPinging: true)
    }
    .padding()
}
