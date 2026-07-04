//
// BeaconSetupView.swift
// bitchat
//
// First-run identity setup: pick a name, an avatar emoji, and a color.
// The avatar shows on the map at your position; the name is the bitchat
// nickname (single identity across map and chat).
//

import SwiftUI

/// Shows first-run setup as a plain full-screen overlay — no presentation
/// machinery, so it can't collide with the host's sheets/covers or lose the
/// launch-time presentation race. It IS the app until setup completes.
struct BeaconSetupGate: View {
    @ObservedObject private var profile = BeaconProfile.shared

    var body: some View {
        if !profile.hasCompletedSetup {
            BeaconSetupView()
                .transition(.opacity)
        }
    }
}

struct BeaconSetupView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ObservedObject private var profile = BeaconProfile.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var name: String = ""

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Live avatar preview
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(profile.avatarColor)
                        .frame(width: 88, height: 88)
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 88, height: 88)
                    Text(profile.avatarEmoji)
                        .font(.system(size: 44))
                }
                Text(trimmedName.isEmpty ? "anon" : trimmedName)
                    .font(.bitchatSystem(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
            }

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("name")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    TextField("anon", text: $name)
                        .font(.bitchatSystem(size: 16, design: .monospaced))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .padding(12)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("avatar")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                        ForEach(BeaconProfile.emojiChoices, id: \.self) { emoji in
                            Text(emoji)
                                .font(.system(size: 26))
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle().fill(profile.avatarEmoji == emoji ? profile.avatarColor.opacity(0.35) : Color.clear)
                                )
                                .onTapGesture { profile.avatarEmoji = emoji }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("color")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        ForEach(BeaconProfile.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().stroke(Color.white, lineWidth: profile.avatarColorHex == hex ? 3 : 0)
                                )
                                .onTapGesture { profile.avatarColorHex = hex }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)

            Spacer()

            Button(action: finishSetup) {
                Text("start beaconing")
                    .font(.bitchatSystem(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(textColor)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(trimmedName.isEmpty)
            .opacity(trimmedName.isEmpty ? 0.5 : 1)
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea())
        .onAppear {
            name = appChromeModel.nickname
        }
    }

    private func finishSetup() {
        guard !trimmedName.isEmpty else { return }
        appChromeModel.setNickname(trimmedName)
        profile.completeSetup()
    }
}
