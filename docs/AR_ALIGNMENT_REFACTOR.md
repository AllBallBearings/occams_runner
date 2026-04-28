# AR Route Alignment Refactor — Working Notes

Branch: `claude/ar-route-alignment-b5sjh`

## Goal

Replace the current "place every coin in `routeGroupNode` at run start, freeze the
group transform, hope the alignment was right" approach with a **per-item
just-in-time anchored placement** model.

The user's hard constraint (do not violate): every collectible must feel like it
exists at a real-world location. Once a player can see an item, they can orbit it,
back up to it, and inspect it from any angle. That requires every visible item to
be parented to its own `ARAnchor` and never repositioned afterward.

## The conceptual model

Per-item lifecycle (runtime state, not persisted):

- `pending`   — known by progress along the route, not yet visible. No `SCNNode`,
               no `ARAnchor`. Best-guess world pose computed on demand from
               `routeGroupNode.simdWorldTransform * item.resolvedLocalPosition()`.
- `committed` — user crossed the **commit horizon** (~12 m). At that moment we
               (a) take the current best-guess pose, (b) create a custom
               `QuestItemAnchor` (or `QuestBoxAnchor`) at that pose, (c) ARKit's
               `renderer(_:didAdd:for:)` callback fires, and we attach the coin/box
               geometry to the anchor's node. From this moment forward the node is
               a real anchored object; ARKit handles tracking, we never move it.
- `collected` — committed item that the player picked up. Node fades+removes;
               anchor is removed from the session. Persisted in `QuestItem.collected`.

**Implementation note:** the `pending`/`committed` distinction is encoded
implicitly by the presence of an entry in `itemAnchors` / `boxAnchors`. An item
is `committed` iff its anchor is in the dictionary, otherwise it's `pending`.
A separate `ItemPlacementState` enum was tried first but turned out to duplicate
the anchor dictionary, so it was removed during simplification review.

`routeGroupNode` survives the refactor but only as a **logical reference frame** —
no nodes are parented to it for runtime visibility. It carries the current
"where did the recorded route's local origin land in the AR world" transform, and
is moved by manual-alignment gestures (today) and by GPS+heading / `ARGeoAnchor`
(future steps). The path-ribbon nodes can stay parented to it because they're an
alignment guide that should follow alignment changes.

## Why placement state is NOT on the persisted model

In the conversation I floated adding `pending`/`committed` to `QuestItem`. On
re-examination this is wrong:

1. Placement state is a *runtime* concept (depends on the camera's current
   position relative to a per-session ARKit reference frame). It has no meaning
   when the quest is sitting in `~/Documents` waiting to be played.
2. Persisting it would force decoder updates and pollute `Route3DView` and the
   map preview — both of which iterate `quest.items` and should always see *all*
   items regardless of AR state.
3. Existing tests construct `QuestItem(type:routeProgress:)` and check `.collected`.
   Adding a new field to the persisted model needlessly invalidates them.

So placement state lives **in `ARCoordinator`** as `[UUID: ItemPlacementState]`
dictionaries (`itemPlacement`, `boxPlacement`). When an item is committed, we
also stash it in `coinNodes` / `boxNodes` (existing dictionaries) so the rest of
the code — collection engine, distance arrow, etc. — keeps working with no
changes to its protocol.

## What changes in this slice (Step 1+2 of the plan)

### `Models/RouteModels.swift`
**No changes.** Persisted model stays clean.

### `Views/AR/ARCoordinator.swift` (the bulk of this work)

1. New private types at file scope:
   - `enum ItemPlacementState { case pending, committed }`
   - `final class QuestItemAnchor: ARAnchor` — carries the `UUID` of the item it
     represents.
   - `final class QuestBoxAnchor: ARAnchor` — same, for boxes.

2. New properties:
   - `private var itemPlacement: [UUID: ItemPlacementState]`
   - `private var boxPlacement:  [UUID: ItemPlacementState]`
   - `private let commitHorizonMeters: Float = 12.0`

3. Behaviour changes:
   - `buildCoinNodes(forceRebuild:)` and `buildBoxNodes(forceRebuild:)` no longer
     pre-spawn any node geometry. They reconcile state: tear down committed
     nodes/anchors for items that were collected/removed, but never *create* a
     node for a `pending` item.
   - New `evaluateCommitHorizon()` runs each AR frame in `.running` mode.
     For every pending item it computes the best-guess world pose via
     `routeGroupNode.simdWorldTransform * resolvedLocalPosition()`, compares to
     the camera position, and if within the horizon adds a `QuestItemAnchor` to
     the session.
   - `renderer(_:didAdd:for:)` (new) — when ARKit calls back with the node it
     created for our anchor, we attach the coin/box geometry there and register
     it in `coinNodes` / `boxNodes`.
   - Collection-time node removal also calls `arView.session.remove(anchor:)`
     so we don't leak anchors.
   - The route-transform freeze (`frozenRouteWorldTransform`) becomes a no-op
     for committed items — they're already independent of `routeGroupNode`.
     We keep it for now so any still-pending items behave identically to today
     until they commit.

