#!/usr/bin/env python3
"""Generate ARKit-friendly voxel USDZ models for Occam's Runner.

The models are deliberately built from low-count box meshes and simple
faceted solids so they render reliably in SceneKit/RealityKit on-device.
"""

from __future__ import annotations

import math
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "OccamsRunner" / "Models" / "3DModels"
UNIT = 0.025


MATERIALS: dict[str, tuple[float, ...]] = {
    "black": (0.035, 0.028, 0.035, 0.0, 0.85),
    "wood": (0.64, 0.35, 0.16, 0.0, 0.58),
    "gold": (1.00, 0.73, 0.08, 0.35, 0.24),
    "chest_wood": (0.55, 0.22, 0.055, 0.0, 0.52, 0.88, 0.035),
    "chest_gold": (1.00, 0.64, 0.075, 0.18, 0.26, 0.90, 0.13),
    # The final two values are opacity and emissive strength. These materials
    # are designed for models assembled from individually visible glass cubes.
    "ruby": (0.93, 0.02, 0.25, 0.05, 0.18),
    "emerald": (0.06, 0.73, 0.34, 0.05, 0.18),
    "cyan": (0.36, 0.84, 1.00, 0.05, 0.16),
    "diamond_cyan": (0.36, 0.84, 1.00, 0.05, 0.16, 0.68, 0.18),
    "glass": (0.68, 0.90, 1.00, 0.02, 0.18),
    "ice": (0.28, 0.82, 1.00, 0.02, 0.18),
    "white": (0.96, 0.96, 0.92, 0.0, 0.4),
    "fire_red": (1.00, 0.15, 0.03, 0.0, 0.36, 0.90, 0.08),
    "fire_orange": (1.00, 0.47, 0.03, 0.0, 0.30, 0.86, 0.18),
    "fire_yellow": (1.00, 0.92, 0.12, 0.0, 0.25, 0.90, 0.32),
    "fire_white": (1.00, 0.96, 0.62, 0.0, 0.18, 0.94, 0.50),
    "stone": (0.48, 0.45, 0.40, 0.0, 0.8),
    "steel_dark": (0.34, 0.43, 0.50, 0.15, 0.34),
    "steel": (0.70, 0.82, 0.88, 0.20, 0.26),
    "label_green": (0.10, 0.46, 0.20, 0.0, 0.55),
    "label_yellow": (0.95, 0.77, 0.34, 0.0, 0.5),
    "skin": (0.95, 0.63, 0.45, 0.0, 0.5),
    "purple": (0.58, 0.20, 0.94, 0.02, 0.2),
    "blue": (0.22, 0.38, 0.95, 0.02, 0.22),
    "bow_string": (0.30, 0.16, 0.07, 0.0, 0.72),
    "sword_guard": (0.24, 0.39, 0.48, 0.12, 0.30),
    "sword_grip": (0.07, 0.13, 0.28, 0.02, 0.54),
    "cork": (0.72, 0.43, 0.19, 0.0, 0.7),
}


def material_properties(values: tuple[float, ...], name: str = "") -> tuple[float, float, float, float, float, float, float]:
    """Return color, surface, translucency, and glow values for a cube material."""
    r, g, b, metallic, roughness = values[:5]
    if len(values) > 6:
        return r, g, b, metallic, roughness, values[5], values[6]

    if name.startswith(("ruby", "emerald", "cyan", "purple", "blue")):
        opacity, emissive = 0.78, 0.18
    elif name.startswith(("glass", "ice")):
        opacity, emissive = 0.58, 0.16
    elif name.startswith("fire"):
        opacity, emissive = 0.84, 0.48
    elif name.startswith("gold") or name in ("label_yellow", "white"):
        opacity, emissive = 0.88, 0.14
    elif name.startswith(("steel", "stone")):
        opacity, emissive = 0.86, 0.035
    elif name.startswith("wood") or name in ("cork", "shadow_brown"):
        opacity, emissive = 0.90, 0.025
    elif name in ("black", "label_green", "skin"):
        opacity, emissive = 0.90, 0.02
    else:
        opacity, emissive = 0.86, 0.06
    return r, g, b, metallic, roughness, opacity, emissive


def rotate_point(point: tuple[float, float, float], rot: tuple[float, float, float]) -> tuple[float, float, float]:
    x, y, z = point
    rx, ry, rz = rot
    if rx:
        c, s = math.cos(rx), math.sin(rx)
        y, z = y * c - z * s, y * s + z * c
    if ry:
        c, s = math.cos(ry), math.sin(ry)
        x, z = x * c + z * s, -x * s + z * c
    if rz:
        c, s = math.cos(rz), math.sin(rz)
        x, y = x * c - y * s, x * s + y * c
    return x, y, z


@dataclass
class MeshBucket:
    points: list[tuple[float, float, float]] = field(default_factory=list)
    normals: list[tuple[float, float, float]] = field(default_factory=list)
    face_counts: list[int] = field(default_factory=list)
    indices: list[int] = field(default_factory=list)


