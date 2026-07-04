//
// BeaconAppRoot.swift
// bitchat
//
// Map-first shell: the map is home, the full bitchat chat UI is one drawer
// selection away. ContentView embeds unmodified so upstream merges stay cheap.
//

import SwiftUI

@MainActor
final class BeaconNavModel: ObservableObject {
    enum ActivePanel: Equatable {
        case map
        case chat
    }

    @Published var activePanel: ActivePanel = .map
    @Published var isDrawerOpen = false

    func openMap() {
        activePanel = .map
        isDrawerOpen = false
    }

    func openChat() {
        activePanel = .chat
        isDrawerOpen = false
    }

    func toggleDrawer() {
        isDrawerOpen.toggle()
    }
}

struct BeaconAppRoot: View {
    @StateObject private var nav = BeaconNavModel()
    @Environment(\.colorScheme) private var colorScheme

    private static let drawerWidth: CGFloat = 280

    var body: some View {
        ZStack(alignment: .leading) {
            // Content layer: map home or the wrapped bitchat chat UI.
            // Both stay alive so chat state (scroll, composer) survives
            // trips to the map.
            ZStack {
                ContentView()
                    .opacity(nav.activePanel == .chat ? 1 : 0)
                    .allowsHitTesting(nav.activePanel == .chat)

                if nav.activePanel == .map {
                    BeaconView(isRootMode: true, onMenuTap: { nav.toggleDrawer() })
                        .background(colorScheme == .dark ? Color.black : Color.white)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if nav.activePanel == .chat {
                    backToMapButton
                }
            }

            // Drawer scrim
            if nav.isDrawerOpen {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { nav.isDrawerOpen = false }
                    .transition(.opacity)
            }

            // Drawer
            BeaconDrawer(nav: nav)
                .frame(width: Self.drawerWidth)
                .frame(maxHeight: .infinity)
                .offset(x: nav.isDrawerOpen ? 0 : -Self.drawerWidth - 20)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: nav.isDrawerOpen)
        .animation(.easeInOut(duration: 0.2), value: nav.activePanel)
        .overlay { BeaconSetupGate() }
        .onAppear {
            #if DEBUG
            // Screenshot automation
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-beacon.openDrawer") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { nav.isDrawerOpen = true }
            }
            if args.contains("-beacon.openChat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { nav.openChat() }
            }
            #endif
        }
    }

    /// Floating return-to-map control while in the chat panel
    private var backToMapButton: some View {
        Button(action: { nav.openMap() }) {
            BeaconIcon(size: 18, color: .green)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.green.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .padding(.bottom, 88)
        .accessibilityLabel(
            String(localized: "content.accessibility.beacon", comment: "Accessibility label for beacon button")
        )
    }
}
