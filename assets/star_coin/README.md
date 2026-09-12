# Star coin

Created in Blender 5.2.1 through the Blender MCP server at localhost:9876, using the supplied coin image as a visual reference. Both faces have the same upright raised five-point star. The geometry includes a thick gold edge, chamfered raised rim, amber inset, and beveled star with a honey-gold border. No pedestal is included.

## Deliverables

- `../../OccamsRunner/Models/3DModels/StarCoin.usdz`: iPhone AR asset, one mesh with six standard metallic USD Preview Surface materials.
- `StarCoin.blend`: editable Blender scene and preview lighting.
- `StarCoin.glb`: additional portable PBR asset export.
- `StarCoin-preview.png`: transparent front three-quarter render.
- `StarCoin-reverse-usdz.png`: reverse render after importing the delivered USDZ.
- `create_star_coin.py`: reproducible modeling/export script, executed inside Blender. Adjust ROOT if moving the repository.

## AR dimensions and loading

The USDZ is Y-up, uses meters, and has its pivot at the center. Diameter is 0.26 m; maximum thickness across the raised stars is 0.05746 m. The star points upward along +Y and the faces point along +Z and -Z. It can spin around Y without additional pivot offsets.

StarCoin.usdz is included in the app target's Copy Bundle Resources. StarCoinAsset loads it for quest collectibles, 3D route previews, and the default Star Coin selection in the AR asset tester. Existing quests also use this coin; their saved item type and collection state are unchanged. Use environment lighting/reflections for the metallic shine. The included studio renders demonstrate the finish under controlled lighting; the apparent highlights will vary with AR lighting.

## Verification

- 5,060 triangles and 2,536 vertices; six opaque PBR materials, no external textures.
- Zero non-manifold edges and zero degenerate faces.
- Exact front/back vertex symmetry at six decimal places.
- USDZ re-import contains one mesh with six materials; reverse render inspected.
- Apple's `usdchecker --arkit` reports Success (the local checker also emits plugin registration diagnostics; full output retained).
- Native macOS SceneKit successfully loads the USDZ with one mesh and all six materials.
- Not yet tested on a physical iPhone.