@dataclass
class Model:
    name: str
    buckets: dict[str, MeshBucket] = field(default_factory=dict)
    voxels: dict[tuple[int, int, int], str] = field(default_factory=dict)
    cube_scale: float = 1.0
    detail_factor: float = 1.5

    def bucket(self, material: str) -> MeshBucket:
        if material not in self.buckets:
            self.buckets[material] = MeshBucket()
        return self.buckets[material]

    def box(
        self,
        material: str,
        center: tuple[float, float, float],
        size: tuple[float, float, float],
        rot: tuple[float, float, float] = (0.0, 0.0, 0.0),
    ) -> None:
        cx, cy, cz = (center[0] * UNIT, center[1] * UNIT, center[2] * UNIT)
        sx, sy, sz = (size[0] * UNIT, size[1] * UNIT, size[2] * UNIT)
        local = [
            (-sx / 2, -sy / 2, -sz / 2),
            (sx / 2, -sy / 2, -sz / 2),
            (sx / 2, sy / 2, -sz / 2),
            (-sx / 2, sy / 2, -sz / 2),
            (-sx / 2, -sy / 2, sz / 2),
            (sx / 2, -sy / 2, sz / 2),
            (sx / 2, sy / 2, sz / 2),
            (-sx / 2, sy / 2, sz / 2),
        ]
        pts = []
        for p in local:
            px, py, pz = rotate_point(p, rot)
            pts.append((px + cx, py + cy, pz + cz))
        self.poly(material, pts, [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)])

    def voxel(self, material: str, x: int, y: int, z: int) -> None:
        self.voxels[(x, y, z)] = material

    def as_cube_assembly(self, cube_scale: float = 0.86) -> Model:
        """Render occupied cells as separate translucent building blocks."""
        self.cube_scale = cube_scale
        self.detail_factor = 1.0
        return self

    def increase_voxel_detail(self, factor: float | None = None) -> None:
        """Resample occupancy onto a denser grid while enlarging the asset."""
        factor = self.detail_factor if factor is None else factor
        if factor == 1.0:
            return
        if not self.voxels:
            return
        source = self.voxels
        minimum = tuple(min(point[index] for point in source) for index in range(3))
        maximum = tuple(max(point[index] for point in source) for index in range(3))
        source_size = tuple(maximum[index] - minimum[index] + 1 for index in range(3))
        target_size = tuple(round(size * factor) for size in source_size)

        source_maps: list[list[int]] = []
        for axis, size in enumerate(source_size):
            copies = [target_size[axis] // size] * size
            extras = target_size[axis] % size
            # Add the non-integer rows from the centre outward.  This keeps
            # symmetric source models symmetric after resampling.
            order = sorted(range(size), key=lambda index: (abs(index - (size - 1) / 2), index))
            for index in order[:extras]:
                copies[index] += 1
            source_maps.append([minimum[axis] + index for index, count in enumerate(copies) for _ in range(count)])

        self.voxels = {
            (minimum[0] + x, minimum[1] + y, minimum[2] + z): material
            for x in range(target_size[0])
            for y in range(target_size[1])
            for z in range(target_size[2])
            if (material := source.get((source_maps[0][x], source_maps[1][y], source_maps[2][z]))) is not None
        }

    def build_voxel_mesh(self) -> None:
        if not self.voxels:
            return

        if self.cube_scale < 1.0:
            for (x, y, z), material in sorted(self.voxels.items()):
                self.box(material, (x, y, z), (self.cube_scale,) * 3)
            return

        corners = {
            "left": [(-0.5, -0.5, -0.5), (-0.5, -0.5, 0.5), (-0.5, 0.5, 0.5), (-0.5, 0.5, -0.5)],
            "right": [(0.5, -0.5, -0.5), (0.5, 0.5, -0.5), (0.5, 0.5, 0.5), (0.5, -0.5, 0.5)],
            "bottom": [(-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, -0.5, 0.5), (-0.5, -0.5, 0.5)],
            "top": [(-0.5, 0.5, -0.5), (-0.5, 0.5, 0.5), (0.5, 0.5, 0.5), (0.5, 0.5, -0.5)],
            "back": [(-0.5, -0.5, -0.5), (-0.5, 0.5, -0.5), (0.5, 0.5, -0.5), (0.5, -0.5, -0.5)],
            "front": [(-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5)],
        }
        directions = [
            ((-1, 0, 0), "left"),
            ((1, 0, 0), "right"),
            ((0, -1, 0), "bottom"),
            ((0, 1, 0), "top"),
            ((0, 0, -1), "back"),
            ((0, 0, 1), "front"),
        ]

        for (x, y, z), material in sorted(self.voxels.items()):
            for (dx, dy, dz), face_name in directions:
                if (x + dx, y + dy, z + dz) in self.voxels:
                    continue
                pts = [((x + px) * UNIT, (y + py) * UNIT, (z + pz) * UNIT) for px, py, pz in corners[face_name]]
                self.poly(material, pts, [(0, 1, 2, 3)])

    def poly(self, material: str, points: list[tuple[float, float, float]], faces: list[tuple[int, ...]]) -> None:
        bucket = self.bucket(material)
        for face in faces:
            face_points = [points[index] for index in face]
            ax, ay, az = face_points[0]
            bx, by, bz = face_points[1]
            cx, cy, cz = face_points[2]
            ux, uy, uz = bx - ax, by - ay, bz - az
            vx, vy, vz = cx - ax, cy - ay, cz - az
            nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            length = math.sqrt(nx * nx + ny * ny + nz * nz)
            normal = (nx / length, ny / length, nz / length)
            offset = len(bucket.points)
            bucket.points.extend(face_points)
            bucket.normals.extend([normal] * len(face_points))
            bucket.face_counts.append(len(face))
            bucket.indices.extend(range(offset, offset + len(face_points)))

    def diamond(self, materials: tuple[str, str, str], center: tuple[float, float, float], radius: float, height: float) -> None:
        cx, cy, cz = (center[0] * UNIT, center[1] * UNIT, center[2] * UNIT)
        r, h = radius * UNIT, height * UNIT
        top = (cx, cy + h / 2, cz)
        bottom = (cx, cy - h / 2, cz)
        ring = [(cx - r, cy, cz), (cx, cy, cz - r * 0.75), (cx + r, cy, cz), (cx, cy, cz + r * 0.75)]
        face_mats = [materials[0], materials[1], materials[2], materials[1]]
        for i in range(4):
            self.poly(face_mats[i], [top, ring[i], ring[(i + 1) % 4]], [(0, 1, 2)])
            self.poly(face_mats[(i + 1) % 4], [bottom, ring[(i + 1) % 4], ring[i]], [(0, 1, 2)])

    def normalize(self) -> None:
        pts = [p for bucket in self.buckets.values() for p in bucket.points]
        min_x, max_x = min(p[0] for p in pts), max(p[0] for p in pts)
        min_y, max_y = min(p[1] for p in pts), max(p[1] for p in pts)
        min_z, max_z = min(p[2] for p in pts), max(p[2] for p in pts)
        dx, dy, dz = -(min_x + max_x) / 2, -(min_y + max_y) / 2, -(min_z + max_z) / 2
        for bucket in self.buckets.values():
            bucket.points = [(x + dx, y + dy, z + dz) for x, y, z in bucket.points]

    def write_usda(self, path: Path) -> None:
        self.build_voxel_mesh()
        self.normalize()
        safe = self.name
        lines = [
            "#usda 1.0",
            "(",
            f'    defaultPrim = "{safe}"',
            "    metersPerUnit = 1",
            '    upAxis = "Y"',
            ")",
            "",
            f'def Xform "{safe}" (',
            '    kind = "component"',
            ")",
            "{",
        ]
        for material, bucket in self.buckets.items():
            pts = ", ".join(f"({x:.6f}, {y:.6f}, {z:.6f})" for x, y, z in bucket.points)
            normals = ", ".join(f"({x:.6f}, {y:.6f}, {z:.6f})" for x, y, z in bucket.normals)
            counts = ", ".join(str(i) for i in bucket.face_counts)
            indices = ", ".join(str(i) for i in bucket.indices)
            lines.extend(
                [
                    f'    def Mesh "{material}_mesh" (',
                    '        prepend apiSchemas = ["MaterialBindingAPI"]',
                    "    )",
                    "    {",
                    f"        point3f[] points = [{pts}]",
                    f'        normal3f[] normals = [{normals}] (interpolation = "faceVarying")',
                    f"        int[] faceVertexCounts = [{counts}]",
                    f"        int[] faceVertexIndices = [{indices}]",
                    '        uniform token subdivisionScheme = "none"',
                    f"        rel material:binding = </Materials/{material}>",
                    "    }",
                ]
            )
        lines.extend(["}", "", 'def Scope "Materials"', "{"])
        for name, values in MATERIALS.items():
            r, g, b, metallic, roughness, opacity, emissive = material_properties(values, name)
            lines.extend(
                [
                    f'    def Material "{name}"',
                    "    {",
                    f"        token outputs:surface.connect = </Materials/{name}/PreviewSurface.outputs:surface>",
                    f'        def Shader "PreviewSurface"',
                    "        {",
                    '            uniform token info:id = "UsdPreviewSurface"',
                    f"            color3f inputs:diffuseColor = ({r:.4f}, {g:.4f}, {b:.4f})",
                    f"            float inputs:metallic = {metallic:.4f}",
                    f"            float inputs:roughness = {roughness:.4f}",
                    f"            float inputs:opacity = {opacity:.4f}",
                    f"            color3f inputs:emissiveColor = ({r * emissive:.4f}, {g * emissive:.4f}, {b * emissive:.4f})",
                    "            token outputs:surface",
                    "        }",
                    "    }",
                ]
            )
        lines.append("}")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def cube(model: Model, material: str, x: float, y: float, z: float = 0.0) -> None:
    model.voxel(material, round(x), round(y), round(z))


def cube_assembly(name: str, cube_scale: float = 0.84) -> Model:
    return Model(name).as_cube_assembly(cube_scale=cube_scale)


def centered_layers(count: int) -> list[float]:
    start = -(count // 2)
    return list(range(start, start + count))


def voxel_sphere(model: Model, material: str, radius: int, scale: tuple[float, float, float] = (1, 1, 1)) -> None:
    sx, sy, sz = scale
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                d = math.sqrt((x / sx) ** 2 + (y / sy) ** 2 + (z / sz) ** 2)
                if d <= radius + 0.25:
                    cube(model, material, x, y, z)


def voxel_beveled_cube(model: Model, material: str, radius: int, bevel: int = 3) -> None:
    limit = radius * 3 - bevel
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                if abs(x) + abs(y) + abs(z) <= limit:
                    cube(model, material, x, y, z)


def voxel_chamfered_box(
    model: Model,
    material: str,
    center: tuple[int, int, int],
    half_size: tuple[int, int, int],
    bevel: int = 2,
) -> None:
    """Fill a box while trimming its corners into stepped voxel chamfers."""
    cx, cy, cz = center
    hx, hy, hz = half_size
    for x in range(-hx, hx + 1):
        for y in range(-hy, hy + 1):
            for z in range(-hz, hz + 1):
                corner = (
                    max(0, abs(x) - (hx - bevel))
                    + max(0, abs(y) - (hy - bevel))
                    + max(0, abs(z) - (hz - bevel))
                )
                if corner <= bevel:
                    cube(model, material, cx + x, cy + y, cz + z)


def add_gem_ribbon(model: Model, material: str, radius: int = 6) -> None:
    """Add the stepped corner bands and sparse glints from the concept sheet."""
    for step in range(-4, 5):
        cube(model, material, -radius, step, radius - 1)
        cube(model, material, -radius + 1, step, radius)
        cube(model, material, step, radius, radius - 1)
    for x, y in [(-2, 4), (-1, 3), (0, 2), (1, 1), (2, 0), (1, -1)]:
        cube(model, material, x, y, radius + 1)


def voxel_gem_prism(model: Model, material: str) -> None:
    """Build the stout, octagonal-cut gemstones shown in the asset sheet."""
    layers = [
        (-6, 1, 1),
        (-5, 3, 3),
        (-4, 4, 4),
        (-3, 5, 4),
        (-2, 5, 4),
        (-1, 5, 4),
        (0, 5, 4),
        (1, 5, 4),
        (2, 5, 4),
        (3, 5, 4),
        (4, 4, 4),
        (5, 3, 3),
        (6, 2, 2),
    ]
    for y, radius_x, radius_z in layers:
        for x in range(-radius_x, radius_x + 1):
            for z in range(-radius_z, radius_z + 1):
                if abs(x) / radius_x + abs(z) / radius_z <= 1.65:
                    cube(model, material, x, y, z)


def voxel_diamond_shape(model: Model, material: str) -> None:
    layers = {
        5: 3,
        4: 5,
        3: 6,
        2: 7,
        1: 7,
        0: 6,
        -1: 5,
        -2: 4,
        -3: 3,
        -4: 2,
        -5: 1,
    }
    for y, radius in layers.items():
        for x in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                if abs(x) + abs(z) <= radius + 1:
                    cube(model, material, x, y, z)


def voxel_flame_lobe(model: Model, material: str, cx: int, cy: int, cz: int, rx: float, ry: float, rz: float) -> None:
    for x in range(math.floor(cx - rx), math.ceil(cx + rx) + 1):
        for y in range(math.floor(cy - ry), math.ceil(cy + ry) + 1):
            for z in range(math.floor(cz - rz), math.ceil(cz + rz) + 1):
                d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 + ((z - cz) / rz) ** 2
                taper = max(0.35, 1.0 - max(0, y - cy) / (ry * 1.4))
                if d <= taper:
                    cube(model, material, x, y, z)


def voxel_disk(model: Model, material: str, radius: int, depth: int, z_offset: float = 0.0) -> None:
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            if math.sqrt(x * x + y * y) <= radius + 0.15:
                for z in centered_layers(depth):
                    cube(model, material, x, y, z + z_offset)


def voxel_ring(model: Model, material: str, radius: int, depth: int, z_offset: float = 0.0) -> None:
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            d = math.sqrt(x * x + y * y)
            if radius - 1.0 <= d <= radius + 0.2:
                for z in centered_layers(depth):
                    cube(model, material, x, y, z + z_offset)


def voxel_line(model: Model, material: str, start: tuple[int, int], end: tuple[int, int], z: float = 0.0) -> None:
    x0, y0 = start
    x1, y1 = end
    steps = max(abs(x1 - x0), abs(y1 - y0))
    if steps == 0:
        cube(model, material, x0, y0, z)
        return
    for i in range(steps + 1):
        x = round(x0 + (x1 - x0) * i / steps)
        y = round(y0 + (y1 - y0) * i / steps)
        cube(model, material, x, y, z)


def voxel_line_thick(model: Model, material: str, start: tuple[int, int], end: tuple[int, int], depth: int = 3) -> None:
    for z in centered_layers(depth):
        voxel_line(model, material, start, end, z=z)


def voxel_stack(model: Model, material: str, x: int, y: int, depth: int = 3, z_offset: int = 0) -> None:
    for z in centered_layers(depth):
        cube(model, material, x, y, z + z_offset)


def voxel_polyline_points(points: list[tuple[int, int]]) -> set[tuple[int, int]]:
    pixels: set[tuple[int, int]] = set()
    if len(points) == 1:
        return {points[0]}
    for start, end in zip(points, points[1:]):
        x0, y0 = start
        x1, y1 = end
        steps = max(abs(x1 - x0), abs(y1 - y0))
        if steps == 0:
            pixels.add((x0, y0))
            continue
        for step in range(steps + 1):
            x = round(x0 + (x1 - x0) * step / steps)
            y = round(y0 + (y1 - y0) * step / steps)
            pixels.add((x, y))
    return pixels


def carve_front_line(model: Model, points: list[tuple[int, int]], layers: int = 1, width: int = 0) -> None:
    pixels = voxel_polyline_points(points)
    if width:
        pixels = {
            (x + dx, y + dy)
            for x, y in pixels
            for dx in range(-width, width + 1)
            for dy in range(-width, width + 1)
            if abs(dx) + abs(dy) <= width
        }
    for x, y in pixels:
        candidates = sorted(z for px, py, z in model.voxels if px == x and py == y)
        for z in candidates[-layers:]:
            model.voxels.pop((x, y, z), None)


def stamp_pixels(model: Model, material: str, pixels: set[tuple[int, int]], face_z: int, thickness: int = 2) -> None:
    for offset in range(thickness):
        z = face_z + offset if face_z > 0 else face_z - offset
        for x, y in pixels:
            cube(model, material, x, y, z)


def model_ruby() -> Model:
    m = cube_assembly("VoxelRubyGem")
    voxel_chamfered_box(m, "ruby", (0, 0, 0), (6, 6, 6), bevel=2)
    add_gem_ribbon(m, "ruby")
    return m


def model_emerald_cluster() -> Model:
    m = cube_assembly("VoxelEmeraldGem")
    voxel_chamfered_box(m, "emerald", (0, 0, 0), (6, 6, 6), bevel=2)
    add_gem_ribbon(m, "emerald")
    return m


def build_loot_box(name: str, lid_angle_degrees: float) -> Model:
    m = cube_assembly(name, cube_scale=0.86)

    # Hollow lower chest. The open top and actual inner floor make the cavity
    # darken naturally under lighting without a baked shadow material.
    for x in range(-8, 9):
        for z in range(-4, 5):
            for y in (-6, -5):
                cube(m, "chest_wood", x, y, z)
    for x in range(-8, 9):
        for y in range(-5, 0):
            for z in (-4, -3, 3, 4):
                cube(m, "chest_wood", x, y, z)
    for x in (-8, -7, 7, 8):
        for y in range(-5, 0):
            for z in range(-3, 4):
                cube(m, "chest_wood", x, y, z)

    # One-cube gold rails define the rim, base, and corners while leaving the
    # wood panels exposed on every side.
    for x in range(-8, 9):
        for z in (-4, 4):
            cube(m, "chest_gold", x, 0, z)
            cube(m, "chest_gold", x, -6, z)
    for z in range(-4, 5):
        for x in (-8, 8):
            cube(m, "chest_gold", x, 0, z)
            cube(m, "chest_gold", x, -6, z)
    for x in (-8, 8):
        for z in (-4, 4):
            for y in range(-6, 1):
                cube(m, "chest_gold", x, y, z)

    # A raised front frame surrounds the recessed wood panel.
    for x in range(-8, 9):
        for y in (-6, 0):
            cube(m, "chest_gold", x, y, 5)
    for x in (-8, 8):
        for y in range(-6, 1):
            cube(m, "chest_gold", x, y, 5)

    # Front plank relief, narrow center strap, and compact keyhole latch.
    for y in (-4, -2):
        for x in range(-7, 8):
            cube(m, "chest_wood", x, y, 5)
    for y in range(-5, 1):
        cube(m, "chest_gold", 0, y, 5)
    for x in range(-1, 2):
        for y in range(-4, -1):
            cube(m, "chest_gold", x, y, 6)
    for x, y in [(0, -2), (0, -3)]:
        cube(m, "black", x, y, 6)

    # Build a closed barrel shell in local coordinates, then rotate it open
    # around the rear rim. Rounding keeps every component on the voxel grid.
    lid_arch = {-4: 0, -3: 2, -2: 4, -1: 5, 0: 5, 1: 5, 2: 4, 3: 2, 4: 0}
    lid_angle = math.radians(lid_angle_degrees)
    lid_cos, lid_sin = math.cos(lid_angle), math.sin(lid_angle)

    def open_lid_point(x: int, y: int, z: int) -> tuple[int, int, int]:
        dz = z + 4
        return (
            x,
            round(y * lid_cos - dz * lid_sin),
            round(y * lid_sin + dz * lid_cos - 4),
        )

    # Connected shell layers avoid gaps introduced when the rotated points
    # snap back to the integer grid.
    for x in range(-7, 8):
        for thickness in (0, -1, -2):
            transformed = [
                open_lid_point(x, lid_arch[z] + thickness, z)
                for z in sorted(lid_arch)
            ]
            for py, pz in voxel_polyline_points([(point[1], point[2]) for point in transformed]):
                cube(m, "chest_wood", x, py, pz)

    # Stepped gold end arches share the same hinge transform as the shell.
    for x in (-8, 8):
        for thickness in (0, -1, -2):
            transformed = [
                open_lid_point(x, lid_arch[z] + thickness, z)
                for z in sorted(lid_arch)
            ]
            for py, pz in voxel_polyline_points([(point[1], point[2]) for point in transformed]):
                cube(m, "chest_gold", x, py, pz)

    # Hinge and lip rails plus raised wooden slats across the curved lid.
    for x in range(-8, 9):
        for z in (-4, 4):
            px, py, pz = open_lid_point(x, lid_arch[z], z)
            cube(m, "chest_gold", px, py, pz)
        for z in (-2, 0, 2):
            px, py, pz = open_lid_point(x, lid_arch[z] + 1, z)
            cube(m, "chest_wood", px, py, pz)

    # Rear hinges remain visible as the chest turns.
    for x in (-5, -4, 4, 5):
        cube(m, "chest_gold", x, 0, -5)
    return m


def model_loot_box() -> Model:
    return build_loot_box("VoxelLootBox", lid_angle_degrees=0)


def model_loot_box_open() -> Model:
    return build_loot_box("VoxelLootBoxOpen", lid_angle_degrees=-74)


def model_fireball() -> Model:
    m = cube_assembly("VoxelFireball", cube_scale=0.86)
    body_profile = {
        -9: 5,
        -8: 7,
        -7: 8,
        -6: 9,
        -5: 9,
        -4: 9,
        -3: 9,
        -2: 9,
        -1: 8,
        0: 8,
        1: 8,
        2: 7,
        3: 7,
        4: 6,
        5: 5,
        6: 5,
        7: 4,
        8: 4,
        9: 3,
        10: 3,
        11: 2,
        12: 1,
        13: 0,
    }

    def ellipse_pixels(cx: int, cy: int, rx: float, ry: float) -> set[tuple[int, int]]:
        pixels: set[tuple[int, int]] = set()
        for x in range(math.floor(cx - rx), math.ceil(cx + rx) + 1):
            for y in range(math.floor(cy - ry), math.ceil(cy + ry) + 1):
                if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                    pixels.add((x, y))
        return pixels

    # A hollow, nearly round teardrop keeps the asset volumetric without the
    # dense horizontal banding caused by filling every interior cell.
    for y, radius in body_profile.items():
        for x in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                radial = math.sqrt(x * x + z * z) / max(radius, 1)
                if radial > 1.04 or (radius > 2 and radial < 0.58):
                    continue
                material = "fire_red" if y <= -8 else "fire_orange"
                cube(m, material, x, y, z)

    def face_cell(axis: str, sign: int, tangent: int, y: int) -> tuple[int, int, int] | None:
        if axis == "z":
            candidates = [point for point in m.voxels if point[0] == tangent and point[1] == y]
            if not candidates:
                return None
            return max(candidates, key=lambda point: point[2] * sign)
        candidates = [point for point in m.voxels if point[2] == tangent and point[1] == y]
        if not candidates:
            return None
        return max(candidates, key=lambda point: point[0] * sign)

    def paint_faces(material: str, pixels: set[tuple[int, int]], depth: int = 1) -> None:
        for axis, sign in (("z", 1), ("x", 1), ("z", -1), ("x", -1)):
            for tangent, y in pixels:
                surface = face_cell(axis, sign, tangent, y)
                if surface is None:
                    continue
                x, _, z = surface
                for layer in range(depth):
                    px = x - layer * sign if axis == "x" else x
                    pz = z - layer * sign if axis == "z" else z
                    cube(m, material, px, y, pz)

    # Repeat the icon's three hot regions around all four principal faces so
    # the recognizable motif survives the in-app pirouette.
    tongue_width = {
        -5: 1, -4: 2, -3: 2, -2: 2, -1: 2, 0: 2, 1: 1,
        2: 1, 3: 1, 4: 1, 5: 1, 6: 0, 7: 0, 8: 0, 9: 0,
    }
    central_tongue = {
        (tangent, y)
        for y, width in tongue_width.items()
        for tangent in range(-width, width + 1)
    }
    central_core = {
        (tangent, y)
        for y, width in {2: 1, 3: 1, 4: 0, 5: 0}.items()
        for tangent in range(-width, width + 1)
    }
    side_heat = ellipse_pixels(-5, -3, 1.8, 2.2) | ellipse_pixels(5, -3, 1.8, 2.2)
    side_cores = ellipse_pixels(-5, -3, 1.2, 1.3) | ellipse_pixels(5, -3, 1.2, 1.3)

    def pixel_border(pixels: set[tuple[int, int]]) -> set[tuple[int, int]]:
        expanded = {
            (x + dx, y + dy)
            for x, y in pixels
            for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1))
        }
        return expanded - pixels

    motif = central_tongue | side_heat
    paint_faces("fire_red", pixel_border(motif), depth=1)
    paint_faces("fire_yellow", motif, depth=1)
    paint_faces("fire_white", central_core | side_cores, depth=1)

    # Eight small detached embers provide the reference's negative-space
    # rhythm without forming long trails around the body.
    ember_specs = [
        (0, 7, 8, "fire_orange"), (5, 8, 5, "fire_red"),
        (8, 6, 0, "fire_orange"), (5, 10, -5, "fire_red"),
        (0, 8, -7, "fire_orange"), (-5, 9, -5, "fire_red"),
        (-8, 6, 0, "fire_orange"), (-5, 10, 5, "fire_red"),
    ]
    for x, y, z, material in ember_specs:
        cube(m, material, x, y, z)
        cube(m, material, x, y + 1, z)
    return m


