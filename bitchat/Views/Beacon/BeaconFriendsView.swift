//
// BeaconFriendsView.swift
// bitchat
//
// The friends list = your mutual favorites. Tap one to open their DM.
// "friends" and "mutual favorites" are the same thing: you favorited them
// and they favorited you back — the only people who can see each other.
//

import SwiftUI
import BitFoundation

struct BeaconFriendsView: View {
    @ObservedObject var nav: BeaconNavModel
    @ObservedObject private var favorites = FavoritesPersistenceService.shared
    @ObservedObject private var beaconService = BeaconService.shared
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var mutuals: [FavoritesPersistenceService.FavoriteRelationship] {
        favorites.favorites.values
            .filter { $0.isMutual }
            .sorted { $0.peerNickname.lowercased() < $1.peerNickname.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if mutuals.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(mutuals, id: \.peerNoisePublicKey) { rel in
                            friendRow(rel)
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }
        }
        .background((colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("friends")
                    .font(.bitchatSystem(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                Text("\(mutuals.count) mutual favorite\(mutuals.count == 1 ? "" : "s")")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(Color.primary.opacity(0.6))
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private func friendRow(_ rel: FavoritesPersistenceService.FavoriteRelationship) -> some View {
        let name = rel.peerNickname
        let location = beaconService.peerLocations[PeerID(publicKey: rel.peerNoisePublicKey).id]
        let located = location?.hasLocation == true
        return Button(action: { openDM(with: rel) }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(BeaconProfile.peerColor(nickname: name))
                        .frame(width: 38, height: 38)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.bitchatSystem(size: 15, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(located ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(located ? "on the map" : "no location yet")
                            .font(.bitchatSystem(size: 11, design: .monospaced))
                            .foregroundColor(Color.primary.opacity(0.6))
                    }
                }
                Spacer()
                Image(systemName: "bubble.left")
                    .font(.system(size: 15))
                    .foregroundColor(textColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("no friends yet")
                .font(.bitchatSystem(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
            Text("favorite someone in chat — when they favorite you back, they show up here and on the map")
                .font(.bitchatSystem(size: 12, design: .monospaced))
                .foregroundColor(Color.primary.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func openDM(with rel: FavoritesPersistenceService.FavoriteRelationship) {
        let peerID = PeerID(publicKey: rel.peerNoisePublicKey)
        peerListModel.startConversation(with: peerID)
        dismiss()
        nav.openChat()
    }
}
