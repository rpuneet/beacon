# Beacon Feature Architecture

> Location sharing for mutual favorites using BitChat's existing mesh and relay infrastructure.

---

## 1. Overview

### What is Beacon?

Beacon allows mutual favorites to share their GPS location with each other on-demand. When you "ping" your friends, they respond with their current location, which is displayed on a map.

### Design Principles

1. **Use existing infrastructure** - No new transport layers, protocols, or message types
2. **Privacy first** - Only mutual favorites can track each other
3. **Simple implementation** - Beacon is a thin layer on top of BitChat
4. **Battery conscious** - On-demand pings, not continuous tracking

### How It Works

Beacon uses BitChat's existing **private message** system with special message prefixes:

```
[PING]:<request_id>                       → "Please send me your location"
[PONG]:<request_id>:<response_data>       → "Here's my location + UWB + RSSI"
```

This is the same pattern used for favorites (`[FAVORITED]:npub...`).

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         BeaconView                               │
│                    (Map + Favorites List)                        │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                        BeaconViewModel                           │
│              (UI state, map region, selection)                   │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         BeaconService                            │
│                                                                  │
│  • sendPing(to: PeerID)         - Request location from peer    │
│  • handleIncomingMessage(...)   - Parse [PING]/[PONG] messages  │
│  • peerLocations: [PeerID: PeerLocation]  - Location cache      │
│                                                                  │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                │  Uses existing sendPrivateMessage()
                                │
              ┌─────────────────┴─────────────────┐
              ▼                                   ▼
┌──────────────────────┐              ┌──────────────────────┐
│      BLEService      │              │    NostrTransport    │
│     (unchanged)      │              │     (unchanged)      │
│                      │              │                      │
│ • sendPrivateMessage │              │ • sendPrivateMessage │
│ • isPeerConnected    │              │ • isPeerReachable    │
└──────────────────────┘              └──────────────────────┘
              │
              ▼
┌──────────────────────┐
│  UWBTrackingManager  │
│  (precise ranging)   │
└──────────────────────┘
```

### Key Insight

BeaconService doesn't need special transport methods. It just:
1. Calls `sendPrivateMessage()` with `[PING]:...` content
2. Listens for incoming private messages
3. Parses `[PING]` and `[PONG]` prefixes
4. Updates the location cache

---

## 3. Message Format

### Ping Request

Sent when user taps "Find Friends" or the ping button.

```
[PING]:<request_id>

Example:
[PING]:a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

### Pong Response

Sent automatically when receiving a ping from a mutual favorite. Contains **three tracking signals**:

```
[PONG]:<request_id>:<base64_response_data>

Example:
[PONG]:a1b2c3d4-e5f6-7890-abcd-ef1234567890:eyJncHMiOnsiZW5hYmxlZCI6dHJ1ZSwi...
```

### Response Data Structure

The response contains three types of tracking data:

```json
{
  "gps": {
    "enabled": true,
    "lat": 37.7849,
    "lon": -122.4094,
    "alt": 10.5,
    "acc": 5.0
  },
  "uwb": {
    "supported": true,
    "token": "base64_encoded_uwb_discovery_token"
  },
  "ble": {
    "rssi": -65
  },
  "ts": 1706400000000
}
```

### Field Descriptions

#### GPS Object
| Field | Type | Description |
|-------|------|-------------|
| `enabled` | Bool | Whether GPS/location services are enabled |
| `lat` | Double? | Latitude (null if GPS disabled) |
| `lon` | Double? | Longitude (null if GPS disabled) |
| `alt` | Double? | Altitude in meters |
| `acc` | Double? | Horizontal accuracy in meters |

#### UWB Object
| Field | Type | Description |
|-------|------|-------------|
| `supported` | Bool | Whether device supports UWB (iPhone 11+) |
| `token` | String? | Base64-encoded UWB discovery token for precise ranging |

#### BLE Object
| Field | Type | Description |
|-------|------|-------------|
| `rssi` | Int? | Signal strength (dBm) that **responder sees for requester** |

#### Metadata
| Field | Type | Description |
|-------|------|-------------|
| `ts` | Int64 | Timestamp (ms since epoch) |

### Example Responses

