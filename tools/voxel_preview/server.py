#!/usr/bin/env python3
"""Local browser preview for generated voxel assets."""

from __future__ import annotations

import argparse
import importlib.util
import json
import mimetypes
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse


ROOT = Path(__file__).resolve().parents[2]
STATIC_DIR = Path(__file__).resolve().parent / "static"
GENERATOR_PATH = ROOT / "tools" / "generate_voxel_models.py"
MODELS_DIR = ROOT / "OccamsRunner" / "Models" / "3DModels"
ASSETS_DIR = ROOT / "assets"


def load_generator():
    module_name = f"voxel_generator_preview_{time.time_ns()}"
    spec = importlib.util.spec_from_file_location(module_name, GENERATOR_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GENERATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        sys.modules.pop(module_name, None)


def model_payload(name: str) -> dict:
    generator = load_generator()
    factories = {factory().name: factory for factory in generator.MODELS}
    if name not in factories:
        raise KeyError(name)

    model = factories[name]()
    model.increase_voxel_detail()
    voxels = [
        {"x": x, "y": y, "z": z, "material": material}
        for (x, y, z), material in sorted(model.voxels.items())
    ]
    bounds = {
        axis: [min(v[axis] for v in model.voxels), max(v[axis] for v in model.voxels)]
        for axis in range(3)
    }
    palette = {
        material: {
            "color": properties[:3],
            "metallic": properties[3],
            "roughness": properties[4],
            "opacity": properties[5],
            "emissive": properties[6],
        }
        for material, values in generator.MATERIALS.items()
        for properties in [generator.material_properties(values, material)]
    }

    return {
        "name": model.name,
        "usdz": f"{model.name}.usdz",
        "sourceMtime": GENERATOR_PATH.stat().st_mtime,
        "voxelCount": len(voxels),
        "unit": generator.UNIT,
        "cubeScale": model.cube_scale,
        "bounds": {
            "x": bounds[0],
            "y": bounds[1],
            "z": bounds[2],
        },
        "palette": palette,
        "voxels": voxels,
    }


def list_models() -> dict:
    generator = load_generator()
    return {
        "sourceMtime": GENERATOR_PATH.stat().st_mtime,
        "models": [factory().name for factory in generator.MODELS],
    }


class PreviewHandler(BaseHTTPRequestHandler):
    server_version = "VoxelPreview/1.0"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[voxel-preview] {self.address_string()} - {fmt % args}")

    def send_json(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path: Path, content_type: str | None = None) -> None:
        if not path.exists() or not path.is_file():
            self.send_error(404)
            return
        data = path.read_bytes()
        guessed = content_type or mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", guessed)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        try:
            if path == "/api/models":
                self.send_json(list_models())
                return

            if path == "/api/model":
                name = parse_qs(parsed.query).get("name", ["VoxelRubyGem"])[0]
                self.send_json(model_payload(name))
                return

            if path.startswith("/usdz/"):
                filename = Path(path.removeprefix("/usdz/")).name
                self.send_file(MODELS_DIR / filename, "model/vnd.usdz+zip")
                return

            if path == "/asset/assets.png":
                self.send_file(ASSETS_DIR / "assets.png", "image/png")
                return

            if path in ("", "/"):
                self.send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
                return

            static_path = (STATIC_DIR / path.lstrip("/")).resolve()
            if STATIC_DIR.resolve() in static_path.parents:
                self.send_file(static_path)
                return

            self.send_error(404)
        except KeyError as error:
            self.send_json({"error": f"Unknown model: {error.args[0]}"}, status=404)
        except Exception as error:
            self.send_json({"error": str(error)}, status=500)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the voxel preview viewer.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), PreviewHandler)
    print(f"Voxel preview running at http://{args.host}:{args.port}")
    print("Edit tools/generate_voxel_models.py and the browser preview will reload automatically.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