def model_spinach_can() -> Model:
    m = cube_assembly("VoxelSpinachCan", cube_scale=0.86)
    radius = 5
    for y in range(-7, 8):
        material = "label_yellow" if -2 <= y <= 2 else "label_green"
        for x in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                distance = math.sqrt(x * x + z * z)
                if radius - 1.15 <= distance <= radius + 0.2:
                    cube(m, material, x, y, z)
    for y in (-8, 8):
        for x in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                distance = math.sqrt(x * x + z * z)
                if distance <= radius + 0.15:
                    cube(m, "steel", x, y, z)
    for y in range(-6, 7):
        cube(m, "label_green", -5, y, 1)
        cube(m, "label_green", 5, y, 1)
    return m


def model_boulder() -> Model:
    m = cube_assembly("VoxelBoulder", cube_scale=0.82)
    rx, ry, rz = 9.0, 8.2, 4.5
    for x in range(-9, 10):
        for y in range(-8, 9):
            for z in range(-4, 5):
                d = (x / rx) ** 2 + (y / ry) ** 2 + (z / rz) ** 2
                if d <= 1.0:
                    cube(m, "stone", x, y, z)

    # Cracks are recessed into the front surface so lighting creates the dark
    # read without introducing a separate painted shadow material.
    crack_lines = [
        [(-5, 6), (-3, 3), (-5, 1), (-4, -2), (-6, -5)],
        [(-3, 3), (0, 2), (2, 4), (5, 3)],
        [(-1, 1), (1, -1), (0, -4), (2, -6)],
        [(1, -1), (4, -2), (6, -5)],
        [(-8, -1), (-6, -2), (-4, -4)],
        [(3, 1), (5, -1)],
    ]
    for line in crack_lines:
        carve_front_line(m, line, layers=2, width=1)
        for x, y in voxel_polyline_points(line):
            candidates = sorted(z for px, py, z in m.voxels if px == x and py == y)
            if candidates:
                cube(m, "black", x, y, candidates[-1] + 1)
    for x, y in [(-6, 5), (-7, 3), (-5, -6), (-1, 6), (3, 6), (6, 1), (6, -3), (0, -7)]:
        carve_front_line(m, [(x, y), (x, y)], layers=1)
    return m


