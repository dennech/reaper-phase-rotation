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
// ReaScript API: PhaseRot_SetTake, PhaseRot_ClearTake, PhaseRot_GetTake,
// PhaseRot_Analyze, PhaseRot_Refresh, PhaseRot_GetVersion.
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
#define REAPERAPI_WANT_SetExtState

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

#define PR_VERSION "1.0.0"
#define PR_EXT_KEY "P_EXT:phaserot"
#define PR_EXT_IDENTIFY 0x50524f54 /* 'PROT' */
#define PR_MAGIC 0x50686153     /* 'PhaS' */

static const double PI = 3.14159265358979323846;

// ============================================================================ DSP
namespace dsp {

static double bessel_i0(double x)
{
  double q = x * x * 0.25, s = 1, t = 1;
  for (int k = 1; k < 80; k++) { t *= q / ((double)k * k); s += t; }
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

} // namespace dsp

// ============================================================================ parameters
struct Params {
  double angle_l = 0, angle_r = 0;
  int adaptive = 0, smooth = 0, bypass = 0;
  bool operator==(const Params& o) const
  { return angle_l == o.angle_l && angle_r == o.angle_r && adaptive == o.adaptive && smooth == o.smooth && bypass == o.bypass; }
  bool operator!=(const Params& o) const { return !(*this == o); }
  std::string serialize() const
  {
    char b[128];
    snprintf(b, sizeof(b), "1 %.4f %.4f %d %d %d", angle_l, angle_r, adaptive, smooth, bypass);
    return b;
  }
  static bool parse(const char* s, Params* p)
  {
    if (!s || !*s) return false;
    int ver = 0, ad = 0, sm = 0, by = 0; double al = 0, ar = 0;
    if (sscanf(s, "%d %lf %lf %d %d %d", &ver, &al, &ar, &ad, &sm, &by) < 3 || ver != 1) return false;
    p->angle_l = al; p->angle_r = ar; p->adaptive = ad ? 1 : 0; p->smooth = std::min(2, std::max(0, sm)); p->bypass = by ? 1 : 0;
    return true;
  }
};

// ============================================================================ source wrapper
class PhaseRotSource;
static std::mutex g_registry_mutex;
static std::vector<PhaseRotSource*> g_registry;   // live wrappers (for safe identification)

class PhaseRotSource : public PCM_source
{
public:
  PhaseRotSource(PCM_source* child, const Params& p) : m_child(child), m_params(p)
  {
    std::lock_guard<std::mutex> lk(g_registry_mutex);
    g_registry.push_back(this);
  }
  ~PhaseRotSource() override
  {
    { std::lock_guard<std::mutex> lk(g_registry_mutex);
      g_registry.erase(std::remove(g_registry.begin(), g_registry.end(), this), g_registry.end()); }
    delete m_child;
  }
  static bool is_wrapper(PCM_source* s)
  {
    if (!s) return false;
    std::lock_guard<std::mutex> lk(g_registry_mutex);
    return std::find(g_registry.begin(), g_registry.end(), (PhaseRotSource*)s) != g_registry.end();
  }
  PCM_source* detach() { PCM_source* c = m_child; m_child = nullptr; return c; }
  PCM_source* child() const { return m_child; }
  const Params& params() const { return m_params; }
  void set_params(const Params& p)
  {
    std::lock_guard<std::mutex> lk(m_mutex);
    bool need_traj = p.adaptive && (!m_params.adaptive || p.smooth != m_params.smooth || !m_traj);
    m_params = p;
    m_peaks_valid = false;
    if (need_traj) m_traj = nullptr;
    if (p.adaptive && !m_traj) build_trajectory_locked();
  }

