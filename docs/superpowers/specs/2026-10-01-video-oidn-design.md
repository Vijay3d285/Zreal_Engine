# Video OIDN: per-frame OpenImageDenoise for the video route

**Date:** 2026-10-01. **Status:** landed 2026-10-06 in `pipeline_references` as the selectable
video mode (`ZR_VIDEO_DENOISER=oidn`) at **4 samples per pixel** (4 sub-frames, one sample
each); DLSS-RR stays the default. The owner ships to production; "shipped" below means the
committed default. **Corrected 2026-10-06 (final review): every OIDN sample count in this
document was 3 times too high** -- see the Correction at the top of Measured. The design below
is the 2026-10-01 text, relabelled; where it says 2 samples or "2 sub-frames" the shipped
value is 4 samples / 4 sub-frames, and the corrected figures and the outcome of every test are
in **Measured (2026-10-06)** at the end. **Scope:** engine
(`modules/raycaster_oidn`, one settings line, one log rate-limit) and the video pipeline
(`video_glb_creation.gd`, `video_render.gd`).
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
   the sample count at **about 6 samples per pixel per frame**, the same as today (DLSS-RR's
   one-shot value). *(Correction 2026-10-06: the design reached "6" as 2 sub-frames of 3 spp,
   but a sub-frame is one sample, so what was built and measured is 2 samples per pixel, a
   third of DLSS-RR's. Superseded 2026-10-06: the full job measured 1512 s at 2 samples, so
   there was room; the owner chose 4 samples, labelled 12 spp at the time, about 2400 s. See
   Measured.)*
3. **Approach A first** (per-frame OIDN, measured against a flicker bar); **approach B**
   (temporal reuse of radiance before OIDN) only if A fails that bar, under its own spec.
   *(Outcome 2026-10-06: the flicker bar could not be validated; the owner judged by eye,
   chose A, and B is not pursued now. See Measured, T4 and T7.)*
4. **Stills stay on CPU OIDN.** The still route must not change. *(Task 1-2 kept it; the
   later guide fix of 2026-10-04, `2026-10-04-oidn-guide-feature-passthrough-design.md`,
   deliberately changed still output, by owner decision. See Measured, T2.)*

## What was measured before designing

1. **OIDN cost at 4K**, HDR with clean auxiliaries (`oidnBenchmark
   RT.hdr_calb_cnrm.3840x2160`): CPU **5270 ms/frame**, CUDA (RTX A4000) **157 ms** --
   34x. On the current CPU path, denoising alone would add 37 minutes to a 421-frame video.
2. **OIDN 2.5.0's default quality is HIGH on both devices** (CUDA default 156.57 ms ==
   high 156.63 ms; balanced 76.74 ms). The engine never sets `quality`, so it has never
   been silently degraded.
3. **CUDA OIDN is visually identical to CPU OIDN on a real frame.** Job 201 at 1080p,
   2 samples per pixel, the engine's own OIDN inputs dumped with `ZR_OIDN_DUMP`, denoised by
   `oidnDenoise -q high --clean_aux` on each device, compared after exposure: **no pixel
   2 or more display levels apart, maximum 1 level, display PSNR 61.8 dB**; relative error
   p50 0.09%, p99 0.38%, max 2.2%.
