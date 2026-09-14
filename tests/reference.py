#!/usr/bin/env python3
"""Reference implementation + test-signal generator for REAPER Phase Rotation.

The FIR Hilbert transformer designed here must be bit-for-bit the same design
as the one in phase_rotation.jsfx and phase_rotation_core.lua:

    M      = 8193 (sample rate <= 50 kHz) or 16385 (above)   -- odd length
    D      = (M - 1) / 2                                     -- group delay
    h[D+k] = k odd : (2 / (pi * k)) * kaiser(k)              -- k = -D .. D
             k even: 0
    kaiser(k) = I0(beta * sqrt(1 - (k / D)^2)) / I0(beta),  beta = 8

Rotation convention (identical everywhere, and the same sign as iZotope RX -
verified against RX 10 renders, see RX_REFERENCE.md):

    y = cos(theta) * x + sin(theta) * H{x}

so for x = cos(w t) the output is cos(w t - theta).

Suggest criterion: RX's "Suggest" is reproduced by minimising the L8 norm
sum |y|^8 over the selection ("rx" criterion, default).  The exact sample-peak
minimum ("peak" criterion) is also computed.

Usage:
    python3 reference.py gen  <outdir>          # write test WAVs + manifest.json
    python3 reference.py verify <outdir> <log>  # compare REAPER results with reference
    python3 reference.py fir                    # print FIR passband figures
"""
import json
import math
import os
import sys

import numpy as np
from scipy.io import wavfile

BETA = 8.0
THR_REL = 0.5          # only samples with envelope >= THR_REL * max envelope matter for the peak
TIE_TOL_DB = 0.01      # prefer the smallest rotation that is within this of the best peak


def fir_length(sr):
    return 16385 if sr > 50000 else 8193


def kaiser_hilbert_fir(M, beta=BETA):
    D = (M - 1) // 2
    k = np.arange(-D, D + 1)
    w = np.i0(beta * np.sqrt(np.clip(1.0 - (k / D) ** 2, 0.0, 1.0))) / np.i0(beta)
    h = np.zeros(M)
    odd = (k % 2) != 0
    h[odd] = 2.0 / (np.pi * k[odd]) * w[odd]
    return h


def hilbert_fir(x, sr):
    """H{x} aligned with x (FIR group delay removed, zero padding at both ends)."""
    h = kaiser_hilbert_fir(fir_length(sr))
    D = (len(h) - 1) // 2
    full = np.convolve(x, h)          # length len(x)+M-1 ; full[n] corresponds to x time n-D
    return full[D:D + len(x)]


def rotate(x, hx, theta_deg):
    t = math.radians(theta_deg)
    return math.cos(t) * x + math.sin(t) * hx


def peak_for_angles(x, hx, thetas_deg, thr_rel=THR_REL):
    """Exact max|y_theta| for many angles, using only samples with a large envelope."""
    env = np.hypot(x, hx)
    sel = env >= thr_rel * env.max()
    xs, hs = x[sel], hx[sel]
    t = np.radians(thetas_deg)
    # y = cos t * x - sin t * h  -> shape (angles, samples) in chunks to save memory
    peaks = np.empty(len(t))
    step = 64
    for i in range(0, len(t), step):
        ct = np.cos(t[i:i + step])[:, None]
        st = np.sin(t[i:i + step])[:, None]
        peaks[i:i + step] = np.abs(ct * xs + st * hs).max(axis=1)
    return peaks


LP_ORDER = 8           # RX-like criterion: minimise sum |y|^8
LP_THR_REL = 0.1       # samples below this fraction of the max envelope are negligible for the L8 sum


def lp_for_angles(x, hx, thetas_deg, p=LP_ORDER, thr_rel=LP_THR_REL):
    env = np.hypot(x, hx)
    sel = env >= thr_rel * env.max()
    xs, hs = x[sel], hx[sel]
    t = np.radians(thetas_deg)
    out = np.empty(len(t))
    step = 32
    for i in range(0, len(t), step):
        ct = np.cos(t[i:i + step])[:, None]
        st = np.sin(t[i:i + step])[:, None]
        out[i:i + step] = (np.abs(ct * xs + st * hs) ** p).sum(axis=1)
    return out