**Full response (GPS + UWB + RSSI):**
```json
{
  "gps": {"enabled": true, "lat": 37.7849, "lon": -122.4094, "alt": 10.5, "acc": 5.0},
  "uwb": {"supported": true, "token": "SGVsbG8gV29ybGQ="},
  "ble": {"rssi": -58},
  "ts": 1706400000000
}
```

**GPS disabled, no UWB:**
```json
{
  "gps": {"enabled": false},
  "uwb": {"supported": false},
  "ble": {"rssi": -72},
  "ts": 1706400000000
}
```

**Via Nostr relay (no BLE data):**
```json
{
  "gps": {"enabled": true, "lat": 37.7849, "lon": -122.4094, "alt": 10.5, "acc": 5.0},
  "uwb": {"supported": false},
  "ble": {},
  "ts": 1706400000000
}
```

---

## 4. Three Tracking Signals

When you ping a friend, you can receive up to **three independent distance/location signals**:

### 4.1 GPS (Coarse Location)

- **Accuracy:** 5-100+ meters depending on conditions
- **Range:** Unlimited (works via relay too)
- **Use case:** Shows friend on map, navigate to general area

### 4.2 UWB (Precise Distance)

- **Accuracy:** ~10cm when in range
- **Range:** ~10-30 meters line-of-sight
- **Use case:** Find friend in crowded place, precise direction
- **Requirements:** Both devices need UWB (iPhone 11+, not on macOS)

**UWB Flow:**
1. A sends `[PING]` to B
2. B responds with `[PONG]` containing UWB discovery token
3. A uses token to start UWB ranging session with B
4. UWBTrackingManager provides real-time distance updates

### 4.3 BLE RSSI (Signal Strength)

- **What it is:** The signal strength B sees when receiving from A
- **Accuracy:** Rough distance estimate (+/-5-10m)
- **Range:** ~10-100 meters
- **Use case:** "Getting warmer/colder" feedback, works indoors

**Why peer's RSSI?**
- The pinger (A) already knows their own RSSI for peer (B)
- The pong includes B's RSSI reading of A
- Two-way RSSI gives better distance estimation
- Helps account for asymmetric antenna/power conditions

---

## 5. Components

### 5.1 BeaconService

The core service that manages pinging and location state.

```swift
@MainActor
final class BeaconService: ObservableObject {
    static let shared = BeaconService()

    // Published state
    @Published private(set) var peerLocations: [String: PeerLocation] = [:]
    @Published private(set) var isPinging = false

    // Dependencies (injected via configure())
    private weak var bleService: BLEService?
    private weak var nostrTransport: NostrTransport?

    // Pending pings for RTT calculation
    private var pendingPings: [String: PendingPing] = [:]

    // MARK: - Public API

    func configure(ble: BLEService, nostr: NostrTransport)
    func pingAllFavorites()
    func pingPeer(_ peerID: PeerID, noisePublicKey: Data)

    // MARK: - Message Handling (called by ChatViewModel)

    func handlePrivateMessage(from peerID: PeerID, content: String, via transport: TransportType)
}
```

### 5.2 BeaconViewModel

UI state management for BeaconView.

```swift
@MainActor
final class BeaconViewModel: ObservableObject {
    @Published var mapRegion: MKCoordinateRegion
    @Published var selectedPeerID: String?
    @Published var userHasInteracted = false

    let beaconService = BeaconService.shared
    let locationManager = LocationStateManager.shared

    // Computed
    var myLocation: CLLocationCoordinate2D?
    var peersWithLocation: [PeerLocation]

    // Actions
    func pingAll()
    func selectPeer(_ id: String)
    func deselectPeer()
    func fitAllPeers()
}
```

### 5.3 PeerLocation

Data model for a peer's location and tracking signals.

