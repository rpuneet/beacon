//
// BeaconProfile.swift
// bitchat
//
// The local user's beacon identity: avatar emoji + color shown on the map.
// Display name reuses the bitchat nickname (single source of truth).
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class BeaconProfile: ObservableObject {
    static let shared = BeaconProfile()

    /// Curated palette; peers without a shared profile get a stable pick from
    /// the same palette so the map stays coherent.
    static let palette: [String] = [
        "#34C759", // green
        "#32ADE6", // cyan
        "#FF9F0A", // orange
        "#FF375F", // pink
        "#BF5AF2", // purple
        "#FFD60A", // yellow
        "#0A84FF", // blue
        "#FF453A", // red
    ]

    static let emojiChoices: [String] = [
        "🙂", "😎", "🦊", "🐼", "🐸", "🦉", "🐙", "🌵",
        "⚡️", "🔥", "🌊", "🌙", "🎯", "🎧", "🛰️", "👾",
    ]

    @Published var avatarEmoji: String {
        didSet { defaults.set(avatarEmoji, forKey: Keys.emoji) }
    }

    @Published var avatarColorHex: String {
        didSet { defaults.set(avatarColorHex, forKey: Keys.color) }
    }

    @Published private(set) var hasCompletedSetup: Bool

    private enum Keys {
        static let emoji = "beacon.profile.emoji"
        static let color = "beacon.profile.color"
        static let setupDone = "beacon.profile.setupDone"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.avatarEmoji = defaults.string(forKey: Keys.emoji) ?? "🙂"
        self.avatarColorHex = defaults.string(forKey: Keys.color) ?? Self.palette[0]
        self.hasCompletedSetup = defaults.bool(forKey: Keys.setupDone)
    }

    var avatarColor: Color { Color(hex: avatarColorHex) }

    func completeSetup() {
        hasCompletedSetup = true
        defaults.set(true, forKey: Keys.setupDone)
    }

    /// Stable color for a peer, matching the color chat uses for their
    /// nickname so identity reads the same on the map and in conversation.
    static func peerColor(nickname: String, isDark: Bool = true) -> Color {
        Color(peerSeed: nickname.lowercased(), isDark: isDark)
    }
}

// MARK: - Hex Color

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
