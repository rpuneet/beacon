# Beacon Feature Architecture

> Location sharing for mutual favorites using BitChat's mesh network.

---

## 1. Overview

### What is Beacon?

Beacon allows mutual favorites to share their GPS location with each other on-demand. When you "ping" your friends, they respond with their current location, which is displayed on a map. When you select someone to track, you get a full-screen tracking experience with compass direction and proximity feedback.

### Design Principles

1. **Use existing infrastructure** - Uses BLE private messages, no new protocols
2. **Privacy first** - Only mutual favorites can track each other
3. **Simple implementation** - Compact text protocol, minimal overhead
4. **Battery conscious** - On-demand pings, not continuous tracking

### How It Works

Beacon uses BitChat's existing **private message** system with special message prefixes:

```
[PING]:ID:rssi:lat,lon,alt,hacc,vacc    → "Here's my location, send yours"
[PONG]:ID:rssi:lat,lon,alt,hacc,vacc    → "Here's my location back"
```

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
│                         TrackingView                             │
│           (Full-screen compass + proximity tracking)             │
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
│  • pingAllFavorites()         - Ping all connected favorites    │
│  • handlePrivateMessage(...)  - Parse [PING]/[PONG] messages    │
│  • peerLocations: [String: PeerLocation]  - Location cache      │
│                                                                  │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                │  Uses sendPrivateMessage()
                                ▼
                    ┌──────────────────────┐
                    │      BLEService      │
                    │                      │
                    │ • sendPrivateMessage │
                    │ • getRSSI(for:)      │
                    │ • getConnectedPeers  │
                    └──────────────────────┘
```

---

## 3. Message Protocol

### Compact Text Format

Messages use a simple colon-separated format that fits within the 255-byte TLV limit:

```
[PING]:ID:rssi:lat,lon,alt,hacc,vacc
[PONG]:ID:rssi:lat,lon,alt,hacc,vacc
```

### Field Descriptions

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| ID | String | 8-char hex request ID | `8CD15541` |
| rssi | Int | Signal strength in dBm (empty if unavailable) | `-72` |
| lat | Double | Latitude (6 decimal places) | `37.774929` |
| lon | Double | Longitude (6 decimal places) | `-122.419415` |
| alt | Int | Altitude in meters | `10` |
| hacc | Int | Horizontal accuracy in meters | `5` |
| vacc | Int | Vertical accuracy in meters | `10` |

### Example Messages

**Full location:**
```
[PING]:8CD15541:-72:37.774929,-122.419415,10,5,10
[PONG]:8CD15541:-65:37.775012,-122.419320,12,3,8
```

**No GPS available:**
```
[PING]:8CD15541:-72:
[PONG]:8CD15541:-65:
```

**Message Size:** ~70 bytes typical, well under 255-byte limit.

---

## 4. Tracking Signals

### 4.1 GPS (Map Location)

- **Accuracy:** 5-100+ meters depending on conditions
- **Use case:** Shows friend on map, navigate to general area
- **UI:** Map annotations, direction arrow when far

### 4.2 BLE RSSI (Proximity)

- **What it is:** Signal strength between devices
- **Range:** ~10-100 meters
- **Use case:** Hot/cold feedback when close
- **UI:** Proximity circle with levels: Far → Medium → Near → Very Near → Here

### 4.3 UWB (Precise Distance) — Future

- **Accuracy:** ~10cm when in range
- **Range:** ~10-30 meters line-of-sight
- **Requirements:** Both devices need UWB (iPhone 11+)
- **Status:** Infrastructure exists, protocol support pending

---

## 5. Components

### 5.1 BeaconService

Core service managing pings and location state.

```swift
@MainActor
final class BeaconService: ObservableObject {
    static let shared = BeaconService()

    @Published private(set) var peerLocations: [String: PeerLocation] = [:]
    @Published private(set) var pingState: BeaconPingState = .idle
    @Published var isBeaconModeEnabled: Bool = false  // Auto-ping every 30s

    func configure(ble: BLEService)
    func pingAllFavorites()
    func handlePrivateMessage(from:senderNoiseKey:content:transport:) -> Bool
}
```

### 5.2 TrackingView (iOS)

Full-screen tracking experience shown when selecting a favorite.

**Features:**
- Centered direction arrow rotating with device compass
- Proximity mode when close (< 50m or within GPS accuracy)
- Pulsing circle with color-coded proximity levels
- Haptic feedback on proximity changes
- Distance display (UWB/BLE/GPS source indicated)

```swift
struct TrackingView: View {
    let peerLocation: PeerLocation
    let peerName: String
    let onDismiss: () -> Void

    // Proximity levels with colors and haptics
    enum ProximityLevel {
        case unknown, far, medium, near, veryNear, here
    }
}
```

### 5.3 LocationStateManager

Extended with heading support for compass tracking.

```swift
// Added for beacon
@Published private(set) var currentHeading: Double?

func startHeadingUpdates()  // Call when entering tracking mode
func stopHeadingUpdates()   // Call when leaving tracking mode
```

### 5.4 PeerLocation

Data model for peer location information.

```swift
struct PeerLocation: Identifiable, Equatable {
    let id: String
    let peerIDString: String