```swift
struct PeerLocation: Identifiable, Equatable {
    let id: String              // PeerID string
    let peerID: PeerID

    // GPS (coarse location)
    let gpsEnabled: Bool
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?

    // UWB (precise distance)
    let uwbSupported: Bool
    let uwbToken: Data?
    var uwbDistance: Double?    // Updated by UWBTrackingManager
    var uwbDirection: Float?    // Angle in degrees (if available)

    // BLE (signal strength from peer's perspective)
    let peerRSSI: Int?          // RSSI that peer sees for us

    // Metadata
    let timestamp: Date
    let rtt: Int                // Round-trip time in ms
    let transport: TransportType

    // Computed
    var hasLocation: Bool { latitude != nil && longitude != nil }
    var coordinate: CLLocationCoordinate2D?
    var isStale: Bool           // > 5 minutes old
    var hasUWB: Bool { uwbSupported && uwbToken != nil }
}

enum TransportType: String {
    case ble = "BLE"
    case relay = "Relay"
}
```

### 5.4 UWBTrackingManager

Manages UWB ranging sessions for precise distance.

```swift
final class UWBTrackingManager: NSObject, ObservableObject {
    static let shared = UWBTrackingManager()

    // Whether device supports UWB
    var isUWBSupported: Bool

    // Get my UWB discovery token to send to peer
    func getMyToken() -> Data?

    // Start ranging session with peer using their token
    func startRanging(with peerID: PeerID, peerToken: Data)

    // Stop ranging session
    func stopRanging(with peerID: PeerID)

    // Callback when distance updates
    var onDistanceUpdate: ((PeerID, Double, Float?) -> Void)?
}
```

### 5.5 BeaconView

The main UI showing map and favorites list.

```swift
struct BeaconView: View {
    @StateObject private var viewModel = BeaconViewModel()
    @EnvironmentObject private var chatViewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header with ping button
            headerView

            // Map with peer annotations
            mapView

            // Favorites list with status
            favoritesListView
        }
    }
}
```

---

## 6. Data Flow

### 6.1 Sending a Ping

```
User taps "Ping"
       │
       ▼
BeaconViewModel.pingAll()
       │
       ▼
BeaconService.pingAllFavorites()
       │
       ├─── For each mutual favorite:
       │         │
       │         ▼
       │    Is peer BLE connected?
       │         │
       │    YES  │  NO
       │    ▼    │  ▼
       │  BLE    │  Has Nostr npub?
       │         │    │
       │         │  YES  │  NO
       │         │  ▼    │  ▼
       │         │ Nostr │ Skip (unreachable)
       │         │       │
       └─────────┴───────┘
                 │
                 ▼
       sendPrivateMessage("[PING]:uuid", to: peer)
                 │
                 ▼
       Store in pendingPings with timestamp
```

### 6.2 Receiving a Ping (Building the Response)

```
Receive [PING] from peerID
       │
       ▼
Is sender a MUTUAL favorite? ──NO──► Ignore
       │
      YES
       │
       ▼
┌──────────────────────────────────────────┐
│           Build Response Data            │
├──────────────────────────────────────────┤
│                                          │
│  1. GPS: Get current location            │
│     └─► {enabled, lat, lon, alt, acc}    │
│                                          │
│  2. UWB: Get my discovery token          │
│     └─► {supported, token}               │
│                                          │
│  3. BLE: Get RSSI for the pinger         │
│     └─► {rssi} (what I see for them)     │
│                                          │
│  4. Timestamp                            │
│     └─► {ts}                             │
│                                          │
└──────────────────────────────────────────┘
       │
       ▼
Encode as JSON, then base64
       │
       ▼
sendPrivateMessage("[PONG]:uuid:base64data", to: pinger)
```

### 6.3 Processing a Pong Response

```
Receive [PONG] from peerID
       │
       ▼
Parse request_id, find in pendingPings
       │
       ▼
Calculate RTT (now - sentAt)
       │
       ▼
Decode base64 → JSON → PeerLocation
       │
       ▼
┌──────────────────────────────────────────┐
│         Process Tracking Signals         │
├──────────────────────────────────────────┤
│                                          │
│  1. GPS: Update map annotation           │
│                                          │
│  2. UWB: If token present:               │
│     └─► Start UWB ranging session        │
│     └─► Get precise distance updates     │
│                                          │
│  3. RSSI: Store peer's reading           │
│     └─► Use for distance estimation      │
│                                          │
└──────────────────────────────────────────┘
       │
       ▼
Update peerLocations[peerID]
       │
       ▼
UI updates via @Published
```

---

## 7. Integration Points

### 7.1 ChatViewModel Changes

Add message routing to BeaconService:

