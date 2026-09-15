// reaper_phaserot - broadband phase rotation as a non-destructive media source wrapper.
//
// A PhaseRotSource wraps the take's original PCM_source and returns
//     y = cos(theta) * x + sin(theta) * H{x}
// (H = linear-phase FIR Hilbert transformer, same design as phase_rotation.jsfx /
// phase_rotation_core.lua) for playback, rendering AND waveform peaks.
//
// Nothing about the project file changes: the wrapper reports the child's type
// and writes the child's state, so an RPP saved with rotated takes is a plain
// project (the original file plays unprocessed in a REAPER without this
// extension).  The rotation parameters live in the take's "P_EXT:phaserot"
// string, which REAPER keeps in the project and in undo states.  A timer scans
// all takes and wraps / unwraps sources so that the state always follows P_EXT
// (project load, undo/redo, copy/paste, scripts).
//
// Optional "allpass rotator" block (broadcast phase rotator: a cascade of identical
// first- or second-order allpass sections, e.g. Orban's 4 x 200 Hz) runs BEFORE the
// broadband rotation; analysis and the adaptive estimator see the allpass output.
//
// ReaScript API: PhaseRot_SetTake, PhaseRot_ClearTake, PhaseRot_GetTake,
// PhaseRot_SetPreview / ClearPreview / ClearAllPreviews (audition without changing the
// project or the waveform), PhaseRot_Analyze / AnalyzeEx, PhaseRot_Refresh, PhaseRot_GetVersion.
//
// Part of https://github.com/dennech/reaper-phase-rotation  (MIT)

#define REAPERAPI_IMPLEMENT
#define REAPERAPI_MINIMAL
#define REAPERAPI_WANT_EnumProjects
#define REAPERAPI_WANT_CountMediaItems
#define REAPERAPI_WANT_GetMediaItem
#define REAPERAPI_WANT_CountTakes
#define REAPERAPI_WANT_GetTake
#define REAPERAPI_WANT_GetMediaItemTake_Item
#define REAPERAPI_WANT_GetSetMediaItemTakeInfo
#define REAPERAPI_WANT_GetSetMediaItemTakeInfo_String
#define REAPERAPI_WANT_TakeIsMIDI
#define REAPERAPI_WANT_UpdateItemInProject
#define REAPERAPI_WANT_UpdateArrange
#define REAPERAPI_WANT_ValidatePtr2
#define REAPERAPI_WANT_ShowConsoleMsg
#define REAPERAPI_WANT_plugin_register
#define REAPERAPI_WANT_time_precise
#define REAPERAPI_WANT_Main_OnCommand
#define REAPERAPI_WANT_SetExtState
#define REAPERAPI_WANT_GetMediaItemTakeInfo_Value
#define REAPERAPI_WANT_GetMediaItemInfo_Value

#include "reaper_plugin.h"
#include "reaper_plugin_functions.h"
#include "WDL/fft.h"
#ifdef min
#undef min
#endif
#ifdef max
#undef max
#endif

#include <cmath>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <memory>
#include <mutex>
#include <string>
#include <algorithm>
#include <atomic>

#define PR_VERSION "1.1.0"
#define PR_EXT_KEY "P_EXT:phaserot"
#define PR_EXT_IDENTIFY 0x50524f54 /* 'PROT' */
#define PR_MAGIC 0x50686153     /* 'PhaS' */

static const double PI = 3.14159265358979323846;

// ============================================================================ DSP
namespace dsp {

static double bessel_i0(double x)
{
  double q = x * x * 0.25, s = 1, t = 1;
  for (int k = 1; k <= 80; k++) { t *= q / ((double)k * k); s += t; }
  return s;
}

static int fir_length(double srate) { return srate > 50000 ? 16385 : 8193; }

// FFT-domain FIR Hilbert transformer (Kaiser beta 8), spectrum in WDL permuted order, scaled 1/N.
struct Kernel {
  int N = 0, M = 0, D = 0, hop = 0;
  std::vector<WDL_FFT_COMPLEX> spec;
};

static std::mutex g_kernel_mutex;
static std::vector<std::shared_ptr<Kernel>> g_kernels;

static std::shared_ptr<Kernel> kernel_for(double srate)
{
  int M = fir_length(srate);
  std::lock_guard<std::mutex> lk(g_kernel_mutex);
  for (auto& k : g_kernels) if (k->M == M) return k;
  auto k = std::make_shared<Kernel>();
  k->M = M; k->D = (M - 1) / 2; k->N = 32768; k->hop = k->N - (M - 1);
  k->spec.assign(k->N, WDL_FFT_COMPLEX{0, 0});
  const double beta = 8.0, i0b = bessel_i0(beta);
  for (int kk = -k->D; kk <= k->D; kk++) {
    if ((std::abs(kk) & 1) == 0) continue;
    double r = (double)kk / k->D;
    double w = bessel_i0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / i0b;
    k->spec[kk + k->D].re = 2.0 / (PI * kk) * w / k->N;
  }
  WDL_fft(k->spec.data(), k->N, 0);
  g_kernels.push_back(k);
  return k;
}

// in: N frames of one or two channels packed as complex (re = ch a, im = ch b); out: H{ch a}, H{ch b}
// for frames [M-1, N) of the block, i.e. hop frames.  Both in and out are complex arrays of N.
static void hilbert_block(const Kernel& k, WDL_FFT_COMPLEX* buf)
{
  WDL_fft(buf, k.N, 0);
  for (int i = 0; i < k.N; i++) {
    double ar = buf[i].re, ai = buf[i].im, br = k.spec[i].re, bi = k.spec[i].im;
    buf[i].re = ar * br - ai * bi;
    buf[i].im = ar * bi + ai * br;
  }
  WDL_fft(buf, k.N, 1);
}

// Rotation angle provider: fixed per channel or piecewise-linear trajectory in time.
struct Trajectory {
  double sub_sec = 0;                 // sub-block duration (s)
  std::vector<float> est_l, est_r;    // estimate per sub-block (degrees, continuous)
  double at(double t, int ch) const   // degrees
  {
    const std::vector<float>& e = ch == 0 ? est_l : est_r;
    if (e.empty()) return 0.0;
    double p = t / sub_sec - 0.5;
    if (p <= 0) return e.front();
    int i = (int)p;
    if (i >= (int)e.size() - 1) return e.back();
    double f = p - i;
    return e[i] + (e[i + 1] - e[i]) * f;
  }
};

// ---- allpass "phase rotator": cascade of identical allpass sections (broadcast style)
//   type 1: first-order, corner f0 (90 deg at f0):  y = c x + x[n-1] - c y[n-1],  c = (tan(pi f0/fs) - 1) / (tan(pi f0/fs) + 1)
//   type 2: second-order (RBJ allpass) at f0 with Q: b = [1-a, -2cos w0, 1+a] / (1+a), a = sin w0 / 2Q
// The same designs live in phase_rotation.jsfx and tests/reference.py.
struct ApDesign {
  int type = 0, stages = 0;
  double c = 0, b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  bool operator==(const ApDesign& o) const { return type == o.type && stages == o.stages && c == o.c && b0 == o.b0 && b1 == o.b1; }
};

static ApDesign ap_design(int type, int stages, double freq, double q, double srate)
{
  ApDesign d;
  if (type <= 0 || stages <= 0 || srate < 1) return d;
  d.type = type == 1 ? 1 : 2; d.stages = std::min(64, stages);
  double f = std::max(1.0, std::min(freq, srate * 0.45));
  if (d.type == 1) {
    double k = std::tan(PI * f / srate);
    d.c = (k - 1) / (k + 1);
  } else {
    double w0 = 2 * PI * f / srate, alpha = std::sin(w0) / (2 * std::max(q, 0.05)), a0 = 1 + alpha;
    d.b0 = (1 - alpha) / a0; d.b1 = -2 * std::cos(w0) / a0; d.b2 = 1.0; d.a1 = d.b1; d.a2 = d.b0;
  }
  return d;
}

static int ap_preroll(double srate) { return (int)(0.5 * srate); }   // IIR warm-up before a random-access read

struct Allpass {
  ApDesign d; int nch = 0;
  std::vector<double> st;   // per channel, per stage: 2 state values (direct form II transposed)
  void setup(const ApDesign& dd, int nch_) { d = dd; nch = std::max(0, nch_); st.assign((size_t)nch * std::max(1, d.stages) * 2, 0.0); }
  void reset() { std::fill(st.begin(), st.end(), 0.0); }
  bool active() const { return d.type != 0 && d.stages > 0 && nch > 0; }
  // in place, interleaved 'stride' channels; channels >= nch pass through
  void process(double* buf, int nframes, int stride)
  {
    if (!active() || nframes <= 0) return;
    const int nc = std::min(stride, nch);
    for (int c = 0; c < nc; c++) {
      for (int s = 0; s < d.stages; s++) {
        double* z = &st[((size_t)c * d.stages + s) * 2];
        double s1 = z[0], s2 = z[1];
        double* p = buf + c;
        if (d.type == 1) {
          const double cc = d.c;
          for (int i = 0; i < nframes; i++, p += stride) { double x = *p, y = cc * x + s1; s1 = x - cc * y; *p = y; }
        } else {
          const double b0 = d.b0, b1 = d.b1, b2 = d.b2, a1 = d.a1, a2 = d.a2;
          for (int i = 0; i < nframes; i++, p += stride) { double x = *p, y = b0 * x + s1; s1 = b1 * x - a1 * y + s2; s2 = b2 * x - a2 * y; *p = y; }
        }
        z[0] = s1; z[1] = s2;
      }
    }
  }
};

// Sequential allpass over random-access reads: remembers the filter state at the position where the
// next read is expected to start, so consecutive reads (playback, peak building) need no warm-up.
struct ApStream {
  Allpass ap; bool have = false; double next_pos = -1; std::vector<double> snap;
  bool continuous(double pos) const { return have && std::fabs(pos - next_pos) < 0.5; }
  void prepare(const ApDesign& d, int nch) { if (!(ap.d == d) || ap.nch != nch) { ap.setup(d, nch); have = false; } }
  // filter buf (nframes x stride) that starts at absolute frame position pos; the next read is expected at pos + advance
  void run(double* buf, int nframes, int stride, double pos, int advance)
  {
    if (continuous(pos)) ap.st = snap; else ap.reset();
    int a = std::max(0, std::min(advance, nframes));
    ap.process(buf, a, stride);
    snap = ap.st;
    if (a < nframes) ap.process(buf + (size_t)a * stride, nframes - a, stride);
    next_pos = pos + advance; have = true;
  }
};

} // namespace dsp

