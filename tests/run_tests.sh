#!/usr/bin/env bash
# Runs the integration tests inside an isolated REAPER instance (macOS).
# A second REAPER window opens for ~20 s per run - do not click in it; it is killed when done.
#   ./tests/run_tests.sh [scratch_dir]
# Requires: REAPER.app in /Applications, python3 venv with numpy+scipy at $PY (see below).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-${TMPDIR:-/tmp}/reaper-phase-rotation-tests}"
PY="${PY:-python3}"
REAPER_BIN="${REAPER_BIN:-/Applications/REAPER.app/Contents/MacOS/REAPER}"
RES="$SCRATCH/reaper_res"
mkdir -p "$RES/Effects/PhaseRotation" "$SCRATCH/media" "$SCRATCH/testsignals" "$SCRATCH/proj"
if [ ! -f "$RES/reaper.ini" ]; then
  # minimal isolated config: no plugin scanning, no update check, media into scratch
  cat > "$RES/reaper.ini" <<INI
[REAPER]
verchk=0
splash=0
splash2=0
vstpath_arm64=$SCRATCH/emptyplugins
vstpath=$SCRATCH/emptyplugins
defrecpath=$SCRATCH/media
projsrate=48000
projsrateuse=1
INI
fi
# helper JSFX used by the track-FX-bypass test
cat > "$RES/Effects/PhaseRotation/probe.jsfx" <<'JS'
desc:Probe Half Gain
slider1:0.5<0,1,0.01>Gain
@sample
spl0 *= slider1; spl1 *= slider1;
JS
[ -f "$SCRATCH/testsignals/manifest.json" ] || "$PY" "$REPO/tests/reference.py" gen "$SCRATCH/testsignals"
export PR_REPO="$REPO" PR_TEST_DIR="$SCRATCH/testsignals" PR_TEST_OUT="$SCRATCH/test.log" PR_PROJ="$SCRATCH/proj/test.rpp"
# optional RX 10 reference files (generate with tests/make_rx_ref.sh, then process in RX as described in RX_REFERENCE.md)
[ -d "${PR_RX_REF_DIR:-$SCRATCH/rx_ref}" ] && export PR_RX_REF_DIR="${PR_RX_REF_DIR:-$SCRATCH/rx_ref}"
rm -f "$PR_TEST_OUT"
run_reaper() { # $1 = script, $2 = log file, $3 = end marker
  rm -f "$2"   # a stale log from a previous run would satisfy the end-marker check immediately
  sleep 2      # let the previous instance release the resource directory
  "$REAPER_BIN" -newinst -nosplash -ignoreerrors -cfgfile "$RES/reaper.ini" -new "$1" >"$2.stdout" 2>&1 &
  local pid=$!
  local waited=0
  until grep -q -E "$3" "$2" 2>/dev/null || ! kill -0 "$pid" 2>/dev/null || [ "$waited" -ge 180 ]; do sleep 1; waited=$((waited+1)); done
  sleep 1
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true   # the project lives in scratch: no need to let REAPER ask about saving
}
# ---- extension: build (if cmake is available) and install into the isolated UserPlugins
EXT_BIN=""
if command -v cmake >/dev/null 2>&1; then
  if [ "$(uname)" = "Darwin" ]; then
    cmake -S "$REPO/extension" -B "$REPO/extension/build" -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" >/dev/null && cmake --build "$REPO/extension/build" >/dev/null
    EXT_BIN="$REPO/extension/build/reaper_phaserot.dylib"
  else
    cmake -S "$REPO/extension" -B "$REPO/extension/build" >/dev/null && cmake --build "$REPO/extension/build" >/dev/null
    EXT_BIN="$REPO/extension/build/reaper_phaserot.so"
  fi
  mkdir -p "$RES/UserPlugins" && cp "$EXT_BIN" "$RES/UserPlugins/"
fi
mkdir -p "$SCRATCH/out"
export PR_OUT_DIR="$SCRATCH/out"

run_reaper "$REPO/tests/run_in_reaper.lua" "$PR_TEST_OUT" "^DONE"
echo "---- REAPER log:"; cat "$PR_TEST_OUT"
if [ -n "$EXT_BIN" ]; then
  PR_TEST_OUT="$SCRATCH/ext_test.log" run_reaper "$REPO/tests/ext_test.lua" "$SCRATCH/ext_test.log" "^DONE"
  echo "---- extension log:"; cat "$SCRATCH/ext_test.log" | cut -c1-200
  cat "$SCRATCH/ext_test.log" >> "$PR_TEST_OUT"
fi
echo "---- verify:"; "$PY" "$REPO/tests/reference.py" verify "$SCRATCH/testsignals" "$PR_TEST_OUT"

# ---- GUI smoke test (scripted actions through the real GUI script)
export PHASE_ROTATION_TEST_LOG="$SCRATCH/gui.log" PHASE_ROTATION_TEST_ACTIONS="link_on,dump,suggest,dump,next,dump,angle=12.5,dump,link_off,angle=-20,dump,angle=0,dump,bypass,dump,bypass,adaptive,dump,adaptive,preview,preview,render,dump,remove,quit"
rm -f "$PHASE_ROTATION_TEST_LOG"
export PR_TEST_OUT="$SCRATCH/gui_smoke.log" PR_PROJ="$SCRATCH/proj/gui.rpp"
run_reaper "$REPO/tests/gui_smoke.lua" "$SCRATCH/gui_smoke.log" "gui smoke end"
echo "---- GUI smoke:"; cat "$SCRATCH/gui_smoke.log"; cat "$PHASE_ROTATION_TEST_LOG"
if grep -q ERROR "$SCRATCH/gui_smoke.log" "$PHASE_ROTATION_TEST_LOG"; then echo "GUI SMOKE FAILED"; exit 1; fi
# after Suggest the first item (asym_mono) must carry the RX-style angle (+77.6)
if ! grep -q "res=77.625" "$PHASE_ROTATION_TEST_LOG"; then echo "GUI SMOKE FAILED: Suggest did not produce the expected angle"; exit 1; fi
# unlinked: L set to 0 after -20 must apply (0 is a valid angle), R keeps its own value
if ! grep -q "L=0.0 R=12.5" "$PHASE_ROTATION_TEST_LOG"; then echo "GUI SMOKE FAILED: setting 0 degrees did not apply"; exit 1; fi
echo "ALL TESTS PASSED"
