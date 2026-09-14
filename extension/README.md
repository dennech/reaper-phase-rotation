# reaper_phaserot

REAPER extension that applies broadband phase rotation to a media item's **source**.
It is the engine behind the *Phase Rotation (RX-style)* script; it has no UI of its own.

* The take's original `PCM_source` is wrapped at runtime. The wrapper returns
  `y = cos θ·x + sin θ·H{x}` (linear-phase FIR Hilbert transformer, FFT overlap-save)
  for playback, rendering, glue **and waveform peaks**. No latency, no files.
* The wrapper reports the child's type and writes the child's state, so a saved project
  contains a normal `<SOURCE WAVE …>`. The rotation lives in the take's `P_EXT:phaserot`
  string (`1 angle_l angle_r adaptive smooth bypass link`), which REAPER keeps in the project
  and in undo states. A timer keeps sources in sync with `P_EXT` (project load, undo/redo,
  copy/paste, other scripts). Without the extension the original file plays unprocessed.
* Adaptive mode: the angle minimising the peak is estimated per 43 ms sub-block and
  interpolated between sub-block centres (computed once per take, deterministic).

## ReaScript API

| Function | Description |
|---|---|
| `boolean PhaseRot_SetTake(take, angle_l, angle_r, adaptive, smooth, bypass, link)` | apply / update (degrees, RX sign convention; link=1: adaptive tracks one angle for both channels) |
| `boolean PhaseRot_ClearTake(take)` | remove, restore the original source |
| `boolean, al, ar, adaptive, smooth, bypass, link = PhaseRot_GetTake(take, 0,0,0,0,0,0)` | read the settings |
| `boolean PhaseRot_Analyze(take)` | analyse the original audio; result in `GetExtState("phaserot","analysis")` |
| `PhaseRot_Refresh()` | re-sync all takes now |
| `string PhaseRot_GetVersion()` | version |

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
