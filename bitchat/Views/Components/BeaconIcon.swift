//
// BeaconIcon.swift
// bitchat
//
// Custom beacon icon - "B" with radar waves
//

import SwiftUI

struct BeaconIcon: View {
    let size: CGFloat
    var color: Color = .cyan

    var body: some View {
        ZStack {
            // Radar waves (3 arcs)
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .trim(from: 0.6, to: 0.9)
                    .stroke(color.opacity(0.3 + Double(i) * 0.2), lineWidth: 1)
                    .frame(width: size * (0.7 + CGFloat(i) * 0.3), height: size * (0.7 + CGFloat(i) * 0.3))
                    .rotationEffect(.degrees(-45))
            }

            // "B" letter
            Text("B")
                .font(.system(size: size * 0.6, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

#Preview {
    VStack(spacing: 20) {
        BeaconIcon(size: 14)
        BeaconIcon(size: 24, color: .green)
        BeaconIcon(size: 40, color: .orange)
    }
    .padding()
    .background(Color.black)
}
