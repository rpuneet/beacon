//
// BeaconSettingsView.swift
// bitchat
//
// Privacy controls for Beacon: global sharing, precision, per-friend
// overrides, and the location sharing audit log.
//

import SwiftUI

struct BeaconSettingsView: View {
    @ObservedObject private var settings = BeaconSettings.shared
    @ObservedObject private var auditLog = BeaconAuditLog.shared
    @ObservedObject private var favoritesService = FavoritesPersistenceService.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sharingSection
                    precisionSection
                    perFriendSection
                    auditSection
                }
                .padding(16)
            }
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 500)
        #endif
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("beacon privacy")
                .font(.bitchatSystem(size: 16, design: .monospaced))
                .foregroundColor(textColor)

            if auditLog.isActivelySharing {
                sharingIndicator
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(textColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sharingIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "location.fill")
                .font(.system(size: 10))
            Text("\(auditLog.activeSharingPeers.count)")
                .font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
    }

    // MARK: - Sharing

    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("sharing")

            card {
            Toggle(isOn: $settings.isSharingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("share my location")
                        .font(.bitchatSystem(size: 13, design: .monospaced))
                    Text("respond to pings with your position")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .tint(.green)

            Toggle(isOn: $settings.requireMutualFavorites) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("mutual favorites only")
                        .font(.bitchatSystem(size: 13, design: .monospaced))
                    Text("they must favorite you back")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .tint(.green)
            .disabled(!settings.isSharingEnabled)
            }
        }
    }

    // MARK: - Precision

    private var precisionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("precision")

            card {
                HStack(spacing: 6) {
                    ForEach(BeaconSettings.PrecisionLevel.allCases) { level in
                        Button(action: { settings.precision = level }) {
                            Text(level.displayName)
                                .font(.bitchatSystem(size: 12, weight: settings.precision == level ? .semibold : .regular, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(
                                    settings.precision == level ? textColor.opacity(0.2) : Color.secondary.opacity(0.08),
                                    in: Capsule()
                                )
                                .overlay(Capsule().stroke(settings.precision == level ? textColor : .clear, lineWidth: 1))
                                .foregroundColor(settings.precision == level ? textColor : .secondary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .disabled(!settings.isSharingEnabled)

                Text(precisionCaption)
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var precisionCaption: String {
        switch settings.precision {
        case .exact: return "friends see your exact position"
        case .approximate: return "position snapped to a ~1 km grid"
        case .city: return "position snapped to a ~5 km grid"
        }
    }

    // MARK: - Per-Friend

    private var favoriteItems: [FavoriteDisplayItem] {
        favoritesService.favorites.compactMap { (key, rel) in
            guard rel.isFavorite else { return nil }
            return FavoriteDisplayItem(noiseKey: key, nickname: rel.peerNickname)
        }
        .sorted { $0.nickname.lowercased() < $1.nickname.lowercased() }
    }

    private var perFriendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("per friend")

            card {
                if favoriteItems.isEmpty {
                    Text("no favorites yet — favorite people in chat to control sharing per friend")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(favoriteItems, id: \.noiseKey) { fav in
                        friendRow(fav)
                    }
                }
            }
        }
    }

    private func friendRow(_ fav: FavoriteDisplayItem) -> some View {
        let override = settings.override(for: fav.noiseKey)

        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { settings.override(for: fav.noiseKey).isAllowed },
                set: { settings.setAllowed($0, for: fav.noiseKey) }
            )) {
                Text(fav.nickname)
                    .font(.bitchatSystem(size: 13, design: .monospaced))
                    .lineLimit(1)
            }
            .tint(.green)

            Menu {
                Button("default (\(settings.precision.displayName))") {
                    settings.setPrecision(nil, for: fav.noiseKey)
                }
                ForEach(BeaconSettings.PrecisionLevel.allCases) { level in
                    Button(level.displayName) {
                        settings.setPrecision(level, for: fav.noiseKey)
                    }
                }
            } label: {
                Text(override.precision?.displayName ?? "default")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(override.precision == nil ? .secondary : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }
            .disabled(!override.isAllowed || !settings.isSharingEnabled)
        }
        .opacity(settings.isSharingEnabled ? 1 : 0.5)
    }

    // MARK: - Audit

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("activity (24h)")
                Spacer()
                if !auditLog.events.isEmpty {
                    Button("clear") {
                        auditLog.clearAll()
                    }
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                }
            }

            card {
                if auditLog.recentEvents.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                        Text("no location activity — nothing has been shared")
                            .font(.bitchatSystem(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(auditLog.recentEvents.prefix(50)) { event in
                        auditRow(event)
                    }
                }
            }
        }
    }

    private func auditRow(_ event: BeaconAuditEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: event.type.systemImage)
                .font(.system(size: 11))
                .foregroundColor(auditColor(event.type))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(event.peerName)
                        .font(.bitchatSystem(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text(event.type.displayName)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let precision = event.precision {
                        Text(precision)
                            .font(.bitchatSystem(size: 10, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
                Text(event.timestamp, style: .relative)
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func auditColor(_ type: BeaconAuditEvent.EventType) -> Color {
        switch type {
        case .locationSent: return .orange
        case .locationReceived: return .green
        case .pingDenied: return .red
        case .trackingStarted, .trackingStopped: return .blue
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.5)
            .foregroundColor(.secondary)
    }

    /// Card container: green is the accent, structure comes from surfaces
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
