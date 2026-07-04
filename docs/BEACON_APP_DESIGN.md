# Beacon App Design — Map-First Pivot

> From "bitchat with a beacon sheet" to "Beacon: a map-first app that wraps
> all bitchat features." Owner's vision: profile-on-map identity, map as the
> home screen, side-drawer navigation for channels/people, bitchat features
> seamlessly wrapped, minimal monospace aesthetic.

## Navigation Shell (Phase B — next)

Root becomes `BeaconAppRoot`, a ZStack:

1. **Content layer** — `MapHomeView` (map-first home) or the existing
   `ContentView()` (full bitchat chat UI), switched by `BeaconNavModel.activePanel`.
2. **Drawer scrim** — translucent tap-to-dismiss overlay.
3. **BeaconDrawer** — slides from leading edge (280pt, spring):
   Map · Channels (#mesh, joined geohashes) · Favorites · Private chats (unread
   badges) · Settings.

`ContentView` embeds unmodified; channel selection flows through the existing
`LocationChannelsModel.select()` so the chat header/message list stay correct
with zero upstream-file changes. A single environment key
(`isEmbeddedInBeaconShell`) hides the now-redundant beacon header button.

New files: `Beacon/Navigation/BeaconNavModel.swift`, `BeaconAppRoot.swift`,
`BeaconDrawer.swift`, `BeaconDrawerRow.swift`, `Beacon/Map/MapHomeView.swift`,
`Utils/BeaconEnvironmentKeys.swift`. Modified: `BitchatApp.swift` (WindowGroup
body → `BeaconAppRoot()`), `ContentHeaderView.swift` (3 lines).

## Profile System (Phase A — shipped)

- `BeaconProfile` (`Services/BeaconProfile.swift`): avatar emoji + color,
  UserDefaults-persisted; display name IS the bitchat nickname (one identity).
- First-run setup (`Views/BeaconSetupView.swift`): full-screen overlay gate on
  first launch — name, emoji grid, color palette, "start beaconing". Rendered
  as a plain overlay (no sheet/cover) so it can't lose presentation races.
- Map identity: own position renders the avatar (emoji on chosen color);
  peers render an identity-colored bubble (same `Color(peerSeed:)` used for
  their nickname in chat) with their initial, transport ring (green BLE /
  purple relay), and an always-visible monospace name chip.

### Phase C sketch — avatar over the wire
`AnnouncementPacket` TLV `0x05 = avatarEmoji` (≤4 UTF-8 bytes + 2 TLV bytes;
decoder already skips unknown TLVs, so old clients are unaffected). Flow:
announce → `BLEAnnounceHandler` → peer identity store → map pins render the
peer's actual emoji instead of their initial.

## Map Home (Phase B)

Full-bleed map + floating chrome: hamburger (drawer), privacy indicator
(precision at a glance → settings), pill stack (beacon mode toggle, ping,
recenter). Favorites with locations are avatar pins; tap → tracking overlay
(existing full-screen TrackingView with compass/UWB/Found!). The current
`BeaconView` pieces map 1:1; it is retired once `MapHomeView` lands.

## Phasing

- **A (shipped)**: profile + first-run setup + avatar/name map pins + own
  avatar on user location. Screenshot-automation launch args
  (`-beacon.screenshotMode`, `-beacon.autoOpen`, `-beacon.autoOpenSettings`),
  DEBUG-only.
- **B (next)**: BeaconAppRoot shell — map home + drawer + embedded ContentView.
- **C**: avatar TLV broadcast; drawer absorbs LocationChannelsSheet; retire
  BeaconView sheet entry.

Upstream-merge cost stays minimal: B touches BitchatApp (WindowGroup body) and
3 lines of ContentHeaderView; C's ContentView change is a pure deletion.
