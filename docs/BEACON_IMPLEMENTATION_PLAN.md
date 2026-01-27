# Beacon Implementation Plan

> Step-by-step guide to implement the Beacon feature on `app/beacon-v2`

---

## Source Reference

The old `app/beacon` branch has existing code that can be reused. This plan indicates:
- **COPY** = Take directly from old branch (no changes needed)
- **ADAPT** = Copy from old branch but modify for new architecture
- **CREATE** = Write from scratch (doesn't exist or not reusable)
- **CHERRY-PICK** = Take specific changes from old branch

---

## Phase 1: Core Models & Services

### 1.1 `PeerLocation.swift` — ADAPT
**Path:** `bitchat/Models/PeerLocation.swift`
**Source:** `app/beacon:bitchat/Models/PeerLocation.swift`

**What exists:** Full model with GPS, UWB, RSSI, transport type, timestamps.

**Changes needed:**
- Remove dependency on `TrackResponse` and `LocationAnnounce` (from deleted TrackingMessage.swift)
- Add `PongResponseData` struct for JSON parsing
- Update factory initializer to work with new JSON-based pong data

```swift
// ADD: JSON structure for [PONG] payload
struct PongResponseData: Codable {
    struct GPS: Codable {
        let enabled: Bool
        let lat: Double?
        let lon: Double?
        let alt: Double?
        let acc: Double?
    }
    struct UWB: Codable {
        let supported: Bool
        let token: String?  // base64
    }
    struct BLE: Codable {
        let rssi: Int?
    }
    let gps: GPS
    let uwb: UWB
    let ble: BLE
    let ts: Int64
}

// KEEP: Most of PeerLocation struct
// MODIFY: Factory initializer to use PongResponseData instead of TrackResponse
```

---

### 1.2 `BeaconService.swift` — ADAPT
**Path:** `bitchat/Services/BeaconService.swift`
**Source:** `app/beacon:bitchat/Services/TrackingService.swift` (rename + significant changes)

**What exists:** TrackingService with ping logic, peer location cache, UWB integration.

**Changes needed:**
- Rename class to `BeaconService`
- Remove `Transport.sendTrackRequest()` calls — use `sendPrivateMessage("[PING]:...")` instead
- Remove `Transport.sendLocationAnnounce()` calls
- Add `handlePrivateMessage()` to parse `[PING]` and `[PONG]` prefixes
- Add `buildPongResponse()` to create JSON payload
- Remove persistence (keep it simple for v1)
- Remove location announcement timer (not needed for on-demand pings)

```swift
// REMOVE: These patterns from TrackingService
bleService?.sendTrackRequest(to: peerID) { ... }  // OLD
nostrTransport?.sendTrackRequest(to: peerID, noisePublicKey: key) { ... }  // OLD

// REPLACE WITH:
bleService?.sendPrivateMessage("[PING]:\(requestID)", to: peerID, ...)  // NEW
nostrTransport?.sendPrivateMessage("[PING]:\(requestID)", to: peerID, ...)  // NEW
```

---

### 1.3 `UWBTrackingManager.swift` — COPY (minor cleanup)
**Path:** `bitchat/Services/UWBTrackingManager.swift`
**Source:** `app/beacon:bitchat/Services/UWBTrackingManager.swift`

**What exists:** Full UWB implementation with NISession management, token generation, ranging.

**Changes needed:**
- Minor: Remove any references to deleted types (TrackingMessage, etc.) if present
- Otherwise copy as-is — this is well-implemented

---

### 1.4 `HapticManager.swift` — COPY
**Path:** `bitchat/Utils/HapticManager.swift`
**Source:** `app/beacon:bitchat/Utils/HapticManager.swift`

**What exists:** Complete haptic feedback manager with ping-specific methods.

**Changes needed:** None — copy as-is.

---

## Phase 2: View Layer

### 2.1 `BeaconViewModel.swift` — ADAPT
**Path:** `bitchat/ViewModels/BeaconViewModel.swift`
**Source:** `app/beacon:bitchat/ViewModels/TrackingViewModel.swift` (rename + simplify)

**What exists:** TrackingViewModel with map region, selection state, ping triggers.

**Changes needed:**
- Rename class to `BeaconViewModel`
- Change `trackingService` reference to `beaconService`
- Remove any references to deleted types
- Simplify if needed

---

### 2.2 `BeaconView.swift` — ADAPT
**Path:** `bitchat/Views/BeaconView.swift`
**Source:** `app/beacon:bitchat/Views/BeaconView.swift`

**What exists:** Full UI with map, annotations, favorites list, tracking popup.

**Changes needed:**
- Update to use `BeaconViewModel` instead of `TrackingViewModel`
- Update to use `BeaconService` instead of `TrackingService`
- Remove references to deleted components (DirectionalArrow, etc.)
- Keep the core UI structure

---

### 2.3 `PingWaveAnimation.swift` — COPY
**Path:** `bitchat/Views/Components/PingWaveAnimation.swift`
**Source:** `app/beacon:bitchat/Views/Components/PingWaveAnimation.swift`

**What exists:** Complete ping button and wave animation components.

**Changes needed:** None — copy as-is.

---

## Phase 3: Integration

### 3.1 `ChatViewModel.swift` — MODIFY
**Source:** Changes from `app/beacon` branch + new routing logic

**CHERRY-PICK from old branch:**
- `nostrTransport` property exposure (line ~432 in old branch)
- `refreshFavoriteNpubExchange()` method
- `getPeerID(for:)` method (useful for beacon)

**NEW changes needed:**

```swift
// In private message handler (wherever [FAVORITED] is handled)
private func processPrivateMessageContent(from peerID: PeerID, content: String, transport: TransportType) {
    // NEW: Route beacon messages
    if content.hasPrefix("[PING]:") || content.hasPrefix("[PONG]:") {
        BeaconService.shared.handlePrivateMessage(
            from: peerID,
            content: content,
            transport: transport
        )
        return  // Don't show in chat
    }

    // Existing [FAVORITED]/[UNFAVORITED] handling...
}

// In init or setupServices:
BeaconService.shared.configure(ble: meshService, nostr: nostrTransport)
```

---

### 3.2 `ContentView.swift` — MODIFY
**Source:** Changes from `app/beacon` branch

**CHERRY-PICK from old branch:**
- `showGroupTrackingSheet` state (rename to `showBeaconSheet`)
- `TrackingButtonContent` view (rename to `BeaconButtonContent`)
- Beacon button in header
- Sheet modifier for BeaconView

These exist in the old branch and can be adapted.

---

### 3.3 `LocationStateManager.swift` — CHERRY-PICK
**Source:** `app/beacon` branch has all needed changes

**CHERRY-PICK these additions:**
- `isLocationEnabled` computed property
- `currentLocation` computed property
- `currentHeading` published property
- `beginTrackingMode()` method
- `endTrackingMode()` method
- `requestFreshLocation(completion:)` method

All of these exist in the old branch diff and can be cherry-picked directly.

---

### 3.4 `BLEService.swift` — CHERRY-PICK (minimal)
**Source:** `app/beacon` branch

**CHERRY-PICK only:**
- `peerRSSI: [PeerID: Int]` dictionary
- `getRSSI(for:)` method
- RSSI tracking in `didDiscover` / `didReadRSSI`

**DO NOT cherry-pick:**
- `sendTrackRequest()` method (not needed)
- `handleTrackRequest()` / `handleTrackResponse()` (not needed)
- `sendLocationAnnounce()` (not needed)
- `TransportMetadata` conformance (not needed)

---

## Phase 4: Polish & Testing

### 4.1 Add Localizations

Update `Localizable.xcstrings` — can cherry-pick relevant strings from old branch.

---

### 4.2 Update Xcode Project

Add new files to `bitchat.xcodeproj`:
- Models/PeerLocation.swift
- Services/BeaconService.swift
- Services/UWBTrackingManager.swift
- Utils/HapticManager.swift
- ViewModels/BeaconViewModel.swift
- Views/BeaconView.swift
- Views/Components/PingWaveAnimation.swift

---

## Implementation Order

```
Phase 1: Core (can be done in parallel)
├── 1.4 HapticManager.swift ───────────── COPY
├── 1.3 UWBTrackingManager.swift ──────── COPY (minor cleanup)
└── 1.1 PeerLocation.swift ────────────── ADAPT (add PongResponseData)
         │
         ▼
    1.2 BeaconService.swift ───────────── ADAPT (major rewrite)
         │
         ▼
Phase 2: Views (can be done in parallel)
├── 2.3 PingWaveAnimation.swift ───────── COPY
└── 2.1 BeaconViewModel.swift ─────────── ADAPT (rename + simplify)
         │
         ▼
    2.2 BeaconView.swift ──────────────── ADAPT (update refs)
         │
         ▼
Phase 3: Integration
├── 3.3 LocationStateManager.swift ────── CHERRY-PICK
├── 3.4 BLEService.swift ──────────────── CHERRY-PICK (RSSI only)
├── 3.1 ChatViewModel.swift ───────────── MODIFY (add routing)
└── 3.2 ContentView.swift ─────────────── CHERRY-PICK + MODIFY
         │
         ▼
Phase 4: Polish
├── 4.1 Localizations
└── 4.2 Xcode project updates
```

---

## Files from Old Branch: Action Summary

### COPY (use as-is)
```
app/beacon:bitchat/Utils/HapticManager.swift
app/beacon:bitchat/Views/Components/PingWaveAnimation.swift
```

### ADAPT (copy + modify)
```
app/beacon:bitchat/Models/PeerLocation.swift → Remove TrackResponse dep, add PongResponseData
app/beacon:bitchat/Services/TrackingService.swift → Rename to BeaconService, use [PING]/[PONG]
app/beacon:bitchat/Services/UWBTrackingManager.swift → Minor cleanup if needed
app/beacon:bitchat/ViewModels/TrackingViewModel.swift → Rename to BeaconViewModel
app/beacon:bitchat/Views/BeaconView.swift → Update references
```

### CHERRY-PICK (take specific changes)
```
app/beacon:bitchat/Services/LocationStateManager.swift → Tracking mode methods
app/beacon:bitchat/Services/BLE/BLEService.swift → RSSI tracking only
app/beacon:bitchat/ViewModels/ChatViewModel.swift → nostrTransport exposure
app/beacon:bitchat/Views/ContentView.swift → Beacon button + sheet
```

### DELETE (do not use)
```
bitchat/Views/GroupTrackingView.swift
bitchat/Views/TrackingView.swift
bitchat/Views/TrackingMapView.swift
bitchat/Views/PrivateServerSettingsView.swift
bitchat/Services/TransportManager.swift
bitchat/Services/TransportMetadata.swift
bitchat/Services/PrivateServerTransport.swift
bitchat/Services/PrivateServerPersistenceService.swift
bitchat/Models/GroupMemberLocation.swift
bitchat/Models/TrackingSource.swift
bitchat/Models/SignalFusion.swift
bitchat/Models/UWBTokenMessage.swift
bitchat/Models/TrackingMessage.swift
bitchat/Views/Components/DirectionalArrow.swift
bitchat/Views/Components/HotColdIndicator.swift
bitchat/Views/Components/TrackingSourceIndicators.swift
```

### REVERT (restore to main, don't use old branch changes)
```
bitchat/Services/Transport.swift
bitchat/Services/MessageRouter.swift
bitchat/Protocols/BitchatProtocol.swift
bitchat/Nostr/NostrEmbeddedBitChat.swift
```

---

## Estimated Scope

| Category | Action | Files | Lines (est.) |
|----------|--------|-------|--------------|
| Models | ADAPT | 1 | ~150 |
| Services | COPY+ADAPT | 3 | ~500 |
| ViewModels | ADAPT | 1 | ~100 |
| Views | COPY+ADAPT | 2 | ~400 |
| Integration | CHERRY-PICK+MODIFY | 4 | ~150 |
| **Total** | | **11** | **~1300** |

Much of this is adaptation rather than writing from scratch.

---

## Testing Checklist

- [ ] Ping works over BLE (two nearby devices)
- [ ] Ping works over Nostr relay (devices not in BLE range)
- [ ] Only mutual favorites can ping each other
- [ ] Non-favorites are ignored (no response)
- [ ] GPS disabled shows "gps.enabled: false" in response
- [ ] UWB token is included on iPhone 11+
- [ ] UWB ranging starts after receiving token
- [ ] Peer's RSSI is included in BLE responses
- [ ] RTT (round-trip time) is calculated correctly
- [ ] Map shows peer locations correctly
- [ ] Selecting peer on map shows detail sheet
- [ ] macOS build works (UWB disabled gracefully)
- [ ] Haptic feedback on ping/response (iOS)
