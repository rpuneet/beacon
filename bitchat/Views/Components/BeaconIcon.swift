//
// BeaconIcon.swift
// bitchat
//
// The beacon glyph: a dot radiating waves, using the native SF Symbol so
// it stays crisp and consistent with the other header symbols.
//

import SwiftUI

struct BeaconIcon: View {
    let size: CGFloat
    /// nil inherits the surrounding tint, like other header symbols
    var color: Color? = nil

    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(color)
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
