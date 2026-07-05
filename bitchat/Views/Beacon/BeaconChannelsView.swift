//
// BeaconChannelsView.swift
// bitchat
//
// The location-channels experience, folded into the Beacon drawer:
// #mesh + nearby geohash channels with live people counts, bookmarks,
// teleport, and the Tor toggle. Replaces the standalone LocationChannelsSheet.
//

import SwiftUI

struct BeaconChannelsView: View {
    @ObservedObject var nav: BeaconNavModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var customGeohash = ""

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }
    private let meshColor = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)

    private var isMeshSelected: Bool {
        if case .mesh = locationChannelsModel.selectedChannel { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch locationChannelsModel.permissionState {
            case .notDetermined:
                meshRow
                enableLocationButton
            case .denied, .restricted:
                meshRow
                deniedNotice
            case .authorized:
                meshRow
                nearbyChannels
                teleportField
                if !locationChannelsModel.bookmarks.isEmpty {
                    sectionTitle("bookmarked")
                    ForEach(locationChannelsModel.bookmarks, id: \.self) { gh in
                        bookmarkRow(gh)
                    }
                }
                torToggle
            @unknown default:
                meshRow
            }
        }
        .onAppear {
            locationChannelsModel.enableAndRefresh()
            locationChannelsModel.beginLiveRefresh()
        }
        .onDisappear { locationChannelsModel.endLiveRefresh() }
    }

    // MARK: - Rows

    private var meshRow: some View {
        channelRow(
            icon: "antenna.radiowaves.left.and.right",
            label: "#mesh",
            sublabel: "bluetooth range",
            count: peerListModel.reachableMeshPeerCount,
            accent: meshColor,
            isSelected: isMeshSelected && nav.activePanel == .chat
        ) {
            locationChannelsModel.select(.mesh)
            nav.openChat()
        }
    }

    private var nearbyChannels: some View {
        let nearby = locationChannelsModel.availableChannels.filter { $0.level != .building }
        return Group {
            if nearby.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("finding nearby channels…")
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            } else {
                ForEach(nearby) { channel in
                    channelRow(
                        icon: "number",
                        label: channel.level.displayName,
                        sublabel: "#\(channel.geohash)",
                        count: peerListModel.participantCount(for: channel.geohash),
                        accent: textColor,
                        isSelected: isSelected(channel) && nav.activePanel == .chat,
                        bookmarked: locationChannelsModel.isBookmarked(channel.geohash),
                        onBookmark: { locationChannelsModel.toggleBookmark(channel.geohash) }
                    ) {
                        locationChannelsModel.markTeleported(for: channel.geohash, false)
                        locationChannelsModel.select(.location(channel))
                        nav.openChat()
                    }
                }
            }
        }
    }

    private func bookmarkRow(_ gh: String) -> some View {
        channelRow(
            icon: "bookmark.fill",
            label: "#\(gh)",
            sublabel: locationChannelsModel.bookmarkNames[gh],
            count: peerListModel.participantCount(for: gh),
            accent: textColor,
            isSelected: false,
            bookmarked: true,
            onBookmark: { locationChannelsModel.toggleBookmark(gh) }
        ) {
            locationChannelsModel.teleport(to: gh)
            nav.openChat()
        }
        .onAppear { locationChannelsModel.resolveBookmarkNameIfNeeded(for: gh) }
    }

    // MARK: - Teleport

    private var teleportField: some View {
        HStack(spacing: 6) {
            Text(verbatim: "#")
                .font(.bitchatSystem(size: 13, design: .monospaced))
                .foregroundColor(.secondary)
            TextField("teleport to geohash", text: $customGeohash)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.asciiCapable)
                #endif
                .font(.bitchatSystem(size: 13, design: .monospaced))
                .onChange(of: customGeohash) { newValue in
                    let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
                    let filtered = newValue.lowercased()
                        .replacingOccurrences(of: "#", with: "")
                        .filter { allowed.contains($0) }
                    customGeohash = String(filtered.prefix(12))
                }
            if isValidGeohash {
                Button(action: {
                    locationChannelsModel.teleport(to: customGeohash)
                    customGeohash = ""
                    nav.openChat()
                }) {
                    Image(systemName: "face.dashed")
                        .font(.system(size: 14))
                        .foregroundColor(textColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var isValidGeohash: Bool {
        let len = customGeohash.count
        return len >= 2 && len <= 12
    }

    // MARK: - Tor + permission

    private var torToggle: some View {
        Button(action: { locationChannelsModel.setUserTorEnabled(!locationChannelsModel.userTorEnabled) }) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("route via tor")
                        .font(.bitchatSystem(size: 13, design: .monospaced))
                    Text("hide your ip from relays")
                        .font(.bitchatSystem(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(locationChannelsModel.userTorEnabled ? "on" : "off")
                    .font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(locationChannelsModel.userTorEnabled ? textColor : .secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        (locationChannelsModel.userTorEnabled ? textColor.opacity(0.18) : Color.secondary.opacity(0.12)),
                        in: Capsule()
                    )
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private var enableLocationButton: some View {
        Button(action: { locationChannelsModel.enableLocationChannels() }) {
            HStack(spacing: 8) {
                Image(systemName: "location")
                    .font(.system(size: 13))
                Text("enable location channels")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(textColor)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var deniedNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("location is off")
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            Button("open settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                #endif
            }
            .font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.blue)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - Building blocks

    private func isSelected(_ channel: GeohashChannel) -> Bool {
        if case .location(let sel) = locationChannelsModel.selectedChannel { return sel.geohash == channel.geohash }
        return false
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func channelRow(
        icon: String,
        label: String,
        sublabel: String?,
        count: Int,
        accent: Color,
        isSelected: Bool,
        bookmarked: Bool? = nil,
        onBookmark: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundColor(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.bitchatSystem(size: 14, weight: count > 0 ? .semibold : .regular, design: .monospaced))
                        .lineLimit(1)
                    if let sublabel {
                        Text(sublabel)
                            .font(.bitchatSystem(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if count > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "person.fill").font(.system(size: 9))
                        Text("\(count)").font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(accent)
                }
                if let bookmarked, let onBookmark {
                    Button(action: onBookmark) {
                        Image(systemName: bookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13))
                            .foregroundColor(bookmarked ? textColor : .secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if isSelected {
                    Circle().fill(accent).frame(width: 6, height: 6)
                }
            }
            .foregroundColor(isSelected ? accent : .primary)
            .padding(.leading, 18)
            .padding(.trailing, onBookmark == nil ? 18 : 8)
            .padding(.vertical, 9)
            .background(isSelected ? accent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