def pick_angle(thetas, peaks):
    """Smallest |theta| whose peak is within TIE_TOL_DB of the global minimum."""
    best = peaks.min()
    ok = peaks <= best * 10 ** (TIE_TOL_DB / 20)
    idx = np.where(ok)[0]
    j = idx[np.argmin(np.abs(thetas[idx]))]
    return float(thetas[j]), float(peaks[j]), float(best)


def pick_lp(thetas, cost):
    best = cost.min()
    ok = cost <= best * (1 + 1e-6)
    idx = np.where(ok)[0]
    j = idx[np.argmin(np.abs(thetas[idx]))]
    return float(thetas[j])


def best_angle(x, hx, resolution=0.125, criterion="rx"):
    """Returns (angle, peak_after, best_possible_peak)."""
    thetas = np.arange(-90.0, 90.0, resolution)
    peaks = peak_for_angles(x, hx, thetas)
    if criterion == "peak":
        return pick_angle(thetas, peaks)
    th = pick_lp(thetas, lp_for_angles(x, hx, thetas))
    return th, float(peaks[int(round((th + 90) / resolution)) % len(thetas)]), float(peaks.min())


def best_angle_linked(chans, resolution=0.125, criterion="rx"):
    thetas = np.arange(-90.0, 90.0, resolution)
    peaks = np.zeros(len(thetas))
    lp = np.zeros(len(thetas))
    for x, hx in chans:
        peaks = np.maximum(peaks, peak_for_angles(x, hx, thetas))
        if criterion != "peak":
            lp += lp_for_angles(x, hx, thetas)
    if criterion == "peak":
        return pick_angle(thetas, peaks)
    th = pick_lp(thetas, lp)
    return th, float(peaks[int(round((th + 90) / resolution)) % len(thetas)]), float(peaks.min())


def db(v):
    return 20 * math.log10(max(v, 1e-12))


# ---------------------------------------------------------------- test signals

def voice_like(sr, dur, f0=118.0, seed=1, formants=((600, 0.06), (1150, 0.08), (2500, 0.1))):
    """Asymmetric, speech-like pulse train: one-sided glottal pulses through resonators."""
    rng = np.random.default_rng(seed)
    n = int(sr * dur)
    t = np.arange(n) / sr
    f = f0 * (1 + 0.03 * np.sin(2 * np.pi * 5.3 * t)) * (1 + 0.02 * rng.standard_normal(n).cumsum() / np.sqrt(np.arange(1, n + 1)))
    ph = np.cumsum(f / sr)
    x = np.zeros(n)
    # glottal-like pulse: exponentially decaying one-sided spike at each period start
    pulses = np.where(np.diff(np.floor(ph)) > 0)[0]
    kern_len = int(sr * 0.004)
    kern = np.exp(-np.arange(kern_len) / (sr * 0.0008)) * np.linspace(1, 0, kern_len) ** 0.3
    for p in pulses:
        e = min(n, p + kern_len)
        x[p:e] += kern[:e - p]
    # resonators (formants) - simple 2nd order IIR
    y = np.zeros_like(x)
    for fc, bw in formants:
        r = math.exp(-math.pi * bw * fc / sr)
        a1 = -2 * r * math.cos(2 * math.pi * fc / sr)
        a2 = r * r
        s = np.zeros(n)
        z1 = z2 = 0.0
        g = 1 - r
        for i in range(n):
            v = g * x[i] - a1 * z1 - a2 * z2
            s[i] = v
            z2, z1 = z1, v
        y += s / (0.3 + fc / 1000)
    # "words": amplitude envelope with pauses
    env = np.ones(n)
    word = int(sr * 0.7)
    gap = int(sr * 0.25)
    i = 0
    k = 0
    while i < n:
        seg = word if k % 2 == 0 else gap
        if k % 2 == 1:
            env[i:i + seg] = 0.0
        else:
            m = min(seg, n - i)
            env[i:i + m] *= np.hanning(m) ** 0.35 * (0.6 + 0.4 * rng.random())
        i += seg
        k += 1
    y *= env
    y += 1e-4 * rng.standard_normal(n)
    y /= np.abs(y).max()
    return y * 0.5


def write_wav(path, sr, data):
    data = np.asarray(data, dtype=np.float32)
    wavfile.write(path, sr, data.T if data.ndim == 2 else data)