// ============================================================================ parameters
struct Params {
  double angle_l = 0, angle_r = 0;
  int adaptive = 0, smooth = 0, bypass = 0, link = 1;
  int ap_type = 0, ap_stages = 4;          // allpass rotator: 0 off, 1 first-order cascade, 2 second-order cascade
  double ap_freq = 200, ap_q = 0.35;
  bool ap_on() const { return ap_type != 0 && ap_stages > 0; }
  bool rotates() const { return adaptive != 0 || angle_l != 0 || angle_r != 0; }
  bool identity() const { return bypass != 0 || (!rotates() && !ap_on()); }
  bool same_ap(const Params& o) const { return ap_type == o.ap_type && ap_stages == o.ap_stages && ap_freq == o.ap_freq && ap_q == o.ap_q; }
  bool operator==(const Params& o) const
  { return angle_l == o.angle_l && angle_r == o.angle_r && adaptive == o.adaptive && smooth == o.smooth && bypass == o.bypass && link == o.link && same_ap(o); }
  bool operator!=(const Params& o) const { return !(*this == o); }
  void clamp()
  {
    adaptive = adaptive ? 1 : 0; bypass = bypass ? 1 : 0; link = link ? 1 : 0;
    smooth = std::min(2, std::max(0, smooth));
    ap_type = std::min(2, std::max(0, ap_type));
    ap_stages = std::min(16, std::max(1, ap_stages));
    ap_freq = std::min(2000.0, std::max(20.0, ap_freq));
    ap_q = std::min(10.0, std::max(0.1, ap_q));
  }
  std::string serialize() const
  {
    char b[192];
    snprintf(b, sizeof(b), "2 %.4f %.4f %d %d %d %d %d %d %.3f %.4f", angle_l, angle_r, adaptive, smooth, bypass, link, ap_type, ap_stages, ap_freq, ap_q);
    return b;
  }
  static bool parse(const char* s, Params* p)
  {
    if (!s || !*s) return false;
    int ver = 0, ad = 0, sm = 0, by = 0, li = 1, at = 0, ast = 4; double al = 0, ar = 0, af = 200, aq = 0.35;
    int n = sscanf(s, "%d %lf %lf %d %d %d %d %d %d %lf %lf", &ver, &al, &ar, &ad, &sm, &by, &li, &at, &ast, &af, &aq);
    if (n < 3 || (ver != 1 && ver != 2)) return false;
    Params q; q.angle_l = al; q.angle_r = ar; q.adaptive = ad; q.smooth = sm; q.bypass = by; q.link = li;
    if (ver >= 2 && n >= 11) { q.ap_type = at; q.ap_stages = ast; q.ap_freq = af; q.ap_q = aq; }
    q.clamp(); *p = q;
    return true;
  }
};

// ============================================================================ source wrapper
class PhaseRotSource;
static std::mutex g_registry_mutex;
static std::vector<PhaseRotSource*> g_registry;   // live wrappers (for safe identification)

// Playback-only override shared by a wrapper and all its Duplicate()s (REAPER reads takes through
// duplicates: audio accessors, playback buffers), so a preview set on the take's wrapper is heard everywhere.
struct PreviewState {
  std::mutex m;
  std::shared_ptr<Params> p;
  std::shared_ptr<dsp::Trajectory> traj;
};

class PhaseRotSource : public PCM_source
{
public:
  PhaseRotSource(PCM_source* child, const Params& p) : m_child(child), m_params(p), m_prev(std::make_shared<PreviewState>())
  {
    dbg_created = time_precise();
    std::lock_guard<std::mutex> lk(g_registry_mutex);
    g_registry.push_back(this);
  }
  ~PhaseRotSource() override
  {
    { std::lock_guard<std::mutex> lk(g_registry_mutex);
      g_registry.erase(std::remove(g_registry.begin(), g_registry.end(), this), g_registry.end()); }
    delete m_ui_child;
    if (m_owns_child) delete m_child;
  }
  static bool is_wrapper(PCM_source* s)
  {
    if (!s) return false;
    std::lock_guard<std::mutex> lk(g_registry_mutex);
    return std::find(g_registry.begin(), g_registry.end(), (PhaseRotSource*)s) != g_registry.end();
  }
  // Hand the child back to REAPER. The pointer stays valid inside this object (a GetSamples
  // call that is still running keeps working), only ownership moves.
  PCM_source* detach() { m_owns_child = false; return m_child; }
  PCM_source* child() const { return m_child; }
  Params params() { std::lock_guard<std::mutex> lk(m_mutex); return m_params; }
  // Separate decoder instance for UI-thread reads (peaks, trajectory) so that the audio
  // thread and the UI never call GetSamples on the same child object at the same time.
  PCM_source* ui_child()
  {
    std::lock_guard<std::mutex> lk(m_ui_mutex);
    if (!m_ui_child && m_child) m_ui_child = m_child->Duplicate();
    return m_ui_child ? m_ui_child : m_child;
  }
  void set_params(const Params& p)
  {
    bool need_traj;
    {
      std::lock_guard<std::mutex> lk(m_mutex);
      need_traj = p.adaptive && (!m_params.adaptive || p.smooth != m_params.smooth || p.link != m_params.link || !p.same_ap(m_params) || !m_traj);
      m_params = p;
      m_peaks_valid = false;
      if (need_traj) m_traj = nullptr;
    }
    if (p.adaptive && need_traj) {
      auto t = build_trajectory(p);            // reads the UI child, no lock held
      std::lock_guard<std::mutex> lk(m_mutex);
      m_traj = t;
    }
  }
  // Preview: parameters used for PLAYBACK only (GetSamples). Peaks, project and undo keep the
  // committed parameters, so the user hears the staged settings while the waveform shows the applied ones.
  void set_preview(const Params* p)
  {
    std::shared_ptr<Params> np; std::shared_ptr<dsp::Trajectory> nt;
    if (p) {
      np = std::make_shared<Params>(*p); np->bypass = 0;
      if (np->adaptive) {
        std::shared_ptr<Params> cur; { std::lock_guard<std::mutex> lk(m_prev->m); cur = m_prev->p; nt = m_prev->traj; }
        if (!(cur && nt && cur->adaptive && cur->smooth == np->smooth && cur->link == np->link && cur->same_ap(*np))) nt = build_trajectory(*np);
      }
    }
    std::lock_guard<std::mutex> lk(m_prev->m);
    m_prev->p = np; m_prev->traj = nt;
  }
  bool has_preview() { std::lock_guard<std::mutex> lk(m_prev->m); return m_prev->p != nullptr; }
  // a replacement wrapper (parameter change) keeps sharing the preview state of the one it replaces
  void copy_preview_from(PhaseRotSource* o) { m_prev = o->m_prev; }

  // ---- PCM_source
  PCM_source* Duplicate() override
  {
    PCM_source* c = m_child ? m_child->Duplicate() : nullptr;
    if (!c) return nullptr;
    Params p; std::shared_ptr<dsp::Trajectory> t;
    { std::lock_guard<std::mutex> lk(m_mutex); p = m_params; t = m_traj; }
    PhaseRotSource* d = new PhaseRotSource(c, p);
    d->m_traj = t;
    d->m_prev = m_prev;     // duplicates hear the same preview
    return d;
  }
  bool IsAvailable() override { return m_child && m_child->IsAvailable(); }
  void SetAvailable(bool avail) override { if (m_child) m_child->SetAvailable(avail); }
  const char* GetType() override { return m_child ? m_child->GetType() : "WAVE"; }
  const char* GetFileName() override { return m_child ? m_child->GetFileName() : nullptr; }
  bool SetFileName(const char* newfn) override { return m_child ? m_child->SetFileName(newfn) : false; }
  // The child is deliberately NOT exposed through GetSource()/SetSource(): REAPER treats a
  // source with a parent like a SECTION wrapper and may keep/free the child on its own
  // (e.g. when restoring undo states), which would double-free it.
  PCM_source* GetSource() override { return nullptr; }
  void SetSource(PCM_source* src) override { (void)src; }
  int GetNumChannels() override { return m_child ? m_child->GetNumChannels() : 0; }
  double GetSampleRate() override { return m_child ? m_child->GetSampleRate() : 0; }
  double GetLength() override { return m_child ? m_child->GetLength() : 0; }
  double GetLengthBeats() override { return m_child ? m_child->GetLengthBeats() : -1.0; }
  int GetBitsPerSample() override { return m_child ? m_child->GetBitsPerSample() : 0; }
  double GetPreferredPosition() override { return m_child ? m_child->GetPreferredPosition() : -1.0; }
  int PropertiesWindow(HWND hwndParent) override { return m_child ? m_child->PropertiesWindow(hwndParent) : 0; }
  void SaveState(ProjectStateContext* ctx) override { if (m_child) m_child->SaveState(ctx); }
  int LoadState(const char* firstline, ProjectStateContext* ctx) override { return m_child ? m_child->LoadState(firstline, ctx) : -1; }
  void Peaks_Clear(bool deleteFile) override { invalidate(); if (m_child) m_child->Peaks_Clear(deleteFile); }
  int PeaksBuild_Begin() override { return 0; }
  int PeaksBuild_Run() override { return 0; }
  void PeaksBuild_Finish() override {}
  int Extended(int call, void* parm1, void* parm2, void* parm3) override
  {
    if (call == PR_EXT_IDENTIFY) return PR_MAGIC;
    return m_child ? m_child->Extended(call, parm1, parm2, parm3) : 0;
  }

