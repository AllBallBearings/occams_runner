# OccamsRunner — Claude Instructions

## TODO

- [ ] **Milestone Collection Mode** — Add a pre-run picker for "Precise" vs "Milestone" collection. Milestone treats each coin as a vertical plane (2ft left/right, 2ft up/down, no depth check) so runners collect coins as they pass through without exact coordinate matching. Full implementation plan saved in memory: `project_milestone_collection.md`.

- [ ] **Punch Boxes** — Along the quest route, place a brown 3D cube (SCNBox) at every 10th coin position. Design details:
  - **Placement**: At the route-progress position of every 10th coin, offset up to 4ft (1.22m) from the route centerline. The offset direction is a random clock-face angle (0–360°) in the horizontal plane, but the box must never be placed below the runner's ground plane (no negative Y offset from route altitude). Angles should vary between boxes so they feel scattered (e.g. 2:00, 8:00, 3:00).
  - **Appearance**: Brown `SCNBox` (~1ft cube), same node-building pipeline as coins. No collection via proximity — interaction only via fist punch.
  - **Hand tracking**: Use Vision framework (`VNDetectHumanHandPoseRequest`) on each AR camera frame to detect hand landmarks. Determine "fist" pose by checking finger curl (tip joints close to MCP joints). Project the detected fist's screen position into AR world space using a ray-cast or depth estimate to get a 3D world position.
  - **Collision / punch detection**: Each tick, if a fist pose is detected and the 3D fist position is within ~0.3m of a box node's world position, trigger the explosion. Optionally also detect a "punching motion" (rapid forward velocity of fist toward the box) to reduce false positives.
  - **Explosion effect**: On hit — play a particle burst (`SCNParticleSystem`) from the box position, then remove the box node. Haptic feedback (`UIImpactFeedbackGenerator` .heavy). Optional: reward points or a special item drop.
  - **Data model**: Add a `QuestBox` type (similar to `QuestItem`) with `id`, `routeProgress`, `clockAngleDegrees`, `radialOffsetMeters`. Store in `Quest`. Generate boxes when the quest is created or first loaded, not at record time.
  - **Key files to touch**: `RouteModels.swift` (QuestBox model), `CollectionEngine.swift` or new `BoxEngine.swift` (punch detection logic), `ARCoordinator.swift` (Vision hand pose request, box nodes, explosion), `QuestDetailView.swift` or quest generation logic (spawn boxes at every 10th coin).
