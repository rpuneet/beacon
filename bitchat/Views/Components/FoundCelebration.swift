//
// FoundCelebration.swift
// bitchat
//
// Full-screen celebration overlay shown when a tracked peer is found
// (sustained close proximity). Ported from the original Beacon prototype.
//

import SwiftUI

struct FoundCelebration: View {
    let peerName: String
    let onDismiss: () -> Void

    @State private var ringScale: CGFloat = 0.3
    @State private var ringOpacity: Double = 0.9
    @State private var checkScale: CGFloat = 0.1
    @State private var particlesVisible = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            // Expanding rings
            ForEach(0..<3) { i in
                Circle()
                    .stroke(
                        LinearGradient(colors: [.green, .cyan], startPoint: .top, endPoint: .bottom),
                        lineWidth: 3
                    )
                    .frame(width: 180 + CGFloat(i) * 80, height: 180 + CGFloat(i) * 80)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity * (1.0 - Double(i) * 0.25))
            }

            // Radiating particles
            ForEach(0..<12) { i in
                Circle()
                    .fill(i % 2 == 0 ? Color.green : Color.cyan)
                    .frame(width: 8, height: 8)
                    .offset(y: particlesVisible ? -150 : -60)
                    .opacity(particlesVisible ? 0 : 1)
                    .rotationEffect(.degrees(Double(i) * 30))
            }

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(
                        LinearGradient(colors: [.green, .cyan], startPoint: .top, endPoint: .bottom)
                    )
                    .scaleEffect(checkScale)

                Text("found!")
                    .font(.bitchatSystem(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)

                Text(peerName)
                    .font(.bitchatSystem(size: 18, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            celebrationHaptics()

            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                checkScale = 1.0
            }
            withAnimation(.easeOut(duration: 1.2)) {
                ringScale = 1.3
                ringOpacity = 0
            }
            withAnimation(.easeOut(duration: 1.0)) {
                particlesVisible = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                onDismiss()
            }
        }
    }

    private func celebrationHaptics() {
        HapticManager.shared.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            HapticManager.shared.impact(.medium)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            HapticManager.shared.impact(.light)
        }
    }
}

extension View {
    /// Shows the found celebration overlay when the binding becomes true.
    func foundCelebration(isPresented: Binding<Bool>, peerName: String) -> some View {
        overlay {
            if isPresented.wrappedValue {
                FoundCelebration(peerName: peerName) {
                    isPresented.wrappedValue = false
                }
                .transition(.opacity)
            }
        }
    }
}