def model_diamond_gem() -> Model:
    m = cube_assembly("VoxelDiamondGem", cube_scale=0.84)
    layers = {5: 3, 4: 5, 3: 6, 2: 7, 1: 7, 0: 6, -1: 5, -2: 4, -3: 3, -4: 2, -5: 1}
    for y, radius in layers.items():
        for x in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                if abs(x) + abs(z) <= radius + 1:
                    cube(m, "diamond_cyan", x, y, z)
    return m


def model_sword() -> Model:
    m = cube_assembly("VoxelSword", cube_scale=0.80)

    # Long, narrow blade with the reference's left-side stepped spine and
    # clipped point.  It is intentionally much longer than the grip so it reads
    # as a sword instead of a dagger in the rotating preview.
    blade_profile: dict[int, tuple[int, int]] = {}
    for y in range(0, 43):
        if y < 31:
            blade_profile[y] = (-2, 3)
        elif y < 36:
            blade_profile[y] = (-2, 2)
        elif y < 40:
            blade_profile[y] = (-1, 2)
        else:
            blade_profile[y] = (0, 1)

    for y, (left, right) in blade_profile.items():
        for x in range(left, right + 1):
            for z in centered_layers(3):
                cube(m, "ice", x, y, z)

    for y in range(3, 31, 2):
        left = blade_profile[y][0]
        for z in centered_layers(3):
            cube(m, "ice", left - 1, y, z)

    # Remove front-center cubes to form the blade's recessed channel without
    # using a separate darker material that would rotate incorrectly in AR.
    for line in [[(1, 4), (1, 18), (3, 25)], [(-1, 22), (1, 19)]]:
        carve_front_line(m, line, layers=1)
        for x, y in voxel_polyline_points(line):
            for z in (1, 2, 3):
                cube(m, "cyan", x, y, z)

    # Straight crossguard with stepped ends, matching the straight-on concept.
    for x in range(-9, 10):
        for y in (-2, -1):
            for z in centered_layers(3):
                cube(m, "sword_guard", x, y, z)
    for x, y in [(-10, -1), (-9, 0), (-8, 0), (-7, 0), (7, 0), (8, 0), (9, 0), (10, -1), (-8, -3), (-7, -3), (7, -3), (8, -3)]:
        for z in centered_layers(3):
            cube(m, "sword_guard", x, y, z)

    # Dark wrapped handle with a tapered neck between guard and pommel.
    for y in range(-13, -2):
        width = 1 if y % 2 else 2
        if y in (-12, -11, -4, -3):
            width = 1
        for x in range(-width, width + 1):
            for z in centered_layers(3):
                cube(m, "sword_grip", x, y, z)
    for x, y in [(-2, -6), (2, -8), (-2, -10)]:
        for z in centered_layers(3):
            cube(m, "sword_guard", x, y, z)

    voxel_chamfered_box(m, "ice", (0, -16, 0), (2, 2, 2), bevel=1)
    return m


