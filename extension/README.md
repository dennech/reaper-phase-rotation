# reaper_phaserot

REAPER extension that applies phase rotation (broadband RX-style rotation and/or a
broadcast-style allpass rotator) to a media item's **source**.
It is the engine behind the *Phase Rotation (RX-style)* script; it has no UI of its own.

* The take's original `PCM_source` is wrapped at runtime. The wrapper returns
  `y = cos θ·x + sin θ·H{x}` (linear-phase FIR Hilbert transformer, FFT overlap-save)
  for playback, rendering, glue **and waveform peaks**. No latency, no files.
* The wrapper reports the child's type and writes the child's state, so a saved project
  contains a normal `<SOURCE WAVE …>`. The rotation lives in the take's `P_EXT:phaserot`
  string (`2 angle_l angle_r adaptive smooth bypass link ap_type ap_stages ap_freq ap_q`;
  version-1 strings without the allpass fields are still read), which REAPER keeps in the project
  and in undo states. A timer keeps sources in sync with `P_EXT` (project load, undo/redo,
  copy/paste, other scripts). Without the extension the original file plays unprocessed.
* Adaptive mode: the angle minimising the peak is estimated per 43 ms sub-block and
  interpolated between sub-block centres (computed once per take, deterministic).
* Allpass rotator (`ap_type` 1 = first-order sections, 2 = RBJ second-order sections with
  `ap_q`; `ap_stages` 1..16 identical sections at `ap_freq`) runs before the rotation. The
  IIR state follows consecutive reads and is warmed up over 0.5 s before a random-access
  read, so seeking, peak building and analysis are sample-exact.
* Preview (`PhaseRot_SetPreview`): a playback-only parameter set on the wrapper. GetSamples
  renders it, GetPeakInfo / project / undo keep the applied parameters; a wrapper is kept
  alive for a preview even when nothing is applied.
* REAPER caches the drawn peaks of an item and does not re-read them when the take's
  source object changes, so after every wrap / parameter change / reset the extension
  triggers "Peaks: Build any missing peaks" (action 40047), which makes the arrange view
  re-request peaks (measured to be the cheapest reliable trigger).

## ReaScript API

| Function | Description |
|---|---|
| `boolean PhaseRot_SetTake(take, angle_l, angle_r, adaptive, smooth, bypass, link, ap_type, ap_stages, ap_freq, ap_q)` | apply / update (degrees, RX sign convention; link=1: adaptive tracks one angle for both channels; pass `ap_type` 0 for no allpass; ReaScript requires all arguments) |
| `boolean PhaseRot_ClearTake(take)` | remove, restore the original source |
| `boolean, al, ar, adaptive, smooth, bypass, link, ap_type, ap_stages, ap_freq, ap_q = PhaseRot_GetTake(take, 0,0,0,0,0,0,0,0,0,0)` | read the settings |
| `boolean PhaseRot_SetPreview(take, angle_l, angle_r, adaptive, smooth, link, ap_type, ap_stages, ap_freq, ap_q)` | audition: playback uses these settings, project / undo / waveform keep the applied ones |
| `boolean PhaseRot_ClearPreview(take)`, `PhaseRot_ClearAllPreviews()` | end an audition |
| `boolean PhaseRot_Analyze(take)` | analyse the original audio; result in `GetExtState("phaserot","analysis")` |
| `boolean PhaseRot_AnalyzeEx(take, ap_type, ap_stages, ap_freq, ap_q)` | the same, with the audio passed through the allpass rotator first (`peak_orig` in the result is the original peak) |
| `PhaseRot_Refresh()` | re-sync all takes now |
| `string PhaseRot_GetVersion()` | version |
| `boolean PhaseRot_GetDebug(take)` | debug counters of the take's wrapper in `GetExtState("phaserot","debug")` |

Wrap calls in `Undo_BeginBlock()` / `Undo_EndBlock()` to make them undoable.

## Building

```bash
cmake -S extension -B extension/build -DCMAKE_BUILD_TYPE=Release   # add -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" on macOS
cmake --build extension/build --config Release
```

Copy the resulting `reaper_phaserot.dylib` / `.dll` / `.so` into `<resource path>/UserPlugins/`
and restart REAPER. Binaries for macOS (universal), Windows x64 and Linux (x86_64, aarch64)
are built by GitHub Actions and attached to releases; ReaPack installs them from the
repository index.

Vendored: REAPER plugin SDK headers (Cockos), WDL `fft.c` and swell headers (Cockos, zlib license).
