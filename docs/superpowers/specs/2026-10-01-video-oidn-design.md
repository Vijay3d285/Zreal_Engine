# Video OIDN: per-frame OpenImageDenoise for the video route

**Date:** 2026-10-01. **Scope:** engine (`modules/raycaster_oidn`, one settings line, one
log rate-limit) and the video pipeline (`video_glb_creation.gd`, `video_render.gd`).
**Predecessors:** the still route's Phase A (accumulate + Blackman-Harris pixel filter +
OIDN, production since 2026-09-16, `2026-09-16-still-route-pixel-filter-design.md`);
the accumulated OIDN guides (Gap #29); video port 3 (the offscreen exposure probe, which
established doing multi-frame GPU work inside one `_process()` call so MovieWriter never
captures it). Research notes with every raw number:
`.superpowers/sdd/2026-10-01-video-oidn/research.md`.

## The goal

Video renders through DLSS Ray Reconstruction. The still route left DLSS-RR on
2026-09-16 because, as a game denoiser, its reconstruction "never converges to the
pixel-filtered image, and on a 4K still it left a one-pixel staircase on every edge and a
checkerboard on flat walls, whatever it was fed" (`image_glb_creation.gd`, Phase A
comment). The owner wants video denoised by OIDN, as Blender Cycles does, without new
artefacts and without lowering quality.

## Owner decisions (brainstorm 2026-10-01)

1. **Budget about one hour** for a 7-second video -- today's cost, inside the
   `VIDEO_RENDER_TIMEOUT_SECONDS = 3600` the owner set on 2026-09-30.
2. **Keep 4K at 60 fps.** No resolution or frame-rate trade. Together with (1) this fixes
   the sample count at **about 6 samples per pixel per frame**, the same as today.
3. **Approach A first** (per-frame OIDN, measured against a flicker bar); **approach B**
   (temporal reuse of radiance before OIDN) only if A fails that bar, under its own spec.
4. **Stills stay on CPU OIDN.** The still route must not change.

## What was measured before designing

1. **OIDN cost at 4K**, HDR with clean auxiliaries (`oidnBenchmark
   RT.hdr_calb_cnrm.3840x2160`): CPU **5270 ms/frame**, CUDA (RTX A4000) **157 ms** --
   34x. On the current CPU path, denoising alone would add 37 minutes to a 421-frame video.
2. **OIDN 2.5.0's default quality is HIGH on both devices** (CUDA default 156.57 ms ==
   high 156.63 ms; balanced 76.74 ms). The engine never sets `quality`, so it has never
   been silently degraded.
3. **CUDA OIDN is visually identical to CPU OIDN on a real frame.** Job 201 at 1080p,
   6 spp, the engine's own OIDN inputs dumped with `ZR_OIDN_DUMP`, denoised by
   `oidnDenoise -q high --clean_aux` on each device, compared after exposure: **no pixel
   2 or more display levels apart, maximum 1 level, display PSNR 61.8 dB**; relative error
   p50 0.09%, p99 0.38%, max 2.2%.
4. **6 spp + OIDN against 768 spp + OIDN**, identical pipeline (job 201, same probe,
   exposure, relief and tone curve; only the sample count differs): frame mean -1.04%,
   PSNR 28.2 dB, 14.8% of pixels 10 or more levels off. Visually clean and noise-free,
   lighting correct; it loses fine detail -- a faint glossy streak on the TV, crispness in
   the wall pattern and rug weave, slight low-frequency mottling on textured walls. That
   per-frame error is driven by noise, so it changes every frame: **the risk is boiling
   in motion**, which T4 measures.
