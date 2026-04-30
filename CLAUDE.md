# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

iOS SwiftUI app that turns recorded running routes into AR coin-collection quests. Native Apple frameworks only (ARKit, SceneKit, CoreLocation, CoreMotion, AVFoundation, Vision, SwiftUI) — no external dependencies, no package manager. Requires Xcode 15+, iOS 17+; AR features require a physical device.

## Build and Test Commands

Open in Xcode (`open OccamsRunner.xcodeproj`) and Cmd+R / Cmd+U. From CLI:

```bash
# Unit tests
xcodebuild test \
  -project OccamsRunner.xcodeproj \
  -scheme OccamsRunner \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing OccamsRunnerTests

# UI tests
xcodebuild test \
  -project OccamsRunner.xcodeproj \
  -scheme OccamsRunner \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing OccamsRunnerUITests

# Single test class or method
xcodebuild test … -only-testing OccamsRunnerTests/QuestGeneratorTests
xcodebuild test … -only-testing OccamsRunnerTests/QuestGeneratorTests/testCoinSpacing
```

CI (`.github/workflows/test.yml`) runs unit tests then UI tests on macos-15 against an iPhone 16 simulator. UI tests gate on unit tests passing.

## Architecture

### Dual-track route model (`Models/RouteModels.swift`)

A `RecordedRoute` carries two parallel sample arrays:

- `geoTrack: [GeoRouteSample]` — GPS+barometer coordinates for map display and the GPS gate
- `localTrack: [LocalRouteSample]` — ARKit local-space (meters) coordinates for precise AR replay

Both arrays share a `progress` field in `[0, 1]`. **Route progress is the canonical placement coordinate** for everything in a quest — `QuestItem` and `QuestBox` store `routeProgress` only and resolve to a geo or local position via `route.geoSample(atProgress:)` / `route.localSample(atProgress:)`, which interpolate between samples. Never store absolute coordinates on quest items.

`RouteCaptureQuality.isReadyForPreciseReplay` decides whether AR replay is allowed: needs `matchedSampleRatio ≥ 0.65`, `averageFeaturePoints ≥ 75`, `averageTrackingScore ≥ 0.65`, and an encrypted world map. Thresholds are tuned for outdoor reality (less feature texture than indoors); see comments in `RouteCaptureQuality`.

### Persistence (`Services/DataStore.swift`)

Plain JSON files in the app's documents directory: `routes.json`, `quests.json`, `sessions.json`. ARKit world maps live as **sidecar binaries** (`worldmap_<routeId>.bin`) — they're 2–10 MB each so we keep them out of `routes.json`. `route(for:)` rehydrates the sidecar; `saveRoute` strips and writes it out separately.

The schema evolves via **custom `init(from decoder:)` on `RecordedRoute`, `Quest`, `RunSession`** that uses `decodeIfPresent` and defaults for newly added fields (`recordingMode` → `.vast`, `boxes` → `[]`, `isPaused` → `false`, heading fields → `nil`). When you add a field to one of these models you must add a matching `decodeIfPresent` line — otherwise older saved data fails to decode and the user appears to lose all their routes/quests/sessions.

`performOneTimeHardResetIfNeeded` is gated by `hardResetVersionKey` in UserDefaults and wipes all JSON files on first run after a breaking schema change. Use this (bump the key) only as a last resort when a backward-compatible decoder isn't feasible.

### Pure collection logic (`Services/CollectionEngine.swift`)

`CollectionEngine.evaluateCollections` is a static pure function: it takes camera position, items, coin world positions, pending IDs, and a tick serial, and returns IDs to collect plus a debug log string. **No ARKit, no timers, no I/O.** This is what `CollectionStateMachineTests` and `CollectionIntegrationTests` exercise. When changing collection semantics, change this function — don't add logic to `ARCoordinator` that reads quest state.

Collection radius is **0.15 m** (the half-foot diameter of the coin sphere). `QuestItem.collectionRadiusMeters` (1.524 m) is a separate, generous geo-space radius used elsewhere.

### AR pipeline (`Views/AR/ARCoordinator.swift`, ~1400 lines)

