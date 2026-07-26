# Fix: Video Render Producing Only 2 Frames

## Root Cause

The issue is **NOT related to DLSS** — it's a frame count calculation bug in `video_render.gd`.

### The Bug

In `video_render.gd` line 122-128:
```gdscript
_keyframes = anim_data.get("keyframes", [])
_total_frames = _keyframes.size()  # ← BUG: 2 keyframes = 2 total output frames!

if _total_frames == 0:  # Only triggers when NO keyframes exist
    var duration = anim_data.get("duration_seconds", 5.0)
    _total_frames = int(duration * _fps)
```

When the input JSON has 2 keyframes (e.g., start position + end position), `_total_frames` is set to **2**, producing only 2 rendered frames. Each keyframe is treated as a single output frame instead of a camera waypoint to interpolate between.

### Why It Seemed to Work Before

The old `render.gd` video path (line 422-423) calculated frames differently:
```gdscript
var duration = anim_data.get("duration_seconds", 5.0)
var total_frames = int(duration * fps)  # 20s × 30fps = 600 frames
```
It always used `duration × fps` and **lerped** camera position across all frames. The keyframes weren't used as individual output frames.

## Proposed Fix

#### [MODIFY] [video_render.gd](file:///c:/Users/aiadmin/Desktop/RTX_path_tracing/pipeline_references/video_render.gd)

Change `_setup_render()` to always compute `_total_frames` from `duration_seconds × fps`, and interpolate across keyframes:

```diff
 if data.has("video_animation") and data["video_animation"] != null:
     var anim_data = data["video_animation"]
     _fps = int(anim_data.get("fps", 30))
     _keyframes = anim_data.get("keyframes", [])
-    _total_frames = _keyframes.size()
+    var duration = anim_data.get("duration_seconds", 5.0)
+    _total_frames = int(duration * _fps)
     
-    if _total_frames == 0:
-        # Lerp fallback - generate keyframes from start/end
-        var duration = anim_data.get("duration_seconds", 5.0)
-        _total_frames = int(duration * _fps)
+    if _keyframes.size() == 0:
         _generate_lerp_keyframes(anim_data, _total_frames)
+    elif _keyframes.size() < _total_frames:
+        # Interpolate sparse keyframes across all output frames
+        _interpolate_keyframes_to_frame_count(_total_frames)
```

> [!IMPORTANT]
> The `_interpolate_keyframes_to_frame_count()` function must be implemented to evenly distribute the existing keyframes across the full frame count, interpolating camera position/rotation between them.

## Verification Plan

1. Check console output for `Video: 600 frames at 30 fps` (for a 20s video)
2. Verify all 600 frames render with unique camera positions
3. Confirm DLSS denoising is applied to all frames
