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
| Suggest                    | Analyses each selected item and puts the suggested rotation on the sliders (nothing is applied yet). Reproduces RX 10's own Suggest values (verified against RX renders, see `tests/RX_REFERENCE.md`); a "minimum sample peak" criterion is available too |
| Left / Right rotation [°]  | Sliders -180..+180 with a value box (click to type), Link button            |
| Adaptive phase rotation    | Re-estimates the best angle every ~43 ms and glides between values (both engines) |
| Preview / Bypass           | Preview plays the item with the staged settings while the project and the waveform stay untouched; Bypass switches an applied rotation off and on |
| Apply                      | Writes the staged settings to the items (one undo step). With the extension the rotation is applied to the item's source: the waveform updates immediately, nothing is written, nothing is added to the item |
| Render                     | Not needed with the extension (see Apply); the take-FX fallback offers it to bake the JSFX |
| *(no RX equivalent)*       | **Rotator** menu: besides the transparent RX-style rotation, a broadcast-style **allpass rotator** (Orban 4 x 200 Hz, the old VoicePhaseRotator 8 x 200 Hz, custom) - see below |
| Compare                    | Not implemented - use Bypass and REAPER's undo instead                      |

## Two engines

**Source engine (recommended)** - with the `reaper_phaserot` extension installed, the
script applies the rotation to the take's *source* at runtime. Playback, rendering,
glue and the **waveform display** all show the rotated audio; no files are written,
no take FX is added, there is no latency. The project file stays a plain project:
the take still references the original `<SOURCE WAVE>` and the rotation is stored in
the take's `P_EXT:phaserot` string, which REAPER keeps in the project and in undo
states (undo/redo, copy/paste and duplicates all work). A REAPER without the extension
opens such a project normally and plays the *original, unrotated* audio - nothing goes
offline; install the extension (ReaPack, one click) to hear and see the rotation.

**Take-FX engine (fallback)** - without the extension the bundled JSFX
**"Phase Rotation (RX-style, Hilbert)"** is inserted as a take FX. Sound is processed
live, but REAPER draws item waveforms from the source, so the display does not change;
a *Render* button (new take) is offered in this mode for that purpose.

Angles use the same sign convention as RX; results match RX's Suggest (see below).

![Phase Rotation (RX-style) window: Suggest, Left/Right rotation, Adaptive, Preview / Bypass / Reset](docs/screenshot.png)

## Installation

### ReaPack (recommended)

1. Extensions → ReaPack → Import repositories…
2. Paste `https://github.com/dennech/reaper-phase-rotation/raw/main/index.xml`
3. Install **Phase Rotation (RX-style).lua** (the JSFX comes with it) and the extension
   **reaper_phaserot** (Extensions category; macOS universal, Windows x64, Linux x86_64 /
   aarch64), then restart REAPER.

### Manual

1. Copy the `Items` folder into `<REAPER resource path>/Scripts/` (rename it as you like,
   e.g. `Scripts/Phase Rotation/`). The three files must stay together:
   `Phase Rotation (RX-style).lua`, `phase_rotation_core.lua`, `phase_rotation.jsfx`.
2. Actions → Show action list → *New action…* → *Load ReaScript…* → pick the `.lua`.
3. On first run the script copies `phase_rotation.jsfx` into `Effects/Phase Rotation/`
   so that REAPER can load it.
4. Extension: put `reaper_phaserot.dylib` / `.dll` / `.so` (from the GitHub release, or
   build it - see `extension/README.md`) into `<resource path>/UserPlugins/` and restart
   REAPER. The script shows the active engine in its bottom-right corner.

Requires REAPER 6.x or newer (tested on 7.80, macOS). No extensions needed
(plain `gfx` UI, no ReaImGui / SWS / js_ReaScriptAPI).

## Usage

The workflow is RX's: nothing changes until you press **Apply**.

1. Select one or more **audio items** (mono or stereo).
2. Run the action **Script: Phase Rotation (RX-style).lua**.
3. Press **Suggest** (or `S`). Each item gets its own analysis; the suggested angles
   appear on the sliders and the window shows the peak before / after and the headroom
   you would gain. The items themselves are not touched yet.
4. **Preview** (`Space`) plays the item with the staged settings - the project, the undo
   history and the waveform keep the applied state. Drag the sliders while listening
   (Shift = fine, mouse wheel = 1°, double-click = 0°, click the value box to type a
   number); the orange tick on a slider marks the applied value.
5. **Apply** (`A`) writes the staged settings to all selected items (one undo step). With
   the source engine the waveform updates at once. **Revert** puts the sliders back to the
   applied values, **Bypass** (`B`) compares an applied rotation with the original,
   **Reset** removes it. Everything is undoable.

Multi-selection: **Suggest / Apply / Bypass / Reset / Adaptive / Link / Rotator act on all
selected items**, the sliders edit the item shown in the *Item i / n* navigator.

If you prefer the old behaviour (sliders and Suggest change the item immediately), enable
*Apply changes instantly* in the `...` menu. The polar *envelope vs. phase* plot is also
in that menu.

### Rotator types

* **RX-style** (default): one angle for all frequencies. Inaudible by itself - only the
  waveform shape and the peaks change. This is what RX does.
