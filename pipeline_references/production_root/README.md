# Production root files

Files in this folder belong in the production folder that holds `main.py`
(`C:\Zlendo2026\ZlenderRender_stage_copy\`), not in `godot_project\`. Godot skips this folder
(`.gdignore`).

## Shipping the 2026-10-08 video changes

Copy these four files over their production counterparts:

| From (this repo) | To (production) |
|---|---|
| `pipeline_references/video_glb_creation.gd` | `godot_project/video_glb_creation.gd` |
| `pipeline_references/image_glb_creation.gd` | `godot_project/image_glb_creation.gd` |
| `pipeline_references/production_root/scene_optimizer_video.py` | `scene_optimizer_video.py` |
| `pipeline_references/production_root/README.md` | not needed |

Ship `video_glb_creation.gd` and `scene_optimizer_video.py` together. With only the first, the
room is darker, the daylight probe exposes about 13x higher, and flicker rises about 1.5x.

Do not copy `project.godot`: production's copy was re-saved by the 4.7 editor and already has
`movie_writer/video_quality=1.0`.

What changed:

- `video_glb_creation.gd`
  - A fixture whose bulb surface glows is lit by that surface (emissive-mesh lighting, with
    shadows) instead of an added shadowless light, as the still route already does.
  - Textures are capped at 2048. A map shared by several material slots is resized once.
  - "wallmount" is no longer a lamp keyword (it made the wall-mounted AC a lamp).
  - Production's own settings are kept: `VIDEO_DENOISER := "oidn"`,
    `VIDEO_OIDN_ACCUM_TARGET := 24`.
- `image_glb_creation.gd`: the "wallmount" keyword fix only.
- `scene_optimizer_video.py`: items inside a room the camera stands in are no longer culled for
  being outside the view cone. Rooms seen only through an opening are unchanged.

Measured on job 210, keyframes 204-215, 4K, camera moving:

| | s per frame | flicker mean / p90 | GPU memory |
|---|---|---|---|
| production before, 24 spp | 28.4 | 0.52 / 1.13 | 16.4 GB |
| these changes, 24 spp | 41.4 | 0.57 / 1.21 | 14.4 GB |
| these changes, 16 spp | 29.5 | 0.59 / 1.36 | 14.4 GB |

To trade some flicker for production's current render time, set `VIDEO_OIDN_ACCUM_TARGET := 16`
in `video_glb_creation.gd`.
