//
// BeaconDrawer.swift
// bitchat
//
// Side-drawer navigation: map home, channels (#mesh + location channels),
// and beacon privacy — the terminal-minimal command center.
//

import SwiftUI

struct BeaconDrawer: View {
    @ObservedObject var nav: BeaconNavModel
    @ObservedObject private var profile = BeaconProfile.shared
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var showBeaconSettings = false

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var isMeshSelected: Bool {
        if case .mesh = locationChannelsModel.selectedChannel { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileHeader
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    drawerRow(icon: "map", label: "map", isActive: nav.activePanel == .map) {
                        nav.openMap()
                    }

                    sectionTitle("channels")

                    drawerRow(
                        icon: "antenna.radiowaves.left.and.right",
                        label: "#mesh",
                        isActive: nav.activePanel == .chat && isMeshSelected
                    ) {
                        locationChannelsModel.select(.mesh)
                        nav.openChat()
                    }

                    if case .location(let channel) = locationChannelsModel.selectedChannel {
                        drawerRow(
                            icon: "number",
                            label: "#\(channel.geohash)",
                            isActive: nav.activePanel == .chat
                        ) {
                            nav.openChat()
                        }
                    }

                    drawerRow(icon: "globe", label: "location channels…", isActive: false) {
                        nav.openChat()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            appChromeModel.isLocationChannelsSheetPresented = true
                        }
                    }

                    sectionTitle("beacon")

                    drawerRow(icon: "shield", label: "privacy & sharing", isActive: false) {
                        showBeaconSettings = true
                    }
                }
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            Text("beacon · bitchat mesh")
                .font(.bitchatSystem(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background((colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showBeaconSettings) {
            BeaconSettingsView()
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(profile.avatarColor)
                    .frame(width: 44, height: 44)
                Text(profile.avatarEmoji)
                    .font(.system(size: 22))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appChromeModel.nickname)
                    .font(.bitchatSystem(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Text("beacon")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func drawerRow(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(label)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isActive {
                    Circle().fill(textColor).frame(width: 6, height: 6)
                }
            }
            .foregroundColor(isActive ? textColor : .primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(isActive ? textColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
