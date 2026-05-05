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


MATERIALS: dict[str, tuple[float, float, float, float, float]] = {
    "black": (0.035, 0.028, 0.035, 0.0, 0.85),
    "shadow_brown": (0.18, 0.10, 0.07, 0.0, 0.8),
    "wood_dark": (0.36, 0.18, 0.08, 0.0, 0.72),
    "wood": (0.64, 0.35, 0.16, 0.0, 0.58),
    "wood_light": (0.90, 0.55, 0.25, 0.0, 0.5),
    "gold_dark": (0.77, 0.43, 0.05, 0.25, 0.38),
    "gold": (1.00, 0.67, 0.09, 0.35, 0.28),
    "gold_light": (1.00, 0.88, 0.28, 0.25, 0.22),
    "ruby_dark": (0.38, 0.01, 0.12, 0.05, 0.22),
    "ruby": (0.93, 0.02, 0.25, 0.05, 0.18),
    "ruby_light": (1.00, 0.28, 0.47, 0.02, 0.14),
    "emerald_dark": (0.02, 0.27, 0.19, 0.03, 0.25),
    "emerald": (0.06, 0.73, 0.34, 0.05, 0.18),
    "emerald_light": (0.43, 1.00, 0.45, 0.02, 0.15),
    "cyan_dark": (0.12, 0.45, 0.88, 0.05, 0.2),
    "cyan": (0.36, 0.84, 1.00, 0.05, 0.16),
    "cyan_light": (0.86, 0.98, 1.00, 0.02, 0.12),
    "ice": (0.28, 0.82, 1.00, 0.02, 0.18),
    "white": (0.96, 0.96, 0.92, 0.0, 0.4),
    "fire_red": (1.00, 0.15, 0.03, 0.0, 0.36),
    "fire_orange": (1.00, 0.47, 0.03, 0.0, 0.3),
    "fire_yellow": (1.00, 0.92, 0.12, 0.0, 0.25),
    "stone_dark": (0.25, 0.23, 0.23, 0.0, 0.86),
    "stone": (0.48, 0.45, 0.40, 0.0, 0.8),
    "stone_light": (0.73, 0.69, 0.61, 0.0, 0.74),
    "steel_dark": (0.34, 0.43, 0.50, 0.15, 0.34),
    "steel": (0.70, 0.82, 0.88, 0.20, 0.26),
    "label_green": (0.10, 0.46, 0.20, 0.0, 0.55),
    "label_yellow": (0.95, 0.77, 0.34, 0.0, 0.5),
    "skin": (0.95, 0.63, 0.45, 0.0, 0.5),
    "purple": (0.58, 0.20, 0.94, 0.02, 0.2),
    "blue": (0.22, 0.38, 0.95, 0.02, 0.22),
    "cork": (0.72, 0.43, 0.19, 0.0, 0.7),
}


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
    face_counts: list[int] = field(default_factory=list)
    indices: list[int] = field(default_factory=list)


@dataclass
class Model:
    name: str
    buckets: dict[str, MeshBucket] = field(default_factory=dict)

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

    def poly(self, material: str, points: list[tuple[float, float, float]], faces: list[tuple[int, ...]]) -> None:
        bucket = self.bucket(material)
        offset = len(bucket.points)
        bucket.points.extend(points)
        for face in faces:
            bucket.face_counts.append(len(face))
            bucket.indices.extend(offset + i for i in face)

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
            counts = ", ".join(str(i) for i in bucket.face_counts)
            indices = ", ".join(str(i) for i in bucket.indices)
            lines.extend(
                [
                    f'    def Mesh "{material}_mesh" (',
                    '        prepend apiSchemas = ["MaterialBindingAPI"]',
                    "    )",
                    "    {",
                    f"        point3f[] points = [{pts}]",
                    f"        int[] faceVertexCounts = [{counts}]",
                    f"        int[] faceVertexIndices = [{indices}]",
                    '        uniform token subdivisionScheme = "none"',
                    f"        rel material:binding = </Materials/{material}>",
                    "    }",
                ]
            )
        lines.extend(["}", "", 'def Scope "Materials"', "{"])
        for name, (r, g, b, metallic, roughness) in MATERIALS.items():
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
                    "            token outputs:surface",
                    "        }",
                    "    }",
                ]
            )
        lines.append("}")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def disk(model: Model, material: str, radius: int, depth: float, z: float, color_edge: str | None = None) -> None:
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            d = math.sqrt(x * x + y * y)
            if d <= radius + 0.15:
                mat = color_edge if color_edge and d > radius - 1.0 else material
                model.box(mat, (x, y, z), (1.05, 1.05, depth))