  // debug counters (PhaseRot_GetDebug)
  std::atomic<long> dbg_samples{0}, dbg_peaks{0};
  double dbg_created = 0;

  void GetSamples(PCM_source_transfer_t* block) override
  {
    dbg_samples++;
    if (!m_child) { block->samples_out = 0; return; }
    Params p; std::shared_ptr<dsp::Trajectory> tr;
    bool have_prev = false;
    { std::lock_guard<std::mutex> lk(m_prev->m); if (m_prev->p) { p = *m_prev->p; tr = m_prev->traj; have_prev = true; } }
    if (!have_prev) { std::lock_guard<std::mutex> lk(m_mutex); p = m_params; tr = m_traj; }
    if (p.identity()) {
      m_child->GetSamples(block);
      return;
    }
    // the allpass state follows consecutive reads of the audio thread; a concurrent reader gets its own warm-up
    std::unique_lock<std::mutex> lk(m_ap_audio_mutex, std::try_to_lock);
    render(m_child, block->time_s, block->samplerate, block->nch, block->length, block->samples, &block->samples_out, p, tr,
           lk.owns_lock() ? &m_ap_audio : nullptr);
    block->midi_events = nullptr;
  }

  void GetPeakInfo(PCM_source_peaktransfer_t* block) override
  {
    dbg_peaks++;
    block->peaks_out = 0;
    block->extra_requested_data_out = 0;
    block->extra_requested_data_out2 = 0;
    if (!m_child) return;
    Params p; std::shared_ptr<dsp::Trajectory> tr;
    { std::lock_guard<std::mutex> lk(m_mutex); p = m_params; tr = m_traj; }
    if (p.identity()) {
      m_child->GetPeakInfo(block);
      return;
    }
    const int nchp = block->nchpeaks;
    const int npts = block->numpeak_points;
    if (nchp <= 0 || npts <= 0 || block->peakrate <= 0) return;
    const double len = GetLength();
    const double sr = GetSampleRate();
    if (sr < 1) return;

    if (block->output_mode == PCM_source_peaktransfer_t::PEAKTRANSFER_WAVEFORM_MODE || block->peakrate > sr / (2 * PEAK_BIN)) {
      // zoomed in: compute from samples
      int nch = std::max(1, GetNumChannels());
      double span = npts / block->peakrate;
      int nfr = (int)std::ceil(span * sr) + 2;
      if (nfr > 4 * 1024 * 1024) return;
      std::vector<double> buf((size_t)nfr * nch);
      int got = 0;
      render(ui_child(), block->start_time, sr, nch, nfr, buf.data(), &got, p, tr, nullptr);
      int outp = 0;
      for (int i = 0; i < npts; i++) {
        double t0 = block->start_time + i / block->peakrate;
        if (t0 >= len) break;
        int f0 = (int)std::floor((t0 - block->start_time) * sr);
        int f1 = (int)std::floor((t0 + 1.0 / block->peakrate - block->start_time) * sr);
        if (f1 <= f0) f1 = f0 + 1;
        f0 = std::max(0, std::min(f0, got - 1)); f1 = std::max(f0 + 1, std::min(f1, got));
        for (int c = 0; c < nchp; c++) {
          int sc = std::min(c, nch - 1);
          double mx = -1e30, mn = 1e30;
          for (int f = f0; f < f1; f++) { double v = buf[(size_t)f * nch + sc]; if (v > mx) mx = v; if (v < mn) mn = v; }
          if (f0 >= got) { mx = mn = 0; }
          block->peaks[i * nchp + c] = mx;
          if (block->peaks_minvals) block->peaks_minvals[i * nchp + c] = mn;
        }
        outp++;
      }
      block->peaks_out = outp;
      if (block->peaks_minvals) block->peaks_minvals_used = 1;
      return;
    }

    ensure_peaks(p, tr);
    std::lock_guard<std::mutex> lk(m_mutex);
    if (!m_peaks_valid || m_peak_nbins == 0) return;
    const double binrate = sr / PEAK_BIN;
    int outp = 0;
    for (int i = 0; i < npts; i++) {
      double t0 = block->start_time + i / block->peakrate;
      if (t0 >= len) break;
      double t1 = t0 + 1.0 / block->peakrate;
      int b0 = (int)std::floor(t0 * binrate), b1 = (int)std::ceil(t1 * binrate);
      b0 = std::max(0, std::min(b0, m_peak_nbins - 1)); b1 = std::max(b0 + 1, std::min(b1, m_peak_nbins));
      for (int c = 0; c < nchp; c++) {
        int sc = std::min(c, m_peak_nch - 1);
        float mx = -1e30f, mn = 1e30f;
        const float* pmax = &m_peak_max[(size_t)sc * m_peak_nbins];
        const float* pmin = &m_peak_min[(size_t)sc * m_peak_nbins];
        for (int b = b0; b < b1; b++) { if (pmax[b] > mx) mx = pmax[b]; if (pmin[b] < mn) mn = pmin[b]; }
        block->peaks[i * nchp + c] = mx;
        if (block->peaks_minvals) block->peaks_minvals[i * nchp + c] = mn;
      }
      outp++;
    }
    block->peaks_out = outp;
    if (block->peaks_minvals) block->peaks_minvals_used = 1;
  }

  // Render 'length' frames at 'srate' starting at time_s into out (interleaved nch), rotated.
  // 'src' is the decoder to read from (m_child on the audio thread, ui_child() elsewhere).
  // 'stream' keeps the allpass state between consecutive reads (nullptr = warm up from scratch).
  void render(PCM_source* src, double time_s, double srate, int nch, int length, double* out, int* out_frames,
              const Params& p, const std::shared_ptr<dsp::Trajectory>& traj, dsp::ApStream* stream)
  {
    *out_frames = 0;
    if (!src || length <= 0 || nch <= 0 || srate < 1) return;
    dsp::ApStream local_stream;
    if (!stream) stream = &local_stream;
    const bool ap = p.ap_on();
    if (ap) stream->prepare(dsp::ap_design(p.ap_type, p.ap_stages, p.ap_freq, p.ap_q, srate), std::min(2, nch));
    static thread_local std::vector<double> in;          // reused: no allocation in steady state
    static thread_local std::vector<WDL_FFT_COMPLEX> fbuf;
    if (!p.rotates()) {
      // allpass only: no FIR context needed
      const double pos = time_s * srate;
      const int PRE = stream->continuous(pos) ? 0 : dsp::ap_preroll(srate);
      const size_t need = (size_t)(PRE + length) * nch;
      if (in.size() < need) in.resize(need);
      std::fill(in.begin(), in.begin() + need, 0.0);
      int nvalid = fetch_child(src, time_s - (double)PRE / srate, srate, nch, PRE + length, in.data()) - PRE;
      if (nvalid <= 0 && time_s >= GetLength()) return;
      stream->run(in.data(), PRE + length, nch, pos - PRE, PRE + length);
      memcpy(out, in.data() + (size_t)PRE * nch, sizeof(double) * (size_t)length * nch);
      *out_frames = std::min(length, std::max(0, nvalid));
      if (*out_frames < length && time_s + (double)length / srate <= GetLength() + 1e-9) *out_frames = length;
      return;
    }
    auto kern = dsp::kernel_for(srate);
    const int D = kern->D, M = kern->M, N = kern->N, hop = kern->hop;
    // input needed: [time_s - D/sr, time_s + (length + D)/sr)  (+ allpass warm-up before it)
    const int nin = length + (M - 1);
    const double t_in = time_s - (double)D / srate;
    const double pos = t_in * srate;
    const int PRE = (ap && !stream->continuous(pos)) ? dsp::ap_preroll(srate) : 0;
    if (in.size() < (size_t)(PRE + nin) * nch) in.resize((size_t)(PRE + nin) * nch);
    if (fbuf.size() < (size_t)N) fbuf.resize(N);
    std::fill(in.begin(), in.begin() + (size_t)(PRE + nin) * nch, 0.0);
    int nvalid_in = fetch_child(src, t_in - (double)PRE / srate, srate, nch, PRE + nin, in.data()) - PRE;
    if (nvalid_in <= 0 && time_s >= GetLength()) return;
    if (ap) stream->run(in.data(), PRE + nin, nch, pos - PRE, PRE + length);
    const double* IN = in.data() + (size_t)PRE * nch;

    const double a_l = p.angle_l * PI / 180, a_r = p.angle_r * PI / 180;
    const double cl = std::cos(a_l), sl = std::sin(a_l), cr = std::cos(a_r), sr_ = std::sin(a_r);

    for (int c0 = 0; c0 < nch; c0 += 2) {
      const int c1 = (c0 + 1 < nch) ? c0 + 1 : -1;
      const bool rot_c0 = (c0 <= 1), rot_c1 = (c1 == 1);
      if (!rot_c0 && !rot_c1) {
        // channels beyond the first two pass through untouched
        for (int f = 0; f < length; f++) {
          out[(size_t)f * nch + c0] = IN[(size_t)(f + D) * nch + c0];
          if (c1 >= 0) out[(size_t)f * nch + c1] = IN[(size_t)(f + D) * nch + c1];
        }
        continue;
      }
      for (int start = 0; start < length; start += hop) {
        // block input frames [start, start + N) of 'in' (zero beyond nin)
        for (int j = 0; j < N; j++) {
          int f = start + j;
          if (f < nin) { fbuf[j].re = IN[(size_t)f * nch + c0]; fbuf[j].im = c1 >= 0 ? IN[(size_t)f * nch + c1] : 0.0; }
          else { fbuf[j].re = 0; fbuf[j].im = 0; }
        }
        dsp::hilbert_block(*kern, fbuf.data());
        int nout = std::min(hop, length - start);
        for (int i = 0; i < nout; i++) {
          int f = start + i;                 // output frame
          int j = i + (M - 1);               // FFT index with valid linear convolution
          double xl = IN[(size_t)(f + D) * nch + c0], hl = fbuf[j].re;
          double xr = c1 >= 0 ? IN[(size_t)(f + D) * nch + c1] : 0.0, hr = fbuf[j].im;
          double cL = cl, sL = sl, cR = cr, sR = sr_;
          if (p.adaptive && traj) {
            double t = time_s + (double)f / srate;
            double al = traj->at(t, 0) * PI / 180, ar = traj->at(t, 1) * PI / 180;
            cL = std::cos(al); sL = std::sin(al); cR = std::cos(ar); sR = std::sin(ar);
          }
          out[(size_t)f * nch + c0] = rot_c0 ? (cL * xl + sL * hl) : xl;
          if (c1 >= 0) out[(size_t)f * nch + c1] = rot_c1 ? (cR * xr + sR * hr) : xr;
        }
      }
    }
    // frames actually available from the child (beyond the end: silence, report like the child would)
    int avail = nvalid_in - D;
    if (avail < 0) avail = 0;
    *out_frames = std::min(length, std::max(0, avail));
    if (*out_frames < length && time_s + (double)length / srate <= GetLength() + 1e-9) *out_frames = length;
  }

private:
  static const int PEAK_BIN = 128;
  friend void bury_wrapper(PhaseRotSource*);

