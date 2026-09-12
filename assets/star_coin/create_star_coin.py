"""Run in Blender via its MCP Python executor. Builds only the reference coin asset."""
import bpy, math, json
from pathlib import Path
from mathutils import Vector

ROOT=Path('/Users/jaredgoolsby/Documents/Github/occams_runner')
OUT=ROOT/'assets/star_coin'
OUT.mkdir(parents=True,exist_ok=True)
old=bpy.data.scenes.get('Star Coin Studio')
if old:
    for obj in list(old.objects):
        bpy.data.objects.remove(obj,do_unlink=True)
    bpy.data.scenes.remove(old)
for name in ('Star Coin Asset','Preview lighting (excluded from exports)'):
    col=bpy.data.collections.get(name)
    if col: bpy.data.collections.remove(col)
for m in list(bpy.data.materials):
    if m.name.startswith('Gold |') and m.users==0: bpy.data.materials.remove(m)
scene=bpy.data.scenes.new('Star Coin Studio')
bpy.context.window.scene=scene
scene.unit_settings.system='METRIC'
scene.unit_settings.scale_length=1
asset=bpy.data.collections.new('Star Coin Asset')
scene.collection.children.link(asset)
S=.13

def linear(c):
    return c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4

def mat(name,hexcolor,metal,rough):
    rgb=tuple(linear(int(hexcolor[i:i+2],16)/255) for i in (0,2,4))
    m=bpy.data.materials.new(name)
    m.diffuse_color=(*rgb,1)
    m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value=(*rgb,1)
    p.inputs['Metallic'].default_value=metal
    p.inputs['Roughness'].default_value=rough
    return m

edge=mat('Gold | edge','E8A51C',.8,.27)
rim=mat('Gold | polished raised rim','FFCA24',.78,.24)
face=mat('Gold | amber inset','D79713',.65,.32)
groove=mat('Gold | recessed honey border','9E5D14',.65,.32)
star=mat('Gold | star face','FFD333',.7,.25)
shine=mat('Gold | bevel highlights','FFE777',.78,.22)
materials=[edge,rim,face,groove,star,shine]

# The axial profile is mirrored front/back. Depth maps onto -Y; Z is upright.
# Profile runs from rear center across the edge to front center.
half=[(.0,.105),(.705,.105),(.728,.108),(.748,.125),(.769,.156),(.807,.177),(.929,.177),(.963,.159),(.991,.12),(1.0,.075),(1.0,0)]
profile=[(r,-d) for r,d in half]+list(reversed(half[:-1]))
N=128
verts=[(r*math.cos(2*math.pi*i/N)*S,-d*S,r*math.sin(2*math.pi*i/N)*S) for r,d in profile for i in range(N)]
faces=[];indices=[]
for j in range(len(profile)-1):
    r=(profile[j][0]+profile[j+1][0])/2
    material=2 if r<.718 else 3 if r<.753 else 0 if r<.775 else 5 if r<.815 else 1 if r<.951 else 5 if r<.979 else 0
    for i in range(N):
        faces.append((j*N+i,j*N+(i+1)%N,(j+1)*N+(i+1)%N,(j+1)*N+i))
        indices.append(material)

def mesh_object(name,verts,faces,indices):
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata(verts,[],faces);mesh.update()
    obj=bpy.data.objects.new(name,mesh);asset.objects.link(obj)
    for m in materials:mesh.materials.append(m)
    for p,idx in zip(mesh.polygons,indices):p.material_index=idx
    bpy.context.view_layer.objects.active=obj;obj.select_set(True)
    # Merge the coincident axial pole vertices, then establish outward normals.
    bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=.000001)
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode='OBJECT')
    obj.select_set(False)
    return obj

body=mesh_object('Coin body and raised rim',verts,faces,indices)
# Flat profile bands keep rim bevels crisp; normals vary smoothly around each band.
# Custom per-corner normals prevent highlight seams without rounding the inset.
normals=[]
for p in body.data.polygons:
    p.use_smooth=True
    center=p.center
    radial=Vector((center.x,0,center.z)).normalized()
    radial_weight=p.normal.dot(radial)
    axial=p.normal.y
    if abs(axial)>.9999: radial_weight=0;axial=1 if axial>0 else -1
    for li in p.loop_indices:
        v=body.data.vertices[body.data.loops[li].vertex_index].co
        direction=Vector((v.x,0,v.z)).normalized()
        n=Vector((direction.x*radial_weight,axial,direction.z*radial_weight)).normalized()
        normals.append(tuple(n))
body.data.normals_split_custom_set(normals)