4. **2 samples + OIDN against 256 samples + OIDN**, identical pipeline (job 201, same probe,
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
  `accum_frame < 5`. With target 2 that is 1 skip line + 3 denoise lines = 4 per frame, about
  1,700 lines over 421 frames (at the shipped target 4 it is 3 + 3 = 6 per frame, about 2,500,
  i.e. 1.5x).

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
*(T5 measured 2380 s at the shipped 4 samples, so the trigger did not fire. The 8-sample job
did exceed 3600 s; the GPU profile shows the path tracer's 1.02 s per sub-frame (one sample)
dominates it. The fixed non-tracer cost is about 1.1 s per frame (about 11% of an 8-sample
frame) and was not decomposed; removing all of it would take the 8-sample job from 4150 s to
about 3690 s, still over 3600 s. See Measured.)*

### 2. Pipeline: a video OIDN mode

**Switch.** `const VIDEO_DENOISER := "dlssrr"` in `video_glb_creation.gd`, overridden by
the environment variable `ZR_VIDEO_DENOISER` (`dlssrr` | `oidn`). On `dlssrr` nothing
changes -- T3 proves it frame-for-frame.

**Setup in OIDN mode** -- a mirror of the still route's Phase A, not a reinterpretation:

| setting | value | reason |
|---|---|---|
| `pathtracing_denoiser` | 0 | DLSS-RR is not the integrator |
| `pathtracing_accumulate` | true | Phase A |
| `pathtracing_accumulation_target` | 4 (`VIDEO_OIDN_ACCUM_TARGET`; designed as 2) | 4 sub-frames of one sample each = **4 samples per pixel**, the shipped value (owner, 2026-10-06; 2 samples, then labelled 6 spp, was the 2026-10-01 design) |
| `pathtracing_samples_per_pixel` | 3 | read only by the one-shot (accumulate off) draws, i.e. the settle draws of the accumulator reset; Phase A's accumulate branch traces one sample per draw and ignores it, so it is NOT the image's sample count. The still route's day value, kept under the TDR watchdog |
| `pathtracing_oidn_denoise` | true | |
| `pathtracing_dlss_rr_final` | false | |
| `pathtracing_max_bounces` | 6 | today's video value: the A/B against DLSS-RR holds the bounces equal (the samples per pixel are not: 4 here, 6 for DLSS-RR; see the Correction) |
| `pathtracing_clamp_indirect` | 10.0 | Cycles' default; stills measured unclamped fireflies are what OIDN smears into blotches |
| `pathtracing_noise_threshold` | 0.0 | as stills |
| viewport | `SCALING_3D_MODE_BILINEAR` @ 1.0, `use_taa` off | under DLSS scaling the renderer bakes a Halton jitter into the projection and the tracer's own pixel filter jitters again -- "a soft image with ragged edges" (`render.gd`, Phase A comment) |
| `rendering/pathtracer/oidn_device` | 1 (CUDA) | |

**Per delivered frame**, inside one `_process()` call:

1. `_apply_keyframe(n)`, then `force_update_transform()` on the camera and the sun.
   Godot defers transform notifications to the end of the frame and the draws below
   happen inside this one (video port 3 met exactly this).
2. `RenderingServer.force_draw(false)` once per sub-frame: `VIDEO_OIDN_ACCUM_TARGET` times
   (shipped 4; designed as 2). The camera moved, so the first draw resets the accumulator
   and clears the OIDN latch (`render_raytracing.cpp:4312-4346`); the last reaches
   `accum_frame == target` and OIDN fires (`render_forward_clustered.cpp:1961`).
   `force_draw` does not reach `movie_writer->add_frame`, so no sub-frame is recorded.
3. Return. The main loop's own draw sees an unchanged camera and a set latch, **skips the
   trace** (`render_forward_clustered.cpp:2955`) and re-shows the denoised image. That
   draw is what MovieWriter captures.

On a held shot the camera does not move, so the frame freezes: no flicker at all, at the
cost of ignoring a sun re-orientation during the hold (`_apply_keyframe` re-orients the
sun every 5th frame).

**Adjusted in OIDN mode.**
- DLSS priming is skipped -- there is no DLSS to prime. Measured layout (Task 2): every
  movie is the pre-roll, then the delivered frames, then ONE trailing frame; the pre-roll is
  **20** frames in OIDN mode (20 warmup) and **25** in DLSS-RR mode (20 warmup + 5 priming).
  The full 421-frame job is therefore 20 + 421 + 1 = **442** frames in OIDN mode (delivered
  = indices 20..440) and 25 + 421 + 1 = 447 in DLSS-RR mode; the 12-keyframe test job is
  33 = 20 + 12 + 1 (OIDN) and 38 = 20 + 5 + 12 + 1 (DLSS-RR). The 2026-10-01 text said the
  pre-roll "falls from 26 to 21" and counted the extra frame as a leading one; both were
  off by one. See Measured, "Frame layout", for what the DLSS-RR frames actually contain.
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
| T4 | **Flicker -- was to decide A vs B.** | **Not validated.** Two instruments were built; each failed its own pre-registered negative control, so no numeric gate decided A vs B. The owner decided by eye at T7 (review material from 2026-10-04; decision 2026-10-06). The measurements are recorded under Measured, T4. |
| T5 | **Budget.** The full 421-frame job in OIDN mode. | under 3600 s by the wall clock, with the budget line's projection reported. Over: multithread the conversion loops, re-run. |
| T6 | **VRAM and stability.** `nvidia-smi` sampled during T5. | no device loss; peak with clear margin under 16 GB. |
| T7 | **The owner's eyes.** 30 consecutive production-speed frames, OIDN vs DLSS-RR side by side, captured losslessly as for T4; edge and flat-wall crops. | the staircase and checkerboard are gone; the owner approves the look. |

**A ships when T1-T6 pass and the owner approves T7.** If T4 fails, approach B is
specified separately; A's engine work (the CUDA path) is reused by it unchanged.
*(Outcome: T1-T3, T5, T6 passed; T4 could not be validated. T7 was not recorded as an
approval: the record shows the owner's decisions to render the converged frame first, to test
4 and 8 samples first (then labelled 12 and 24 spp), to render the full video at 8 samples
(24 spp), and (2026-10-06) to set the recommended 4 samples (12 spp); A was chosen and B is not
pursued now. See Measured.)*

## Risks, recorded

Each risk below is written as designed on 2026-10-01; the note after it is what was measured.

- **Boiling at 2 samples** is the central risk and is exactly what T4 measures. The fallback is
  B, already agreed. *Measured: T4 could not separate boiling from texture sliding past the
  camera; descriptive numbers at 8 samples show flat walls level with DLSS-RR and only the thin
  window mullion edge about twice DLSS-RR's frame-to-frame residual. The owner judged by eye
  and chose A; B is not pursued now.*
- **Fine detail at 2 samples** is below the still's (measured, finding 4). That is the cost of
  the owner's budget and is not changed by the denoiser choice; B recovers some of it.
  *Measured: against a 256-sample reference, on lossless frames, the shipped 4 samples are
  closer than DLSS-RR on the whole frame, door, bicycle, plant and pictures; in the delivered
  MJPEG movie the whole-frame error is level with DLSS-RR (4.75 vs 4.64). Fine text (the AC
  label) is legible at 8 samples (label RMSE 2.62 vs DLSS-RR 2.50).*
- **VRAM.** OIDN's CUDA scratch at 4K is added to a render that peaked at 10.8 GB on the
  worst still. T6 measures; if needed, OIDN's `maxMemoryMB` makes it tile. *Measured: the
  video job peaks at 15947-16001 MiB of 16376 (97.4-97.7%) in both modes (one run each for
  the DLSS-RR / OIDN comparison); OIDN uses no more than DLSS-RR. The margin is thin; that it
  is the scene's is plausible but not demonstrated.*
- **CUDA and Vulkan on one GPU.** Separate contexts on the same device. OIDN's kernels at
  4K total about 157 ms, far below the 8 s TDR watchdog. *Measured: no device loss in any
  full-job run.*
- **Budget margin.** Removing the per-frame DLSS-RR evaluation saves some time; the OIDN
  round trip and a second dispatch per frame cost some. Net unknown until T5. *Measured: the
  cost is dominated by path tracing, about 1.02 s per sub-frame (one sample); see Measured, T5 and
  the GPU profile.*

## Out of scope (recorded)

- Approach B (temporal reuse) -- its own spec, only if T4 fails. *(Not pursued now: owner,
  2026-10-06. A's engine work is reusable by it unchanged if more fine detail is wanted
  later.)*
- Moving stills to CUDA OIDN -- its own measured change; would save about 5 s per 4K still.
- Zero-copy Vulkan-CUDA interop for the denoise round trip.
- **Still-route side finding:** OIDN also fires during the still's exposure probe
  (`accum_frame=16 target=16`) -- a full denoise whose output is never read, because
  `Daylight.probe` reads the raw accumulator. About 5 s of CPU per 4K still. Fixing it is
  a still-route change.
- Raising video bounces from 6 to the still's 12 -- a quality knob that costs budget,
  deliberately held equal for the A/B.

## Measured (2026-10-06)

Runs 2026-10-02 to 2026-10-06 on the RTX A4000, urbanvideotest1 (421 keyframes, 4K, 60 fps)
unless stated; raw logs and images are under `.superpowers/sdd/2026-10-01-video-oidn/`
(untracked working notes). The engine is the build of commit `a098ece884` for every run from
T5 onward.

**Correction (final review, 2026-10-06): every OIDN sample count in this document was 3 times
too high.** A Phase A draw traces ONE sample per pixel. The raygen accumulate branch calls
`trace_one_sample` once per launch and blends the result into the running average
(`scene_raytracing_raygen.glsl`, "blend one 1-SPP sample per launch"); the C++ issues one
`trace_rays` per draw and then advances `accum_frame` (`render_forward_clustered.cpp`).
`pathtracing_samples_per_pixel` feeds only the one-shot branch, which Phase A never takes, so a
delivered frame holds `VIDEO_OIDN_ACCUM_TARGET` samples per pixel, not target x 3. The times,
images, RMSE values and cost figures in this section are measurements and did not change; the
labels did:

| written | actual samples per pixel |
|---|---|
| 6 spp (target 2) | 2 |
| 12 spp (target 4, the shipped default) | 4 |
| 24 spp (target 8) | 8 |
| 48 spp (target 16) | 16 |
| 768 spp (target 256) | 256 |
| "9-spp" raw frames (target 2 plus the main loop's own draw, no OIDN latch) | 3 |

Per-sample cost is about 1.0 s at 4K (the GPU profile: "Pathtracer" 1010 ms per draw, one
sample per draw), not 0.34 s. The shipped configuration is therefore **4 samples per pixel per
frame**. Its comparison partner, the DLSS-RR video, traces **6** samples per pixel per frame
(`set_pathtracing_samples_per_pixel(6)` in the DLSS-RR branch of `video_glb_creation.gd`, the
one-shot path, whose raygen loop runs the packed count) plus its temporal reuse. The DLSS-RR
log line said "spp=4" and the comment beside the 6 said "4 SPP": stale text, not the value
(the production copy of the script also sets 6); both now read 6, text only. So the 2026-10-01 design's "6 spp, the same as today" was 2
samples against DLSS-RR's 6, and the shipped 4 is two thirds of them. A corroboration that does
not depend on reading the code: the keyframe-210 window's 92.7% unwritten guide pixels
(`2026-10-04-oidn-guide-feature-passthrough-design.md`) is close to what two samples through a
pane that passes 96.7% of rays give (0.967^2 = 93.5%); six samples would give 80.2%, which that
spec's own 6-sample 256x256 probe measured. Where this section says "OIDN at 6 / 12 / 24 spp" read 2 / 4 /
8 samples; run directories and file names (`spp_6`, `oidn6`, `oidn48`) keep their old labels.

**T1 -- CUDA == CPU in-engine: passed.** Fixture: 83.61% of floats differ between the devices,
**0 pixels 2 or more display levels apart**, maximum 1 level. Job 201 at 1080p (the engine's
own dumped inputs, input md5s identical on both devices): 100.00% of floats differ, **0.0000%
of pixels 2 or more levels apart, maximum 1**, display PSNR 61.46 dB. The negative control
works: CUDA at `quality = BALANCED` against CPU HIGH on the same inputs reads 80.41% of pixels
2 or more levels apart, maximum 173, 33.3 dB, so a quality drop cannot hide in the bar.

**T2 -- stills unchanged by the CUDA work: passed as an A/B, not as a byte gate.** The archived
md5 `2a17e657...` is a two-state coin flip on this machine: job 201 at 1080p produces either
`befe659d...` or `2a17e657...`, which differ in about 2 of 2,073,600 pixels by one display
level (the engine's own render nondeterminism). The new binary gave `befe659d` 3 of 5 times
and `2a17e657` 2 of 5 (and `befe659d` 4 of 4 with `ZR_OIDN_DUMP` set, with identical OIDN
input and output hashes); the pre-change binary gave `befe659d` 5 of 6 and `2a17e657` 1 of 6;
every run printed the same 24 `[OIDN-DIAG]` lines. So "stills unchanged" is a comparison of
two binaries in one session state. **The later guide fix did change stills, deliberately** (see
below): against the pre-change still, job 201 at 1080p on the final fix build has a mean-pixel
ratio of 0.99981 with 0.905% of pixels 8 or more levels off (the first fix commit read
1.03%), md5 `10c98486960c8bca460f63f8e146f75c`
(`2026-10-04-oidn-guide-feature-passthrough-design.md`, Measured).

**T3 -- the video default is untouched: passed.** `VIDEO_DENOISER = dlssrr`, job 301, 12
keyframes, 38 frames: `ffmpeg -f framemd5` **38 of 38 frames identical** before and after the
pipeline changes, and 38 of 38 again after the guide fix (the guide fix is compiled only into
the accumulate variant; DLSS-RR one-shot GPU time +0.18%, inside the run-to-run floor).

**T4 -- flicker: not validated; measured on 2026-10-03.** Two instruments were built and each
failed its own pre-registered negative control, so no numeric gate decided A vs B. The owner
decided by eye at T7.

- *Design 1* (one pose held for 30 frames, accumulator force-reset each frame): **blind.** The
  raw 3-sample frames read a mean of 0.033 levels, and all 30 delivered frames were
  md5-identical in both the raw and the OIDN runs. Cause: the accumulate route seeds from
  `accum_frame`, which resets with the accumulator (`scene_raytracing_raygen.glsl:417-421`),
  so every cycle replays the same Sobol sequence -- as Cycles gives every frame one seed by
  default (`use_animated_seed = False`, `blender/addon/properties.py:905-908`;
  `blender/sync.cpp:408`). Consequence for production: **on static content, OIDN video cannot
  flicker.**
- *Design 2* (urbanvideotest1 keyframes 0-29 at production speed; per-pixel temporal second
  difference on the flattest half of the frame, one mask from the 16-sample run): d2 rms raw
  28.717, oidn6 (2 samples; the run keeps its old name) 14.033, oidn48 (16 samples) 13.801,
  dlssrr 13.215. The negative control (raw / dlssrr)
  read 2.17 against a pre-registered 3.0: **FAILED.** A content floor of about 13.8 levels
  (texture sliding past at constant speed; the motion-smeared mean made the "flat" mask
  permissive) swamps the noise. The gate's 1.062 is therefore not a verdict, and is biased
  besides: DLSS-RR reads 4.2% *below* the near-noise-free 16-sample reference because its
  temporal smoothing also damps moving texture.
- *Descriptive, post-hoc, not a gate:* in quadrature against the 16-sample run, raw adds 25.18
  levels of temporal noise and 2-sample OIDN 2.54; 2 samples read 1.7% above 16 samples (same
  denoiser, same frames, only the samples differ) -- 8x the samples barely moved stability.
- *Defect found in the plan's metric code:* the flat-mask box blur summed in float32 over a 4K
  frame (sums about 2e9, float32 spacing 128-256), wrong on 43.8% of pixels in a synthetic
  check; fixed to float64. The plan-verbatim version gave control 1.92 and gate 1.047 -- the
  same outcomes.
- *Descriptive motion numbers at 8 samples (2026-10-05, keyframes 203-217, camera motion
  included, not a gate):* flat walls level with DLSS-RR (first-difference rms 0.249 / 0.262 vs
  0.250 / 0.255); window glass quieter than DLSS-RR (0.43 / 0.51 vs 1.18 / 0.80); AC label,
  plant and bicycle within 5-11% of DLSS-RR on a translation-registered residual; the thin
  black window mullion about twice DLSS-RR's residual (3.67 vs 1.77), the one place a viewer
  might see shimmer.

**T5 -- budget (full 421-frame job, `VIDEO_RENDER_TIMEOUT_SECONDS` 3600).** Same job, same
scene; only the sub-frame count differs:

| run | samples per pixel | seconds | `[Budget]` projection (delivered frames 10-30) | VRAM peak (MiB of 16376) | movie frames | held exposure |
|---|---|---|---|---|---|---|
| before the guide fix (2026-10-04) | 2 | 1501 | 3.28 s/frame -> 1510 s | 15987 | 442 | 0.7659 |
| after the guide fix | 2 | 1512 | 3.30 s/frame -> 1523 s | 15984 | 442 | 0.7659 |
| after the guide fix | 8 | **4150** | 9.79 s/frame -> 4262 s, "WILL BE KILLED" | 15997 | 442 | 0.7659 |
| **shipped default** | **4** | **2380** | 5.42 s/frame -> 2413 s, "fits" | 15947 | 442 | 0.7659 |

Every run: `[OIDN] denoising on CUDA (quality HIGH, 3840x2160)` once and no fallback, no
device loss, no fence error, one engine banner. DLSS-RR's own run of this job (2026-09-30)
held 0.7660; the 0.7659 vs 0.7660 difference is the exposure probe's run-to-run noise (the
same job on the same binary differs by 1-2e-4 in other pairs of runs). The shipped 4 samples fit
the hour with 34% to spare; 8 samples do not (production `main.py` would kill Godot at 3600 s,
around frames 350-365: 432 s were spent at frame 30, then 9.5-9.8 s/frame). The test harness
does not enforce the timeout; it only feeds the `[Budget]` verdict.

**The GPU profile (2026-10-06): the cost is dominated by the path tracer.**
Moving segment, keyframes 180-215, 8 samples, `--gpu-profile` with the timestamp-query limit
raised to 8192 in the scratch project (0 overflows, 139 profile blocks over delivered frames
10-30 of the segment): each drawn frame, i.e. one sub-frame (one sample), costs a **median 1017.8 ms
of GPU, of which the "Pathtracer" task is 1010.3 ms**; all raster, post and TLAS work together
is about 8 ms. That is about 1.0 s per sample at 4K (the 0.34 s first written divided by 3
samples that were never traced). The `[Budget]` of 9.39 s/frame at 8 samples
in that run decomposes as 8 x 1.02 s + the OIDN denoise and conversions + about 1.1 s fixed
per frame. The profile covers GPU time only: the fixed non-tracer cost of about 1.1 s per
frame (about 11% of an 8-sample frame) was not decomposed. Per-frame cost did not vary with the
view beyond the run-to-run spread (10.51 s/frame at keyframes 190-210 and 9.39 in the clean
profiled run, against 9.79 at keyframes 10-30: a spread of about 12%). Earlier static-job
timings are invalid: after the first converged
frame a static job holds the OIDN latch and skips the trace (2 denoises per 5-frame run),
which is why a projection built on them (0.387 s per sub-frame, the 8-sample job about 2490 s)
was 40% low. Removing all of the fixed cost would take the 8-sample job from 4150 s to about
3690 s, still over 3600 s, so 8 samples per pixel need a faster tracer.

**T6 -- VRAM and stability: passed, with a thin margin.** Peak
15947-15997 MiB of 16376 MiB in every full run (margin 2.3-2.6%), flat for the whole job, no
device loss. Attribution run (urbanvideotest1 segment, 1 s samples): DLSS-RR peak 16001 MiB
(late median 15891), OIDN 15950 (late median 15822): **OIDN uses no more VRAM than DLSS-RR**.
Both sit at 97.4-97.7% of capacity (n = 1 each), so attributing the ceiling to the scene plus
the driver is plausible but not demonstrated.

**Converged reference (2026-10-05) -- OIDN against DLSS-RR, both against 256 samples.** Keyframe
210 held static, 256 sub-frames of one sample (256 samples per pixel) through the same OIDN path, exposure forced
to 0.7659 (no fill was placed in the full run, so forcing is equivalent), lossless PNG; the
reference's frames 20-23 are identical (frame 24 RMSE 0.22). OIDN at 2, 4 and 8 samples from
static renders of the same frame, lossless; DLSS-RR lossless from a moving segment
(keyframes 180-215, exposure 0.7660, delivered keyframe 210 = idx 56, whose RMSE against its
neighbours is at least 19.7, so it is the right frame). RMSE against the 256-sample frame in
8-bit display levels, lower is better:

| region | OIDN 2 samples | OIDN **4 samples** (shipped) | OIDN 8 samples | DLSS-RR (6 spp + temporal) |
|---|---|---|---|---|
| whole frame, lossless | 3.53 | **2.81** | 2.27 | 4.05 |
| whole frame, delivered MJPEG movie frame (OIDN idx 230, DLSS-RR idx 236) | 5.15 | 4.75 | 4.52 | **4.64** |
| AC label (fine text) | 4.90 | 4.03 | 2.62 | **2.50** |
| door (window exterior) | 3.25 | **2.50** | 2.10 | 5.61 |
| bicycle (thin spokes) | 6.04 | **4.46** | 3.62 | 5.62 |
| wall (flat) | 0.56 | 0.48 | 0.41 | 0.43 |
| plant | 5.26 | **4.03** | 3.21 | 5.69 |
| pictures | 5.72 | **4.09** | 3.20 | 5.07 |

**On lossless frames** OIDN at 4 samples is closer to the reference than DLSS-RR on the whole
frame, door, bicycle, plant and pictures. DLSS-RR is closer on the label (the "SAMSUNG"
letters are an unreadable bar at 4 samples and legible at 8, label RMSE 2.62 vs DLSS-RR
2.50) and, by 0.05 of a level, on the flat wall. DLSS-RR's regular mesh on the door is an
artefact: it is absent from the reference.

**In the delivered MJPEG movie the whole-frame error is level with DLSS-RR** (4.75 vs 4.64 at
4 samples; DLSS-RR 0.11 closer; 8 samples is 0.12 closer than DLSS-RR). The MJPEG row decodes the
delivered movie frames at the aligned keyframe (OIDN idx 230 of the 2 / 4 / 8-sample job movies,
DLSS-RR idx 236 of the 2026-09-30 movie) and compares each with the reference (frame 22 or
frame 24; they agree to 0.001), whole-frame RGB RMSE recomputed 2026-10-06: 5.155 / 4.748 /
4.517 / 4.641 before rounding. Taking the codec's error to add in quadrature, it is about
3.8 levels on the OIDN frames (3.76 / 3.82 / 3.91 at 2 / 4 / 8 samples) and about 2.3 on
DLSS-RR's; these are estimates, because every lossless frame is a separate render from the
job movie (a static run, or a moving segment for DLSS-RR) and so also carries
render-to-render noise. The per-region rows are lossless on purpose (the codec noise would swamp them),
but the MJPEG movie is what is delivered, so the tie is the headline. It is a single
frame; temporal behaviour is covered under T4 and T7.

*Why OIDN keeps the label at 256 samples and not at 2:* the 2-sample albedo guide carries the
text sharply, yet OIDN erases it. An offline test on the engine's own 2-sample inputs (`oidnDenoise`)
compared the engine's configuration (prefiltered guides + `cleanAux`, which is Cycles'
`ACCURATE`) with two alternatives. Whole-frame / label error: engine configuration 4.02 /
6.27; raw (unfiltered) guides with `cleanAux` 10.08 / 10.16 with door speckle (door 35.7);
raw guides without `cleanAux` 4.53 / 5.57. The engine's configuration is the best overall
(the third reads the label slightly better and everything else worse), so the sample count,
not the filter set-up, is the limit. (An offline ranking in that experiment's own display
transform; not comparable in absolute terms with the table above.)

**Frame layout, measured: the DLSS-RR output lags the camera by one frame.** Every movie is
the pre-roll, the delivered frames, and one trailing frame: OIDN 20 + 421 + 1 = 442, DLSS-RR
25 + 421 + 1 = 447 (12-keyframe job: 33 = 20 + 12 + 1 and 38 = 20 + 5 + 12 + 1). By content,
however, the DLSS-RR movie is shifted: its delivered frames 25 and 26 are both keyframe 0
(consecutive-frame MSE 0.2, noise), the camera first moves at 26 -> 27, delivered frame 445
is keyframe 419, and **keyframe 420 sits in the "trailing" frame 446**. A best-match search of
every OIDN frame against the DLSS-RR movie gives an offset of +6, not +5, for 421 of 422
frames (+5 for the trailing duplicate); at keyframe 210 OIDN idx 230 matches DLSS-RR idx 236
to 0.004 px (RMSE 4.4 levels), against 5.7 px / 20.3 levels at the nominal idx 235. The OIDN
movie is exact: idx 19 == 20 == keyframe 0 (the denoised re-show), delivered 20..440 =
keyframes 0..420, idx 441 == 440. **Aligning the two takes `trim=start_frame=26:end_frame=447`
on the DLSS-RR movie**; a frame-count trim of 25 on a DLSS-RR movie ships a duplicated first
frame and leaves the last pose out of the delivered range. This is a property of the
unmodified DLSS-RR path (owner rule: not changed here), recorded rather than fixed.

**The glass blotches and Task 5.** The first 2-sample review (2026-10-04) showed the view through
the window blotchy in OIDN and clean in DLSS-RR. Root cause: `inc_transmission_bounce()` adds a
bounce and every OIDN guide write is gated on `total_bounces == 0`, so a surface seen through
an alpha pane wrote no guide (keyframe-210 window: **92.7% of guide pixels unwritten**) and
OIDN smeared the exterior. The fix ported Cycles' denoising-feature pass-through and its
deferral through smooth specular surfaces (glass, mirrors, smooth metal) to the accumulate
path (window: 92.7% -> 0.00% unwritten; blotches gone; aligned MSE against DLSS-RR 6.36 ->
5.79 at 2 samples), compiled only into the accumulate variant so DLSS-RR output is
frame-identical. The full account, gate and measurements are in
`docs/superpowers/specs/2026-10-04-oidn-guide-feature-passthrough-design.md`; it is the
reason the window blotches are gone, at the shipped 4 samples too. Known consequence, as in
Cycles: a smooth metal frame defers, so its guide follows its reflection; the window mullions
read clean but their frame-to-frame residual is about twice DLSS-RR's (T4, motion numbers).

**T7 -- the owner's decision (relayed 2026-10-06).** The review ran on the 2-sample material
(2026-10-04), the guide fix and re-render, the converged reference and the 4 / 8-sample tests
(2026-10-05), and the 8-sample full job and the GPU profile (2026-10-05 and 06). The decision,
as relayed: "OIDN video runs at 12 spp" (the label of the time; the setting is 4 samples per
pixel), and DLSS-RR stays the video default
(`VIDEO_DENOISER := "dlssrr"`, unchanged); OIDN is the selectable mode
(`ZR_VIDEO_DENOISER=oidn`). Approach A was chosen; approach B (temporal reuse) is not pursued
now. The constant is `VIDEO_OIDN_ACCUM_TARGET := 4` (4 samples per pixel) in
`pipeline_references/video_glb_creation.gd`. The record holds these decisions rather than an
explicit approval of the look, quoted in the labels of the time (12 spp = 4 samples, 24 spp = 8):
"render the converged frame first", "test 12 and 24 samples first", "render the full video at 24
samples", and "set the recommended 12".

**Follow-ups, not done:** approach B only if more fine detail is wanted than 4 samples give;
moving stills to CUDA OIDN (about 5 s per 4K still); the still route's wasted denoise inside
its exposure probe; a faster tracer or a per-clip sample choice if 8 samples (legible fine text,
label RMSE 2.62 vs DLSS-RR 2.50) are ever wanted inside an hour; DLSS-RR's one-frame lag, if the DLSS-RR path is ever opened.
Ship manifest: the engine binary (the CUDA path and the guide fix are C++ and GLSL) plus
`pipeline_references/video_glb_creation.gd` and `pipeline_references/video_render.gd`.
