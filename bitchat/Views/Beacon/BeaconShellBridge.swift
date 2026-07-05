//
// BeaconShellBridge.swift
// bitchat
//
// Lets the wrapped bitchat chat UI become part of the Beacon shell without
// forking upstream views. When present in the environment, the chat header
// reroutes its channel control to the Beacon drawer and drops the now-
// redundant beacon-sheet button — the header smoothly becomes Beacon's own.
//

import SwiftUI

struct BeaconShellBridge {
    /// Open the Beacon side drawer (which now hosts the channel switcher).
    let openDrawer: () -> Void
    /// Return to the map home.
    let openMap: () -> Void
}

private struct BeaconShellBridgeKey: EnvironmentKey {
    static let defaultValue: BeaconShellBridge? = nil
}

extension EnvironmentValues {
    /// Non-nil only while the chat UI is embedded inside the Beacon shell.
    var beaconShell: BeaconShellBridge? {
        get { self[BeaconShellBridgeKey.self] }
        set { self[BeaconShellBridgeKey.self] = newValue }
    }
}
