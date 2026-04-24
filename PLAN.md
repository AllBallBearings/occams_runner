# OccamsRunner — Implementation Plan

Use this file to continue implementation in a new session if tokens run out.

---

## Completed in Previous Session

### AR Route Alignment Fixes
- **Auto-orientation**: `ARCoordinator.autoOrientRoute(frame:)` uses GPS bearing + stored compass heading to rotate the route to match real-world direction. Formula: `R = routeStartBearingRad - compassRad + cameraHeadingInAR - arBearing`
- **Spiderweb fix**: `buildRoutePath()` limits route preview to first 300m during alignment mode (prevents all 3 miles rendering at once in wrong directions)
- **Start navigation**: `ARRunnerView.navigateToStartOverlay(route:)` shows orange directional arrow + distance to route start, visible when `alignmentState == .moveToStart`, disappears at 40m gate
- **Compass heading in samples**: `LocalRouteSample.compassHeading: Double?` stores magnetometer reading per AR sample; backwards-compatible with old recordings
- **Heading in all logs**: `LocationService` logs include `heading=NNN°` in geo samples, quality snapshots, and world map captures

### Files Changed
- `OccamsRunner/Views/AR/ARCoordinator.swift` — autoOrientRoute, buildRoutePath preview limit, autoBase math
- `OccamsRunner/Views/AR/ARRunnerContainerView.swift` — compassHeading prop threading
- `OccamsRunner/Views/AR/ARRunnerView.swift` — navigateToStartOverlay, bearingToRouteStart
- `OccamsRunner/Models/RouteModels.swift` — compassHeading on LocalRouteSample
- `OccamsRunner/Services/LocationService.swift` — heading capture, logging

---

## Completed in Current Session

### Background GPS Recording
- `OccamsRunner/Info.plist` — Added `UIBackgroundModes` with `location`
- `LocationService.startRecording()` — Sets `allowsBackgroundLocationUpdates = true`, disables idle timer (keeps screen on)
- `LocationService.stopRecording()` — Resets both to false/default
- `LocationService.handleAppBackgrounded()` — Logs the transition; ARKit pauses automatically
- `LocationService.handleAppForegrounded()` — Resumes AR session without `resetTracking` so it relocalizes
- `RecordRunView` — `@Environment(\.scenePhase)` observer calls the two handlers

### Recording Start Countdown
- `RecordRunView` — enum `CountdownPhase { idle, countdown, recording }`
- On START tap: calls `startRecording()` immediately, then shows 5-second countdown overlay
- Overlay shows: large countdown, "Hold phone steady", "Face forward at chest height", live tracking %
- Early exit: if tracking score ≥ 0.4 and ≥ 1 geo sample with ≥ 3 seconds elapsed, dismiss early
- Overlay animated fade-out when countdown ends

---

## Pending Work

### 1. Milestone Collection Mode (CLAUDE.md TODO)
Full plan in `memory/project_milestone_collection.md`. Pre-run picker for "Precise" vs "Milestone" collection. Milestone treats each coin as a vertical plane (2ft radius, no depth check).

### 2. Punch Boxes (CLAUDE.md TODO)
Brown SCNBox at every 10th coin position. Vision framework hand tracking for fist detection. Particle explosion on punch.

### 3. AR Alignment Guidance Overlay (Future)
During the AR alignment scanning phase (`alignmentState == .aligning`), show a brief overlay with directions:
- "Scan slowly — look at textured surfaces (walls, grass, pavement)"
- "Avoid sky and water"
- In `ARRunnerView.swift`, check `alignmentState` and show for first 8 seconds

---

## Key Architecture Notes for Cold-Start Agent

### Dual-Track Recording
- **geoTrack**: GPS `CLLocation` samples, stored as `GeoDraftSample`, keyed by `sampleId`
- **localTrack**: ARKit camera positions in recording session's coordinate space, stored as `LocalDraftSample`, correlated to geoTrack by `sampleId`
- Correlation: for each GPS fix, find nearest AR frame within 350ms tolerance

### AR Coordinate System
- ARKit +Y = gravity-up; horizontal plane has arbitrary rotation at session start
- `atan2(dx, -dz)` converts AR direction vector to angle from AR -Z (clockwise)
- Formula to align route: `R = routeStartBearingRad - compassRad + cameraHeadingInAR - arBearing`

### Background Location
- Requires both `UIBackgroundModes: location` in Info.plist AND `allowsBackgroundLocationUpdates = true`
- ARKit pauses in background — only GPS keeps running
- On foreground, call `arSession.run(config, options: [])` (no resetTracking) to try relocalizing

### Key Files
| File | Purpose |
|------|---------|
| `OccamsRunner/Services/LocationService.swift` | GPS + ARKit recording engine |
| `OccamsRunner/Views/AR/ARCoordinator.swift` | AR session delegate + scene management |
| `OccamsRunner/Views/AR/ARRunnerView.swift` | AR run SwiftUI shell + alignment HUD |
| `OccamsRunner/Views/AR/ARRunnerContainerView.swift` | UIViewRepresentable bridge |
| `OccamsRunner/Views/RecordRunView.swift` | Recording UI |
| `OccamsRunner/Models/RouteModels.swift` | All data models |
| `OccamsRunner/Info.plist` | App capabilities and permissions |