def model_coin() -> Model:
    m = Model("VoxelCoin")
    disk(m, "gold", 5, 1.4, 0, "gold_dark")
    disk(m, "gold_light", 3, 0.45, 0.95)
    for x in range(-2, 3):
        m.box("gold_dark", (x, 0, 1.25), (1, 1, 0.35))
    for y in range(-2, 3):
        m.box("gold_dark", (0, y, 1.25), (1, 1, 0.35))
    m.box("gold_light", (0, 2.5, 1.3), (1.3, 1, 0.45), rot=(0, 0, math.radians(45)))
    return m


def model_ruby() -> Model:
    m = Model("VoxelRubyGem")

    def p(x: float, y: float, z: float) -> tuple[float, float, float]:
        return (x * UNIT, y * UNIT, z * UNIT)

    front_z = 1.45
    back_z = -1.45
    outer = [
        (-3.4, 3.8),
        (3.4, 3.8),
        (5.4, 1.8),
        (5.4, -2.8),
        (3.2, -4.5),
        (-3.2, -4.5),
        (-5.4, -2.8),
        (-5.4, 1.8),
    ]
    table = [
        (-2.3, 2.6),
        (2.5, 2.6),
        (3.6, 1.2),
        (3.4, -2.0),
        (2.0, -3.2),
        (-2.2, -3.2),
        (-3.6, -1.8),
        (-3.5, 1.1),
    ]
    crown = p(0.2, 0.4, front_z + 0.35)

    m.poly("ruby_light", [p(*table[0], front_z), p(*table[1], front_z), crown, p(*table[7], front_z)], [(0, 1, 2, 3)])
    m.poly("ruby", [p(*table[1], front_z), p(*table[2], front_z), p(*table[3], front_z), crown], [(0, 1, 2, 3)])
    m.poly("ruby", [crown, p(*table[3], front_z), p(*table[4], front_z), p(*table[5], front_z)], [(0, 1, 2, 3)])
    m.poly("ruby_dark", [p(*table[7], front_z), crown, p(*table[5], front_z), p(*table[6], front_z)], [(0, 1, 2, 3)])

    facet_mats = ["ruby_light", "ruby", "ruby_dark", "ruby_dark", "ruby", "ruby_dark", "ruby", "ruby_light"]
    for i, mat in enumerate(facet_mats):
        j = (i + 1) % len(outer)
        m.poly(mat, [p(*outer[i], front_z - 0.1), p(*outer[j], front_z - 0.1), p(*table[j], front_z + 0.18), p(*table[i], front_z + 0.18)], [(0, 1, 2, 3)])

    side_mats = ["ruby_dark", "ruby_dark", "ruby_dark", "ruby_dark", "ruby_dark", "ruby_dark", "ruby", "ruby"]
    for i, mat in enumerate(side_mats):
        j = (i + 1) % len(outer)
        m.poly(mat, [p(*outer[i], front_z - 0.1), p(*outer[j], front_z - 0.1), p(*outer[j], back_z), p(*outer[i], back_z)], [(0, 1, 2, 3)])

    m.poly("ruby_dark", [p(x * 0.86, y * 0.86, back_z) for x, y in outer], [tuple(range(len(outer)))])
    m.poly("white", [p(-2.65, 2.9, front_z + 0.5), p(-1.75, 2.9, front_z + 0.5), p(-2.55, 0.45, front_z + 0.5), p(-3.15, 0.85, front_z + 0.5)], [(0, 1, 2, 3)])
    m.poly("ruby_light", [p(2.9, -2.55, front_z + 0.45), p(4.0, -2.55, front_z + 0.45), p(3.8, -3.3, front_z + 0.45), p(2.75, -3.3, front_z + 0.45)], [(0, 1, 2, 3)])
    return m


def add_crystal(m: Model, x: float, y: float, z: float, h: int, mats: tuple[str, str, str], scale: float = 1.0) -> None:
    for i in range(h):
        width = max(1, round((h - abs(i - h * 0.45)) * 0.35 * scale))
        mat = mats[2] if i > h * 0.55 else mats[1] if i > h * 0.25 else mats[0]
        m.box(mat, (x, y + i, z), (width, 1, width * 0.9))
    m.diamond((mats[2], mats[1], mats[0]), (x, y + h + 0.6, z), max(1.4, scale * 2.0), 2.2)


def model_emerald_cluster() -> Model:
    m = Model("VoxelEmeraldGem")
    add_crystal(m, 0, -4, 0, 9, ("emerald_dark", "emerald", "emerald_light"), 1.4)
    add_crystal(m, -5, -4, 1, 4, ("emerald_dark", "emerald", "emerald_light"), 0.9)
    add_crystal(m, 5, -4, 1, 4, ("emerald_dark", "emerald", "emerald_light"), 0.9)
    m.diamond(("emerald_light", "emerald", "emerald_dark"), (-2, -2, 3), 3, 4)
    m.diamond(("emerald", "emerald_light", "emerald_dark"), (4, -3, -3), 2.4, 3.8)
    return m


