# OccamsRunner

**Every jog is a quest 🗡️**

OccamsRunner transforms your running routes into AR treasure hunts. Record a route, generate a quest with virtual coins placed along the path, then go collect them in Augmented Reality on your next run.

---

## Features

- **Route Recording** — GPS + barometric altitude tracking with two precision modes
- **Quest Generation** — Auto-place virtual coins along any recorded route
- **AR Coin Collection** — Collect coins in real-time using ARKit while you run
- **3D Route Visualization** — View your routes in 3D with SceneKit
- **Pause & Resume** — Interrupt a run and pick up exactly where you left off
- **Procedural Audio** — Synthesized coin-collect chime, no audio assets needed

---

## Requirements

- **Xcode** 15 or later
- **iOS** 17+
- **Device**: iPhone with ARKit support (A9 chip or later)
- **Permissions**: Camera, Location (always), Motion & Fitness

> AR features require a physical device. Most non-AR functionality works in Simulator.

---

## Getting Started

```bash
git clone https://github.com/AllBallBearings/occams_runner.git
cd occams_runner
open OccamsRunner.xcodeproj
```

1. Select your target device or simulator in Xcode
2. Press **Cmd+R** to build and run

---

## How It Works

### 1. Record a Route
Open the **Record** tab and start a run. OccamsRunner logs GPS coordinates and barometric altitude at regular intervals using one of two spacing modes:

| Mode | Min Spacing | Best For |
|------|-------------|----------|
| **Tight** | ~1 ft | Stairs, indoor loops |
| **Vast** | ~16 ft | Outdoor runs |

### 2. Generate a Quest
From the **Routes** tab, open any route and create a quest. Coins are auto-placed at ~16 ft intervals along the route. You can also open the Quest Editor to fine-tune placement.

### 3. Run the Quest
Open the **Quests** tab, select a quest, and tap **Start AR Run**. Walk or run to the start of the route — the app aligns your AR session using the saved ARKit world map and GPS anchor. Coins appear as 3D objects in the world. Run through them to collect.

---

## Architecture

```
OccamsRunner/
├── Models/
│   ├── RouteModels.swift        # Core data types (routes, quests, sessions)
│   └── ARRunMode.swift          # AR state machine enum
├── Services/
│   ├── LocationService.swift    # GPS + barometer recording
│   ├── DataStore.swift          # JSON persistence
│   ├── QuestGenerator.swift     # Coin placement along routes
│   └── CollectionEngine.swift   # 3D proximity detection (pure function)
├── Views/
│   ├── RecordRunView.swift       # Live GPS recording UI
│   ├── RoutesListView.swift      # Saved routes list
│   ├── RouteDetailView.swift     # Route stats + 3D preview
│   ├── Route3DView.swift         # SceneKit 3D visualization
│   ├── QuestsListView.swift      # Active quests list
│   ├── QuestDetailView.swift     # Quest progress + run button
│   ├── QuestEditorView.swift     # Manual coin placement editor
│   └── AR/
│       ├── ARRunnerView.swift         # AR run HUD
│       ├── ARRunnerContainerView.swift
│       └── ARCoordinator.swift        # Core ARKit integration (~600 lines)
└── Audio/
    └── CoinSoundPlayer.swift    # Procedurally synthesized chime
```

**No external dependencies** — built entirely on native iOS frameworks: ARKit, SceneKit, CoreLocation, CoreMotion, AVFoundation, SwiftUI.

---

## Data Storage

All data is persisted locally to the device's documents directory as JSON:

- **Routes** — GPS + local AR coordinate samples, capture quality metrics
- **Quests** — Coin definitions tied to a route
- **Run Sessions** — Active run state (collected coins, paused position)
- **World Maps** — ARKit world map sidecar files (2–10 MB each) for precise AR relocation

---

## AR Alignment

When starting a quest run, the app uses a two-phase alignment process:

1. **GPS Gate** — Walk to within 40m of the route's start point
2. **ARKit Relocation** — The app attempts to relocalize using the saved world map. Once confidence exceeds 70% and tracking is solid, the AR frame locks and coins appear in the correct world positions.

If the AR frame drifts (e.g., after a pause), the app detects low confidence and prompts for realignment.

---

## Testing

```bash
# Run unit tests
xcodebuild test \
  -project OccamsRunner.xcodeproj \
  -scheme OccamsRunner \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing OccamsRunnerTests

# Run UI tests
xcodebuild test \
  -project OccamsRunner.xcodeproj \
  -scheme OccamsRunner \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing OccamsRunnerUITests
```

Or press **Cmd+U** in Xcode to run all tests.

### Test Coverage

| Suite | Focus |
|-------|-------|
| `RouteModelsTests` | Data model validation |
| `QuestGeneratorTests` | Coin placement logic |
| `DataStoreTests` | JSON persistence |
| `ARCoordinatorLogicTests` | AR state machine |
| `CollectionStateMachineTests` | Collection state transitions |
| `CollectionIntegrationTests` | Full AR collection pipeline |
| `NavigationFlowTests` | UI tab navigation (UI tests) |

CI runs on every push and pull request to `main` via GitHub Actions (macOS 15, iPhone 16 simulator).

---

## Roadmap

- [ ] **Milestone Collection Mode** — A more forgiving collection geometry where each coin acts as a vertical plane (±2 ft left/right, ±2 ft up/down, no depth check), so runners collect coins as they pass through rather than requiring precise point matching.

---

## License

See [LICENSE](LICENSE) for details.
