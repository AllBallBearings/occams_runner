"""Create the reference fireball in Blender; run through localhost:9876 MCP.

Only the asset collection is exported. No pedestal, lights, or camera in USDZ.
"""
import bpy
import bmesh
import json
import math
from pathlib import Path
from mathutils import Vector

ROOT = Path('/Users/jaredgoolsby/Documents/Github/occams_runner')
OUT = ROOT / 'assets/fireball'
OUT.mkdir(parents=True, exist_ok=True)
NAME = 'Fireball Studio'
old = bpy.data.scenes.get(NAME)
if old:
    for obj in list(old.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.scenes.remove(old)
scene = bpy.data.scenes.new(NAME)
bpy.context.window.scene = scene
scene.unit_settings.system = 'METRIC'
scene.unit_settings.scale_length = 1.0
asset = bpy.data.collections.new('Fireball Asset')
scene.collection.children.link(asset)

def linear(c):
    return c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4

def material(name, color, emission):
    rgb = tuple(linear(int(color[i:i+2], 16) / 255) for i in (0, 2, 4))
    mat = bpy.data.materials.new('Fireball | ' + name)
    mat.diffuse_color = (*rgb, 1)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value = (*rgb, 1)
    shader.inputs['Roughness'].default_value = .62
    shader.inputs['Specular IOR Level'].default_value = .18
    shader.inputs['Emission Color'].default_value = (*rgb, 1)
    shader.inputs['Emission Strength'].default_value = emission
    return mat

mats = [
    material('burnt orange outline', 'A6440B', .15),
    material('outer orange', 'F46A06', .30),
    material('tangerine bevel', 'FF920B', .40),
    material('gold flame', 'FFBC25', .50),
    material('yellow flame', 'FFDC59', .60),
    material('hot cream', 'FFF0A2', .70),
    material('white spiral', 'FFFDE3', .85),
]

# Reference-space contours, authored as closed, solid, curved volumes. X/Z
# follow the illustration; Y gives the flame its rounded, sculptural depth.
S = .00125
def point(pixel, depth, side=1):
    x, y = pixel
    return ((x - 164) * S, -side * depth, (174 - y) * S)

def mesh(name, verts, faces, material_ids):
    data = bpy.data.meshes.new(name)
    data.from_pydata(verts, [], faces)
    data.update()
    obj = bpy.data.objects.new(name, data)
    asset.objects.link(obj)
    for mat in mats:
        data.materials.append(mat)
    for face, mat_id in zip(data.polygons, material_ids):
        face.material_index = mat_id
    bm = bmesh.new()
    bm.from_mesh(data)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bmesh.ops.triangulate(bm, faces=list(bm.faces))
    bm.to_mesh(data)
    bm.free()
    return obj

def volume(name, contour, center, rings, bands, cap_material, side=1):
    """Closed contour with successively inset depth rings and triangulated caps."""
    n = len(contour)
    verts = []
    for scale, depth in rings:
        for x, y in contour:
            p = (center[0] + (x-center[0])*scale, center[1] + (y-center[1])*scale)
            verts.append(point(p, depth, side))
    faces = [tuple(reversed(range(n)))]
    ids = [bands[0]]
    for j in range(len(rings)-1):
        for i in range(n):
            faces.append((j*n+i, j*n+(i+1)%n, (j+1)*n+(i+1)%n, (j+1)*n+i))
            ids.append(bands[j])
    faces.append(tuple((len(rings)-1)*n+i for i in range(n)))
    ids.append(cap_material)
    return mesh(name, verts, faces, ids)

outer = [
    (170,278),(137,272),(111,261),(91,243),(75,218),(61,185),
    (80,204),(74,168),(84,143),(107,108),(117,125),(128,82),
    (150,61),(179,42),(174,77),(191,94),(200,111),(211,90),
    (230,114),(243,142),(242,174),(255,151),(260,180),
    (267,202),(256,229),(238,249),(207,264),
]
body = volume('Flame outer volume', outer, (164,195),
    [(.58,-.066),(.83,-.053),(.96,-.024),(1,0),(.96,.024),(.83,.053),(.58,.066)],
    [2,1,0,0,1,2], 2)

gold = [
    (170,263),(132,254),(106,233),(92,208),(86,171),(104,192),
    (98,154),(112,132),(120,147),(138,130),(135,104),(150,77),
    (159,65),(156,103),(177,126),(186,145),(196,127),(212,145),
    (226,175),(228,201),(246,182),(239,216),(222,241),(195,256),
]
yellow = [
    (170,249),(138,241),(115,224),(106,199),(111,165),(121,194),
    (124,159),(140,144),(145,125),(153,111),(170,133),(176,155),
    (190,144),(208,163),(216,190),(214,215),(198,239),
]
cream = [
    (166,237),(141,230),(126,214),(118,194),(126,171),(138,158),
    (152,153),(155,136),(170,153),(187,157),(203,174),(210,197),
    (202,220),(185,233),
]

# A continuous raised spiral with a tapering flame tip. The slight golden
# recess inside the curl is real negative space between the ribbon's edges.
spiral = [
    (150,122),(166,137),(170,153),(187,151),(205,163),(217,182),
    (220,204),(212,225),(198,240),(181,246),(194,230),(203,213),
    (205,192),(197,177),(180,167),(163,166),(150,174),(145,185),
    (150,197),(157,202),(161,195),(158,188),(168,188),(176,196),
    (173,209),(162,217),(148,218),(135,210),(126,197),(123,181),
    (128,165),(139,152),(148,142),
]

for side, label in [(1,'front'),(-1,'rear')]:
    volume('Golden inner flame '+label, gold, (165,202),
        [(.98,.031),(1,.042),(.91,.069),(.64,.079)], [2,3,3],3,side)
    volume('Yellow heart '+label, yellow, (164,201),
        [(.98,.065),(1,.071),(.86,.087),(.60,.091)], [3,4,4],4,side)
    volume('Cream core '+label, cream, (166,195),
        [(.97,.085),(1,.088),(.84,.098)], [4,5],5,side)
    # Tiny bevel without shrinking the spiral across its concave curl.
    ribbon = volume('White spiral '+label, spiral, (167,187),
        [(1,.097),(1,.103)], [5],6,side)
    bpy.context.view_layer.objects.active = ribbon
    bevel = ribbon.modifiers.new('Soft spiral edge','BEVEL')
    bevel.width = .0014
    bevel.segments = 2
    bevel.affect = 'EDGES'
    bpy.ops.object.modifier_apply(modifier=bevel.name)

embers = [
    ('Ember left high',[(98,100),(95,78),(111,57),(115,76)],(105,79)),
    ('Ember left low',[(68,148),(63,126),(80,104),(82,126)],(73,126)),
    ('Ember right high',[(220,89),(211,72),(216,49),(229,72)],(219,72)),
    ('Ember right low',[(251,141),(250,111),(262,119),(265,131),(260,139)],(257,127)),
]
for name, contour, center in embers:
    volume(name, contour, center,
        [(.67,-.011),(.96,-.005),(1,0),(.93,.005),(.68,.012)],
        [2,0,0,2],3)

# Join all disconnected solid components for inexpensive mobile rendering.
bpy.ops.object.select_all(action='DESELECT')
for obj in asset.objects:
    obj.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
body.name = 'Fireball'
tri = body.modifiers.new('Export triangles','TRIANGULATE')
bpy.ops.object.modifier_apply(modifier=tri.name)
body['description'] = 'Rounded orange flame, yellow heart, raised white spiral, four floating embers. No pedestal.'
body.data.update()

usdz = ROOT / 'OccamsRunner/Models/3DModels/Fireball.usdz'
bpy.ops.wm.usd_export(filepath=str(usdz), selected_objects_only=True,
    export_animation=False, export_materials=True, generate_preview_surface=True,
    generate_materialx_network=False, export_lights=False, export_cameras=False,
    convert_orientation=True, export_global_forward_selection='NEGATIVE_Z',
    export_global_up_selection='Y', convert_scene_units='METERS', meters_per_unit=1.0,
    root_prim_path='/Fireball', export_custom_properties=False)
bpy.ops.export_scene.gltf(filepath=str(OUT/'Fireball.glb'), export_format='GLB',
    use_selection=True, use_active_scene=True, export_yup=True)

studio = bpy.data.collections.new('Fireball preview lighting (not exported)')
scene.collection.children.link(studio)
def aim(obj):
    obj.rotation_euler = (Vector((0,0,0)) - obj.location).to_track_quat('-Z','Y').to_euler()
def area(name, location, energy, size):
    data = bpy.data.lights.new(name, 'AREA')
    data.energy, data.shape, data.size = energy, 'DISK', size
    obj = bpy.data.objects.new(name, data)
    studio.objects.link(obj)
    obj.location = location
    aim(obj)
area('Soft key',(-.35,-.5,.6),9,.5)
area('Warm edge',(.4,.15,.4),6,.4)
world = bpy.data.worlds.new('Fireball studio world')
world.use_nodes = True
world.node_tree.nodes['Background'].inputs[0].default_value = (.25,.25,.25,1)
world.node_tree.nodes['Background'].inputs[1].default_value = .4
scene.world = world
data = bpy.data.cameras.new('Fireball preview camera')
camera = bpy.data.objects.new('Fireball preview camera', data)
studio.objects.link(camera)
camera.location = (.20,-.85,.16)
aim(camera)
data.type, data.ortho_scale = 'ORTHO', .385
scene.camera = camera
scene.render.engine = 'CYCLES'
scene.cycles.samples = 32
scene.cycles.use_denoising = True
scene.render.resolution_x = scene.render.resolution_y = 1000
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.view_settings.exposure = -.35
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.filepath = str(OUT/'Fireball-preview.png')
bpy.data.libraries.write(str(OUT/'Fireball.blend'), {scene}, fake_user=True)
bpy.ops.render.render(write_still=True)
bm = bmesh.new()
bm.from_mesh(body.data)
stats = dict(triangles=len(body.data.polygons), vertices=len(body.data.vertices),
    non_manifold_edges=sum(not e.is_manifold for e in bm.edges),
    degenerate_faces=sum(f.calc_area()<1e-12 for f in bm.faces),
    dimensions_blender_m=list(body.dimensions), materials=len(body.data.materials),
    usdz=str(usdz), blend=str(OUT/'Fireball.blend'))
bm.free()
(OUT/'validation.json').write_text(json.dumps(stats, indent=2)+'\n')
print(json.dumps(stats))
