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

            // Live avatar preview — shown as a map pin, matching the real product
            VStack(spacing: 10) {
                ZStack {
                    // Mini map plane: the identity promise, not a floating circle
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color(red: 0.08, green: 0.10, blue: 0.14), Color(red: 0.12, green: 0.14, blue: 0.20)]
                                    : [Color(red: 0.90, green: 0.93, blue: 0.90), Color(red: 0.82, green: 0.88, blue: 0.84)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 140)
                        .overlay {
                            // Soft street grid
                            Canvas { context, size in
                                let ink = colorScheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.06)
                                for i in stride(from: 0.0, through: size.width, by: 28) {
                                    var path = Path()
                                    path.move(to: CGPoint(x: i, y: 0))
                                    path.addLine(to: CGPoint(x: i, y: size.height))
                                    context.stroke(path, with: .color(ink), lineWidth: 1)
                                }
                                for i in stride(from: 0.0, through: size.height, by: 28) {
                                    var path = Path()
                                    path.move(to: CGPoint(x: 0, y: i))
                                    path.addLine(to: CGPoint(x: size.width, y: i))
                                    context.stroke(path, with: .color(ink), lineWidth: 1)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(profile.avatarColor)
                                .frame(width: 56, height: 56)
                            Circle()
                                .stroke(Color.white.opacity(0.9), lineWidth: 2.5)
                                .frame(width: 56, height: 56)
                            Text(profile.avatarEmoji)
                                .font(.system(size: 28))
                        }
                        Text(trimmedName.isEmpty ? appChromeModel.nickname : trimmedName)
                            .font(.bitchatSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.65), in: Capsule())
                    }
                    .scaleEffect(previewPop ? 1.08 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: previewPop)
                }
                .padding(.horizontal, 28)

                Text("this is how friends see you on the map")
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(Color.primary.opacity(0.7))
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
        // Product is called Beacon — leave setup already beaconing, with
        // sharing on (fail-closed mutual-favorites still applies).
        BeaconSettings.shared.isSharingEnabled = true
        BeaconService.shared.isBeaconModeEnabled = true
        HapticManager.shared.impact(.medium)
    }
}