Two-phase alignment: (1) GPS gate — user must be within `startGateDistanceMeters` (3 m) of route start; (2) ARKit relocalization against the saved world map until smoothed confidence exceeds threshold and tracking is solid. State machine is `ARRunMode` × `ARAlignmentState` (`Models/ARRunMode.swift`).

`ARCoordinator` callback closures (`onAlignmentUpdate`, `onItemCollected`, …) are **`var`, not `let`**. `updateUIView` reassigns them on every SwiftUI render so callbacks always close over the live `@State`/`@EnvironmentObject` rather than the stale snapshot from `makeCoordinator`. Don't change these to `let`.

Both `statusTimer` and `collectionTimer` run on the main RunLoop so all `coinNodes` access stays single-threaded. Don't move coin/box node mutation off main.

`ManualAlignmentState` (`Models/ManualAlignmentState.swift`) is a **class** (reference type) shared between SwiftUI gesture handlers and `ARCoordinator` so both sides read/write the same instance without going through SwiftUI state diffing. Keep it a class.

Hand-pose detection uses `VNDetectHumanHandPoseRequest` throttled to ~10 fps via `handPoseInterval`. Box punch logic also lives in `ARCoordinator` with its own pending set (`pendingBoxIds`) parallel to coin collection.

### UI test data injection (`OccamsRunnerApp.swift`)

When `UI_TESTING=1` is in the launch environment, `OccamsRunnerApp` swaps in a `DataStore(directory:)` pointed at a per-PID temp directory so tests never touch real user data. With `LOAD_FIXTURE_ROUTES=1`, `loadUITestFixtures` injects two routes (one with a generated quest). The splash screen is also suppressed under `UI_TESTING`. UI tests must set both env vars in their launch arguments to get a deterministic state.

### Quest generation (`Services/QuestGenerator.swift`)

`generateItems(along:intervalFeet:)` walks `geoTrack` segments, accumulates distance, and emits a `QuestItem` every `intervalFeet` of arc length — the route-progress for each item is interpolated within the segment that crossed the threshold, so coin spacing is true distance, not point-index. `generateBoxes(from:)` places a `QuestBox` at every 10th coin in one of 9 grid slots (3 lateral × 3 vertical) on a vertical plane perpendicular to the route tangent.

### Tabs and views (`Views/`)

Four-tab `TabView` (`ContentView.swift`): Home, Routes, Quests, Settings. AR runner UI is `Views/AR/ARRunnerContainerView` → `ARRunnerView` (HUD) backed by `ARCoordinator`. The app uses a glassmorphism aesthetic (frosted `.ultraThinMaterial`, radial gradients) — see `AppDescriptionForRedesign.md` for the design language if you're touching UI.

## Open work (from prior CLAUDE.md TODOs)

- **Splash & icon image files** — code and asset catalog entries are in place; two PNGs must be added manually:
  - `OccamsRunner/Assets.xcassets/SplashImage.imageset/splash.png` — full splash (dark bg, orange/cyan aura, "OccamsRunner" wordmark, "Loading…")
  - `OccamsRunner/Assets.xcassets/AppIcon.appiconset/AppIcon.png` — 1024×1024 logo mark only (C + lightning bolt + runner with energy aura, no wordmark, dark bg with breathing room)

- **Milestone Collection Mode** — pre-run picker for "Precise" vs "Milestone". Milestone treats each coin as a vertical plane (±2 ft left/right, ±2 ft up/down, no depth check) so runners collect by passing through. Implementation plan in memory: `project_milestone_collection.md`.

- **Punch Boxes** — data model and quest generation are wired (`QuestBox` in `RouteModels.swift`, `QuestGenerator.generateBoxes`, box rendering in `ARCoordinator`). Remaining work is hand-pose-driven punch detection:
  - Use `VNDetectHumanHandPoseRequest` (already wired at 10 fps in `ARCoordinator`) to detect a fist (tip joints close to MCP joints).
  - Project the fist screen position into AR world space (raycast or depth estimate).
  - On each tick, if fist within ~0.3 m of a box's world position, trigger explosion: `SCNParticleSystem` burst, remove the node, `.heavy` `UIImpactFeedbackGenerator`. Optionally require forward-velocity to reduce false positives.
