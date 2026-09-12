"""Run inside Blender after create_fireball.py to inspect the delivered USDZ."""
import bpy
import json
from pathlib import Path
from mathutils import Vector

ROOT = Path('/Users/jaredgoolsby/Documents/Github/occams_runner')
OUT = ROOT/'assets/fireball'
source = bpy.data.scenes['Fireball Studio']
bpy.context.window.scene = source
with bpy.context.temp_override(scene=source, view_layer=source.view_layers[0]):
    bpy.ops.object.select_all(action='DESELECT')
    source.objects['Fireball'].select_set(True)
    bpy.context.view_layer.objects.active = source.objects['Fireball']
    bpy.ops.export_scene.gltf(filepath=str(OUT/'Fireball.glb'), export_format='GLB',
        use_selection=True, use_active_scene=True, export_yup=True)

scene = bpy.data.scenes.new('Fireball USDZ verification')
bpy.context.window.scene = scene
with bpy.context.temp_override(scene=scene, view_layer=scene.view_layers[0]):
    bpy.ops.wm.usd_import(filepath=str(ROOT/'OccamsRunner/Models/3DModels/Fireball.usdz'))
    meshes = [o for o in scene.objects if o.type == 'MESH']
    assert len(meshes) == 1, [(o.name,o.type) for o in scene.objects]
    assert len(meshes[0].data.materials) == 7
    assert not any(o.type in ('LIGHT','CAMERA') for o in scene.objects)

    # Reuse studio objects for render only, never write them back into the USDZ.
    for o in source.objects:
        if o.type == 'LIGHT':
            scene.collection.objects.link(o)
    camera = source.camera.copy()
    camera.data = source.camera.data.copy()
    scene.collection.objects.link(camera)
    scene.camera = camera
    scene.world = source.world
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 24
    scene.cycles.use_denoising = True
    scene.render.resolution_x = scene.render.resolution_y = 800
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.view_settings.view_transform = 'Standard'
    scene.view_settings.exposure = -.35
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    for name, position in [('Fireball-usdz-front',(.20,-.85,.16)),
                           ('Fireball-usdz-rear',(-.50,.80,.10))]:
        camera.location = position
        camera.rotation_euler = (Vector((0,0,0))-camera.location).to_track_quat('-Z','Y').to_euler()
        scene.render.filepath = str(OUT/(name+'.png'))
        bpy.ops.render.render(write_still=True)

stats = json.loads((OUT/'validation.json').read_text())
stats['usdz_reimport_meshes'] = len(meshes)
stats['usdz_reimport_materials'] = len(meshes[0].data.materials)
(OUT/'validation.json').write_text(json.dumps(stats,indent=2)+'\n')
bpy.context.window.scene = source
print(json.dumps(stats))