def model_loot_box() -> Model:
    m = Model("VoxelLootBox")
    m.box("wood_dark", (0, -2, 0), (12, 6, 5))
    m.box("wood", (0, 0, 0.2), (11, 7, 4.5))
    for x in (-5.8, 5.8):
        m.box("gold", (x, 0, 0), (1.2, 8.3, 5.4))
    m.box("gold", (0, -4.5, 0), (13, 1.1, 5.4))
    m.box("gold", (0, 1.2, 2.75), (13, 1.1, 0.8))
    m.box("gold_light", (0, 4.0, 0), (11, 1.0, 5.1))
    m.box("wood_light", (0, 3.0, 0), (10, 2.5, 4.5))
    m.box("gold", (0, -0.8, 3.25), (3.1, 3.0, 0.8))
    m.box("black", (0, -1.0, 3.75), (0.8, 1.5, 0.35))
    return m


def model_fireball() -> Model:
    m = Model("VoxelFireball")
    outer = [(-4, -4), (-3, -2), (-5, 0), (-3, 2), (-2, 5), (0, 4), (2, 6), (2, 2), (5, 1), (3, -2), (4, -4), (0, -5)]
    for x, y in outer:
        m.box("fire_red", (x, y, 0), (2.2, 2.2, 2.2), rot=(0, 0, math.radians((x + y) * 7)))
    mid = [(-2, -3), (-1, -1), (-2, 1), (0, 2), (1, 4), (2, 0), (3, -2), (1, -4)]
    for x, y in mid:
        m.box("fire_orange", (x, y, 0.2), (2.0, 2.0, 2.0), rot=(0, 0, math.radians((x - y) * 10)))
    inner = [(-1, -2), (0, -1), (1, 0), (0, 1), (-1, 1), (1, -2)]
    for x, y in inner:
        m.box("fire_yellow", (x, y, 0.55), (1.8, 1.8, 1.8))
    for x, y in [(-6, 3), (5, 4), (6, -1), (-5, -1)]:
        m.box("fire_orange", (x, y, 0), (0.9, 1.9, 0.9), rot=(0, 0, math.radians(25)))
    return m


def model_spinach_can() -> Model:
    m = Model("VoxelSpinachCan")
    for y in range(-5, 6):
        mat = "label_green" if -3 <= y <= 3 else "steel"
        disk(m, mat, 4, 1.6, y, "steel_dark" if abs(y) > 3 else None)
    m.box("label_yellow", (0, -1, 4.7), (7, 2.6, 0.4))
    m.box("skin", (0.3, -1, 5.05), (1.8, 1.2, 0.35))
    m.box("skin", (1.2, -0.1, 5.05), (1.1, 1.4, 0.35), rot=(0, 0, math.radians(-35)))
    for x in [-2, -1, 1, 2]:
        m.box("white", (x, 2.3, 5.1), (0.65, 0.7, 0.3))
        m.box("white", (x, -4.0, 5.1), (0.65, 0.7, 0.3))
    return m


def model_boulder() -> Model:
    m = Model("VoxelBoulder")
    rows = {
        -4: [(-2, 3), (-1, 3), (0, 3), (1, 3)],
        -3: [(-4, 2), (-2, 4), (1, 4)],
        -2: [(-5, 1), (-3, 5), (1, 5)],
        -1: [(-5, 2), (-3, 6)],
        0: [(-5, 2), (-4, 6), (2, 4)],
        1: [(-4, 4), (-1, 6)],
        2: [(-3, 5), (0, 5)],
        3: [(-2, 4), (1, 3)],
        4: [(-1, 3)],
    }
    for y, spans in rows.items():
        for start, end in spans:
            for x in range(start, end):
                d = math.sqrt((x * 0.8) ** 2 + y * y)
                mat = "stone_light" if x < -1 and y > 0 else "stone_dark" if x > 2 or y < -2 else "stone"
                m.box(mat, (x, y, 0), (1.05, 1.05, max(2.5, 8.0 - d)))
    for cx, cy, ang in [(-1.5, 1.7, -45), (2.2, -0.4, 25), (0.7, -2.2, -30)]:
        m.box("stone_dark", (cx, cy, 4.6), (0.45, 3.2, 0.35), rot=(0, 0, math.radians(ang)))
    return m


