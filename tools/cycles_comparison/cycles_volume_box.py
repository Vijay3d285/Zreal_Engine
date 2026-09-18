# Homogeneous fog box against Cycles -- the pt_volume_gate stimulus
# (spec 2026-09-17-volumetrics-design.md, roadmap F2 / Gap #16).
#
# Godot (x, y, z) -> Blender (x, -z, y). The box [-1,1] x [0,2] x [-1,1]
# (Godot) is Blender [-1,1] x [-1,1] x [0,2]. Eight 1 cm black cubes pin the
# corners (they exist so the Godot side's automatic box is this box), a 2 m
# cube object carries the Volume Scatter shader, a 2 x 2 floor at z = 0.
# Camera at Blender (0, -4, 1) looking +Y tilted 8.53 deg down (at the
# Godot point (0, 0.4, 0)), 30 deg vertical FOV, 256 x 256: the floor spans
# rows 59-83 % of the frame, the fog above it reads against the black sky.
#
#   V3: albedo 1, sigma_t 0.3, g 0.8, Sun straight down (strength 3), black
#       world; prints fog crop mean, floor crop mean, and their ratio.
#   V4: albedo 1, sigma_t 0.3, g 0.0, uniform world 1.0, black floor; prints
#       the fog crop mean.
#   volume_bounces = 0 (Cycles' default: single scattering), volume sampling
#   Distance, 1024 spp.
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_volume_box.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = int(os.environ.get("SAMPLES", "1024"))
SUN_STRENGTH = 3.0


def mat_surface(name, albedo):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (albedo, albedo, albedo, 1.0)
    b.inputs["Roughness"].default_value = 1.0
    b.inputs["Specular IOR Level"].default_value = 0.0
    return m


def mat_volume(sigma_t, albedo, g):
    m = bpy.data.materials.new("fog")
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    vs = nt.nodes.new("ShaderNodeVolumeScatter")
    vs.inputs["Color"].default_value = (albedo, albedo, albedo, 1.0)
    vs.inputs["Density"].default_value = sigma_t
    vs.inputs["Anisotropy"].default_value = g
    nt.links.new(vs.outputs["Volume"], out.inputs["Volume"])
    m.cycles.volume_sampling = "DISTANCE"
    if hasattr(m.cycles, "homogeneous_volume"):
        m.cycles.homogeneous_volume = True
    return m


def build(sigma_t, albedo, g, sun, world_strength, floor_albedo):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 4
    scene.cycles.diffuse_bounces = 4
    scene.cycles.glossy_bounces = 4
    scene.cycles.volume_bounces = 0
    scene.cycles.sample_clamp_direct = 0.0
    scene.cycles.sample_clamp_indirect = 0.0
    scene.render.resolution_x = RES
    scene.render.resolution_y = RES
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "32"
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = world_strength

    black = mat_surface("black", 0.0)
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            for sz in (0.0, 2.0):
                bpy.ops.mesh.primitive_cube_add(size=0.01, location=(sx, sy, sz))
                bpy.context.object.data.materials.append(black)

    # 1 mm INSIDE the fog cube: coplanar with its bottom face the floor is never
    # hit (the surface-less cube face wins the intersection and the continuation
    # skips the coincident plane). The Godot fixture lifts its floor the same 1 mm.
    bpy.ops.mesh.primitive_plane_add(size=2.0, location=(0.0, 0.0, 0.001))
    floor = bpy.context.object
    floor.data.materials.append(mat_surface("floor", floor_albedo))

    bpy.ops.mesh.primitive_cube_add(size=2.0, location=(0.0, 0.0, 1.0))
    fog = bpy.context.object
    fog.name = "fog"
    fog.data.materials.append(mat_volume(sigma_t, albedo, g))

    if sun:
        sd = bpy.data.lights.new("Sun", "SUN")
        sd.energy = SUN_STRENGTH
        sd.angle = 0.0
        so = bpy.data.objects.new("Sun", sd)
        scene.collection.objects.link(so)
        so.rotation_euler = (0.0, 0.0, 0.0)  # points down -Z

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(30.0)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, -4.0, 1.0)
    cam.rotation_euler = (math.radians(90.0) - math.atan2(0.6, 4.0), 0.0, 0.0)  # looks +Y, 8.53 deg down


def crop_mean(path, fy0, fy1, fx0, fx1):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    w, h = img.size
    acc, n = 0.0, 0
    # Blender rows are bottom-up; the gate's fractions are from the top.
    for y in range(int((1.0 - fy1) * h), int((1.0 - fy0) * h)):
        for x in range(int(fx0 * w), int(fx1 * w)):
            i = (y * w + x) * 4
            acc += (px[i] + px[i + 1] + px[i + 2]) / 3.0
            n += 1
    bpy.data.images.remove(img)
    return acc / n


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ VOLUME BOX vs Cycles @@@")
print("@@@ blender: %s  samples %d  volume_bounces 0" % (bpy.app.version_string, SAMPLES))

build(0.3, 1.0, 0.8, True, 0.0, 1.0)
p = os.path.join(OUT, "volume_v3.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
fog3 = crop_mean(p, 0.10, 0.40, 0.30, 0.70)
floor3 = crop_mean(p, 0.62, 0.80, 0.30, 0.70)
print("@@@ V3 fog %.6f floor %.6f ratio %.6f" % (fog3, floor3, fog3 / max(floor3, 1e-9)))

build(0.3, 1.0, 0.0, False, 1.0, 0.0)
p = os.path.join(OUT, "volume_v4.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
fog4 = crop_mean(p, 0.10, 0.40, 0.30, 0.70)
print("@@@ V4 fog %.6f" % fog4)
print("@@@ DONE")
