# OIDN detail retention against Cycles -- the pt_oidn_guide_gate stimulus
# (spec 2026-09-16-oidn-accumulated-guides-design).
#
# One plane fills a 256x256 frame, textured 1:1 with a checker: period 4 px on
# the left half, period 32 px on the right; uniform white world (strength 1),
# diffuse plane, one bounce, so the plane's radiance is its albedo (a furnace).
# Rendered twice at 256 spp: raw, and with OpenImageDenoise (Blender's default
# prefilter ACCURATE). Retention = std(denoised) / std(raw) per half -- the
# gate's G1 / G2, computed the same way on Blender's output.
#
#   "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" -b -P
#       tools/cycles_comparison/cycles_oidn_checker.py -- <out_dir>

import bpy
import math
import os
import sys

OUT = sys.argv[sys.argv.index("--") + 1]
RES = 256
SAMPLES = 256
CAM_DIST = 10.0
CAM_FOV_DEG = 10.0
FINE, COARSE = 4, 32


def make_checker():
    img = bpy.data.images.new("checker", RES, RES, alpha=False, float_buffer=True)
    # Colourspace first: changing it after the pixels are set regenerates the
    # buffer and the checker reads back as zeros.
    img.colorspace_settings.name = "Non-Color"
    px = [0.0] * (RES * RES * 4)
    for y in range(RES):
        for x in range(RES):
            period = FINE if x < 128 else COARSE
            half = period // 2
            on = ((x // half) + (y // half)) % 2 == 0
            v = 0.9 if on else 0.1
            i = (y * RES + x) * 4
            px[i:i + 4] = [v, v, v, 1.0]
    img.pixels.foreach_set(px)
    img.update()
    img.pack()
    return img


def build(denoise):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = denoise
    scene.cycles.denoiser = "OPENIMAGEDENOISE"
    scene.cycles.denoising_prefilter = "ACCURATE"
    scene.cycles.denoising_input_passes = "RGB_ALBEDO_NORMAL"
    scene.cycles.max_bounces = 1
    scene.cycles.diffuse_bounces = 1
    scene.cycles.glossy_bounces = 0
    scene.cycles.transmission_bounces = 0
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
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0

    side = 2.0 * CAM_DIST * math.tan(math.radians(CAM_FOV_DEG) * 0.5)
    bpy.ops.mesh.primitive_plane_add(size=side)
    plane = bpy.context.object
    plane.rotation_euler = (math.radians(90.0), 0.0, 0.0)  # face +Y toward the camera

    mat = bpy.data.materials.new("M")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 1.0
    bsdf.inputs["Specular IOR Level"].default_value = 0.0
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = make_checker()
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    plane.data.materials.append(mat)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle_y = math.radians(CAM_FOV_DEG)
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (0.0, -CAM_DIST, 0.0)
    cam.rotation_euler = (math.radians(90.0), 0.0, 0.0)


def load_rgb(path):
    img = bpy.data.images.load(path)
    px = list(img.pixels)
    w, h = img.size
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            i = (y * w + x) * 4
            row.append((px[i] + px[i + 1] + px[i + 2]) / 3.0)
        rows.append(row)
    bpy.data.images.remove(img)
    return rows


def std(rows, x0, y0, x1, y1):
    vals = [rows[y][x] for y in range(y0, y1) for x in range(x0, x1)]
    m = sum(vals) / len(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))


os.makedirs(OUT, exist_ok=True)
print("")
print("@@@ OIDN CHECKER vs Cycles @@@")
print("@@@ blender: %s" % bpy.app.version_string)
paths = {}
for label, dn in (("raw", False), ("oidn", True)):
    build(dn)
    p = os.path.join(OUT, "%s.exr" % label)
    bpy.context.scene.render.filepath = p
    bpy.ops.render.render(write_still=True)
    paths[label] = p
raw = load_rgb(paths["raw"])
den = load_rgb(paths["oidn"])
# Blender's image rows are bottom-up; the checker is symmetric under that, and
# the crops are the gate's: fine x 24..104, coarse x 152..232, y 40..216.
fr, fo = std(raw, 24, 40, 104, 216), std(den, 24, 40, 104, 216)
cr, co = std(raw, 152, 40, 232, 216), std(den, 152, 40, 232, 216)
print("@@@ fine   raw std %.5f oidn std %.5f retention %.4f" % (fr, fo, fo / fr))
print("@@@ coarse raw std %.5f oidn std %.5f retention %.4f" % (cr, co, co / cr))
print("@@@ DONE")
