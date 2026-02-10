//
// TrackingSourceIndicators.swift
// bitchat
//
// UI component showing active tracking data sources (GPS, UWB, BLE).
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

/// Displays indicators for each tracking source, highlighting which are currently active
/// Only shows GPS and UWB - connection type (BLE/Relay) is shown separately at the top
struct TrackingSourceIndicators: View {
    let activeSources: Set<TrackingSource>
    @Environment(\.colorScheme) private var colorScheme

    // Only show GPS and UWB - BLE/Relay is shown as connection type at top of view
    private var displayableSources: [TrackingSource] {
        [.gps, .uwb]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(displayableSources, id: \.self) { source in
                SourceIndicator(
                    source: source,
                    isActive: activeSources.contains(source)
                )
            }
        }
    }
}

/// Individual indicator for a tracking source (icon only)
struct SourceIndicator: View {
    let source: TrackingSource
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: source.icon)
            .font(.system(size: 14))
            .foregroundColor(isActive ? source.activeColor : .gray.opacity(0.4))
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(isActive ? source.activeColor.opacity(0.15) : Color.clear)
                    .overlay(
                        Circle()
                            .stroke(isActive ? source.activeColor.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                    )
            )
    }
}

/// Compact single-source badge for inline display (icon only)
struct TrackingSourceBadge: View {
    let source: TrackingSource

    var body: some View {
        Image(systemName: source.icon)
            .font(.system(size: 10))
            .foregroundColor(source.activeColor)
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(source.activeColor.opacity(0.15))
            )
    }
}

#Preview {
    VStack(spacing: 20) {
        // All sources inactive
        TrackingSourceIndicators(activeSources: [])

        // GPS only
        TrackingSourceIndicators(activeSources: [.gps])

        // GPS + UWB
        TrackingSourceIndicators(activeSources: [.gps, .uwb])

        // Source badges
        HStack {
            TrackingSourceBadge(source: .gps)
            TrackingSourceBadge(source: .uwb)
        }
    }
    .padding()
    .background(Color.black)
}