def gen(outdir):
    os.makedirs(outdir, exist_ok=True)
    manifest = {"files": []}
    sr = 48000

    def describe(name, sr, chans, extra=None):
        hxs = [hilbert_fir(c, sr) for c in chans]
        entry = {"file": os.path.join(outdir, name), "sr": sr, "nch": len(chans), "channels": [], "n": len(chans[0])}
        for c, hx in zip(chans, hxs):
            th, pk, best = best_angle(c, hx)
            thp, pkp, _ = best_angle(c, hx, criterion="peak")
            entry["channels"].append({
                "peak_before_db": db(np.abs(c).max()),
                "pos_before_db": db(c.max()), "neg_before_db": db(-c.min()),
                "best_angle": th, "peak_after_db": db(pk),
                "minpeak_angle": thp, "minpeak_after_db": db(pkp),
            })
        if len(chans) > 1:
            th, pk, best = best_angle_linked(list(zip(chans, hxs)))
            entry["linked_angle"] = th
            entry["linked_peak_after_db"] = db(pk)
            thp, pkp, _ = best_angle_linked(list(zip(chans, hxs)), criterion="peak")
            entry["linked_minpeak_angle"] = thp
        if extra:
            entry.update(extra)
        manifest["files"].append(entry)
        return entry

    # 1. mono asymmetric voice-like
    a = voice_like(sr, 6.0, seed=1)
    write_wav(os.path.join(outdir, "asym_mono.wav"), sr, a)
    e = describe("asym_mono.wav", sr, [a]); e["id"] = "asym_mono"

    # 2. stereo: R = L rotated by +37 deg (so its optimum differs by -37 from L)
    ha = hilbert_fir(a, sr)
    r = rotate(a, ha, 37.0)
    write_wav(os.path.join(outdir, "asym_stereo.wav"), sr, np.stack([a, r]))
    e = describe("asym_stereo.wav", sr, [a, r]); e["id"] = "asym_stereo"

    # 3. adaptive: first half as is, second half rotated by 60 deg
    b = voice_like(sr, 8.0, seed=2, f0=95.0)
    hb = hilbert_fir(b, sr)
    half = len(b) // 2
    c = b.copy()
    c[half:] = rotate(b, hb, 60.0)[half:]
    write_wav(os.path.join(outdir, "adaptive_switch.wav"), sr, c)
    hc = hilbert_fir(c, sr)
    e = describe("adaptive_switch.wav", sr, [c]); e["id"] = "adaptive_switch"
    th1 = best_angle(c[:half - sr // 2], hc[:half - sr // 2], criterion="peak")
    th2 = best_angle(c[half + sr // 2:], hc[half + sr // 2:], criterion="peak")
    e["half_angles"] = [th1[0], th2[0]]
    e["half_peaks_after_db"] = [db(th1[1]), db(th2[1])]   # best achievable (min-peak) per half
    e["half_peaks_before_db"] = [db(np.abs(c[:half]).max()), db(np.abs(c[half:]).max())]

    # 4. click + quiet tone for PDC/alignment check (theta = 0 must be identity)
    n = 3 * sr
    d = 0.05 * np.sin(2 * np.pi * 300 * np.arange(n) / sr)
    d[sr] = 0.9
    write_wav(os.path.join(outdir, "click.wav"), sr, d)
    manifest["files"].append({"id": "click", "file": os.path.join(outdir, "click.wav"), "sr": sr, "nch": 1, "n": n, "click_index": sr})

    # 5. pure sine: rotation must not change the peak; suggestion should be ~0
    s = 0.5 * np.sin(2 * np.pi * 1000 * np.arange(2 * sr) / sr)
    write_wav(os.path.join(outdir, "sine.wav"), sr, s)
    e = describe("sine.wav", sr, [s]); e["id"] = "sine"

    # 6. long stereo for timing (90 s)
    l1 = voice_like(sr, 90.0, seed=3)
    l2 = voice_like(sr, 90.0, seed=4, f0=140.0)
    write_wav(os.path.join(outdir, "long_stereo.wav"), sr, np.stack([l1, l2]))
    manifest["files"].append({"id": "long_stereo", "file": os.path.join(outdir, "long_stereo.wav"), "sr": sr, "nch": 2, "n": len(l1)})

    with open(os.path.join(outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    for e in manifest["files"]:
        print(e["id"], {k: v for k, v in e.items() if k not in ("file", "channels")}, [
            {kk: round(vv, 3) for kk, vv in ch.items()} for ch in e.get("channels", [])])


def fir_report():
    for sr in (44100, 48000, 96000):
        M = fir_length(sr)
        h = kaiser_hilbert_fir(M)
        nfft = 1 << 21
        H = np.abs(np.fft.rfft(h, nfft))
        f = np.fft.rfftfreq(nfft, 1 / sr)
        for tol_db in (0.1, 0.01):
            tol = 10 ** (-tol_db / 20)
            i = np.argmax(H >= tol)
            # first index after which H stays within tolerance up to mid band
            mid = np.searchsorted(f, sr / 4)
            j = i
            while j < mid and H[j:mid].min() < tol:
                j += 1
            print(f"sr={sr} M={M}: |H| within {tol_db} dB from {f[j]:.1f} Hz; ripple {20*np.log10(H[mid:len(H)-mid].max()):.5f}/{20*np.log10(H[mid:len(H)-mid].min()):.5f} dB")


def read_wav(path):
    sr, d = wavfile.read(path)
    if d.dtype == np.int16:
        d = d / 32768.0
    elif d.dtype == np.int32:
        d = d / 2147483648.0
    d = d.astype(np.float64)
    if d.ndim == 1:
        d = d[:, None]
    return sr, d.T  # (nch, n)


def verify(outdir, logpath):
    """Parse the log written by run_in_reaper.lua and compare with the reference."""
    with open(os.path.join(outdir, "manifest.json")) as f:
        manifest = json.load(f)
    byid = {e["id"]: e for e in manifest["files"]}
    results = {}
    with open(logpath) as f:
        for line in f:
            line = line.strip()
            if line.startswith("RESULT "):
                _, key, val = line.split(" ", 2)
                results[key] = val
    fails = 0

    def check(name, cond, detail=""):
        nonlocal fails
        print(("PASS " if cond else "FAIL ") + name + ("  " + detail if detail else ""))
        if not cond:
            fails += 1

    # --- suggestions
    for fid in ("asym_mono", "asym_stereo", "adaptive_switch", "sine"):
        e = byid[fid]
        for ci, ch in enumerate(e["channels"]):
            key = f"{fid}.angle{ci}"
            if key in results:
                got = float(results[key])
                # a pure sine has a flat L8 curve: any angle is equivalent, histogram noise decides (allow 2 deg)
                tol = 2.0 if fid == "sine" else 0.35
                check(f"suggest(rx) {key}", abs(got - ch["best_angle"]) <= tol, f"got {got:.3f} ref {ch['best_angle']:.3f}")
            key = f"{fid}.minpeak_angle{ci}"
            if key in results:
                got = float(results[key])
                check(f"suggest(peak) {key}", abs(got - ch["minpeak_angle"]) <= 0.35, f"got {got:.3f} ref {ch['minpeak_angle']:.3f}")
            key = f"{fid}.peak_after_db{ci}"
            if key in results:
                got = float(results[key])
                check(f"peak_after {key}", abs(got - ch["peak_after_db"]) <= 0.05, f"got {got:.3f} ref {ch['peak_after_db']:.3f}")
        if "linked_angle" in e and f"{fid}.linked_angle" in results:
            got = float(results[f"{fid}.linked_angle"])
            check(f"suggest(rx) {fid}.linked", abs(got - e["linked_angle"]) <= 0.35, f"got {got:.3f} ref {e['linked_angle']:.3f}")
    # iZotope RX 10 measured +78 deg on tests' asym_mono.wav (see RX_REFERENCE.md); RX shows whole degrees
    if "asym_mono.angle0" in results:
        got = float(results["asym_mono.angle0"])
        check("matches iZotope RX 10 Suggest on asym_mono (+78)", abs(got - 78.0) <= 1.0, f"got {got:.3f}")
    for fid, rx_angle in (("speech_en", 62.0), ("speech_ru", 78.0), ("asym_mono", 78.0)):
        key = f"rxref.{fid}.angle0"
        if key in results:
            got = float(results[key])
            check(f"matches iZotope RX 10 Suggest on {fid} ({rx_angle:+.0f})", abs(got - rx_angle) <= 1.0, f"got {got:.3f}")

    # --- rendered output vs reference rotation
    for key, val in results.items():
        if not key.endswith(".render"):
            continue
        fid = key[:-len(".render")]
        e = byid[results.get(fid + ".render_srcid", fid)]
        angles = [float(v) for v in results[fid + ".render_angles"].split(",")]
        sr_in, src = read_wav(e["file"])
        sr_out, out = read_wav(val)
        check(f"render {fid} samplerate", sr_out == sr_in, f"{sr_out} vs {sr_in}")
        n = min(src.shape[1], out.shape[1])
        check(f"render {fid} length", out.shape[1] >= src.shape[1] - 2, f"out {out.shape[1]} src {src.shape[1]} (a render tail is fine, the item is trimmed)")
        for ci in range(src.shape[0]):
            x = src[ci]
            hx = hilbert_fir(x, sr_in)
            ref = rotate(x, hx, angles[min(ci, len(angles) - 1)])
            oc = out[min(ci, out.shape[0] - 1)]
            # REAPER feeds a couple of samples past the source end into the FX, which
            # the non-causal Hilbert FIR spreads over the last few output samples.
            err = np.abs(oc[:n - 16] - ref[:n - 16]).max()
            err_tail = np.abs(oc[n - 16:n] - ref[n - 16:n]).max()
            check(f"render {fid} ch{ci} max error", err < 2e-4 and err_tail < 2e-2,
                  f"max|err|={err:.2e} (last 16 samples {err_tail:.2e}) angle={angles[min(ci, len(angles)-1)]}")
        if fid == "click":
            oc = out[0]
            check("render click position (PDC)", int(np.argmax(np.abs(oc))) == e["click_index"], f"argmax {int(np.argmax(np.abs(oc)))} expected {e['click_index']}")

    # --- adaptive render: peaks in each half should approach the per-half optimum
    if "adaptive_switch.adaptive_render" in results:
        e = byid["adaptive_switch"]
        sr_out, out = read_wav(results["adaptive_switch.adaptive_render"])
        oc = out[0]
        half = len(oc) // 2
        # the angle has to travel ~60 deg at the boundary; with a 250 ms response it needs
        # about a second to settle, so half 2 is judged from 1.5 s after the switch
        r1 = slice(sr_out // 2, half - sr_out // 2)
        r2 = slice(half + 3 * sr_out // 2, -sr_out // 2)
        p1 = db(np.abs(oc[r1]).max())
        p2 = db(np.abs(oc[r2]).max())
        _, src = read_wav(e["file"])
        sc = src[0]
        b1 = db(np.abs(sc[r1]).max())
        b2 = db(np.abs(sc[r2]).max())
        o1, o2 = e["half_peaks_after_db"]
        print(f"adaptive: half1 before {b1:.2f} dB -> got {p1:.2f} dB (min-peak optimum {o1:.2f}); half2 before {b2:.2f} -> got {p2:.2f} (optimum {o2:.2f})")
        check("adaptive half1 improves >= 0.5 dB and is within 0.5 dB of the fixed optimum", p1 <= b1 - 0.5 and p1 <= o1 + 0.5)
        check("adaptive half2 improves >= 0.5 dB and is within 0.5 dB of the fixed optimum", p2 <= b2 - 0.5 and p2 <= o2 + 0.5)

    if "trackfx_bypass_peak" in results:
        pk = float(results["trackfx_bypass_peak"])
        check("track FX bypassed during render", pk > 0.30, f"peak {pk:.3f} (about 0.4-0.5 expected, half of that if track FX leaked)")
    if "trackfx_enabled_after" in results:
        check("track FX re-enabled after render", results["trackfx_enabled_after"] == "true", results["trackfx_enabled_after"])
    if "long_stereo.analyze_seconds" in results:
        print("timing: long_stereo (90 s stereo) analyzed in", results["long_stereo.analyze_seconds"], "s")
    print("\n%d failure(s)" % fails)
    return fails


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "fir"
    if cmd == "gen":
        gen(sys.argv[2])
    elif cmd == "verify":
        sys.exit(1 if verify(sys.argv[2], sys.argv[3]) else 0)
    else:
        fir_report()