* **Allpass rotator**: the broadcast "phase rotator" - a cascade of identical allpass
  sections around 200 Hz, as found in FM processors since the 1970s. Presets: *Orban
  classic* (4 first-order sections at 200 Hz, the design documented by Orban), 2 and 6
  sections, *VoicePhaseRotator* (8 second-order sections at 200 Hz with Q 0.35 = 16
  first-order sections, reconstructed from the old free Russian VST of that name), and a
  custom setting (order, stages, frequency, Q). Unlike the RX-style rotation this one is
  audible: low frequencies are delayed by up to a few tens of milliseconds relative to the
  highs (about 6 ms for Orban 4 x 200 Hz, 34 ms at 25 Hz for VoicePhaseRotator), which
  softens attacks and makes voices sound denser - the "compression-like" effect these
  units are known for. RMS and spectrum do not change; it is a linear filter. Treat it as a
  sound-shaping choice: listen, and use the same setting on all microphones of one source.
  The RX-style sliders remain available after it as a fine rotation, and Suggest computes
  the angle for the allpass output.

**Adaptive phase rotation** follows the signal instead of using one fixed angle - useful
when the asymmetry changes over time (several speakers, long takes). On our speech
reference it reaches the same peak levels as RX's adaptive mode (see
`tests/RX_REFERENCE.md`). Optional smoothing in the `...` menu. Like RX, it is meant for
dialogue; on music a fixed angle is usually cleaner.

The JSFX can also be used on its own (track FX or take FX) - it has the same controls.

## How it works

* **Rotation**: `y = cos(θ)·x + sin(θ)·H{x}` (RX's sign convention), where `H` is a linear-phase FIR Hilbert
  transformer (Kaiser window, 8193 taps at ≤ 50 kHz, 16385 above), applied by FFT
  overlap-save convolution. Flat to within 0.01 dB from 14 Hz up. At 0° the output is
  bit-identical to the input. In the JSFX the latency (block + one sub-block of look-ahead
  + FIR delay, about 300 ms at 48 kHz) is reported as PDC and fully compensated by REAPER,
  so nothing shifts in time; the extension reads ahead itself and has no latency.
* **Suggest**: the analysis in Lua computes the same Hilbert transform (using REAPER's
  native FFT), builds histograms of the analytic-signal envelope over phase (0.125°
  bins) and searches the angle that minimises `Σ|y|^8` - an L8 norm, i.e. a smooth
  "peak" measure. This is what reproduces iZotope RX 10's Suggest values (+78° / +62° /
  +78° on our three reference files, ours: +77.6° / +62.3° / +77.5°; details in
  `tests/RX_REFERENCE.md`). The alternative criterion (menu `...`) minimises the exact
  sample peak `max |y|`, which gives 0.3–0.6 dB more headroom than RX's angle. A
  90-second stereo file is analysed in about 0.4 s.
* **Adaptive**: the peak-minimising angle is estimated on 43 ms sub-blocks (gating on
  silence, hysteresis between near-equal minima) and interpolated linearly between
  sub-block centres with one sub-block of look-ahead - both in the extension (computed
  once per take) and in the JSFX (with PDC).
* **Allpass rotator**: first-order sections `c = (tan(πf₀/fs) − 1) / (tan(πf₀/fs) + 1)`,
  second-order sections are RBJ allpass biquads (`α = sin ω₀ / 2Q`), designed at the
  source sample rate and run before the Hilbert rotation. The extension keeps the filter
  state between consecutive reads and warms it up over 0.5 s before a random-access read,
  so playback, peak display and analysis are sample-exact against the numpy reference.
* **Preview** (source engine): the wrapper takes a playback-only parameter set, so the
  audio thread renders the staged settings while peaks, project and undo keep the applied
  ones. Nothing is stored.

## Notes and limitations

* Processes whole items. To treat only a region, split the item first.
* Stereo items are analysed per channel; with **Link** on, one common angle is used
  (like RX). Items with more than two channels: channels 1–2 are processed, the rest pass
  through.
* Analysis uses the part of the source the item plays (start offset, length, play rate) and the take's channel mode, but not other take FX.
* The peak criterion is a *sample* peak, as in RX. A single click can dominate it - remove
  clicks first, or set the angle by ear.
* Take-FX engine only: live playback with the JSFX adds ~300 ms of PDC latency; rendering
  is unaffected. The source engine has no latency.
* Source engine: REAPER computes the display peaks of a rotated take on demand (about
  0.3 s per 10 minutes of audio after each change).
* Preview changes reach the audio with REAPER's media-buffer delay (up to a second),
  like any source change during playback.

## Tests

`tests/reference.py` is an independent numpy implementation (FIR design, angle search,
synthetic asymmetric "voice" signals). `tests/run_tests.sh` builds the extension, launches
an isolated REAPER instance (separate resource directory, nothing of your own config is
touched), runs `tests/run_in_reaper.lua` (JSFX engine: analysis, fixed-angle renders, PDC
alignment, adaptive render, track-FX bypass), `tests/ext_test.lua` (source engine: output
vs. reference, waveform peaks, undo/redo, duplicate, save/reload, bypass/reset, adaptive,
allpass presets, seek continuity, preview) and `tests/gui_smoke.lua` (scripted clicks
through the real UI: Suggest must not apply, Apply must, and the audio of the applied item
is read back through REAPER and compared with the numpy chain), and compares the results
with the reference: suggested angles agree within 0.35° (the analysis histogram step is 0.125°), audio matches to ~1e-6. `tests/RX_REFERENCE.md` documents the comparison with iZotope RX 10
(angles, sign convention, rendered audio).

```bash
python3 -m venv .venv && .venv/bin/pip install numpy scipy
PY=.venv/bin/python ./tests/run_tests.sh /tmp/phase-rotation-tests
```

## Credits

Built by [dennech](https://github.com/dennech) together with Claude. The behaviour is
modelled on the documented semantics of iZotope RX's Phase module; no iZotope code is used.
MIT license.
