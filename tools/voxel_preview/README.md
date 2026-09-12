# Voxel Preview

Local browser viewer for the generated voxel assets.

Run it from the repository root:

```bash
python3 tools/voxel_preview/server.py --port 8765
```

Open:

```text
http://127.0.0.1:8765
```

The viewer renders live voxel data from `tools/generate_voxel_models.py`.
Assets are shown upright with a floating bob and vertical-axis spin for app-style
iteration. When the generator file changes, the browser reloads the selected
model automatically. The `USDZ` link points to the currently generated packaged
asset.