    // GPS
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?
    let gpsEnabled: Bool

    // Signal
    let transport: TransportType  // .ble or .relay
    let pingMs: Int               // Round-trip time
    let peerRSSI: Int?            // RSSI peer sees for us

    // UWB (future)
    let uwbSupported: Bool
    let uwbToken: Data?
    var uwbDistance: Float?

    // Computed
    var hasLocation: Bool
    var coordinate: CLLocationCoordinate2D?
    var isStale: Bool  // > 5 minutes old
}
```

---

## 6. Data Flow

### 6.1 Sending Pings

```
User taps "Ping" or beacon mode triggers
       │
       ▼
BeaconService.pingAllFavorites()
       │
       ▼
Get connected peers with noise keys
       │
       ▼
Filter to mutual favorites
       │
       ▼
For each favorite:
├── Build location string: "lat,lon,alt,hacc,vacc"
├── Get RSSI for peer
├── Create content: "[PING]:ID:rssi:location"
├── Store in pendingPings with timestamp
└── sendPrivateMessage(content, to: peerID)
       │
       ▼
15s timeout → finishPingIfNeeded()
```

### 6.2 Receiving Ping

```
Receive private message with [PING]: prefix
       │
       ▼
Parse: ID, rssi, location data
       │
       ▼
Look up sender's noise key from BLE session
       │
       ▼
Is sender a mutual favorite? ──NO──► Ignore
       │
      YES
       │
       ▼
Store sender's location (bidirectional update)
       │
       ▼
Build PONG response:
├── Get my location: "lat,lon,alt,hacc,vacc"
├── Get RSSI for pinger
└── Create: "[PONG]:ID:rssi:location"
       │
       ▼
sendPrivateMessage(content, to: peerID)
```

### 6.3 Receiving Pong

```
Receive private message with [PONG]: prefix
       │
       ▼
Parse: ID, rssi, location data
       │
       ▼
Find matching pendingPing by ID
       │
       ▼
Calculate RTT (now - sentAt)
       │
       ▼
Create PeerLocation and store
       │
       ▼
Trigger wave animation + haptic
       │
       ▼
Update UI via @Published
```

---

## 7. Tracking Experience

### Map View (Default)

- Shows all favorites with location pins
- User location with heading arrow
- PONG wave animations when responses arrive
- Tap pin to enter tracking mode

### Tracking Mode (Full-screen)

When you tap on a favorite to track:

1. **Far (> 50m):** Direction arrow mode
   - Large compass arrow pointing toward peer
   - Arrow rotates with device heading
   - Distance shown in meters/km

2. **Close (< 50m):** Proximity mode
   - Pulsing circle with proximity level
   - Color changes: Blue → Cyan → Yellow → Orange → Green
   - Haptic feedback intensifies as you get closer
   - Shows "Near", "Very Near", "Here!" labels

3. **UWB Range (future):** Precision mode
   - Exact distance in meters/cm
   - Direction arrow if available

---

## 8. Privacy & Security

### Mutual Favorites Only

Location is **only shared with mutual favorites**:

```swift
guard let noiseKey = senderNoiseKey,
      let favorite = favoritesService.favorites[noiseKey],
      favorite.isFavorite else {
    return  // Ignore non-favorites
}
```

### User Control

- Must explicitly **add someone as a favorite** to be trackable
- Can **disable location** in iOS Settings
- Location is **on-demand only** (manual ping or 30s beacon mode)

### Data Minimization

- No location data stored on servers
- Messages are **end-to-end encrypted** (Noise protocol)
- Only latest ping response kept (no history)

---

## 9. File Structure

```
bitchat/
├── Services/
│   └── BeaconService.swift           # Core ping/pong logic
├── ViewModels/
│   └── BeaconViewModel.swift         # UI state management
├── Models/
│   └── PeerLocation.swift            # Location data model
├── Views/
│   ├── BeaconView.swift              # Main map + list UI
│   └── Components/
│       ├── TrackingView.swift        # Full-screen tracking
│       ├── CompassMapView.swift      # MKMapView with heading
│       └── PingWaveAnimation.swift   # Ping animations
└── Utils/
    └── HapticManager.swift           # Haptic feedback
```

---

## 10. Platform Notes

### iOS
- Full support: GPS + BLE RSSI + Compass heading
- UWB: Hardware ready, protocol pending
- TrackingView: Full-screen with haptics

### macOS
- GPS: Yes (via Core Location)
- UWB: Not available
- BLE RSSI: Yes
- No TrackingView (map only)

---

## 11. Summary

| Aspect | Implementation |
|--------|----------------|
| **Protocol** | `[PING]:ID:rssi:gps` / `[PONG]:ID:rssi:gps` |
| **Transport** | BLE mesh (Nostr relay support planned) |
| **Max Message** | ~70 bytes (fits in 255-byte TLV) |
| **Privacy** | Mutual favorites only, E2E encrypted |
| **Tracking** | Map view + full-screen proximity mode |
| **Feedback** | Visual proximity circles + haptics |
