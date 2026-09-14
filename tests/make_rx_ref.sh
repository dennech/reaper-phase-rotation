#!/usr/bin/env bash
# Creates the three files that were measured in iZotope RX 10 (see RX_REFERENCE.md):
#   asym_mono.wav  - synthetic asymmetric pulse train from reference.py (deterministic)
#   speech_en.wav  - macOS TTS (voice Samantha), 48 kHz float, mono
#   speech_ru.wav  - macOS TTS (voice Milena),   48 kHz float, mono
# Usage: tests/make_rx_ref.sh <outdir> [python]
set -euo pipefail
OUT="${1:?outdir}"; PY="${2:-python3}"
mkdir -p "$OUT"
"$PY" "$(dirname "$0")/reference.py" gen "$OUT/_gen" >/dev/null
cp "$OUT/_gen/asym_mono.wav" "$OUT/asym_mono_orig.wav"
say -v Samantha -o "$OUT/speech_en_orig.wav" --file-format=WAVE --data-format=LEF32@48000 \
  "Phase rotation is used to fix asymmetrical waveforms. Voice recordings usually have taller peaks on one side. Rotating the phase of every frequency by the same angle balances the peaks without changing the sound. This sentence exists only to give the analyser some real speech to work with."
say -v Milena -o "$OUT/speech_ru_orig.wav" --file-format=WAVE --data-format=LEF32@48000 \
  "Поворот фазы применяют, чтобы выровнять несимметричную форму волны. У записей голоса пики с одной стороны обычно выше. Если повернуть фазу всех частот на один и тот же угол, пики выравниваются, а звучание не меняется."
ls -la "$OUT"
