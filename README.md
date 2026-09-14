# Phase Rotation (RX-style) for REAPER

A REAPER re-creation of the **iZotope RX "Phase" module**, for media items.

Voice recordings are almost always asymmetric: the positive and negative
peaks have different heights. Rotating the phase of *all* frequencies by the
same angle does not change how the audio sounds, but it redistributes the
peaks - the waveform becomes symmetric and you gain headroom. RX does this
with a **Suggest** button, **Left/Right rotation** sliders and an **Adaptive
phase rotation** mode. This project does the same inside REAPER:

| RX Phase module            | This script                                                                 |
|----------------------------|-----------------------------------------------------------------------------|
| Suggest                    | Analyses each selected item and sets the channel-linked fixed rotation. Reproduces RX 10's own Suggest values (verified against RX renders, see `tests/RX_REFERENCE.md`); a "minimum sample peak" criterion is available too |
| Left / Right rotation [°]  | Sliders -180..+180 with a value box (click to type), Link button            |
| Adaptive phase rotation    | The JSFX re-estimates the best angle every ~43 ms and glides between values |
| Preview / Bypass           | Plays the item from its start; Bypass toggles the take FX                  |
| Render                     | Optional: bakes the rotation into a new take (original kept as a take by default). The rotation is already applied live by the take FX - Render only makes the waveform display reflect it |
| Compare                    | Not implemented - use Bypass and REAPER's undo instead                      |

Everything is non-destructive: the script inserts the bundled JSFX
**"Phase Rotation (RX-style, Hilbert)"** as a *take FX* on each selected item, so
the item plays rotated immediately - no rendering or editing needed. **Render** is
optional (RX has to render because it edits files; REAPER does not): press it only
if you want a new take whose waveform *display* shows the symmetric shape, or want
to free the take FX. Angles use the same sign convention as RX.

*(Screenshot of the UI: see the [GitHub page](https://github.com/dennech/reaper-phase-rotation).)*

## Installation

### ReaPack (recommended)

1. Extensions → ReaPack → Import repositories…
2. Paste `https://github.com/dennech/reaper-phase-rotation/raw/main/index.xml`
3. Install **Phase Rotation (RX-style).lua** from the *REAPER Phase Rotation* repository.
   The JSFX is installed together with the script.

### Manual

1. Copy the `Items` folder into `<REAPER resource path>/Scripts/` (rename it as you like,
   e.g. `Scripts/Phase Rotation/`). The three files must stay together:
   `Phase Rotation (RX-style).lua`, `phase_rotation_core.lua`, `phase_rotation.jsfx`.
2. Actions → Show action list → *New action…* → *Load ReaScript…* → pick the `.lua`.
3. On first run the script copies `phase_rotation.jsfx` into `Effects/Phase Rotation/`
   so that REAPER can load it.

Requires REAPER 6.x or newer (tested on 7.80, macOS). No extensions needed
(plain `gfx` UI, no ReaImGui / SWS / js_ReaScriptAPI).

## Usage

1. Select one or more **audio items** (mono or stereo).
2. Run the action **Script: Phase Rotation (RX-style).lua**.
3. Press **Suggest** (or `S`). Each item gets its own analysis and angle. The window shows
   the peak before/after, positive/negative peaks and the headroom you gain, plus a small
   polar plot of *envelope vs. phase* (grey = before, blue = current rotation; the
   horizontal extent of the shape is the peak level).
4. **Preview** (`Space`) / **Bypass** (`B`) to listen. Drag the sliders for manual
   adjustment (Shift = fine, mouse wheel = 1°, double-click = 0°, click the value box to
   type a number).
5. **Render** bakes the take FX into a new take. Track FX are bypassed during the render so
   only the phase rotation is applied; the original take is kept (change this in the `...`
   menu). Undo works as usual.

Multi-selection: **Suggest / Bypass / Render / Remove FX / Adaptive / Link act on all
selected items**, the sliders edit the item shown in the *Item i / n* navigator.

**Adaptive phase rotation** follows the signal instead of using one fixed angle - useful
when the asymmetry changes over time (several speakers, long takes). The response time is
set in the `...` menu (100 ms … 2 s). Like RX, it is meant for dialogue; on music a fixed
angle is usually cleaner.

The JSFX can also be used on its own (track FX or take FX) - it has the same controls.

## How it works

* **Rotation**: `y = cos(θ)·x + sin(θ)·H{x}` (RX's sign convention), where `H` is a linear-phase FIR Hilbert
  transformer (Kaiser window, 8193 taps at ≤ 50 kHz, 16385 above), applied by FFT
  overlap-save convolution. Flat to within 0.01 dB from 14 Hz up. At 0° the output is
  bit-identical to the input; the latency (HOP + FIR delay, 256 ms at 48 kHz) is reported
  as PDC and fully compensated by REAPER, so nothing shifts in time.
* **Suggest**: the analysis in Lua computes the same Hilbert transform (using REAPER's
  native FFT), builds histograms of the analytic-signal envelope over phase (0.125°
  bins) and searches the angle that minimises `Σ|y|^8` - an L8 norm, i.e. a smooth
  "peak" measure. This is what reproduces iZotope RX 10's Suggest values (+78° / +62° /
  +78° on our three reference files, ours: +77.6° / +62.3° / +77.5°; details in
  `tests/RX_REFERENCE.md`). The alternative criterion (menu `...`) minimises the exact
  sample peak `max |y|`, which gives 0.3–0.6 dB more headroom than RX's angle. A
  90-second stereo file is analysed in about 0.4 s.
* **Adaptive**: the JSFX estimates the peak-minimising angle on 43 ms sub-blocks (with
  look-ahead, gating on silence and hysteresis between near-equal minima) and smooths the
  angle with a one-pole filter (response time in the `...` menu).

## Notes and limitations

* Processes whole items. To treat only a region, split the item first.
* Stereo items are analysed per channel; with **Link** on, one common angle is used
  (like RX). Items with more than two channels: channels 1–2 are processed, the rest pass
  through.
* Analysis uses the take as it plays (playrate, channel mode), but not other take FX.
* The peak criterion is a *sample* peak, as in RX. A single click can dominate it - remove
  clicks first, or set the angle by ear.
* Live playback with the JSFX adds 256 ms of PDC latency; rendering is unaffected.

## Tests

`tests/reference.py` is an independent numpy implementation (FIR design, angle search,
synthetic asymmetric "voice" signals). `tests/run_tests.sh` launches an isolated REAPER
instance (separate resource directory, nothing of your own config is touched), runs
`tests/run_in_reaper.lua` (analysis, fixed-angle renders, PDC alignment, adaptive render,
track-FX bypass) and `tests/gui_smoke.lua` (scripted clicks through the real UI), and
compares the results with the reference: suggested angles match to 0.125°, rendered audio
matches to ~1e-6. `tests/RX_REFERENCE.md` documents the comparison with iZotope RX 10
(angles, sign convention, rendered audio).

```bash
python3 -m venv .venv && .venv/bin/pip install numpy scipy
PY=.venv/bin/python ./tests/run_tests.sh /tmp/phase-rotation-tests
```

## Credits

Built by [dennech](https://github.com/dennech) together with Claude. The behaviour is
modelled on the documented semantics of iZotope RX's Phase module; no iZotope code is used.
MIT license.
