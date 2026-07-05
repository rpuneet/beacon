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
    @ObservedObject private var beaconService = BeaconService.shared
    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var drawerDrag: CGFloat = 0

    private static let drawerWidth: CGFloat = 280

    var body: some View {
        ZStack(alignment: .leading) {
            // Content layer: map home or the wrapped bitchat chat UI.
            // Both stay alive so chat state (scroll, composer) survives
            // trips to the map.
            ZStack {
                ContentView()
                    .environment(\.beaconShell, BeaconShellBridge(
                        openDrawer: { nav.isDrawerOpen = true },
                        openMap: { nav.openMap() }
                    ))
                    .opacity(nav.activePanel == .chat ? 1 : 0)
                    .allowsHitTesting(nav.activePanel == .chat)

                if nav.activePanel == .map {
                    BeaconView(
                        isRootMode: true,
                        onMenuTap: { nav.toggleDrawer() },
                        onOpenChat: { nav.openChat() }
                    )
                    .background(colorScheme == .dark ? Color.black : Color.white)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if nav.activePanel == .chat {
                    backToMapButton
                        .padding(.trailing, 14)
                        .padding(.bottom, 88)
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
                .shadow(color: .black.opacity(nav.isDrawerOpen ? 0.5 : 0), radius: 20, x: 4, y: 0)
                .offset(x: (nav.isDrawerOpen ? 0 : -Self.drawerWidth - 20) + min(0, drawerDrag))
                .animation(.spring(response: 0.3, dampingFraction: 0.88), value: drawerDrag)
        }
        // Best-effort edge swipe: over the map, MKMapView's own pan recognizer
        // may win the touch — the hamburger stays the primary affordance.
        // Closing by drag always works (the drawer/scrim cover the map).
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .updating($drawerDrag) { value, state, _ in
                    if nav.isDrawerOpen && value.translation.width < 0 {
                        state = value.translation.width
                    }
                }
                .onEnded { value in
                    if nav.isDrawerOpen && value.translation.width < -60 {
                        nav.isDrawerOpen = false
                    } else if !nav.isDrawerOpen && value.startLocation.x < 30 && value.translation.width > 60 {
                        nav.isDrawerOpen = true
                    }
                }
        )
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

    /// Floating return-to-map pill while in the chat panel: labeled, legible
    /// on black, with a live count of locatable friends.
    private var backToMapButton: some View {
        Button(action: { nav.openMap() }) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("map")
                    .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                if beaconService.peersWithLocationCount > 0 {
                    Text("\(beaconService.peersWithLocationCount)")
                        .font(.bitchatSystem(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.green, in: Capsule())
                }
            }
            .foregroundColor(.green)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.green.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(Color.green.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(localized: "content.accessibility.beacon", comment: "Accessibility label for beacon button")
        )
    }
}