```swift
// In handlePrivateMessage or when processing Noise payload
private func processPrivateMessageContent(from peerID: PeerID, content: String, transport: TransportType) {
    // Check if it's a beacon message
    if content.hasPrefix("[PING]:") || content.hasPrefix("[PONG]:") {
        BeaconService.shared.handlePrivateMessage(
            from: peerID,
            content: content,
            via: transport
        )
        return  // Don't show in chat UI
    }

    // Existing favorites handling
    if content.hasPrefix("[FAVORITED]:") || content.hasPrefix("[UNFAVORITED]:") {
        // ... existing code
        return
    }

    // Normal message - show in chat
    // ...
}
```

### 7.2 ContentView Changes

Add beacon button and sheet:

```swift
// In toolbar/header
Button(action: { showBeaconSheet = true }) {
    Image(systemName: "location.north.circle.fill")
}

// Sheet
.sheet(isPresented: $showBeaconSheet) {
    BeaconView()
        .environmentObject(chatViewModel)
}
```

### 7.3 BLEService - Get RSSI for Peer

BeaconService needs to get the RSSI we see for a specific peer:

```swift
// Add to BLEService (or expose existing)
func getRSSI(for peerID: PeerID) -> Int? {
    // Return cached RSSI from last didDiscover or readRSSI
}
```

---

## 8. File Structure

### Files to CREATE

```
bitchat/
├── Services/
│   └── BeaconService.swift          # Core ping/pong logic
├── ViewModels/
│   └── BeaconViewModel.swift        # UI state for BeaconView
├── Models/
│   └── PeerLocation.swift           # Location + UWB + RSSI data model
├── Views/
│   └── BeaconView.swift             # Main beacon UI
├── Utils/
│   ├── HapticManager.swift          # Haptic feedback
│   └── UWBTrackingManager.swift     # UWB ranging sessions
└── Views/Components/
    └── PingWaveAnimation.swift      # Ping button animation
```

### Files to MODIFY

```
bitchat/
├── ViewModels/
│   └── ChatViewModel.swift          # Route [PING]/[PONG] to BeaconService
├── Services/
│   ├── LocationStateManager.swift   # Add requestFreshLocation()
│   └── BLEService.swift             # Expose getRSSI(for:) if needed
└── Views/
    └── ContentView.swift            # Add beacon button + sheet
```

---

## 9. Privacy & Security

### 9.1 Mutual Favorites Only

Location is **only shared with mutual favorites**:

```swift
func handlePingRequest(from peerID: PeerID, ...) {
    // CRITICAL: Only respond to mutual favorites
    guard isMutualFavorite(peerID) else {
        SecureLogger.warning("Ignoring ping from non-favorite")
        return
    }
    // ... send response
}
```

### 9.2 User Control

- Users must explicitly **add someone as a favorite** to be trackable
- Users can **disable location** in iOS Settings to stop sharing GPS
- Location is **on-demand only** (no background tracking)
- UWB requires active app usage

### 9.3 Data Minimization

- Location data is **not stored on any server**
- Messages are **end-to-end encrypted** (Noise for BLE, NIP-17 for Nostr)
- No location history is kept (only latest ping response)
- UWB tokens are session-specific

---

## 10. Platform Notes

### iOS
- Full support: GPS + UWB (iPhone 11+) + BLE RSSI
- UWB provides precise indoor tracking

### macOS
- GPS: Yes (via Core Location)
- UWB: **No** (hardware not exposed to third-party apps)
- BLE RSSI: Yes

When a macOS device responds to a ping, `uwb.supported` will be `false`.

---

## 11. Summary

| Aspect | Approach |
|--------|----------|
| **Message Format** | `[PING]:id` and `[PONG]:id:data` via existing privateMessage |
| **Response Data** | GPS location + UWB token + peer's RSSI reading |
| **Transport** | Existing BLE mesh + Nostr relay (no changes) |
| **Protocol** | No new message types |
| **Privacy** | Mutual favorites only, E2E encrypted |
| **UI** | Single BeaconView with map + list |
| **Complexity** | ~6 new files, ~1500 lines of code |

This design keeps Beacon as a **lightweight feature** built entirely on BitChat's existing infrastructure, while providing three complementary tracking signals for different use cases.
