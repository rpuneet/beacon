# Beacon Implementation Plan

> Step-by-step guide to implement the Beacon feature on `app/beacon-v2`

---

## Phase 1: Core Models & Services

### 1.1 Create `PeerLocation.swift`
**Path:** `bitchat/Models/PeerLocation.swift`

Data model for peer location and tracking signals.

```swift
// Key components:
struct PeerLocation: Identifiable, Equatable, Codable
struct PongResponseData: Codable  // JSON structure for [PONG] payload
enum TransportType: String, Codable { case ble, relay }
```

**Dependencies:** None

---

### 1.2 Create `BeaconService.swift`
**Path:** `bitchat/Services/BeaconService.swift`

Core service handling ping/pong logic.

```swift
@MainActor
final class BeaconService: ObservableObject {
    static let shared = BeaconService()

    // State
    @Published private(set) var peerLocations: [String: PeerLocation] = [:]
    @Published private(set) var isPinging = false

    // Pending pings for RTT calculation
    private var pendingPings: [String: (peerID: PeerID, noiseKey: Data, sentAt: Date)] = [:]

    // Dependencies
    private weak var bleService: BLEService?
    private weak var nostrTransport: NostrTransport?

    // MARK: - Configuration
    func configure(ble: BLEService, nostr: NostrTransport)

    // MARK: - Ping API
    func pingAllFavorites()
    func pingPeer(_ peerID: PeerID, noisePublicKey: Data)

    // MARK: - Message Handling (called by ChatViewModel)
    func handlePrivateMessage(from peerID: PeerID, content: String, transport: TransportType)

    // MARK: - Private
    private func handlePing(from peerID: PeerID, requestID: String, transport: TransportType)
    private func handlePong(from peerID: PeerID, requestID: String, data: String, transport: TransportType)
    private func buildPongResponse(for requesterPeerID: PeerID) -> PongResponseData
    private func isMutualFavorite(_ peerID: PeerID) -> Bool
}
```

**Dependencies:** PeerLocation.swift, BLEService, NostrTransport, FavoritesPersistenceService

---

### 1.3 Create `UWBTrackingManager.swift`
**Path:** `bitchat/Services/UWBTrackingManager.swift`

Manages UWB ranging sessions (iOS only).

```swift
#if os(iOS)
import NearbyInteraction
#endif

final class UWBTrackingManager: NSObject, ObservableObject {
    static let shared = UWBTrackingManager()

    var isUWBSupported: Bool

    // Get discovery token to send to peer
    func getMyToken() -> Data?

    // Start ranging with peer's token
    func startRanging(with peerID: PeerID, peerToken: Data)
    func stopRanging(with peerID: PeerID)
    func stopAllRanging()

    // Callbacks
    var onDistanceUpdate: ((PeerID, Double, Float?) -> Void)?
}
```

**Dependencies:** None (platform APIs only)

**Note:** macOS stub returns `isUWBSupported = false`

---

### 1.4 Create `HapticManager.swift`
**Path:** `bitchat/Utils/HapticManager.swift`

Centralized haptic feedback (iOS only).

```swift
final class HapticManager {
    static let shared = HapticManager()

    func pingStarted()
    func pingResponseReceived()
    func pingCompleted(responseCount: Int)
}
```

**Dependencies:** None

---

## Phase 2: View Layer

### 2.1 Create `BeaconViewModel.swift`
**Path:** `bitchat/ViewModels/BeaconViewModel.swift`

UI state for BeaconView.

```swift
@MainActor
final class BeaconViewModel: ObservableObject {
    @Published var mapRegion: MKCoordinateRegion
    @Published var selectedPeerID: String?
    @Published var userHasInteracted = false

    let beaconService = BeaconService.shared

    // Computed
    var myLocation: CLLocationCoordinate2D?
    var peersWithLocation: [PeerLocation]
    var isPinging: Bool

    // Actions
    func pingAll()
    func selectPeer(_ id: String)
    func deselectPeer()
    func fitAllPeers()
    func centerOnUser()
}
```

**Dependencies:** BeaconService, LocationStateManager

---

### 2.2 Create `BeaconView.swift`
**Path:** `bitchat/Views/BeaconView.swift`

Main beacon UI with map and favorites list.

```swift
struct BeaconView: View {
    @StateObject private var viewModel = BeaconViewModel()
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            headerView       // Title + ping button + close
            mapView          // Map with annotations
            favoritesListView // Scrollable list of favorites with status
        }
    }
}

// Wrapper for sheet presentation
struct BeaconSheetView: View { ... }
```

**Dependencies:** BeaconViewModel, ChatViewModel, FavoritesPersistenceService

---

### 2.3 Create `PingWaveAnimation.swift`
**Path:** `bitchat/Views/Components/PingWaveAnimation.swift`

Animated ping button component.

```swift
struct PingButton: View {
    let isPinging: Bool
    let action: () -> Void
}
```

**Dependencies:** None

---

## Phase 3: Integration

### 3.1 Modify `ChatViewModel.swift`

**Changes needed:**

1. **Expose nostrTransport** (if not already public):
```swift
let nostrTransport: NostrTransport  // Change from private
```

