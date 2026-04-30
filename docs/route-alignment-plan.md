# Route Alignment + AR Recording Plan

## Checklist

- [x] Remove manual alignment controls and coordinator offsets.
- [x] Make recording AR-first with the camera full screen.
- [x] Move recording map into a compact lower-corner preview.
- [x] Show live AR feature points while recording.
- [x] Gate route sampling behind GPS, heading, AR tracking, feature density, and mapping readiness.
- [x] Capture a route-start reference with GPS, heading, AR camera transform, feature count, tracking score, mapping status, and timestamp.
- [x] Replace confidence-only quest startup with go-to-start, scan-start-area, localized, and low-confidence lifecycle states.
- [x] Keep route geometry and collectibles hidden until localization is locked.
- [x] Expand start-placement debug output with coordinate-space and AR tracking facts.
- [x] Always record with tight sampling.
- [x] Simplify AR route path rendering to cap SceneKit path segment load while preserving dense route data.
- [x] Add model, readiness, localization, and simplifier tests.

## Field-Tuning Notes

- Current GPS start gate is 3 m.
- Tight sampling records roughly every 0.3 m.
- A 3 mile route is expected to produce about 16,100 dense samples before render simplification.
- Rendered AR path segments are capped at 1,500; dense samples remain available for interpolation and localization diagnostics.
