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
    @State private var previewPop = false

    private var textColor: Color {
        colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)

            // The product promise, said once, right here
            VStack(spacing: 6) {
                Text("beacon")
                    .font(.bitchatSystem(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                Text("find your people. no internet needed.")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Live avatar preview
            VStack(spacing: 10) {
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
                .scaleEffect(previewPop ? 1.08 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: previewPop)
                Text(trimmedName.isEmpty ? appChromeModel.nickname : trimmedName)
                    .font(.bitchatSystem(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                Text("this is how friends see you on the map")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("name")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    TextField(appChromeModel.nickname, text: $name)
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 6) {
                        ForEach(BeaconProfile.emojiChoices, id: \.self) { emoji in
                            Text(emoji)
                                .font(.system(size: 26))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle()
                                        .stroke(profile.avatarEmoji == emoji ? profile.avatarColor : .clear, lineWidth: 2.5)
                                        .padding(1)
                                )
                                .contentShape(Circle())
                                .onTapGesture { pick { profile.avatarEmoji = emoji } }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("color")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(BeaconProfile.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle()
                                        .stroke(profile.avatarColorHex == hex ? profile.avatarColor : .clear, lineWidth: 2.5)
                                        .padding(-4)
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                                .onTapGesture { pick { profile.avatarColorHex = hex } }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)

            Button(action: finishSetup) {
                Text(trimmedName.isEmpty ? "start as \(appChromeModel.nickname)" : "start beaconing")
                    .font(.bitchatSystem(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(textColor)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((colorScheme == .dark ? Color.black : Color.white).ignoresSafeArea())

    }

    /// Selection feels physical: preview pops, light haptic
    private func pick(_ change: () -> Void) {
        change()
        previewPop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { previewPop = false }
        HapticManager.shared.impact(.light)
    }

    private func finishSetup() {
        if !trimmedName.isEmpty {
            appChromeModel.setNickname(trimmedName)
        }
        profile.completeSetup()
    }
}
