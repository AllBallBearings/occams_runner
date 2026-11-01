# OccamsRunner — Claude Instructions

## TODO

- [ ] **Milestone Collection Mode** — Add a pre-run picker for "Precise" vs "Milestone" collection. Milestone treats each coin as a vertical plane (2ft left/right, 2ft up/down, no depth check) so runners collect coins as they pass through without exact coordinate matching. Full implementation plan saved in memory: `project_milestone_collection.md`. A per-quest `CollectionMode` (Phone Touch / Body Touch) now exists in `CollectionEngine.swift`; add Milestone as a third case there instead of a separate picker.