def model_bow_arrow() -> Model:
    m = cube_assembly("VoxelBowArrow", cube_scale=0.86)
    bow_points = [(-5, -9), (-7, -6), (-8, -2), (-8, 2), (-7, 6), (-5, 9)]
    for start, end in zip(bow_points, bow_points[1:]):
        voxel_line_thick(m, "wood", start, end, depth=3)
    voxel_line_thick(m, "bow_string", (-5, -9), (-5, 9), depth=1)
    for y in range(-8, 10):
        for z in centered_layers(2):
            cube(m, "wood", 2, y, z)
    for x, y in [(2, 10), (1, 9), (3, 9), (0, 8), (4, 8)]:
        for z in centered_layers(2):
            cube(m, "steel", x, y, z)
    for x, y in [(1, -8), (3, -8), (0, -9), (4, -9)]:
        for z in centered_layers(2):
            cube(m, "ice", x, y, z)
    for x in range(8, 12):
        for y in range(-8, 1):
            for z in centered_layers(3):
                cube(m, "wood", x, y, z)
    for x in range(8, 12):
        for z in centered_layers(3):
            cube(m, "steel", x, 1, z)
    for x in (9, 10):
        for y in range(2, 6):
            cube(m, "wood", x, y, 0)
        cube(m, "ice", x, 6, 0)
        cube(m, "white", x, 2, 0)
    return m


