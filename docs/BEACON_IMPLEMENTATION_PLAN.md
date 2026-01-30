# Beacon Implementation Status

> Implementation status for the Beacon feature on `app/beacon-v2`

---

## Implementation Complete

The core beacon feature is implemented and functional. This document tracks what's done and what's pending.

---

## Phase 1: Core — COMPLETE

### 1.1 BeaconService.swift ✓
**Path:** `bitchat/Services/BeaconService.swift`

Compact text protocol implementation:
- `pingAllFavorites()` - Pings all connected mutual favorites
- `handlePrivateMessage()` - Parses [PING]/[PONG] messages
- `encodeLocation()` / `decodeLocation()` - Simple text format
- Auto-ping mode (every 30s when enabled)

### 1.2 PeerLocation.swift ✓
**Path:** `bitchat/Models/PeerLocation.swift`

Data model with:
- GPS coordinates and accuracy
- BLE RSSI
- Transport type (BLE/Relay)
- UWB fields (for future use)
- Timestamp and RTT

### 1.3 HapticManager.swift ✓
**Path:** `bitchat/Utils/HapticManager.swift`

Haptic feedback for:
- Ping started/completed
- Response received
- Proximity levels (impact styles)

---

## Phase 2: Views — COMPLETE

### 2.1 BeaconViewModel.swift ✓
**Path:** `bitchat/ViewModels/BeaconViewModel.swift`

UI state management:
- Map region binding
- Peer selection
- Beacon mode toggle
- Computed properties for UI

### 2.2 BeaconView.swift ✓
**Path:** `bitchat/Views/BeaconView.swift`

Main UI with:
- Header (status, beacon mode, ping button)
- Map with peer annotations
- Favorites list section
- PONG wave animations

### 2.3 TrackingView.swift ✓
**Path:** `bitchat/Views/Components/TrackingView.swift`

Full-screen tracking (iOS):
- Direction arrow with compass heading
- Proximity mode with pulsing circles
- Color-coded proximity levels
- Haptic feedback on level changes

### 2.4 CompassMapView.swift ✓
**Path:** `bitchat/Views/Components/CompassMapView.swift`

MKMapView wrapper:
- Heading tracking support
- Custom annotations
- Zoom/scroll enabled

### 2.5 PingWaveAnimation.swift ✓
**Path:** `bitchat/Views/Components/PingWaveAnimation.swift`

Animations for ping/pong feedback.

---

## Phase 3: Integration — COMPLETE

### 3.1 LocationStateManager.swift ✓
Added:
- `currentHeading: Double?` - Device compass heading
- `startHeadingUpdates()` / `stopHeadingUpdates()`
- CLLocationManager heading delegate

### 3.2 BLEService.swift ✓
Added:
- `getRSSI(for: PeerID) -> Int?`
- `getConnectedPeersWithNoiseKeys()`

### 3.3 ChatViewModel.swift ✓
Added:
- BeaconService configuration
- Message routing for [PING]/[PONG]

### 3.4 ChatViewModel+PrivateChat.swift ✓
Added:
- Beacon message detection in all private message handlers
- Noise key passing to BeaconService

### 3.5 ContentView.swift ✓
Added:
- Beacon button in home header
- Sheet presentation for BeaconView

---

## Pending Features

### P1: Verify End-to-End Flow
- [ ] Test PING/PONG between two BLE devices
- [ ] Verify location appears on map
- [ ] Verify TrackingView opens correctly

### P2: Nostr Relay Support
- [ ] Add NostrTransport to BeaconService
- [ ] Handle relay-based PING/PONG
- [ ] Test with geohash channels

### P3: UWB Integration
- [ ] Add UWB token to protocol (fits in 255 bytes?)
- [ ] Start UWB ranging on PONG receive
- [ ] Show precise distance in TrackingView

### P4: UI Polish
- [ ] Off-screen peer indicators at map edge
- [ ] Improve map annotation design
- [ ] Add accuracy circle around peer locations

### P5: Future Features
- [ ] Camera AR view for close tracking
- [ ] Location history/trails
- [ ] Group tracking mode

---

## Protocol Reference

### Message Format

```
[PING]:ID:rssi:lat,lon,alt,hacc,vacc
[PONG]:ID:rssi:lat,lon,alt,hacc,vacc
```

### Example

```
[PING]:8CD15541:-72:37.774929,-122.419415,10,5,10
[PONG]:8CD15541:-65:37.775012,-122.419320,12,3,8
```

### Size

- Typical: ~70 bytes
- Max (with full precision): ~100 bytes
- Limit: 255 bytes (TLV content field)

---

## File Summary

| File | Status | Purpose |
|------|--------|---------|
| `BeaconService.swift` | ✓ | Core ping/pong logic |
| `BeaconViewModel.swift` | ✓ | UI state management |
| `PeerLocation.swift` | ✓ | Location data model |
| `BeaconView.swift` | ✓ | Main map + list UI |
| `TrackingView.swift` | ✓ | Full-screen tracking |
| `CompassMapView.swift` | ✓ | Map with heading |
| `PingWaveAnimation.swift` | ✓ | Animations |
| `HapticManager.swift` | ✓ | Haptic feedback |
| `LocationStateManager.swift` | ✓ | Heading support added |
| `BLEService.swift` | ✓ | RSSI + peer methods |
| `ChatViewModel.swift` | ✓ | BeaconService config |
| `ChatViewModel+PrivateChat.swift` | ✓ | Message routing |
| `ContentView.swift` | ✓ | Beacon button |

---

## Testing Checklist

### Basic Flow
- [ ] Ping button sends [PING] to favorites
- [ ] [PONG] response received and parsed
- [ ] Location appears on map
- [ ] RTT calculated correctly

### TrackingView
- [ ] Opens when tapping map pin
- [ ] Direction arrow points correctly
- [ ] Arrow rotates with device heading
- [ ] Proximity mode triggers when close

### Haptics
- [ ] Ping started feedback
- [ ] Response received feedback
- [ ] Proximity level change feedback

### Edge Cases
- [ ] GPS disabled on peer
- [ ] No favorites in range
- [ ] Peer disconnects during ping
- [ ] Multiple rapid pings