  // reads nframes from 'src' starting at t (may be negative: zero padded). returns frames valid (relative to start).
  static int fetch_child(PCM_source* src, double t, double srate, int nch, int nframes, double* dst)
  {
    int skip = 0;
    if (t < 0) {
      skip = (int)std::ceil(-t * srate - 1e-6);   // positions are sample-aligned; guard against 28096.0000000001
      if (skip >= nframes) return 0;
      t += (double)skip / srate;
    }
    PCM_source_transfer_t tr;
    memset(&tr, 0, sizeof(tr));
    tr.time_s = t;
    tr.samplerate = srate;
    tr.nch = nch;
    tr.length = nframes - skip;
    tr.samples = dst + (size_t)skip * nch;
    tr.samples_out = 0;
    src->GetSamples(&tr);
    int got = tr.samples_out;
    if (got < tr.length) memset(dst + (size_t)(skip + std::max(0, got)) * nch, 0, sizeof(double) * (size_t)(tr.length - std::max(0, got)) * nch);
    return skip + std::max(0, got);
  }

  void invalidate() { std::lock_guard<std::mutex> lk(m_mutex); m_peaks_valid = false; }

  void ensure_peaks(const Params& p, const std::shared_ptr<dsp::Trajectory>& tr)
  {
    {
      std::lock_guard<std::mutex> lk(m_mutex);
      if (m_peaks_valid) return;
    }
    std::lock_guard<std::mutex> lk2(m_build_mutex);
    { std::lock_guard<std::mutex> lk(m_mutex); if (m_peaks_valid) return; }
    PCM_source* src = ui_child();
    const double sr = GetSampleRate();
    const int nch = std::max(1, GetNumChannels());
    const double len = GetLength();
    const long long nframes = (long long)std::ceil(len * sr);
    const int nbins = (int)((nframes + PEAK_BIN - 1) / PEAK_BIN);
    std::vector<float> pmax((size_t)nbins * nch, 0.0f), pmin((size_t)nbins * nch, 0.0f);
    auto kern = dsp::kernel_for(sr);
    const int chunk = kern->hop * 2;
    std::vector<double> buf((size_t)chunk * nch);
    dsp::ApStream stream;
    for (long long start = 0; start < nframes; start += chunk) {
      int n = (int)std::min<long long>(chunk, nframes - start);
      int got = 0;
      render(src, (double)start / sr, sr, nch, n, buf.data(), &got, p, tr, &stream);
      for (int f = 0; f < n; f++) {
        int b = (int)((start + f) / PEAK_BIN);
        for (int c = 0; c < nch; c++) {
          float v = (float)buf[(size_t)f * nch + c];
          float& mx = pmax[(size_t)c * nbins + b]; float& mn = pmin[(size_t)c * nbins + b];
          if ((start + f) % PEAK_BIN == 0) { mx = mn = v; }
          else { if (v > mx) mx = v; if (v < mn) mn = v; }
        }
      }
    }
    std::lock_guard<std::mutex> lk(m_mutex);
    m_peak_max.swap(pmax); m_peak_min.swap(pmin);
    m_peak_nbins = nbins; m_peak_nch = nch;
    m_peaks_valid = true;
  }

  // adaptive: per 43 ms sub-block, the angle minimising the block peak (2 deg bins), nearest-to-previous
  // hysteresis, silence holds the previous value (folded to the principal branch), optional median smoothing.
  // Linked: one angle from both channels; unlinked: one trajectory per channel.
  std::shared_ptr<dsp::Trajectory> build_trajectory(const Params& p)
  {
    PCM_source* src = ui_child();
    const double sr = GetSampleRate();
    const int nch = std::max(1, std::min(2, GetNumChannels()));
    const double len = GetLength();
    if (!src || sr < 1 || len <= 0) return nullptr;
    auto kern = dsp::kernel_for(sr);
    const int SUB = sr > 50000 ? 4096 : 2048;
    const long long nframes = (long long)std::ceil(len * sr);
    const int nsub = (int)((nframes + SUB - 1) / SUB);
    const int NB = 90;
    auto traj = std::make_shared<dsp::Trajectory>();
    traj->sub_sec = SUB / sr;
    traj->est_l.assign(nsub, 0.0f); traj->est_r.assign(nsub, 0.0f);
    const int chunk = kern->hop;
    const int N = kern->N, M = kern->M, D = kern->D;
    std::vector<WDL_FFT_COMPLEX> fbuf(N);
    std::vector<double> in, x((size_t)chunk * 2), h((size_t)chunk * 2);
    std::vector<double> bins[2] = { std::vector<double>(NB), std::vector<double>(NB) };
    double runpk2[2] = {0, 0}, prev[2] = {0, 0};
    const bool linked = p.link != 0 || nch < 2;
    const bool ap = p.ap_on();
    dsp::ApStream stream;
    if (ap) stream.prepare(dsp::ap_design(p.ap_type, p.ap_stages, p.ap_freq, p.ap_q, sr), nch);
    int sub_index = 0;
    auto search = [&](const std::vector<double>& b, double prevdeg) {
      double cost[180]; double best = -1; int bestt = 0;
      for (int t = 0; t < 180; t++) {
        double cst = 0;
        for (int i = 0; i < NB; i++) if (b[i] > 0) {
          double v = b[i] * std::fabs(std::cos((2 * i + 1 - t) * PI / 180));
          if (v > cst) cst = v;
        }
        cost[t] = cst;
        if (best < 0 || cst < best) { best = cst; bestt = t; }
      }
      double bestd = 1e30; int chosen = bestt;
      for (int t = 0; t < 180; t++) if (cost[t] <= best * 1.002) {
        double d = std::fabs(t - prevdeg); d = std::fabs(d - 180.0 * std::floor(d / 180.0 + 0.5));
        if (d < bestd) { bestd = d; chosen = t; }
      }
      return chosen + 180.0 * std::floor((prevdeg - chosen) / 180.0 + 0.5);
    };
    for (long long start = 0; start < nframes; start += chunk) {
      int n = (int)std::min<long long>(chunk, nframes - start);
      const int nin = n + (M - 1);
      const double t = (double)start / sr - (double)D / sr, pos = t * sr;
      const int PRE = (ap && !stream.continuous(pos)) ? dsp::ap_preroll(sr) : 0;
      in.assign((size_t)(PRE + nin) * nch, 0.0);
      fetch_child(src, t - (double)PRE / sr, sr, nch, PRE + nin, in.data());
      if (ap) stream.run(in.data(), PRE + nin, nch, pos - PRE, PRE + n);
      const double* IN = in.data() + (size_t)PRE * nch;
      for (int j = 0; j < N; j++) {
        if (j < nin) { fbuf[j].re = IN[(size_t)j * nch]; fbuf[j].im = nch > 1 ? IN[(size_t)j * nch + 1] : 0.0; }
        else fbuf[j].re = fbuf[j].im = 0;
      }
      dsp::hilbert_block(*kern, fbuf.data());
      for (int f = 0; f < n; f++) {
        x[(size_t)f * 2] = IN[(size_t)(f + D) * nch]; h[(size_t)f * 2] = fbuf[f + M - 1].re;
        x[(size_t)f * 2 + 1] = nch > 1 ? IN[(size_t)(f + D) * nch + 1] : 0.0; h[(size_t)f * 2 + 1] = fbuf[f + M - 1].im;
      }
      for (int s0 = 0; s0 < n; s0 += SUB) {
        int s1 = std::min(n, s0 + SUB);
        double m2[2] = {0, 0};
        for (int f = s0; f < s1; f++) for (int c = 0; c < nch; c++) {
          double a2 = x[(size_t)f * 2 + c] * x[(size_t)f * 2 + c] + h[(size_t)f * 2 + c] * h[(size_t)f * 2 + c];
          if (a2 > m2[c]) m2[c] = a2;
        }
        bool hold[2];
        for (int c = 0; c < 2; c++) { runpk2[c] = std::max(m2[c], runpk2[c] * 0.97); hold[c] = m2[c] < 1e-6 || m2[c] < runpk2[c] * 0.01; }
        if (nch == 1) hold[1] = hold[0];
        if (linked) { bool hh = hold[0] && hold[1]; hold[0] = hold[1] = hh; }
        for (int c = 0; c < nch; c++) {
          std::fill(bins[c].begin(), bins[c].end(), 0.0);
          if (hold[c]) continue;
          double thr2 = m2[c] * 0.25;
          for (int f = s0; f < s1; f++) {
            double xv = x[(size_t)f * 2 + c], hv = h[(size_t)f * 2 + c], a2 = xv * xv + hv * hv;
            if (a2 < thr2 || a2 <= 0) continue;
            double ph = std::atan2(hv, xv); if (ph < 0) ph += PI;
            int b = (int)(ph * NB / PI); if (b >= NB) b = NB - 1;
            double a = std::sqrt(a2); if (a > bins[c][b]) bins[c][b] = a;
          }
        }
        double est[2];
        if (linked) {
          if (hold[0]) {
            est[0] = prev[0] - 180.0 * std::floor((prev[0] + 90.0) / 180.0);
          } else {
            std::vector<double> both(NB);
            for (int b = 0; b < NB; b++) both[b] = std::max(bins[0][b], nch > 1 ? bins[1][b] : 0.0);
            est[0] = search(both, prev[0]);
          }
          est[1] = est[0];
        } else {
          for (int c = 0; c < 2; c++) {
            if (hold[c]) est[c] = prev[c] - 180.0 * std::floor((prev[c] + 90.0) / 180.0);
            else est[c] = search(bins[c], prev[c]);
          }
        }
        prev[0] = est[0]; prev[1] = est[1];
        if (sub_index < nsub) { traj->est_l[sub_index] = (float)est[0]; traj->est_r[sub_index] = (float)est[1]; }
        sub_index++;
      }
    }
    if (p.smooth > 0) {
      int w = p.smooth == 1 ? 1 : 2;
      for (auto* e : { &traj->est_l, &traj->est_r }) {
        std::vector<float> src_e = *e;
        for (int i = 0; i < (int)src_e.size(); i++) {
          std::vector<float> win;
          for (int j = std::max(0, i - w); j <= std::min((int)src_e.size() - 1, i + w); j++) win.push_back(src_e[j]);
          std::sort(win.begin(), win.end());
          (*e)[i] = win[win.size() / 2];
        }
      }
    }
    return traj;
  }