2. **Route beacon messages** in private message handler:
```swift
// In the method that processes incoming private messages
private func processPrivateMessageContent(from peerID: PeerID, content: String, ...) {
    // NEW: Check for beacon messages first
    if content.hasPrefix("[PING]:") || content.hasPrefix("[PONG]:") {
        BeaconService.shared.handlePrivateMessage(
            from: peerID,
            content: content,
            transport: .ble  // or .relay depending on source
        )
        return  // Don't display in chat
    }

    // Existing favorites handling
    if content.hasPrefix("[FAVORITED]:") || content.hasPrefix("[UNFAVORITED]:") {
        // ... existing code
    }

    // ... rest of message handling
}
```

3. **Configure BeaconService** in init or setup:
```swift
BeaconService.shared.configure(ble: meshService, nostr: nostrTransport)
```

---

### 3.2 Modify `ContentView.swift`

**Changes needed:**

1. **Add state for beacon sheet**:
```swift
@State private var showBeaconSheet = false
```

2. **Add beacon button** in header (near favorites/location buttons):
```swift
Button(action: { showBeaconSheet = true }) {
    Image(systemName: "location.north.circle.fill")
        .font(.system(size: 14))
        .foregroundColor(.green)
}
.buttonStyle(.plain)
```

3. **Add sheet modifier**:
```swift
.sheet(isPresented: $showBeaconSheet) {
    BeaconSheetView()
        .environmentObject(viewModel)
}
```

---

### 3.3 Modify `LocationStateManager.swift`

**Changes needed:**

1. **Add fresh location request method**:
```swift
/// Request a fresh GPS fix with callback
func requestFreshLocation(completion: @escaping (CLLocation?) -> Void) {
    // Trigger one-shot location update
    // Call completion with result or timeout after 3 seconds
}
```

2. **Add tracking mode** (optional, for better accuracy during beacon):
```swift
func beginTrackingMode()  // Use kCLLocationAccuracyBest
func endTrackingMode()    // Return to normal accuracy
```

---

### 3.4 Modify `BLEService.swift`

**Changes needed:**

1. **Expose RSSI for peer** (add if not exists):
```swift
/// Get last known RSSI for a connected peer
func getRSSI(for peerID: PeerID) -> Int? {
    return collectionsQueue.sync { peerRSSI[peerID] }
}
```

2. **Track RSSI** (if not already):
```swift
// In didDiscover or didReadRSSI delegate methods
private var peerRSSI: [PeerID: Int] = [:]
```

---

## Phase 4: Polish & Testing

### 4.1 Add Localizations

Update `Localizable.xcstrings` with:
- "Track Favorites" (button accessibility)
- "Find Friends" (ping button)
- "friends" (count label)
- "Nearby" / "Remote" (transport labels)
- etc.

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
├── 1.1 PeerLocation.swift
├── 1.3 UWBTrackingManager.swift
└── 1.4 HapticManager.swift
         │
         ▼
    1.2 BeaconService.swift (depends on PeerLocation, UWB, Haptic)
         │
         ▼
Phase 2: Views (can be done in parallel)
├── 2.3 PingWaveAnimation.swift
└── 2.1 BeaconViewModel.swift (depends on BeaconService)
         │
         ▼
    2.2 BeaconView.swift (depends on ViewModel, Components)
         │
         ▼
Phase 3: Integration
├── 3.1 ChatViewModel.swift changes
├── 3.2 ContentView.swift changes
├── 3.3 LocationStateManager.swift changes
└── 3.4 BLEService.swift changes
         │
         ▼
Phase 4: Polish
├── 4.1 Localizations
└── 4.2 Xcode project updates
```

---

## Cleanup: Old `app/beacon` Branch

If you want to clean up the old branch later, here's what to delete/revert:

### Files to DELETE from old branch
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
bitchat/ViewModels/TrackingViewModel.swift
bitchat/Services/TrackingService.swift
```

### Files to REVERT (restore to main)
```
bitchat/Services/Transport.swift
bitchat/Services/MessageRouter.swift
bitchat/Protocols/BitchatProtocol.swift
bitchat/Nostr/NostrEmbeddedBitChat.swift
```

### Files to KEEP (can be adapted)
```
bitchat/Views/BeaconView.swift          → Adapt UI
bitchat/Services/UWBTrackingManager.swift → Mostly reusable
bitchat/Utils/HapticManager.swift        → Fully reusable
bitchat/Views/Components/PingWaveAnimation.swift → Fully reusable
```

---

## Estimated Scope

| Category | Files | Lines (est.) |
|----------|-------|--------------|
| New Models | 1 | ~100 |
| New Services | 3 | ~400 |
| New ViewModels | 1 | ~100 |
| New Views | 2 | ~500 |
| Modified Files | 4 | ~100 |
| **Total** | **11** | **~1200** |

This is significantly smaller than the old branch (~9500 lines across 51 files).

---

## Testing Checklist

- [ ] Ping works over BLE (two nearby devices)
- [ ] Ping works over Nostr relay (devices not in BLE range)
- [ ] Only mutual favorites can ping each other
- [ ] Non-favorites are ignored (no response)
- [ ] GPS disabled shows "Location disabled" in response
- [ ] UWB token is included on iPhone 11+
- [ ] UWB ranging starts after receiving token
- [ ] RSSI is included in BLE responses
- [ ] RTT (round-trip time) is calculated correctly
- [ ] Map shows peer locations correctly
- [ ] Selecting peer on map shows detail sheet
- [ ] macOS build works (UWB disabled gracefully)
- [ ] Haptic feedback on ping/response (iOS)