### Views unaffected by this slice
- `Views/Route3DView.swift` — iterates all items, no AR concept. Untouched.
- `Views/QuestDetailView.swift`, map views — same.
- `Models/RouteModels.swift` — untouched.
- `Services/CollectionEngine.swift` — untouched. It already takes
  `coinWorldPositions` keyed by item id; world positions still resolve correctly
  whether the node is parented to `routeGroupNode` (legacy) or to an anchor's
  node (new).

## Slice 2 — GPS + heading rigid transform (LANDED)

Commit: `c87746a` "GPS+heading rigid transform as AR alignment seed".

**What it does:** at run start (and on each realign), compute a rigid transform
from the runner's current GPS+true-heading to the route's recorded
GPS+true-heading and use that as the *base pose* for `routeGroupNode`. Manual
alignment gestures are applied on top of this base, so the user's drag/rotate
becomes a fine adjustment instead of placing the route from AR-world origin
every time.

Key additions:
- `RecordedRoute.recordedHeadingDegrees: Double?` — captured at recording start
  (latched from the first `CLHeading` after `startRecording()`).
- `LocationService.currentHeadingDegrees` (`@Published`) — single source of
  heading; replaces the old per-view `HeadingManager` in `ARRunnerView`.
- `ARCoordinator.routeSeed: RouteSeed?` and `seedAlignmentFromGPSHeading(frame:)`.
- `applyManualAlignment` composes manual offsets on top of `routeSeed`.

Routes saved before Slice 2 have no recorded heading; the seed no-ops for those
and the user must align manually as before. Subsumes Slice 5 (compass-yaw
auto-rotate is now the default behaviour, not a separate quick-fix).

## Slice 4 — continuous seed refinement during the run (LANDED)

**What it does:** during `.running` mode, the coordinator refreshes
`routeSeed` from current GPS+heading on a 1 Hz throttle and re-applies it
to `routeGroupNode` via `applyManualAlignment()`. Each refresh is lowpassed
(α = 0.25, with shortest-arc yaw blend) so GPS jitter doesn't snap the
pending-coin spawn frame around. Already-committed items live on their
own ARAnchors and are completely unaffected — only items still in the
pending state pick up the improved localization.

**Removed:** `frozenRouteWorldTransform`. It was kept through Slice 1 as a
defensive freeze on `routeGroupNode` during `.running`, but committed
items are no longer parented to that node, so the freeze is dead weight.
Removing it is what enables the seed to keep refining mid-run.

Key additions in `ARCoordinator.swift`:
- `refineSeedFromGPSHeading(frame:)` — recomputes a candidate seed and
  blends it with the prior using `seedRefreshSmoothing`.
- `blendYaw(_:_:alpha:)` — shortest-arc angle interpolation.
- Throttle fields `lastSeedRefreshAt` / `seedRefreshInterval`.

## What is explicitly NOT in this slice

The remaining slice on the roadmap:

- **Slice 3: `ARGeoAnchor` path** for items where `ARGeoTrackingConfiguration`
  reports availability. Detect at run start; commit items as `ARGeoAnchor`
  instead of `QuestItemAnchor` where supported. Fall back to Slice 2 transform
  outside coverage.

## How to resume from here

1. Read this file.
2. `git log --oneline claude/ar-route-alignment-b5sjh ^main` to see what slices
   have already landed.
3. Run tests: `xcodebuild test -scheme OccamsRunner -destination 'platform=iOS Simulator,name=iPhone 15'` (or the project's equivalent).
4. Pick the next slice from the list above.

## On-device verification (cannot be done in this environment)

This codebase requires Xcode + a physical iOS device with a camera. The CLI
agent cannot exercise `ARWorldTrackingConfiguration` or the AR scene graph at
runtime — only static and unit-test verification is possible here. After landing
each slice, the user (or a Mac+device-equipped agent) should:

1. Record a short outdoor route.
2. Generate a quest, start the AR run.
3. Confirm coins do NOT all spawn at run start.
4. Confirm coins DO spawn one-by-one as the player approaches, and that walking
   around a spawned coin keeps it pinned in place.
5. Watch for orphaned anchors — `arView.session.currentFrame?.anchors.count`
   should track `coinNodes.count + boxNodes.count`.