  PCM_source* m_child;
  PCM_source* m_ui_child = nullptr;
  bool m_owns_child = true;
  Params m_params;
  std::mutex m_mutex, m_build_mutex, m_ui_mutex, m_ap_audio_mutex;
  std::shared_ptr<dsp::Trajectory> m_traj;
  std::shared_ptr<PreviewState> m_prev;              // playback-only override (see set_preview), shared with duplicates
  dsp::ApStream m_ap_audio;                          // allpass state of the audio thread's consecutive reads
  std::vector<float> m_peak_max, m_peak_min;
  int m_peak_nbins = 0, m_peak_nch = 0;
  bool m_peaks_valid = false;
};

// ============================================================================ take management
static bool take_ext(MediaItem_Take* take, Params* p)
{
  char buf[512]; buf[0] = 0;
  if (!GetSetMediaItemTakeInfo_String(take, PR_EXT_KEY, buf, false)) return false;
  return Params::parse(buf, p);
}

static void take_set_ext(MediaItem_Take* take, const Params* p)
{
  char buf[256];
  if (p) snprintf(buf, sizeof(buf), "%s", p->serialize().c_str()); else buf[0] = 0;
  GetSetMediaItemTakeInfo_String(take, PR_EXT_KEY, buf, true);
}

// Wrappers that were taken off a take are not deleted at once: the audio thread may still be
// inside GetSamples(). They are parked here and freed by the timer a few seconds later.
static std::mutex g_grave_mutex;
static std::vector<std::pair<double, PhaseRotSource*>> g_graveyard;
void bury_wrapper(PhaseRotSource* w)
{
  std::lock_guard<std::mutex> lk(g_grave_mutex);
  g_graveyard.push_back({ time_precise(), w });
}
static void sweep_graveyard(bool all)
{
  std::vector<PhaseRotSource*> dead;
  {
    std::lock_guard<std::mutex> lk(g_grave_mutex);
    double now = time_precise();
    for (auto it = g_graveyard.begin(); it != g_graveyard.end();) {
      if (all || now - it->first > 3.0) { dead.push_back(it->second); it = g_graveyard.erase(it); }
      else ++it;
    }
  }
  for (auto* w : dead) delete w;
}

// true if 'src' or any source wrapped inside it (SECTION etc.) is one of ours
static bool chain_has_wrapper(PCM_source* src)
{
  int guard = 0;
  while (src && guard++ < 16) {
    if (PhaseRotSource::is_wrapper(src)) return true;
    src = src->GetSource();
  }
  return false;
}

// make the take's source follow P_EXT. returns true if something changed.
static bool sync_take(MediaItem_Take* take)
{
  if (TakeIsMIDI(take)) return false;
  PCM_source* src = (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr);
  Params p;
  bool has = take_ext(take, &p);
  bool wrapped = PhaseRotSource::is_wrapper(src);
  if (has) {
    if (!src || src->GetNumChannels() <= 0 || src->GetSampleRate() < 1) return false;   // not audio
    if (!wrapped) {
      if (chain_has_wrapper(src)) return false;      // e.g. a SECTION around our wrapper: leave it alone
      PhaseRotSource* w = new PhaseRotSource(src, Params());
      w->set_params(p);
      GetSetMediaItemTakeInfo(take, "P_SOURCE", w);
      return true;
    }
    PhaseRotSource* w = (PhaseRotSource*)src;
    if (w->params() != p) {
      // REAPER keeps the drawn peaks of a take per source object and does not re-read them
      // after UpdateItemInProject, so a parameter change swaps in a fresh wrapper around the
      // same child; the old one is parked in the graveyard until the audio thread is out.
      PhaseRotSource* w2 = new PhaseRotSource(w->detach(), Params());
      w2->set_params(p);
      w2->copy_preview_from(w);
      GetSetMediaItemTakeInfo(take, "P_SOURCE", w2);
      bury_wrapper(w);
      return true;
    }
    return false;
  }
  if (wrapped) {
    PhaseRotSource* w = (PhaseRotSource*)src;
    if (w->has_preview()) {
      // nothing applied but a preview is running: keep the wrapper, with identity as the committed state
      if (w->params() == Params()) return false;
      PhaseRotSource* w2 = new PhaseRotSource(w->detach(), Params());
      w2->copy_preview_from(w);
      GetSetMediaItemTakeInfo(take, "P_SOURCE", w2);
      bury_wrapper(w);
      return true;
    }
    // same reason: give REAPER a fresh copy of the original source so the waveform redraws;
    // the wrapper keeps (and later frees) the child it was reading from
    PCM_source* fresh = w->child() ? w->child()->Duplicate() : nullptr;
    if (fresh) GetSetMediaItemTakeInfo(take, "P_SOURCE", fresh);
    else GetSetMediaItemTakeInfo(take, "P_SOURCE", w->detach());
    bury_wrapper(w);
    return true;
  }
  return false;
}

// REAPER caches the drawn peaks of an item and does not re-read them after UpdateItemInProject
// when the take's source object changes. "Peaks: Build any missing peaks" (40047) makes it
// re-request peaks from every source (cheap: nothing is normally missing) - measured to be the
// least intrusive trigger; property pokes (volume, mute) would touch user state or the audio.
static void refresh_peak_display()
{
  if (Main_OnCommand) Main_OnCommand(40047, 0);
}

static void scan_all_projects()
{
  bool any = false;
  for (int pi = 0;; pi++) {
    ReaProject* proj = EnumProjects(pi, nullptr, 0);
    if (!proj) break;
    int nitems = CountMediaItems(proj);
    for (int i = 0; i < nitems; i++) {
      MediaItem* item = GetMediaItem(proj, i);
      int ntakes = CountTakes(item);
      bool changed = false;
      for (int t = 0; t < ntakes; t++) {
        MediaItem_Take* take = GetTake(item, t);
        if (take && sync_take(take)) changed = true;
      }
      if (changed) { UpdateItemInProject(item); any = true; }
    }
  }
  if (any) refresh_peak_display();
  sweep_graveyard(false);
}

// on unload: give every take its original source back before our vtables disappear
static void unwrap_everything()
{
  for (int pi = 0;; pi++) {
    ReaProject* proj = EnumProjects(pi, nullptr, 0);
    if (!proj) break;
    int nitems = CountMediaItems(proj);
    for (int i = 0; i < nitems; i++) {
      MediaItem* item = GetMediaItem(proj, i);
      for (int t = 0; t < CountTakes(item); t++) {
        MediaItem_Take* take = GetTake(item, t);
        if (!take) continue;
        PCM_source* src = (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr);
        if (PhaseRotSource::is_wrapper(src)) {
          PhaseRotSource* w = (PhaseRotSource*)src;
          GetSetMediaItemTakeInfo(take, "P_SOURCE", w->detach());
          bury_wrapper(w);
        }
      }
    }
  }
  sweep_graveyard(true);
}

