# Many-light noise against Cycles -- is our sampler noisier than Cycles' with a
# lamp rig like the pipeline's? (roadmap Gap #30 follow-up, 2026-09-17)
#
# A 6 x 4 x 2.8 m box room (walls albedo 0.6, ceiling 0.7, floor 0.4), sixteen
# identical point lights (radius 0 -- hard points, like Godot omnis) on a 4 x 4
# grid at 1.9 m, no world light. Camera at 1.2 m looking up at the far ceiling
# corner. 256 samples, no denoiser, no clamp, 12 bounces. Prints the robust
# relative noise (MAD / median) of a flat ceiling patch and of a wall patch --
# the same statistic pt_manylight_noise_probe.gd prints for our tracer.
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_manylight_noise.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES_X, RES_Y = 512, 288
SAMPLES = 256
ROOM = (6.0, 4.0, 2.8)  # x (width), y (depth), z (height)
LIGHT_W = 40.0
GRID = 4


def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 12
    scene.cycles.diffuse_bounces = 12
    scene.cycles.glossy_bounces = 12
    scene.cycles.sample_clamp_direct = 0.0
    scene.cycles.sample_clamp_indirect = 0.0
    scene.cycles.use_light_tree = True
    scene.render.resolution_x = RES_X
    scene.render.resolution_y = RES_Y
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "32"
    scene.view_settings.view_transform = "Standard"

    world = bpy.data.worlds.new("W")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0

    def mat(name, albedo):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        b = m.node_tree.nodes["Principled BSDF"]
        b.inputs["Base Color"].default_value = (albedo, albedo, albedo, 1.0)
        b.inputs["Roughness"].default_value = 1.0
        b.inputs["Specular IOR Level"].default_value = 0.0
        return m

    w, d, h = ROOM
    # Inward-facing planes.
    def plane(name, loc, rot, size_x, size_y, m):
        bpy.ops.mesh.primitive_plane_add(size=1.0, location=loc, rotation=rot)
        o = bpy.context.object
        o.scale = (size_x, size_y, 1.0)
        o.name = name
        o.data.materials.append(m)
        return o

    m_wall, m_ceil, m_floor = mat("wall", 0.6), mat("ceil", 0.7), mat("floor", 0.4)
    plane("floor", (0, 0, 0), (0, 0, 0), w, d, m_floor)
    plane("ceiling", (0, 0, h), (math.pi, 0, 0), w, d, m_ceil)
    plane("wall_y+", (0, d / 2, h / 2), (math.pi / 2, 0, 0), w, h, m_wall)
    plane("wall_y-", (0, -d / 2, h / 2), (-math.pi / 2, 0, 0), w, h, m_wall)
    plane("wall_x+", (w / 2, 0, h / 2), (0, -math.pi / 2, 0), h, d, m_wall)
    plane("wall_x-", (-w / 2, 0, h / 2), (0, math.pi / 2, 0), h, d, m_wall)

    for i in range(GRID):
        for j in range(GRID):
            ld = bpy.data.lights.new("L%d%d" % (i, j), "POINT")
            ld.energy = LIGHT_W
            ld.shadow_soft_size = 0.0
            lo = bpy.data.objects.new(ld.name, ld)
            scene.collection.objects.link(lo)
            lo.location = (-w * 0.375 + i * w * 0.25, -d * 0.375 + j * d * 0.25, 1.9)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "HORIZONTAL"
    cam_data.angle_x = math.radians(60.0)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (-1.5, -1.0, 1.2)
    target = (2.0, 1.5, 2.8)
    dx, dy, dz = (target[0] - cam.location[0], target[1] - cam.location[1], target[2] - cam.location[2])
    # Point -Z at the target. Blender's camera looks down its local -Z; an X
    # rotation of 90 deg makes it horizontal, more than 90 tilts it up.
    yaw = math.atan2(dy, dx) - math.pi / 2
    pitch = math.pi / 2 + math.atan2(dz, math.hypot(dx, dy))
    cam.rotation_euler = (pitch, 0.0, yaw)


def load_luma(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    w, h = img.size
    rows = [[(px[(y * w + x) * 4] + px[(y * w + x) * 4 + 1] + px[(y * w + x) * 4 + 2]) / 3.0 for x in range(w)] for y in range(h)]
    bpy.data.images.remove(img)
    return rows, w, h


def robust(rows, x0, y0, x1, y1):
    v = sorted(rows[y][x] for y in range(y0, y1) for x in range(x0, x1))
    med = v[len(v) // 2]
    dev = sorted(abs(a - med) for a in v)
    mad = dev[len(dev) // 2] * 1.4826
    return med, mad / max(med, 1e-9), max(v) / max(med, 1e-9)


os.makedirs(OUT, exist_ok=True)
build()
p = os.path.join(OUT, "manylight_cycles.exr")
bpy.context.scene.render.filepath = p
bpy.ops.render.render(write_still=True)
rows, w, h = load_luma(p)
print("")
print("@@@ MANY-LIGHT NOISE, Cycles %s, %d spp, %d point lights" % (bpy.app.version_string, SAMPLES, GRID * GRID))
# Blender rows are bottom-up: the ceiling is the top of the frame = last rows.
# Patches: ceiling (top-centre of frame), wall (mid-right). Printed as the same
# fractions the Godot probe uses (x, y in [0,1] of the frame, y from the top).
for name, (fx0, fy0, fx1, fy1) in (("ceiling", (0.35, 0.05, 0.65, 0.25)), ("wall", (0.70, 0.55, 0.95, 0.85))):
    x0, x1 = int(fx0 * w), int(fx1 * w)
    y0, y1 = int((1.0 - fy1) * h), int((1.0 - fy0) * h)
    med, rel, mx = robust(rows, x0, y0, x1, y1)
    print("@@@ %-8s median %.5f  robust noise %.1f%%  max/median %.0fx" % (name, med, 100 * rel, mx))
print("@@@ DONE")