  // ---- PCM_source
  PCM_source* Duplicate() override
  {
    PCM_source* c = m_child ? m_child->Duplicate() : nullptr;
    if (!c) return nullptr;
    PhaseRotSource* d = new PhaseRotSource(c, m_params);
    std::lock_guard<std::mutex> lk(m_mutex);
    d->m_traj = m_traj;
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

  void GetSamples(PCM_source_transfer_t* block) override
  {
    if (!m_child) { block->samples_out = 0; return; }
    if (m_params.bypass || (!m_params.adaptive && m_params.angle_l == 0 && m_params.angle_r == 0)) {
      m_child->GetSamples(block);
      return;
    }
    render(block->time_s, block->samplerate, block->nch, block->length, block->samples, &block->samples_out);
    block->midi_events = nullptr;
  }

  void GetPeakInfo(PCM_source_peaktransfer_t* block) override
  {
    block->peaks_out = 0;
    block->extra_requested_data_out = 0;
    block->extra_requested_data_out2 = 0;
    if (!m_child) return;
    if (m_params.bypass || (!m_params.adaptive && m_params.angle_l == 0 && m_params.angle_r == 0)) {
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
      render(block->start_time, sr, nch, nfr, buf.data(), &got);
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

    ensure_peaks();
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
  void render(double time_s, double srate, int nch, int length, double* out, int* out_frames)
  {
    *out_frames = 0;
    if (length <= 0 || nch <= 0 || srate < 1) return;
    auto kern = dsp::kernel_for(srate);
    const int D = kern->D, M = kern->M, N = kern->N, hop = kern->hop;
    // input needed: [time_s - D/sr, time_s + (length + D)/sr)
    const int nin = length + (M - 1);
    std::vector<double> in((size_t)nin * nch, 0.0);
    double t_in = time_s - (double)D / srate;
    int nvalid_in = fetch_child(t_in, srate, nch, nin, in.data());
    if (nvalid_in <= 0 && time_s >= GetLength()) return;

    std::shared_ptr<dsp::Trajectory> traj;
    Params p;
    { std::lock_guard<std::mutex> lk(m_mutex); traj = m_traj; p = m_params; }
    const double a_l = p.angle_l * PI / 180, a_r = p.angle_r * PI / 180;
    const double cl = std::cos(a_l), sl = std::sin(a_l), cr = std::cos(a_r), sr_ = std::sin(a_r);

    std::vector<WDL_FFT_COMPLEX> fbuf(N);
    for (int c0 = 0; c0 < nch; c0 += 2) {
      const int c1 = (c0 + 1 < nch) ? c0 + 1 : -1;
      const bool rot_c0 = (c0 <= 1), rot_c1 = (c1 == 1);
      if (!rot_c0 && !rot_c1) {
        // channels beyond the first two pass through untouched
        for (int f = 0; f < length; f++) {
          out[(size_t)f * nch + c0] = in[(size_t)(f + D) * nch + c0];
          if (c1 >= 0) out[(size_t)f * nch + c1] = in[(size_t)(f + D) * nch + c1];
        }
        continue;
      }
      for (int start = 0; start < length; start += hop) {
        // block input frames [start, start + N) of 'in' (zero beyond nin)
        for (int j = 0; j < N; j++) {
          int f = start + j;
          if (f < nin) { fbuf[j].re = in[(size_t)f * nch + c0]; fbuf[j].im = c1 >= 0 ? in[(size_t)f * nch + c1] : 0.0; }
          else { fbuf[j].re = 0; fbuf[j].im = 0; }
        }
        dsp::hilbert_block(*kern, fbuf.data());
        int nout = std::min(hop, length - start);
        for (int i = 0; i < nout; i++) {
          int f = start + i;                 // output frame
          int j = i + (M - 1);               // FFT index with valid linear convolution
          double xl = in[(size_t)(f + D) * nch + c0], hl = fbuf[j].re;
          double xr = c1 >= 0 ? in[(size_t)(f + D) * nch + c1] : 0.0, hr = fbuf[j].im;
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

  // reads nframes from the child starting at t (may be negative: zero padded). returns frames valid (relative to start).
  int fetch_child(double t, double srate, int nch, int nframes, double* dst)
  {
    int skip = 0;
    if (t < 0) {
      skip = (int)std::ceil(-t * srate);
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
    m_child->GetSamples(&tr);
    int got = tr.samples_out;
    if (got < tr.length) memset(dst + (size_t)(skip + std::max(0, got)) * nch, 0, sizeof(double) * (size_t)(tr.length - std::max(0, got)) * nch);
    return skip + std::max(0, got);
  }

  void invalidate() { std::lock_guard<std::mutex> lk(m_mutex); m_peaks_valid = false; }

  void ensure_peaks()
  {
    {
      std::lock_guard<std::mutex> lk(m_mutex);
      if (m_peaks_valid) return;
    }
    std::lock_guard<std::mutex> lk2(m_build_mutex);
    { std::lock_guard<std::mutex> lk(m_mutex); if (m_peaks_valid) return; }
    const double sr = GetSampleRate();
    const int nch = std::max(1, GetNumChannels());
    const double len = GetLength();
    const long long nframes = (long long)std::ceil(len * sr);
    const int nbins = (int)((nframes + PEAK_BIN - 1) / PEAK_BIN);
    std::vector<float> pmax((size_t)nbins * nch, 0.0f), pmin((size_t)nbins * nch, 0.0f);
    auto kern = dsp::kernel_for(sr);
    const int chunk = kern->hop * 2;
    std::vector<double> buf((size_t)chunk * nch);
    for (long long start = 0; start < nframes; start += chunk) {
      int n = (int)std::min<long long>(chunk, nframes - start);
      int got = 0;
      render((double)start / sr, sr, nch, n, buf.data(), &got);
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
  void build_trajectory_locked()
  {
    const double sr = GetSampleRate();
    const int nch = std::max(1, std::min(2, GetNumChannels()));
    const double len = GetLength();
    if (sr < 1 || len <= 0) return;
    auto kern = dsp::kernel_for(sr);
    const int SUB = sr > 50000 ? 4096 : 2048;
    const long long nframes = (long long)std::ceil(len * sr);
    const int nsub = (int)((nframes + SUB - 1) / SUB);
    const int NB = 90;
    auto traj = std::make_shared<dsp::Trajectory>();
    traj->sub_sec = SUB / sr;
    traj->est_l.assign(nsub, 0.0f); traj->est_r.assign(nsub, 0.0f);
    std::vector<double> in, fb;
    const int chunk = kern->hop;
    const int N = kern->N, M = kern->M, D = kern->D;
    std::vector<WDL_FFT_COMPLEX> fbuf(N);
    std::vector<double> x((size_t)chunk * 2), h((size_t)chunk * 2);
    double runpk2[2] = {0, 0}; double prev[2] = {0, 0};
    std::vector<double> bins(NB), binsR(NB);
    int sub_index = 0; int sub_fill = 0;
    double mx2[2] = {0, 0};
    // we process chunk by chunk; sub-blocks are aligned to the chunk grid (chunk is a multiple of SUB)
    for (long long start = 0; start < nframes; start += chunk) {
      int n = (int)std::min<long long>(chunk, nframes - start);
      // analytic signal for this chunk
      const int nin = n + (M - 1);
      in.assign((size_t)nin * nch, 0.0);
      fetch_child((double)start / sr - (double)D / sr, sr, nch, nin, in.data());
      for (int j = 0; j < N; j++) {
        if (j < nin) { fbuf[j].re = in[(size_t)j * nch]; fbuf[j].im = nch > 1 ? in[(size_t)j * nch + 1] : 0.0; }
        else fbuf[j].re = fbuf[j].im = 0;
      }
      dsp::hilbert_block(*kern, fbuf.data());
      for (int f = 0; f < n; f++) {
        x[(size_t)f * 2] = in[(size_t)(f + D) * nch]; h[(size_t)f * 2] = fbuf[f + M - 1].re;
        x[(size_t)f * 2 + 1] = nch > 1 ? in[(size_t)(f + D) * nch + 1] : 0.0; h[(size_t)f * 2 + 1] = fbuf[f + M - 1].im;
      }
      // sub-blocks inside this chunk
      for (int s0 = 0; s0 < n; s0 += SUB) {
        int s1 = std::min(n, s0 + SUB);
        double m2[2] = {0, 0};
        for (int f = s0; f < s1; f++) for (int c = 0; c < nch; c++) {
          double a2 = x[(size_t)f * 2 + c] * x[(size_t)f * 2 + c] + h[(size_t)f * 2 + c] * h[(size_t)f * 2 + c];
          if (a2 > m2[c]) m2[c] = a2;
        }
        bool hold[2];
        for (int c = 0; c < 2; c++) { runpk2[c] = std::max(m2[c], runpk2[c] * 0.97); hold[c] = m2[c] < 1e-6 || m2[c] < runpk2[c] * 0.01; }
        if (nch == 1) { hold[1] = hold[0]; }
        // linked: one estimate from both channels (as the script does with Link on)
        bool linked = true;
        if (linked) { bool hh = hold[0] && (nch == 1 || hold[1]); hold[0] = hold[1] = hh; }
        double est[2];
        if (hold[0]) {
          est[0] = prev[0] - 180.0 * std::floor((prev[0] + 90.0) / 180.0);
          est[1] = prev[1] - 180.0 * std::floor((prev[1] + 90.0) / 180.0);
        } else {
          std::fill(bins.begin(), bins.end(), 0.0);
          for (int c = 0; c < nch; c++) {
            double thr2 = m2[c] * 0.25;
            for (int f = s0; f < s1; f++) {
              double xv = x[(size_t)f * 2 + c], hv = h[(size_t)f * 2 + c], a2 = xv * xv + hv * hv;
              if (a2 < thr2 || a2 <= 0) continue;
              double ph = std::atan2(hv, xv); if (ph < 0) ph += PI;
              int b = (int)(ph * NB / PI); if (b >= NB) b = NB - 1;
              double a = std::sqrt(a2); if (a > bins[b]) bins[b] = a;
            }
          }
          // search 0..179 deg: cost(t) = max_b bins[b] * |cos(phi_b - t)|
          double cost[180]; double best = -1; int bestt = 0;
          for (int t = 0; t < 180; t++) {
            double cst = 0;
            for (int b = 0; b < NB; b++) if (bins[b] > 0) {
              double v = bins[b] * std::fabs(std::cos((2 * b + 1 - t) * PI / 180));
              if (v > cst) cst = v;
            }
            cost[t] = cst;
            if (best < 0 || cst < best) { best = cst; bestt = t; }
          }
          double bestd = 1e30; int chosen = bestt;
          for (int t = 0; t < 180; t++) if (cost[t] <= best * 1.002) {
            double d = std::fabs(t - prev[0]); d = std::fabs(d - 180.0 * std::floor(d / 180.0 + 0.5));
            if (d < bestd) { bestd = d; chosen = t; }
          }
          double rep = chosen + 180.0 * std::floor((prev[0] - chosen) / 180.0 + 0.5);
          est[0] = est[1] = rep;
        }
        prev[0] = est[0]; prev[1] = est[1];
        if (sub_index < nsub) { traj->est_l[sub_index] = (float)est[0]; traj->est_r[sub_index] = (float)est[1]; }
        sub_index++;
        (void)sub_fill; (void)mx2; (void)binsR;
      }
    }
    // optional median smoothing
    if (m_params.smooth > 0) {
      int w = m_params.smooth == 1 ? 1 : 2;
      for (auto* e : { &traj->est_l, &traj->est_r }) {
        std::vector<float> src = *e;
        for (int i = 0; i < (int)src.size(); i++) {
          std::vector<float> win;
          for (int j = std::max(0, i - w); j <= std::min((int)src.size() - 1, i + w); j++) win.push_back(src[j]);
          std::sort(win.begin(), win.end());
          (*e)[i] = win[win.size() / 2];
        }
      }
    }
    m_traj = traj;
  }

  PCM_source* m_child;
  Params m_params;
  std::mutex m_mutex, m_build_mutex;
  std::shared_ptr<dsp::Trajectory> m_traj;
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
      PhaseRotSource* w = new PhaseRotSource(src, Params());
      w->set_params(p);
      GetSetMediaItemTakeInfo(take, "P_SOURCE", w);
      return true;
    }
    PhaseRotSource* w = (PhaseRotSource*)src;
    if (w->params() != p) { w->set_params(p); return true; }
    return false;
  }
  if (wrapped) {
    PhaseRotSource* w = (PhaseRotSource*)src;
    PCM_source* child = w->detach();
    GetSetMediaItemTakeInfo(take, "P_SOURCE", child);
    delete w;
    return true;
  }
  return false;
}

static void scan_all_projects()
{
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
      if (changed) UpdateItemInProject(item);
    }
  }
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

// Analyse the ORIGINAL audio of the take (child if wrapped). Result text goes to ExtState phaserot/analysis.
static bool analyze_take(MediaItem_Take* take)
{
  SetExtState("phaserot", "analysis", "", false);
  PCM_source* src = (PCM_source*)GetSetMediaItemTakeInfo(take, "P_SOURCE", nullptr);
  if (!src) return false;
  if (PhaseRotSource::is_wrapper(src)) src = ((PhaseRotSource*)src)->child();
  if (!src || src->GetNumChannels() <= 0 || src->GetSampleRate() < 1) return false;
  const double sr = src->GetSampleRate();
  const int nch = std::min(2, src->GetNumChannels());
  const double len = src->GetLength();
  const long long nframes = (long long)std::ceil(len * sr);
  auto kern = dsp::kernel_for(sr);
  const int N = kern->N, M = kern->M, D = kern->D, hop = kern->hop;
  std::vector<WDL_FFT_COMPLEX> fbuf(N);
  std::vector<double> in;
  ana::ChanStats cs[2];
  for (int c = 0; c < 2; c++) { cs[c].bins_max.assign(ana::NBINS, 0.0); cs[c].s8.assign(ana::NC, 0.0); }
  const double K = ana::NBINS / (2 * PI), THR2 = 0.01;
  for (long long start = 0; start < nframes; start += hop) {
    int n = (int)std::min<long long>(hop, nframes - start);
    int nin = n + (M - 1);
    in.assign((size_t)nin * nch, 0.0);
    // read child with zero padding before 0
    double t = (double)start / sr - (double)D / sr;
    int skip = 0;
    if (t < 0) { skip = (int)std::ceil(-t * sr); t += (double)skip / sr; }
    if (skip < nin) {
      PCM_source_transfer_t tr; memset(&tr, 0, sizeof(tr));
      tr.time_s = t; tr.samplerate = sr; tr.nch = nch; tr.length = nin - skip; tr.samples = in.data() + (size_t)skip * nch;
      src->GetSamples(&tr);
      if (tr.samples_out < tr.length && tr.samples_out >= 0) memset(in.data() + (size_t)(skip + tr.samples_out) * nch, 0, sizeof(double) * (size_t)(tr.length - tr.samples_out) * nch);
    }
    for (int j = 0; j < N; j++) {
      if (j < nin) { fbuf[j].re = in[(size_t)j * nch]; fbuf[j].im = nch > 1 ? in[(size_t)j * nch + 1] : 0.0; }
      else fbuf[j].re = fbuf[j].im = 0;
    }
    dsp::hilbert_block(*kern, fbuf.data());
    for (int f = 0; f < n; f++) {
      for (int c = 0; c < nch; c++) {
        double x = in[(size_t)(f + D) * nch + c];
        double h = c == 0 ? fbuf[f + M - 1].re : fbuf[f + M - 1].im;
        ana::ChanStats& s = cs[c];
        if (x > s.pos) s.pos = x; else if (-x > s.neg) s.neg = -x;
        double a2 = x * x + h * h;
        if (a2 >= s.thr2 && a2 > 0) {
          if (a2 > s.max2) { s.max2 = a2; s.thr2 = a2 * THR2; }
          int b = (int)std::floor(std::atan2(h, x) * K); b = ((b % ana::NBINS) + ana::NBINS) % ana::NBINS;
          double a = std::sqrt(a2);
          if (a > s.bins_max[b]) s.bins_max[b] = a;
          double a4 = a2 * a2;
          s.s8[b % ana::NC] += a4 * a4;
        }
      }
    }
  }
  std::string res;
  char line[256];
  snprintf(line, sizeof(line), "nch=%d sr=%.0f length=%.6f ", nch, sr, len); res += line;
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
    snprintf(line, sizeof(line), "linked_rx=%.4f linked_peak=%.4f linked_after_rx=%.6f linked_minpeak=%.6f peak_before=%.6f ",
             -90 + t_rx * ana::STEP, -90 + t_pk * ana::STEP, cl[t_rx], cl[t_pk], peak_before);
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

static bool API_PhaseRot_SetTake(MediaItem_Take* take, double angle_l, double angle_r, int adaptive, int smooth, int bypass)
{
  if (!valid_take(take) || TakeIsMIDI(take)) return false;
  Params p; p.angle_l = angle_l; p.angle_r = angle_r; p.adaptive = adaptive ? 1 : 0; p.smooth = std::min(2, std::max(0, smooth)); p.bypass = bypass ? 1 : 0;
  take_set_ext(take, &p);
  sync_take(take);
  MediaItem* item = GetMediaItemTake_Item(take);
  if (item) UpdateItemInProject(item);
  return true;
}
static bool API_PhaseRot_ClearTake(MediaItem_Take* take)
{
  if (!valid_take(take)) return false;
  take_set_ext(take, nullptr);
  sync_take(take);
  MediaItem* item = GetMediaItemTake_Item(take);
  if (item) UpdateItemInProject(item);
  return true;
}
static bool API_PhaseRot_GetTake(MediaItem_Take* take, double* angle_lOut, double* angle_rOut, int* adaptiveOut, int* smoothOut, int* bypassOut)
{
  if (!valid_take(take)) return false;
  Params p;
  if (!take_ext(take, &p)) return false;
  if (angle_lOut) *angle_lOut = p.angle_l;
  if (angle_rOut) *angle_rOut = p.angle_r;
  if (adaptiveOut) *adaptiveOut = p.adaptive;
  if (smoothOut) *smoothOut = p.smooth;
  if (bypassOut) *bypassOut = p.bypass;
  return true;
}
static bool API_PhaseRot_Analyze(MediaItem_Take* take)
{
  if (!valid_take(take) || TakeIsMIDI(take)) return false;
  return analyze_take(take);
}
static void API_PhaseRot_Refresh() { scan_all_projects(); }
static const char* API_PhaseRot_GetVersion() { return PR_VERSION; }

// vararg wrappers (ReaScript)
static void* VA_PhaseRot_SetTake(void** a, int n)
{
  return (void*)(INT_PTR)API_PhaseRot_SetTake((MediaItem_Take*)a[0], a[1] ? *(double*)a[1] : 0.0, a[2] ? *(double*)a[2] : 0.0,
                                              (int)(INT_PTR)a[3], (int)(INT_PTR)a[4], (int)(INT_PTR)a[5]);
}
static void* VA_PhaseRot_ClearTake(void** a, int n) { return (void*)(INT_PTR)API_PhaseRot_ClearTake((MediaItem_Take*)a[0]); }
static void* VA_PhaseRot_GetTake(void** a, int n)
{
  return (void*)(INT_PTR)API_PhaseRot_GetTake((MediaItem_Take*)a[0], (double*)a[1], (double*)a[2], (int*)a[3], (int*)a[4], (int*)a[5]);
}
static void* VA_PhaseRot_Analyze(void** a, int n) { return (void*)(INT_PTR)API_PhaseRot_Analyze((MediaItem_Take*)a[0]); }
static void* VA_PhaseRot_Refresh(void** a, int n) { API_PhaseRot_Refresh(); return nullptr; }
static void* VA_PhaseRot_GetVersion(void** a, int n) { return (void*)API_PhaseRot_GetVersion(); }

struct ApiEntry { const char* name; void* func; void* vararg; const char* def; };
static ApiEntry g_api[] = {
  { "PhaseRot_SetTake", (void*)API_PhaseRot_SetTake, (void*)VA_PhaseRot_SetTake,
    "bool\0MediaItem_Take*,double,double,int,int,int\0take,angle_l,angle_r,adaptive,smooth,bypass\0"
    "Apply a broadband phase rotation (degrees, same sign convention as iZotope RX) to the take non-destructively: the take's source is wrapped at runtime, the project file stays a plain project. adaptive=1 follows the signal (smooth 0..2), bypass=1 keeps the settings but passes audio through. Undo-able when called inside Undo_BeginBlock/EndBlock." },
  { "PhaseRot_ClearTake", (void*)API_PhaseRot_ClearTake, (void*)VA_PhaseRot_ClearTake,
    "bool\0MediaItem_Take*\0take\0Remove the phase rotation from the take (restores the original source)." },
  { "PhaseRot_GetTake", (void*)API_PhaseRot_GetTake, (void*)VA_PhaseRot_GetTake,
    "bool\0MediaItem_Take*,double*,double*,int*,int*,int*\0take,angle_lOut,angle_rOut,adaptiveOut,smoothOut,bypassOut\0Get the phase rotation settings of the take. Returns false if the take has none." },
  { "PhaseRot_Analyze", (void*)API_PhaseRot_Analyze, (void*)VA_PhaseRot_Analyze,
    "bool\0MediaItem_Take*\0take\0Analyse the take's ORIGINAL audio (ignoring any phase rotation already applied). The result is stored in the ExtState section 'phaserot', key 'analysis' (read it with GetExtState) as key=value pairs: chN_rx (RX-compatible suggested angle, L8 criterion), chN_peak (minimum sample peak angle), linked_rx, linked_peak, chN_before / chN_after_rx / chN_minpeak (linear peak levels), chN_pos_before, chN_neg_before, chN_pos_after, chN_neg_after, shapeN (360 comma-separated envelope values by phase degree)." },
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
    if (g_rec) { register_api(g_rec, false); g_rec->Register("-timer", (void*)timer_func); }
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