static double g_last_scan = 0;
static void timer_func()
{
  double now = time_precise();
  if (now - g_last_scan < 0.15) return;
  g_last_scan = now;
  scan_all_projects();
}

// ============================================================================ analysis (Suggest)
namespace ana {
static const int NBINS = 2880, NC = 1440;
static const double STEP = 0.125;

struct ChanStats {
  std::vector<double> bins_max, s8;   // NBINS, NC
  double pos = 0, neg = 0, max2 = 0, thr2 = 0;
};

static void cost_curves(const ChanStats& cs, std::vector<double>& cmax, std::vector<double>& c8)
{
  static std::vector<double> C, C8;
  if (C.empty()) {
    C.resize(NC); C8.resize(NC);
    for (int i = 0; i < NC; i++) { double c = std::fabs(std::cos((i + 0.5) * STEP * PI / 180)); C[i] = c; C8[i] = std::pow(c, 8.0); }
  }
  cmax.assign(NC, 0.0); c8.assign(NC, 0.0);
  std::vector<std::pair<double, int>> list;
  for (int b = 0; b < NBINS; b++) if (cs.bins_max[b] > 0) list.push_back({cs.bins_max[b], b});
  std::sort(list.begin(), list.end(), [](auto& a, auto& b) { return a.first > b.first; });
  std::vector<std::pair<double, int>> l8;
  for (int b = 0; b < NC; b++) if (cs.s8[b] > 0) l8.push_back({cs.s8[b], b});
  for (int t = 0; t < NC; t++) {
    double c = 0;
    for (auto& e : list) { if (e.first <= c) break; double v = e.first * C[((e.second - t + 720) % NC + NC) % NC]; if (v > c) c = v; }
    cmax[t] = c;
    double s = 0;
    for (auto& e : l8) s += e.first * C8[((e.second - t + 720) % NC + NC) % NC];
    c8[t] = s;
  }
}

static int pick_min(const std::vector<double>& cost, double tol_rel)
{
  double best = 1e300;
  for (double c : cost) best = std::min(best, c);
  double tol = best * (1 + tol_rel);
  int bt = 0; double bd = 1e300;
  for (int t = 0; t < NC; t++) if (cost[t] <= tol) { double ang = std::fabs(-90 + t * STEP); if (ang < bd) { bd = ang; bt = t; } }
  return bt;
}

static void peaks_after(const ChanStats& cs, double theta_deg, double* pos, double* neg)
{
  double th = theta_deg * PI / 180; *pos = 0; *neg = 0;
  for (int b = 0; b < NBINS; b++) {
    double a = cs.bins_max[b]; if (a <= 0) continue;
    double v = a * std::cos((b + 0.5) * 2 * PI / NBINS - th);
    if (v > *pos) *pos = v; else if (-v > *neg) *neg = -v;
  }
}

static double db(double v) { return v <= 1e-12 ? -240.0 : 20 * std::log10(v); }
} // namespace ana

// Analyse the ORIGINAL audio of the take (child if wrapped), over the part of the source the
// item actually plays (start offset, length, play rate) and through the take's channel mode.
// Result text goes to ExtState phaserot/analysis.
static bool analyze_take(MediaItem_Take* take, const Params& ap_params)
{
  SetExtState("phaserot", "analysis", "", false);
  PCM_source* base = (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr);
  if (!base) return false;
  if (PhaseRotSource::is_wrapper(base)) base = ((PhaseRotSource*)base)->child();
  if (!base || base->GetNumChannels() <= 0 || base->GetSampleRate() < 1) return false;
  PCM_source* src = base->Duplicate();          // private decoder: never shared with the audio thread
  if (!src) return false;
  const double sr = src->GetSampleRate();
  const int src_nch = std::max(1, src->GetNumChannels());
  const double src_len = src->GetLength();
  // take window in source time
  MediaItem* item = GetMediaItemTake_Item(take);
  double offs = GetMediaItemTakeInfo_Value(take, "D_STARTOFFS");
  double rate = GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"); if (rate <= 0) rate = 1.0;
  double ilen = item ? GetMediaItemInfo_Value(item, "D_LENGTH") : src_len;
  double t_start = std::max(0.0, offs);
  double t_end = std::min(src_len, offs + ilen * rate);
  if (t_end <= t_start) { t_start = 0; t_end = src_len; }
  const int chanmode = (int)GetMediaItemTakeInfo_Value(take, "I_CHANMODE");
  // channel routing: which source channels feed analysis channel 0/1 (-1 = downmix of 0+1)
  int map0 = 0, map1 = src_nch > 1 ? 1 : -2;      // -2 = none (mono analysis)
  if (chanmode == 1 && src_nch > 1) { map0 = 1; map1 = 0; }
  else if (chanmode == 2) { map0 = -1; map1 = -2; }
  else if (chanmode >= 3 && chanmode < 64) { map0 = std::min(src_nch - 1, chanmode - 3); map1 = -2; }
  else if (chanmode >= 64) { map0 = std::min(src_nch - 1, chanmode - 64); map1 = (map0 + 1 < src_nch) ? map0 + 1 : -2; }
  const int nch = map1 == -2 ? 1 : 2;
  const long long nframes = (long long)std::ceil((t_end - t_start) * sr);
  auto kern = dsp::kernel_for(sr);
  const int N = kern->N, M = kern->M, D = kern->D, hop = kern->hop;
  std::vector<WDL_FFT_COMPLEX> fbuf(N);
  std::vector<double> raw, in;
  const bool ap = ap_params.ap_on();
  dsp::ApStream stream;
  if (ap) stream.prepare(dsp::ap_design(ap_params.ap_type, ap_params.ap_stages, ap_params.ap_freq, ap_params.ap_q, sr), nch);
  ana::ChanStats cs[2];
  double orig_peak[2] = {0, 0};   // peak of the ORIGINAL audio (before the allpass rotator)
  for (int c = 0; c < 2; c++) { cs[c].bins_max.assign(ana::NBINS, 0.0); cs[c].s8.assign(ana::NC, 0.0); }
  const double K = ana::NBINS / (2 * PI), THR2 = 0.01;
  auto pick = [&](const double* fr, int which) {
    int m = which == 0 ? map0 : map1;
    if (m == -1) return 0.5 * (fr[0] + (src_nch > 1 ? fr[1] : fr[0]));
    return fr[m];
  };
  for (long long start = 0; start < nframes; start += hop) {
    int n = (int)std::min<long long>(hop, nframes - start);
    int nin = n + (M - 1);
    const double t0 = t_start + (double)start / sr - (double)D / sr, pos = t0 * sr;
    const int PRE = (ap && !stream.continuous(pos)) ? dsp::ap_preroll(sr) : 0;
    const int ntot = PRE + nin;
    raw.assign((size_t)ntot * src_nch, 0.0);
    in.assign((size_t)ntot * nch, 0.0);
    double t = t0 - (double)PRE / sr;
    int skip = 0;
    if (t < 0) { skip = (int)std::ceil(-t * sr - 1e-6); t += (double)skip / sr; }
    if (skip < ntot) {
      PCM_source_transfer_t tr; memset(&tr, 0, sizeof(tr));
      tr.time_s = t; tr.samplerate = sr; tr.nch = src_nch; tr.length = ntot - skip; tr.samples = raw.data() + (size_t)skip * src_nch;
      src->GetSamples(&tr);
      if (tr.samples_out < tr.length && tr.samples_out >= 0) memset(raw.data() + (size_t)(skip + tr.samples_out) * src_nch, 0, sizeof(double) * (size_t)(tr.length - tr.samples_out) * src_nch);
    }
    // samples beyond the item window (only the FIR context reaches there) are used as-is: that is what plays
    for (int j = 0; j < ntot; j++) {
      const double* fr = &raw[(size_t)j * src_nch];
      in[(size_t)j * nch] = pick(fr, 0);
      if (nch > 1) in[(size_t)j * nch + 1] = pick(fr, 1);
    }
    for (int f = 0; f < n; f++) for (int c = 0; c < nch; c++) { double v = std::fabs(in[(size_t)(PRE + f + D) * nch + c]); if (v > orig_peak[c]) orig_peak[c] = v; }
    if (ap) stream.run(in.data(), ntot, nch, pos - PRE, PRE + n);
    const double* IN = in.data() + (size_t)PRE * nch;
    for (int j = 0; j < N; j++) {
      if (j < nin) { fbuf[j].re = IN[(size_t)j * nch]; fbuf[j].im = nch > 1 ? IN[(size_t)j * nch + 1] : 0.0; }
      else fbuf[j].re = fbuf[j].im = 0;
    }
    dsp::hilbert_block(*kern, fbuf.data());
    for (int f = 0; f < n; f++) {
      for (int c = 0; c < nch; c++) {
        double x = IN[(size_t)(f + D) * nch + c];
        double h = c == 0 ? fbuf[f + M - 1].re : fbuf[f + M - 1].im;
        ana::ChanStats& st = cs[c];
        if (x > st.pos) st.pos = x; else if (-x > st.neg) st.neg = -x;
        double a2 = x * x + h * h;
        if (a2 >= st.thr2 && a2 > 0) {
          if (a2 > st.max2) { st.max2 = a2; st.thr2 = a2 * THR2; }
          int b = (int)std::floor(std::atan2(h, x) * K); b = ((b % ana::NBINS) + ana::NBINS) % ana::NBINS;
          double a = std::sqrt(a2);
          if (a > st.bins_max[b]) st.bins_max[b] = a;
          double a4 = a2 * a2;
          st.s8[b % ana::NC] += a4 * a4;
        }
      }
    }
  }
  delete src;
  const double len = t_end - t_start;
  std::string res;
  char line[256];
  snprintf(line, sizeof(line), "nch=%d sr=%.0f length=%.6f ap=%d,%d,%.3f,%.4f ", nch, sr, len, ap ? ap_params.ap_type : 0, ap_params.ap_stages, ap_params.ap_freq, ap_params.ap_q); res += line;
  std::vector<double> cmax[2], c8[2];
  double peak_before = 0;
  for (int c = 0; c < nch; c++) {
    ana::cost_curves(cs[c], cmax[c], c8[c]);
    int t_rx = ana::pick_min(c8[c], 1e-6), t_pk = ana::pick_min(cmax[c], std::pow(10.0, 0.01 / 20) - 1);
    double a_rx = -90 + t_rx * ana::STEP, a_pk = -90 + t_pk * ana::STEP;
    double pos, neg; ana::peaks_after(cs[c], a_rx, &pos, &neg);
    double pb = std::max(cs[c].pos, cs[c].neg); peak_before = std::max(peak_before, pb);
    snprintf(line, sizeof(line), "ch%d_rx=%.4f ch%d_peak=%.4f ch%d_before=%.6f ch%d_pos_before=%.6f ch%d_neg_before=%.6f ch%d_after_rx=%.6f ch%d_pos_after=%.6f ch%d_neg_after=%.6f ch%d_minpeak=%.6f ",
             c, a_rx, c, a_pk, c, pb, c, cs[c].pos, c, cs[c].neg, c, cmax[c][t_rx], c, pos, c, neg, c, cmax[c][t_pk]);
    res += line;
  }
  // linked
  {
    std::vector<double> cl(ana::NC), l8(ana::NC);
    for (int t = 0; t < ana::NC; t++) {
      cl[t] = nch > 1 ? std::max(cmax[0][t], cmax[1][t]) : cmax[0][t];
      l8[t] = nch > 1 ? c8[0][t] + c8[1][t] : c8[0][t];
    }
    int t_rx = ana::pick_min(l8, 1e-6), t_pk = ana::pick_min(cl, std::pow(10.0, 0.01 / 20) - 1);
    snprintf(line, sizeof(line), "linked_rx=%.4f linked_peak=%.4f linked_after_rx=%.6f linked_minpeak=%.6f peak_before=%.6f peak_orig=%.6f ",
             -90 + t_rx * ana::STEP, -90 + t_pk * ana::STEP, cl[t_rx], cl[t_pk], peak_before, std::max(orig_peak[0], nch > 1 ? orig_peak[1] : 0.0));
    res += line;
  }
  // polar shapes (360 values per channel, max envelope per degree)
  for (int c = 0; c < nch; c++) {
    snprintf(line, sizeof(line), "shape%d=", c); res += line;
    int per = ana::NBINS / 360;
    for (int d = 0; d < 360; d++) {
      double m = 0; for (int j = 0; j < per; j++) m = std::max(m, cs[c].bins_max[d * per + j]);
      snprintf(line, sizeof(line), "%.4g%s", m, d == 359 ? " " : ","); res += line;
    }
  }
  SetExtState("phaserot", "analysis", res.c_str(), false);
  return true;
}