def model_diamond_gem() -> Model:
    m = Model("VoxelDiamondGem")
    for y, width in [(-4, 3), (-3, 5), (-2, 7), (-1, 9), (0, 11), (1, 9), (2, 7), (3, 5)]:
        for x in range(-width // 2, width // 2 + 1):
            mat = "cyan_light" if y > 0 and x < 1 else "cyan_dark" if x > 2 or y < -2 else "cyan"
            m.box(mat, (x, y, 0), (1, 1, 2.5))
    m.box("white", (-2.4, 1.9, 1.55), (3.8, 0.8, 0.35), rot=(0, 0, math.radians(15)))
    return m


def model_ice_sword() -> Model:
    m = Model("VoxelIceSword")
    for y in range(-2, 13):
        width = 1 if y > 8 else 2 if y > 4 else 3
        mat = "cyan_light" if y > 3 and y % 3 == 0 else "ice"
        m.box(mat, (0, y, 0), (width, 1, 1.4))
    m.diamond(("cyan_light", "ice", "cyan_dark"), (0, 13, 0), 2.0, 3.0)
    m.box("steel_dark", (0, -4.0, 0), (1.6, 4.5, 1.4))
    m.box("steel_dark", (0, -1.9, 0), (7.0, 1.0, 1.3))
    m.box("blue", (0, -6.6, 0), (2.1, 2.1, 1.3), rot=(0, 0, math.radians(45)))
    m.box("white", (0, -2.1, 0.8), (1.3, 1.3, 0.3), rot=(0, 0, math.radians(45)))
    return m


def model_bow_arrow() -> Model:
    m = Model("VoxelBowArrow")
    for y, x, ang in [(-5, -1.8, 15), (-3, -2.2, 8), (-1, -2.1, 2), (1, -1.7, -8), (3, -1.1, -16), (5, -0.3, -24)]:
        m.box("wood_light", (x, y, 0), (1.0, 3.3, 1.0), rot=(0, 0, math.radians(ang)))
    m.box("black", (-3.1, 0, 0), (0.35, 10.8, 0.35))
    m.box("wood_dark", (1.6, -0.5, 0), (0.9, 10.0, 0.9), rot=(0, 0, math.radians(5)))
    m.box("steel", (1.25, 4.8, 0), (1.6, 1.0, 1.1), rot=(0, 0, math.radians(45)))
    for i, x in enumerate([2.7, 3.6, 4.5]):
        m.box("wood_dark", (x, 0.2 + i * 0.4, 0), (0.45, 8.0, 0.45), rot=(0, 0, math.radians(10 - i * 6)))
        m.diamond(("cyan_light", "ice", "cyan_dark"), (x - 0.2, 4.6 + i * 0.4, 0), 1.0, 1.5)
    m.box("steel_dark", (3.8, -4.6, 0), (4.0, 4.4, 1.1), rot=(0, 0, math.radians(9)))
    m.box("steel", (3.8, -4.4, 0.45), (3.2, 3.6, 0.7), rot=(0, 0, math.radians(9)))
    return m


def model_potion_bottle() -> Model:
    m = Model("VoxelPotionBottle")
    for y, width in [(-5, 5), (-4, 7), (-3, 8), (-2, 8), (-1, 7), (0, 5), (1, 3)]:
        for x in range(-width // 2, width // 2 + 1):
            mat = "emerald_light" if y > -2 and x < 0 else "emerald_dark" if x > 2 else "emerald"
            m.box(mat, (x, y, 0), (1, 1, 2.4))
    m.box("cyan_light", (0, 1.6, 0), (4.5, 1.0, 2.6))
    m.box("cyan", (0, 2.9, 0), (3, 2.3, 2.2))
    m.box("cork", (0, 4.6, 0), (2.5, 2.3, 2.1))
    m.box("white", (-2.4, -1.3, 1.55), (0.7, 3.0, 0.35), rot=(0, 0, math.radians(-30)))
    return m


def model_jewel_cluster() -> Model:
    m = Model("VoxelJewelCluster")
    gems = [
        ("cyan", "cyan_light", "cyan_dark", -4, 2, 0, 2.2),
        ("emerald", "emerald_light", "emerald_dark", -5, -2, 0.3, 2.1),
        ("blue", "cyan", "cyan_dark", 0, -1, 0, 2.7),
        ("purple", "ruby_light", "ruby_dark", 4, 1, -0.2, 2.5),
        ("blue", "cyan", "purple", -3, -5, 0, 2.1),
        ("gold", "gold_light", "gold_dark", 5, -4, 0.2, 1.9),
        ("purple", "ruby_light", "ruby_dark", 1, -6, 0, 1.7),
    ]
    for a, b, c, x, y, z, r in gems:
        m.diamond((b, a, c), (x, y, z), r, r * 1.4)
    return m


MODELS = [
    model_coin,
    model_ruby,
    model_emerald_cluster,
    model_loot_box,
    model_fireball,
    model_spinach_can,
    model_boulder,
    model_diamond_gem,
    model_ice_sword,
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
            usda = tmpdir / f"{model.name}.usda"
            usdz = OUT_DIR / f"{model.name}.usdz"
            model.write_usda(usda)
            package_usdz(usda, usdz)
            usdz.chmod(0o644)
            print(usdz.relative_to(ROOT))


if __name__ == "__main__":
    main()
