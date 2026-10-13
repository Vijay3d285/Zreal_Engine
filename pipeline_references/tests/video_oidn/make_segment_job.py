"""T4 input: N CONSECUTIVE keyframes of a production video job, at their real speed.

Spec docs/superpowers/specs/2026-10-01-video-oidn-design.md, T4 (revised 2026-10-03). The
camera moves as it does in production, so the measurement sees what a viewer sees.

usage: python make_segment_job.py <source_job.json> <out.json> [--start S] [--count N]
"""
import argparse
import json

ap = argparse.ArgumentParser()
ap.add_argument("source")
ap.add_argument("out")
ap.add_argument("--start", type=int, default=0, help="first keyframe index of the segment")
ap.add_argument("--count", type=int, default=30, help="consecutive keyframes (= delivered frames)")
a = ap.parse_args()

with open(a.source, encoding="utf-8") as f:
    job = json.load(f)
anim = job["video_animation"]
frames = anim["keyframes"][a.start:a.start + a.count]
if len(frames) != a.count:
    raise SystemExit("source has only %d keyframes from %d" % (len(frames), a.start))
for i, kf in enumerate(frames):
    kf["frame"] = i
anim["keyframes"] = frames
anim["duration_seconds"] = a.count / float(anim.get("fps", 60.0))
with open(a.out, "w", encoding="utf-8") as f:
    json.dump(job, f)
print("wrote %s: keyframes %d..%d (%d consecutive)" % (a.out, a.start, a.start + a.count - 1, a.count))