// ============================================================================ ReaScript API
static bool valid_take(MediaItem_Take* take)
{
  return take && ValidatePtr2(nullptr, take, "MediaItem_Take*");
}

static Params make_params(double angle_l, double angle_r, int adaptive, int smooth, int bypass, int link, int ap_type, int ap_stages, double ap_freq, double ap_q)
{
  Params p; p.angle_l = angle_l; p.angle_r = angle_r; p.adaptive = adaptive; p.smooth = smooth; p.bypass = bypass; p.link = link;
  p.ap_type = ap_type; p.ap_stages = ap_stages; p.ap_freq = ap_freq; p.ap_q = ap_q;
  p.clamp();
  return p;
}
static bool API_PhaseRot_SetTake(MediaItem_Take* take, double angle_l, double angle_r, int adaptive, int smooth, int bypass, int link, int ap_type, int ap_stages, double ap_freq, double ap_q)
{
  if (!valid_take(take) || TakeIsMIDI(take)) return false;
  Params p = make_params(angle_l, angle_r, adaptive, smooth, bypass, link, ap_type, ap_stages, ap_freq, ap_q);
  take_set_ext(take, &p);
  bool changed = sync_take(take);
  MediaItem* item = GetMediaItemTake_Item(take);
  if (item) UpdateItemInProject(item);
  if (changed) refresh_peak_display();
  return true;
}
static bool API_PhaseRot_ClearTake(MediaItem_Take* take)
{
  if (!valid_take(take)) return false;
  take_set_ext(take, nullptr);
  bool changed = sync_take(take);
  MediaItem* item = GetMediaItemTake_Item(take);
  if (item) UpdateItemInProject(item);
  if (changed) refresh_peak_display();
  return true;
}
static bool API_PhaseRot_GetTake(MediaItem_Take* take, double* angle_lOut, double* angle_rOut, int* adaptiveOut, int* smoothOut, int* bypassOut, int* linkOut,
                                 int* ap_typeOut, int* ap_stagesOut, double* ap_freqOut, double* ap_qOut)
{
  if (!valid_take(take)) return false;
  Params p;
  if (!take_ext(take, &p)) return false;
  if (angle_lOut) *angle_lOut = p.angle_l;
  if (angle_rOut) *angle_rOut = p.angle_r;
  if (adaptiveOut) *adaptiveOut = p.adaptive;
  if (smoothOut) *smoothOut = p.smooth;
  if (bypassOut) *bypassOut = p.bypass;
  if (linkOut) *linkOut = p.link;
  if (ap_typeOut) *ap_typeOut = p.ap_type;
  if (ap_stagesOut) *ap_stagesOut = p.ap_stages;
  if (ap_freqOut) *ap_freqOut = p.ap_freq;
  if (ap_qOut) *ap_qOut = p.ap_q;
  return true;
}
static bool API_PhaseRot_AnalyzeEx(MediaItem_Take* take, int ap_type, int ap_stages, double ap_freq, double ap_q)
{
  if (!valid_take(take) || TakeIsMIDI(take)) return false;
  Params p = make_params(0, 0, 0, 0, 0, 1, ap_type, ap_stages, ap_freq, ap_q);
  return analyze_take(take, p);
}
static bool API_PhaseRot_Analyze(MediaItem_Take* take) { return API_PhaseRot_AnalyzeEx(take, 0, 4, 200, 0.35); }
// Preview: audition parameters on the take without touching P_EXT (project/undo) or the waveform.
static bool API_PhaseRot_SetPreview(MediaItem_Take* take, double angle_l, double angle_r, int adaptive, int smooth, int link, int ap_type, int ap_stages, double ap_freq, double ap_q)
{
  if (!valid_take(take) || TakeIsMIDI(take)) return false;
  Params p = make_params(angle_l, angle_r, adaptive, smooth, 0, link, ap_type, ap_stages, ap_freq, ap_q);
  PCM_source* src = (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr);
  if (PhaseRotSource::is_wrapper(src)) { ((PhaseRotSource*)src)->set_preview(&p); return true; }
  if (!src || src->GetNumChannels() <= 0 || src->GetSampleRate() < 1 || chain_has_wrapper(src)) return false;
  Params committed;
  if (!take_ext(take, &committed)) committed = Params();
  PhaseRotSource* w = new PhaseRotSource(src, Params());
  w->set_params(committed);
  w->set_preview(&p);
  GetSetMediaItemTakeInfo(take, "P_SOURCE", w);
  MediaItem* item = GetMediaItemTake_Item(take);
  if (item) UpdateItemInProject(item);
  return true;
}
static bool API_PhaseRot_ClearPreview(MediaItem_Take* take)
{
  if (!valid_take(take)) return false;
  PCM_source* src = (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr);
  if (!PhaseRotSource::is_wrapper(src)) return true;
  ((PhaseRotSource*)src)->set_preview(nullptr);
  bool changed = sync_take(take);
  MediaItem* item = GetMediaItemTake_Item(take);
  if (item) UpdateItemInProject(item);
  if (changed) refresh_peak_display();
  return true;
}
static void API_PhaseRot_ClearAllPreviews()
{
  for (int pi = 0;; pi++) {
    ReaProject* proj = EnumProjects(pi, nullptr, 0);
    if (!proj) break;
    for (int i = 0; i < CountMediaItems(proj); i++) {
      MediaItem* item = GetMediaItem(proj, i);
      for (int t = 0; t < CountTakes(item); t++) {
        MediaItem_Take* take = GetTake(item, t);
        PCM_source* src = take ? (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr) : nullptr;
        if (PhaseRotSource::is_wrapper(src)) ((PhaseRotSource*)src)->set_preview(nullptr);
      }
    }
  }
  scan_all_projects();
}
static void API_PhaseRot_Refresh() { scan_all_projects(); }
// debug: counters of the take's current wrapper -> ExtState phaserot/debug
static bool API_PhaseRot_GetDebug(MediaItem_Take* take)
{
  if (!valid_take(take)) return false;
  PCM_source* src = (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr);
  char b[256];
  if (PhaseRotSource::is_wrapper(src)) {
    PhaseRotSource* w = (PhaseRotSource*)src;
    snprintf(b, sizeof(b), "wrapper=%p peak_calls=%ld sample_calls=%ld age=%.2f", (void*)w, w->dbg_peaks.load(), w->dbg_samples.load(), time_precise() - w->dbg_created);
  } else {
    snprintf(b, sizeof(b), "plain=%p type=%s", (void*)src, src ? src->GetType() : "-");
  }
  SetExtState("phaserot", "debug", b, false);
  return true;
}
static void* VA_PhaseRot_GetDebug(void** a, int n) { return (void*)(INT_PTR)API_PhaseRot_GetDebug((MediaItem_Take*)a[0]); }
static const char* API_PhaseRot_GetVersion() { return PR_VERSION; }

