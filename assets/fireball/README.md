# Fireball

Modeled in Blender 5.2.1 through the Blender MCP server at localhost:9876 from the supplied illustration. The asset has a rounded, faceted orange flame body, layered yellow and cream inner flames, a raised white spiral on both faces, and four floating embers. There is no pedestal.

## Files

- `../../OccamsRunner/Models/3DModels/Fireball.usdz`: bundled iPhone AR asset.
- `Fireball.blend`: editable Blender scene with separate preview lighting.
- `Fireball.glb`: portable export with the same geometry and materials.
- `Fireball-preview.png`: transparent Blender render.
- `Fireball-usdz-front.png` and `Fireball-usdz-rear.png`: renders after re-importing the delivered USDZ.
- `create_fireball.py`: reproducible modeling and export script; adjust ROOT when moving the repository.
- `verify_fireball.py`: USDZ re-import and render checks, run after the creation script.
- `validation.json` and `usdz-validation.txt`: geometry and Apple USDZ validation results.

## App integration

Choose **Fireball** in the AR asset tester's **Item** menu. It is scaled to 34 cm tall and positioned one meter in front of the camera using the existing asset preview placement. Star Coin remains the first preview selection and the default quest collectible. The older Voxel Fireball remains available as a separate asset.

The USDZ uses meters and Y-up coordinates. Its authored size is 25.75 cm wide, 29.5 cm tall, and 20.6 cm deep. The preview loader centers and scales it automatically. The flame is a static sculpted model with emissive materials; it does not require particles, textures, transparent surfaces, or an animation system. Emission keeps the core bright, while its appearance still varies with scene lighting. A surrounding bloom halo is not baked into the geometry.

## Validation

- One mesh, 2,752 triangles, 1,402 vertices, seven opaque USD Preview Surface materials.
- No non-manifold edges or degenerate faces; disconnected flame layers and embers are closed solids.
- USDZ re-import contains one mesh, all seven materials, and no camera or lights.
- Apple's `usdchecker --arkit` reports success; checker plugin diagnostics are retained in the log.
- Front and rear USDZ renders were inspected.
- The app built successfully for the iOS 26.5 simulator. Both focused tests passed: the bundled fireball loads with seven emissive PBR materials and real depth, and Star Coin remains the sole/default coin selection.
- Physical iPhone AR testing is still required.