5. **How Cycles does it** (Blender source, `intern/cycles`): the OIDN device and filter
   persist and are recreated only if passes or quality change
   (`integrator/denoiser_oidn_gpu.cpp:202`); CUDA via `oidnNewCUDADevice(&num, &stream, 1)`
   with a null stream (`:234`, "using the stream from the DeviceQueue returns invalid
   resource handle"); `color` and `output` on the same device memory, so in place;
   `quality` set explicitly, HIGH by default (`denoiser_oidn_base.cpp:33-45`); guides
   prefiltered and `cleanAux` on (`:376`), Blender's `ACCURATE` default
   (`blender/addon/properties.py:423-433`). **Cycles has no temporal OIDN.**
   `temporally_stable` is set only by the standalone *Denoise Animation* operator
   (`session/denoising.cpp:229`) and consumed only by OptiX
   (`denoiser_optix.cpp:62`); no `denoiser_oidn*` file references it. When Blender
   renders an animation with OIDN it denoises each frame independently. **Approach A is
   Cycles' architecture**; B would go beyond it.

### Why the CUDA device is not a one-line change

- `oidn_denoiser.cpp` shares raw **host** pointers with OIDN
  (`oidnSetSharedFilterImage`). A CUDA device cannot read plain host memory on Windows.
- The caller creates a denoiser per denoise (`PathtraceOIDNDenoiser::create()` in
  `_oidn_final_denoise_accumulator`), and the device dies in the destructor. Once per
  still that is harmless; per video frame a CUDA context initialisation would consume
  much of the speed-up.
- `[OIDN-DIAG]` prints three lines per denoise, plus a skip line whenever
  `accum_frame < 5`. With target 2 that is every sub-frame: about 1,700 lines over 421
  frames.

## Design

### 1. Engine: a persistent CUDA OIDN path (`modules/raycaster_oidn`)

**Device selection.** New project setting, registered beside the relief settings
(`rendering_server.cpp`, `GLOBAL_DEF(PropertyInfo(...))` as at :3856):

```
rendering/pathtracer/oidn_device   int enum "CPU,CUDA", default 0 (CPU)
```

Read with `GLOBAL_GET` inside `OIDNDenoiser::denoise_rt`, so the
`PathtraceOIDNDenoiser` interface does not change.

**On CPU the existing code runs unchanged** -- per-call device, shared host images, no
`quality` set. The still route therefore executes the same instructions it does today;
T2 proves it byte-for-byte.

**On CUDA, a new path that mirrors Cycles:**

- One module-level CUDA device for the process, created on first use with
  `oidnNewCUDADevice(&device_id, &stream, 1)`, `device_id` 0, `stream` null -- Cycles'
  exact call. Released in `uninitialize_raycaster_oidn_module` (`register_types.cpp:47`),
  not in the per-call object's destructor.
- OIDN-owned buffers (`oidnNewBuffer`): colour, albedo, normal. Reallocated only when the
  frame size changes. Data moves with `oidnWriteBuffer` / `oidnReadBuffer`.
- Three filters committed once per size, then only executed per frame: the albedo
  prefilter, the normal prefilter, and the RT filter. Committing loads the network
  weights.
- RT filter: `hdr = true`, `cleanAux = true`, **`quality = OIDN_QUALITY_HIGH` set
  explicitly** (measured as the default today; pinned so a future OIDN cannot lower it),
  colour and output on **the same buffer** (in place, as Cycles does).
- Per frame: write colour, albedo, normal -> prefilter albedo in place -> prefilter normal
  in place -> RT filter in place -> read colour back. The host-side caller in
  `render_forward_clustered.cpp` is unchanged: it still hands `denoise_rt` host float
  buffers and uploads the result.

**Failure never loses a frame.** If CUDA is requested but `oidnIsCUDADeviceSupported(0)`
is false, or any CUDA call reports an error, the module logs once --
`[OIDN] CUDA unavailable/failed (<reason>); using CPU for the rest of this process` -- marks
CUDA unusable for the process, and denoises that frame and every later one on the CPU path.
The video completes, more slowly, and the budget line reports the slowdown.

**Log rate-limit.** In `_oidn_final_denoise_accumulator`, the `[OIDN-DIAG]` FIRE, view
and ok lines print for the first 8 denoises of a process, and the skip lines for the first 64.
Measured before choosing: a still performs 2 denoises (the exposure probe's at `target=16`,
then the final one) and prints 15-18 skip lines, so these limits leave a still's log
unchanged; a 421-frame video would otherwise print about 2,100 lines. `ZR_OIDN_DIAG=1`
restores every line. Failures always print.

**Debug dump of the denoised output.** `ZR_OIDN_DUMP=<dir>`, which already writes the OIDN
inputs, also writes `oidn_output.pfm` -- the engine's own denoised colour in linear. T1 compares
devices on real content with it. Production never sets the variable.

**Not done now (YAGNI, with a stated trigger).** The host round trip -- three synchronous
`texture_get_data` readbacks at 4K, single-threaded format conversion over 8.3 M pixels,
`texture_update` back -- stays. Estimated 0.4-0.6 s per frame against ~7 s of tracing. If
T5 measures the full job over 3600 s, the conversion loops are moved to
`WorkerThreadPool` and T5 is re-run. Zero-copy Vulkan-CUDA interop is out of scope.

### 2. Pipeline: a video OIDN mode

**Switch.** `const VIDEO_DENOISER := "dlssrr"` in `video_glb_creation.gd`, overridden by
the environment variable `ZR_VIDEO_DENOISER` (`dlssrr` | `oidn`). On `dlssrr` nothing
changes -- T3 proves it frame-for-frame.

**Setup in OIDN mode** -- a mirror of the still route's Phase A, not a reinterpretation:

| setting | value | reason |
|---|---|---|
| `pathtracing_denoiser` | 0 | DLSS-RR is not the integrator |
| `pathtracing_accumulate` | true | Phase A |
| `pathtracing_accumulation_target` | 2 | 2 sub-frames x 3 spp = 6 spp |
| `pathtracing_samples_per_pixel` | 3 | the still route's day value, kept under the TDR watchdog |
| `pathtracing_oidn_denoise` | true | |
| `pathtracing_dlss_rr_final` | false | |
| `pathtracing_max_bounces` | 6 | today's video value: the A/B against DLSS-RR is equal-cost and isolates the denoiser |
| `pathtracing_clamp_indirect` | 10.0 | Cycles' default; stills measured unclamped fireflies are what OIDN smears into blotches |
| `pathtracing_noise_threshold` | 0.0 | as stills |
| viewport | `SCALING_3D_MODE_BILINEAR` @ 1.0, `use_taa` off | under DLSS scaling the renderer bakes a Halton jitter into the projection and the tracer's own pixel filter jitters again -- "a soft image with ragged edges" (`render.gd`, Phase A comment) |
| `rendering/pathtracer/oidn_device` | 1 (CUDA) | |

**Per delivered frame**, inside one `_process()` call:

1. `_apply_keyframe(n)`, then `force_update_transform()` on the camera and the sun.
   Godot defers transform notifications to the end of the frame and the draws below
   happen inside this one (video port 3 met exactly this).
2. `RenderingServer.force_draw(false)` twice. The camera moved, so the first draw resets
   the accumulator and clears the OIDN latch (`render_raytracing.cpp:4312-4346`); the
   second reaches `accum_frame == 2` and OIDN fires (`render_forward_clustered.cpp:1961`).
   `force_draw` does not reach `movie_writer->add_frame`, so neither sub-frame is
   recorded.
3. Return. The main loop's own draw sees an unchanged camera and a set latch, **skips the
   trace** (`render_forward_clustered.cpp:2955`) and re-shows the denoised image. That
   draw is what MovieWriter captures.

On a held shot the camera does not move, so the frame freezes: no flicker at all, at the
cost of ignoring a sun re-orientation during the hold (`_apply_keyframe` re-orients the
sun every 5th frame).

**Adjusted in OIDN mode.**
- DLSS priming is skipped -- there is no DLSS to prime. The pre-roll falls from 26 frames
  to 21.
- The exposure probe's duplicate Environment sets `pathtracing_oidn_denoise = false`.
  Otherwise OIDN fires inside the probe at 960x540 (its output is never read) and forces
  CUDA buffer reallocation between 960x540 and 4K.
- The budget line is unchanged; it times delivered frames.

### 3. Not changed

The still route and its CPU OIDN code path; DLSS-RR mode (the default); the path tracer,
pixel filter, accumulation and OIDN latch logic; the guides (Gap #29); the exposure probe
and the fill; MovieWriter; `main.py`.

## Testing and acceptance

Every bar is set before measuring. The decisive one carries a negative control that must
fail, so it can be shown to see a real defect.

| # | test | bar |
|---|---|---|
| T1 | **CUDA == CPU in-engine.** A fixture rendered twice, `oidn_device` CPU vs CUDA. Renders are bit-deterministic on this build, so only the device differs. | no pixel 2 or more display levels apart; maximum 1 level. **Negative control:** CUDA at `quality = BALANCED` must FAIL. |
| T2 | **Stills untouched.** Job 201 at 1080p on the new binary. | byte-identical to `knee-sweep/knee_3.0.png` (md5 `2a17e6571e9bd26619591415cfaf0e08`); 25-gate suite green. |
| T3 | **Video default untouched.** `VIDEO_DENOISER = dlssrr`, job 301, 12 keyframes. | `framemd5` identical to the current build. |
| T4 | **Flicker -- decides A vs B.** urbanvideotest1; the camera alternates between pose P and P + 0.1 mm (about 0.003 px at 4K) for 30 frames. Each frame resets, so the 15 P frames are independent 6-spp renders plus OIDN of bit-identical content. A static camera would freeze the latch and read zero -- a vacuous test, which this avoids. Metric: per-pixel temporal standard deviation of 8-bit display luma across the 15 P frames, summarised as its mean and 99th percentile **over all pixels**. Frames are captured **losslessly**: the movie path ends in `.png`, so MovieWriter writes a PNG sequence (`MovieWriterPNGWAV`) -- production's MJPEG `.avi` adds its own frame-to-frame compression noise, which this metric would misread as boiling. | **mean <= 1.0 level and p99 <= 2.0 levels.** The 8-bit quantisation floor alone is about 0.29 levels; 1 level is about 3.5x that and below where low-frequency flicker becomes visible; p99 bounds the worst 1% of pixels, where boiling would show. **Negative control:** raw 6 spp, no denoiser, must FAIL. Reported alongside, not gated: DLSS-RR at the same poses (today's baseline) and OIDN at 48 spp (what B would buy). |
| T5 | **Budget.** The full 421-frame job in OIDN mode. | under 3600 s by the wall clock, with the budget line's projection reported. Over: multithread the conversion loops, re-run. |
| T6 | **VRAM and stability.** `nvidia-smi` sampled during T5. | no device loss; peak with clear margin under 16 GB. |
| T7 | **The owner's eyes.** 30 consecutive production-speed frames, OIDN vs DLSS-RR side by side, captured losslessly as for T4; edge and flat-wall crops. | the staircase and checkerboard are gone; the owner approves the look. |

**A ships when T1-T6 pass and the owner approves T7.** If T4 fails, approach B is
specified separately; A's engine work (the CUDA path) is reused by it unchanged.

## Risks, recorded

- **Boiling at 6 spp** is the central risk and is exactly what T4 measures. The fallback is
  B, already agreed.
- **Fine detail at 6 spp** is below the still's (measured, finding 4). That is the cost of
  the owner's budget and is not changed by the denoiser choice; B recovers some of it.
- **VRAM.** OIDN's CUDA scratch at 4K is added to a render that peaked at 10.8 GB on the
  worst still. T6 measures; if needed, OIDN's `maxMemoryMB` makes it tile.
- **CUDA and Vulkan on one GPU.** Separate contexts on the same device. OIDN's kernels at
  4K total about 157 ms, far below the 8 s TDR watchdog.
- **Budget margin.** Removing the per-frame DLSS-RR evaluation saves some time; the OIDN
  round trip and a second dispatch per frame cost some. Net unknown until T5.

## Out of scope (recorded)

- Approach B (temporal reuse) -- its own spec, only if T4 fails.
- Moving stills to CUDA OIDN -- its own measured change; would save about 5 s per 4K still.
- Zero-copy Vulkan-CUDA interop for the denoise round trip.
- **Still-route side finding:** OIDN also fires during the still's exposure probe
  (`accum_frame=16 target=16`) -- a full denoise whose output is never read, because
  `Daylight.probe` reads the raw accumulator. About 5 s of CPU per 4K still. Fixing it is
  a still-route change.
- Raising video bounces from 6 to the still's 12 -- a quality knob that costs budget,
  deliberately held equal for the A/B.