// vararg wrappers (ReaScript)
static double dbl_arg(void** a, int n, int i, double def) { return (n > i && a[i]) ? *(double*)a[i] : def; }
static int int_arg(void** a, int n, int i, int def) { return n > i ? (int)(INT_PTR)a[i] : def; }
static void* VA_PhaseRot_SetTake(void** a, int n)
{
  return (void*)(INT_PTR)API_PhaseRot_SetTake((MediaItem_Take*)a[0], dbl_arg(a, n, 1, 0), dbl_arg(a, n, 2, 0),
                                              int_arg(a, n, 3, 0), int_arg(a, n, 4, 0), int_arg(a, n, 5, 0), int_arg(a, n, 6, 1),
                                              int_arg(a, n, 7, 0), int_arg(a, n, 8, 4), dbl_arg(a, n, 9, 200), dbl_arg(a, n, 10, 0.35));
}
static void* VA_PhaseRot_ClearTake(void** a, int n) { return (void*)(INT_PTR)API_PhaseRot_ClearTake((MediaItem_Take*)a[0]); }
static void* VA_PhaseRot_GetTake(void** a, int n)
{
  return (void*)(INT_PTR)API_PhaseRot_GetTake((MediaItem_Take*)a[0], (double*)a[1], (double*)a[2], (int*)a[3], (int*)a[4], (int*)a[5], n > 6 ? (int*)a[6] : nullptr,
                                              n > 7 ? (int*)a[7] : nullptr, n > 8 ? (int*)a[8] : nullptr, n > 9 ? (double*)a[9] : nullptr, n > 10 ? (double*)a[10] : nullptr);
}
static void* VA_PhaseRot_Analyze(void** a, int n) { return (void*)(INT_PTR)API_PhaseRot_Analyze((MediaItem_Take*)a[0]); }
static void* VA_PhaseRot_AnalyzeEx(void** a, int n)
{
  return (void*)(INT_PTR)API_PhaseRot_AnalyzeEx((MediaItem_Take*)a[0], int_arg(a, n, 1, 0), int_arg(a, n, 2, 4), dbl_arg(a, n, 3, 200), dbl_arg(a, n, 4, 0.35));
}
static void* VA_PhaseRot_SetPreview(void** a, int n)
{
  return (void*)(INT_PTR)API_PhaseRot_SetPreview((MediaItem_Take*)a[0], dbl_arg(a, n, 1, 0), dbl_arg(a, n, 2, 0), int_arg(a, n, 3, 0), int_arg(a, n, 4, 0), int_arg(a, n, 5, 1),
                                                 int_arg(a, n, 6, 0), int_arg(a, n, 7, 4), dbl_arg(a, n, 8, 200), dbl_arg(a, n, 9, 0.35));
}
static void* VA_PhaseRot_ClearPreview(void** a, int n) { return (void*)(INT_PTR)API_PhaseRot_ClearPreview((MediaItem_Take*)a[0]); }
static void* VA_PhaseRot_ClearAllPreviews(void** a, int n) { API_PhaseRot_ClearAllPreviews(); return nullptr; }
static void* VA_PhaseRot_Refresh(void** a, int n) { API_PhaseRot_Refresh(); return nullptr; }
static void* VA_PhaseRot_GetVersion(void** a, int n) { return (void*)API_PhaseRot_GetVersion(); }

struct ApiEntry { const char* name; void* func; void* vararg; const char* def; };
static ApiEntry g_api[] = {
  { "PhaseRot_SetTake", (void*)API_PhaseRot_SetTake, (void*)VA_PhaseRot_SetTake,
    "bool\0MediaItem_Take*,double,double,int,int,int,int,int,int,double,double\0take,angle_l,angle_r,adaptive,smooth,bypass,link,ap_type,ap_stages,ap_freq,ap_q\0"
    "Apply a phase rotation to the take non-destructively: the take's source is wrapped at runtime, the project file stays a plain project. angle_l/angle_r in degrees (same sign convention as iZotope RX); adaptive=1 follows the signal (smooth 0..2; link=1 tracks one angle for both channels, 0 per channel); bypass=1 keeps the settings but passes audio through. Optional allpass rotator (broadcast style, runs before the rotation): ap_type 0=off, 1=cascade of first-order allpass sections (Orban: 4 stages at 200 Hz), 2=cascade of second-order sections with ap_q; ap_stages 1..16, ap_freq in Hz. Undo-able when called inside Undo_BeginBlock/EndBlock." },
  { "PhaseRot_ClearTake", (void*)API_PhaseRot_ClearTake, (void*)VA_PhaseRot_ClearTake,
    "bool\0MediaItem_Take*\0take\0Remove the phase rotation from the take (restores the original source)." },
  { "PhaseRot_GetTake", (void*)API_PhaseRot_GetTake, (void*)VA_PhaseRot_GetTake,
    "bool\0MediaItem_Take*,double*,double*,int*,int*,int*,int*,int*,int*,double*,double*\0take,angle_lOut,angle_rOut,adaptiveOut,smoothOut,bypassOut,linkOut,ap_typeOut,ap_stagesOut,ap_freqOut,ap_qOut\0Get the phase rotation settings of the take. Returns false if the take has none." },
  { "PhaseRot_SetPreview", (void*)API_PhaseRot_SetPreview, (void*)VA_PhaseRot_SetPreview,
    "bool\0MediaItem_Take*,double,double,int,int,int,int,int,double,double\0take,angle_l,angle_r,adaptive,smooth,link,ap_type,ap_stages,ap_freq,ap_q\0"
    "Audition settings on the take: playback uses these parameters while the project, undo history and the waveform keep the applied settings (or the original if nothing is applied). Not saved; clear with PhaseRot_ClearPreview." },
  { "PhaseRot_ClearPreview", (void*)API_PhaseRot_ClearPreview, (void*)VA_PhaseRot_ClearPreview,
    "bool\0MediaItem_Take*\0take\0End a PhaseRot_SetPreview audition on the take." },
  { "PhaseRot_ClearAllPreviews", (void*)API_PhaseRot_ClearAllPreviews, (void*)VA_PhaseRot_ClearAllPreviews,
    "void\0\0\0End all PhaseRot_SetPreview auditions in all open projects." },
  { "PhaseRot_Analyze", (void*)API_PhaseRot_Analyze, (void*)VA_PhaseRot_Analyze,
    "bool\0MediaItem_Take*\0take\0Analyse the take's ORIGINAL audio (ignoring any phase rotation already applied). The result is stored in the ExtState section 'phaserot', key 'analysis' (read it with GetExtState) as key=value pairs: chN_rx (RX-compatible suggested angle, L8 criterion), chN_peak (minimum sample peak angle), linked_rx, linked_peak, chN_before / chN_after_rx / chN_minpeak (linear peak levels), chN_pos_before, chN_neg_before, chN_pos_after, chN_neg_after, shapeN (360 comma-separated envelope values by phase degree)." },
  { "PhaseRot_AnalyzeEx", (void*)API_PhaseRot_AnalyzeEx, (void*)VA_PhaseRot_AnalyzeEx,
    "bool\0MediaItem_Take*,int,int,double,double\0take,ap_type,ap_stages,ap_freq,ap_q\0Like PhaseRot_Analyze, but the audio is first passed through the given allpass rotator (see PhaseRot_SetTake), so the suggested angles are those to apply after it." },
  { "PhaseRot_GetDebug", (void*)API_PhaseRot_GetDebug, (void*)VA_PhaseRot_GetDebug,
    "bool\0MediaItem_Take*\0take\0Debug: writes counters of the take's source wrapper to ExtState phaserot/debug." },
  { "PhaseRot_Refresh", (void*)API_PhaseRot_Refresh, (void*)VA_PhaseRot_Refresh,
    "void\0\0\0Re-synchronise all takes with their P_EXT:phaserot data immediately (normally done automatically by a timer)." },
  { "PhaseRot_GetVersion", (void*)API_PhaseRot_GetVersion, (void*)VA_PhaseRot_GetVersion,
    "const char*\0\0\0Version of the reaper_phaserot extension." },
};

static void register_api(reaper_plugin_info_t* rec, bool reg)
{
  for (auto& e : g_api) {
    std::string n1 = std::string(reg ? "" : "-") + "API_" + e.name;
    std::string n2 = std::string(reg ? "" : "-") + "APIvararg_" + e.name;
    std::string n3 = std::string(reg ? "" : "-") + "APIdef_" + e.name;
    rec->Register(n1.c_str(), e.func);
    rec->Register(n2.c_str(), e.vararg);
    rec->Register(n3.c_str(), (void*)e.def);
  }
}

static reaper_plugin_info_t* g_rec = nullptr;

extern "C" {
REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec)
{
  if (!rec) {
    if (g_rec) {
      g_rec->Register("-timer", (void*)timer_func);
      if (EnumProjects && GetSetMediaItemTakeInfo) unwrap_everything();
      register_api(g_rec, false);
    }
    g_rec = nullptr;
    return 0;
  }
  if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
  if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;
  g_rec = rec;
  WDL_fft_init();
  register_api(rec, true);
  rec->Register("timer", (void*)timer_func);
  return 1;
}
}