# Matching, upright five-point star relief on both faces; a narrow honey border
# and chamfered gold edge provide the warm illustrated outline as real geometry.
def make_star(name,side):
    rings=[(.635,.318,.106),(.635,.318,.133),(.60,.293,.147),(.60,.293,.190),(.553,.264,.221)]
    vv=[]
    for outer,inner,depth in rings:
        for i in range(10):
            a=math.pi/2+i*math.pi/5
            r=outer if i%2==0 else inner
            vv.append((r*math.cos(a)*S,-side*depth*S,r*math.sin(a)*S))
    ff=[tuple(reversed(range(10)))];mm=[3]
    for j in range(4):
        for i in range(10):
            ff.append((j*10+i,j*10+(i+1)%10,(j+1)*10+(i+1)%10,(j+1)*10+i));mm.append([3,3,0,5][j])
    vv.append((0,-side*.221*S,0))
    for i in range(10):ff.append((50,40+i,40+(i+1)%10));mm.append(4)
    return mesh_object(name,vv,ff,mm)
front=make_star('Star front',1);back=make_star('Star back',-1)

# Apply modifiers and join into one mobile-friendly, material-indexed mesh.
for o in list(asset.objects):
    bpy.context.view_layer.objects.active=o;o.select_set(True)
    for m in list(o.modifiers):bpy.ops.object.modifier_apply(modifier=m.name)
bpy.context.view_layer.objects.active=body
bpy.ops.object.join()
coin=body;coin.name='StarCoin'
coin['description']='Gold coin with matching raised five-point stars on both sides. No pedestal.'
coin['diameter_m']=.26
tri=coin.modifiers.new('Export triangles','TRIANGULATE')
bpy.ops.object.modifier_apply(modifier=tri.name)
coin.data.update()

# Only the selected coin is exported. USDZ has Y-up coordinates, meter units,
# and standard USD Preview Surface materials understood by Apple renderers.
usdz=ROOT/'OccamsRunner/Models/3DModels/StarCoin.usdz'
bpy.ops.wm.usd_export(filepath=str(usdz),selected_objects_only=True,export_animation=False,export_materials=True,generate_preview_surface=True,generate_materialx_network=False,export_lights=False,export_cameras=False,convert_orientation=True,export_global_forward_selection='NEGATIVE_Z',export_global_up_selection='Y',convert_scene_units='METERS',meters_per_unit=1.0,root_prim_path='/StarCoin',export_custom_properties=False)
bpy.ops.export_scene.gltf(filepath=str(OUT/'StarCoin.glb'),export_format='GLB',use_selection=True,export_yup=True)

studio=bpy.data.collections.new('Preview lighting (excluded from exports)');scene.collection.children.link(studio)
def aim(obj,target=(0,0,0)):
    obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler()
def area(name,loc,power,size,color=(1,1,1),shape='DISK',size_y=None):
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape=shape;data.size=size;data.color=color
    if size_y is not None:data.size_y=size_y
    obj=bpy.data.objects.new(name,data);studio.objects.link(obj);obj.location=loc;aim(obj)
area('Large softbox upper left',(-.35,-.45,.55),16,.40)
area('Tall edge reflection',(.4,-.2,.12),9,.16,shape='RECTANGLE',size_y=.5)
area('Top rim strip',(-.1,.22,.45),22,.30)
area('Soft front fill',(.0,-.55,-.15),4,.5)
world=bpy.data.worlds.new('Neutral studio');world.use_nodes=True
world.node_tree.nodes['Background'].inputs[0].default_value=(.65,.65,.65,1)
world.node_tree.nodes['Background'].inputs[1].default_value=.65
scene.world=world
camera_data=bpy.data.cameras.new('Coin preview camera');camera=bpy.data.objects.new('Coin preview camera',camera_data);studio.objects.link(camera)
camera.location=(-.34,-.64,.24);aim(camera);camera_data.type='ORTHO';camera_data.ortho_scale=.345;scene.camera=camera
scene.render.engine='CYCLES';scene.cycles.samples=48;scene.cycles.use_denoising=True
scene.render.resolution_x=1000;scene.render.resolution_y=1000;scene.render.resolution_percentage=100
scene.render.film_transparent=True
scene.view_settings.view_transform='Standard'
scene.view_settings.exposure=-.7
for light in studio.objects:
    if light.type=='LIGHT':light.data.energy*=.35
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA'
scene.render.filepath=str(OUT/'StarCoin-preview.png')
# Save this new scene only; preserve the user's original Blender scene.
bpy.data.libraries.write(str(OUT/'StarCoin.blend'),{scene},fake_user=True)
bpy.ops.render.render(write_still=True)
result={'asset':str(usdz),'blend':str(OUT/'StarCoin.blend'),'triangles':len(coin.data.polygons),'vertices':len(coin.data.vertices),'dimensions_m':list(coin.dimensions),'render':scene.render.filepath}
print(json.dumps(result))
