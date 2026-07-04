//
// BeaconIcon.swift
// bitchat
//
// Typographic beacon glyph: a dot broadcasting, ((•)), in the app's
// monospace voice. Minimal, scales with text, no custom drawing.
//

import SwiftUI

struct BeaconIcon: View {
    let size: CGFloat
    var color: Color = .green

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "((")
                .foregroundColor(color.opacity(0.55))
            Text(verbatim: "•")
                .foregroundColor(color)
            Text(verbatim: "))")
                .foregroundColor(color.opacity(0.55))
        }
        .font(.bitchatSystem(size: size, weight: .semibold, design: .monospaced))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 20) {
        BeaconIcon(size: 14)
        BeaconIcon(size: 20)
        BeaconIcon(size: 32, color: .cyan)
        BeaconIcon(size: 48, color: .orange)
    }
    .padding(30)
    .background(Color.black)
}