def model_potion_bottle() -> Model:
    m = cube_assembly("VoxelPotionBottle", cube_scale=0.82)
    body_radii = {-6: 3, -5: 5, -4: 6, -3: 6, -2: 6, -1: 6, 0: 5, 1: 4, 2: 3}
    for y, radius in body_radii.items():
        for x in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                distance = math.sqrt(x * x + z * z)
                is_shell = radius - 1.2 <= distance <= radius + 0.15
                is_cap = y in (-6, 2) and distance <= radius + 0.15
                if is_shell or is_cap:
                    cube(m, "glass", x, y, z)
    for y in range(3, 7):
        for x in range(-2, 3):
            for z in range(-2, 3):
                distance = math.sqrt(x * x + z * z)
                if 0.8 <= distance <= 2.2:
                    cube(m, "glass", x, y, z)
    for y in (7, 8):
        for x in range(-2, 3):
            for z in range(-2, 3):
                if abs(x) + abs(z) <= 3:
                    cube(m, "cork", x, y, z)
    return m


def model_jewel_cluster() -> Model:
    m = cube_assembly("VoxelJewelCluster", cube_scale=0.80)

    def cut_gem(material: str, cx: int, cy: int, radius: int, height: int, depth: int = 4) -> None:
        for yy in range(-height, height + 1):
            row_radius = max(1, round(radius * (1.0 - abs(yy) / (height + 1)) + 1))
            for x in range(-row_radius, row_radius + 1):
                for z in centered_layers(depth):
                    if abs(x) + abs(yy) * 0.45 <= row_radius + 0.75:
                        cube(m, material, cx + x, cy + yy, z)
        for line in [[(cx - radius + 1, cy), (cx, cy + height)], [(cx, cy + height), (cx + radius - 1, cy)], [(cx, cy - height), (cx, cy + height)]]:
            carve_front_line(m, line, layers=1)

    cut_gem("emerald", 0, -4, 4, 7, depth=5)
    cut_gem("blue", -8, 4, 3, 3, depth=4)
    cut_gem("cyan", 0, 8, 4, 2, depth=4)
    cut_gem("purple", 9, 4, 3, 3, depth=4)

    # Tiny bottom points visible in the reference.
    for material, x, y in [("blue", -8, 0), ("purple", 9, 0), ("cyan", 0, 5)]:
        voxel_stack(m, material, x, y, depth=3)
    return m


MODELS = [
    model_ruby,
    model_emerald_cluster,
    model_loot_box,
    model_loot_box_open,
    model_fireball,
    model_spinach_can,
    model_boulder,
    model_diamond_gem,
    model_sword,
    model_bow_arrow,
    model_potion_bottle,
    model_jewel_cluster,
]


def package_usdz(usda: Path, usdz: Path) -> None:
    usdz.unlink(missing_ok=True)
    if shutil.which("usdzip"):
        result = subprocess.run(["usdzip", "--arkitAsset", str(usda), str(usdz)], text=True, capture_output=True)
        if result.returncode != 0:
            result = subprocess.run(["usdzip", str(usdz), str(usda)], text=True, capture_output=True)
        if result.returncode == 0:
            return
        raise RuntimeError(result.stderr or result.stdout)
    raise RuntimeError("usdzip is required to create aligned USDZ packages")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        for factory in MODELS:
            model = factory()
            model.increase_voxel_detail()
            usda = tmpdir / f"{model.name}.usda"
            usdz = OUT_DIR / f"{model.name}.usdz"
            model.write_usda(usda)
            package_usdz(usda, usdz)
            usdz.chmod(0o644)
            print(usdz.relative_to(ROOT))


if __name__ == "__main__":
    main()
