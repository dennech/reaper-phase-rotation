-- @noindex
-- phase_rotation_core.lua
-- Analysis + FX management for "Phase Rotation (RX-style)" (REAPER).
-- No UI here. Used by "Phase Rotation (RX-style).lua" and by tests.
--
-- Everything numeric here must stay in sync with phase_rotation.jsfx:
--   * FIR Hilbert transformer: Kaiser (beta 8), M = 8193 taps (sr <= 50 kHz) / 16385 taps
--   * rotation: y = cos(t) * x + sin(t) * H{x}   (same sign convention as iZotope RX)
--   * Suggest: "rx" criterion = minimise sum |y|^8 (reproduces RX 10's Suggest values),
--              "peak" criterion = minimise the exact sample peak
-- Author: dennech (built together with Claude). License: MIT.

local r = reaper
local core = {}

core.VERSION = "1.1.2"
core.SECTION = "dennech_PhaseRotation"           -- ExtState section
core.JSFX_FILE = "phase_rotation.jsfx"
core.FX_DESC = "Phase Rotation (RX-style, Hilbert)"
core.PARAM = { ANGLE_L = 0, ANGLE_R = 1, LINK = 2, ADAPTIVE = 3, ADAPT_SMOOTH = 4, CUR_L = 5, CUR_R = 6 }

core.BETA = 8               -- Kaiser beta
core.THR_REL = 0.1          -- samples with envelope < 0.1 * max are ignored (negligible for both criteria)
core.TIE_DB = 0.01          -- peak criterion: prefer the smallest rotation within this of the best peak
core.LP_ORDER = 8           -- rx criterion: minimise sum |y|^8
core.NBINS = 2880           -- phase histogram resolution: 0.125 degrees over [0, 360)
core.STEP_DEG = 0.125       -- candidate angle step
core.NCAND = 1440           -- candidates over [-90, 90); also the folded (180 degree) histogram size

local SEP = package.config:sub(1, 1)
local floor, sqrt, atan, abs, cos, sin, max, min, log = math.floor, math.sqrt, math.atan, math.abs, math.cos, math.sin, math.max, math.min, math.log
local PI = math.pi

-- ------------------------------------------------------------------ utilities

local function file_exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(p, s)
  local f = io.open(p, "wb")
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

function core.module_dir()
  local src = debug.getinfo(1, "S").source
  return src:match("^@(.*)[/\\]") or "."
end

function core.db(v)
  if v <= 1e-12 then return -240 end
  return 20 * log(v, 10)
end

function core.fmt_db(v)
  local d = core.db(v)
  if d <= -200 then return "-inf" end
  return string.format("%.1f", d)
end

-- ------------------------------------------------------------ JSFX location

local function scan_dir(base, rel, depth, want)
  if depth > 5 then return nil end
  local path = rel == "" and base or (base .. SEP .. rel:gsub("/", SEP))
  local i = 0
  while true do
    local f = r.EnumerateFiles(path, i)
    if not f then break end
    if f == want then return rel == "" and f or (rel .. "/" .. f) end
    i = i + 1
  end
  i = 0
  while true do
    local d = r.EnumerateSubdirectories(path, i)
    if not d then break end
    local found = scan_dir(base, rel == "" and d or (rel .. "/" .. d), depth + 1, want)
    if found then return found end
    i = i + 1
  end
  return nil
end

-- Returns the JSFX path relative to <resource>/Effects (forward slashes), or nil, err.
-- Search order: cached path -> known install locations -> recursive scan of Effects
-- -> copy the file that ships next to this module into Effects/Phase Rotation/.
function core.locate_jsfx()
  local res = r.GetResourcePath()
  local effects = res .. SEP .. "Effects"
  local function full(rel) return effects .. SEP .. rel:gsub("/", SEP) end

  local shipped = core.module_dir() .. SEP .. core.JSFX_FILE
  local managed_rel = "Phase Rotation/" .. core.JSFX_FILE

  -- keep the managed copy in sync with the file that ships next to the script
  if file_exists(shipped) and file_exists(full(managed_rel)) then
    local a, b = read_file(shipped), read_file(full(managed_rel))
    if a and b and a ~= b then write_file(full(managed_rel), a) end
  end

  local cached = r.GetExtState(core.SECTION, "jsfx_relpath")
  if cached ~= "" and file_exists(full(cached)) then return cached end

  local cands = {
    "REAPER Phase Rotation/Items/" .. core.JSFX_FILE,    -- ReaPack layout
    managed_rel,                                          -- manual install (copied by us)
  }
  for _, rel in ipairs(cands) do
    if file_exists(full(rel)) then
      r.SetExtState(core.SECTION, "jsfx_relpath", rel, true)
      return rel
    end
  end

  local found = scan_dir(effects, "", 0, core.JSFX_FILE)
  if found then
    r.SetExtState(core.SECTION, "jsfx_relpath", found, true)
    return found
  end

  if file_exists(shipped) then
    r.RecursiveCreateDirectory(effects .. SEP .. "Phase Rotation", 0)
    local s = read_file(shipped)
    if s and write_file(full(managed_rel), s) then
      r.SetExtState(core.SECTION, "jsfx_relpath", managed_rel, true)
      return managed_rel
    end
  end
  return nil, core.JSFX_FILE .. " was not found in " .. effects ..
    " and could not be installed from " .. shipped
end

-- ------------------------------------------------------------- FX management

function core.find_fx(take)
  for i = 0, r.TakeFX_GetCount(take) - 1 do
    local _, name = r.TakeFX_GetFXName(take, i, "")
    if name:find(core.FX_DESC, 1, true) then return i end
  end
  return -1
end

function core.ensure_fx(take)
  local i = core.find_fx(take)
  if i >= 0 then return i end
  local rel, err = core.locate_jsfx()
  if not rel then return -1, err end
  i = r.TakeFX_AddByName(take, "JS:" .. rel, 1)
  if i < 0 then i = r.TakeFX_AddByName(take, rel, 1) end
  if i < 0 then
    r.DeleteExtState(core.SECTION, "jsfx_relpath", true)
    return -1, "REAPER could not load JS:" .. rel .. " (try restarting REAPER)"
  end
  return i
end

function core.remove_fx(take)
  local i = core.find_fx(take)
  if i >= 0 then r.TakeFX_Delete(take, i) return true end
  return false
end

function core.get_state(take, fx)
  local P = core.PARAM
  local function g(p) local v = r.TakeFX_GetParam(take, fx, p) return v end
  return {
    angle_l = g(P.ANGLE_L), angle_r = g(P.ANGLE_R),
    link = g(P.LINK) >= 0.5, adaptive = g(P.ADAPTIVE) >= 0.5,
    smooth = floor(g(P.ADAPT_SMOOTH) + 0.5), cur_l = g(P.CUR_L), cur_r = g(P.CUR_R),
    enabled = r.TakeFX_GetEnabled(take, fx), mode = "fx",
  }
end

-- st fields are optional: angle_l, angle_r, link, adaptive, smooth, enabled
function core.set_state(take, fx, st)
  local P = core.PARAM
  if st.link ~= nil then r.TakeFX_SetParam(take, fx, P.LINK, st.link and 1 or 0) end
  if st.adaptive ~= nil then r.TakeFX_SetParam(take, fx, P.ADAPTIVE, st.adaptive and 1 or 0) end
  if st.smooth then r.TakeFX_SetParam(take, fx, P.ADAPT_SMOOTH, st.smooth) end
  if st.angle_l then r.TakeFX_SetParam(take, fx, P.ANGLE_L, st.angle_l) end
  if st.angle_r then r.TakeFX_SetParam(take, fx, P.ANGLE_R, st.angle_r) end
  if st.enabled ~= nil then r.TakeFX_SetEnabled(take, fx, st.enabled) end
end

-- ------------------------------------------------------------- item helpers

function core.effective_channels(take)
  local src = r.GetMediaItemTake_Source(take)
  local nch = r.GetMediaSourceNumChannels(src)
  local mode = r.GetMediaItemTakeInfo_Value(take, "I_CHANMODE")
  if mode >= 2 and mode < 64 then return 1, nch end
  return min(nch, 2), nch
end

function core.take_info(take)
  local src = r.GetMediaItemTake_Source(take)
  local item = r.GetMediaItemTake_Item(take)
  local _, name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  local nch, src_nch = core.effective_channels(take)
  return {
    name = name, nch = nch, src_nch = src_nch,
    sr = r.GetMediaSourceSampleRate(src),
    length = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
    position = r.GetMediaItemInfo_Value(item, "D_POSITION"),
  }
end

-- --------------------------------------------------------------- DSP: FIR

function core.fir_length(sr)
  return sr > 50000 and 16385 or 8193
end

local function bessel_i0(x)
  local q, s, t = x * x * 0.25, 1, 1
  for k = 1, 80 do t = t * q / (k * k); s = s + t end
  return s
end

local spec_cache = {}

-- FFT (normal order, complex, size N) of the FIR Hilbert transformer, pre-scaled by 1/N.
function core.fir_spectrum(N, M)
  local key = N .. ":" .. M
  if spec_cache[key] then return spec_cache[key] end
  local D = (M - 1) // 2
  local buf = r.new_array(2 * N)
  buf.clear()
  local i0b = bessel_i0(core.BETA)
  local t = {}
  for k = -D, D do
    if k % 2 ~= 0 then
      local w = bessel_i0(core.BETA * sqrt(max(0, 1 - (k / D) ^ 2))) / i0b
      t[2 * (k + D) + 1] = 2 / (PI * k) * w / N
    end
  end
  for idx, v in pairs(t) do buf[idx] = v end
  buf.fft(N, true)
  spec_cache[key] = buf
  return buf
end

-- --------------------------------------------------------------- analysis

local abscos_tab, cos8_tab
local function cos_tables()
  if abscos_tab then return abscos_tab, cos8_tab end
  -- |cos((i + 0.5) * STEP)| and its 8th power for i in 0 .. NCAND-1 (period 180 deg = NCAND steps)
  abscos_tab, cos8_tab = {}, {}
  local step = core.STEP_DEG * PI / 180
  for i = 0, core.NCAND - 1 do
    local c = abs(cos((i + 0.5) * step))
    abscos_tab[i] = c
    cos8_tab[i] = c ^ core.LP_ORDER
  end
  return abscos_tab, cos8_tab
end

-- With y = cos(t) x + sin(t) H{x} = A cos(phi - t): the rotated value of a sample with
-- envelope A and phase phi.  phi_b = (b + 0.5) * 360 / NBINS, theta_t = -90 + t * STEP.
-- Both |cos| tables have period 180 deg = NCAND entries, so the index is (b - t + 720) mod NCAND.

-- Peak criterion: cost[t] = max_b bins[b] * |cos(phi_b - theta_t)|   (bins: 1-based, NBINS entries)
function core.cost_curve(bins)
  local NB, NC = core.NBINS, core.NCAND
  local C = cos_tables()
  local list = {}
  for b = 0, NB - 1 do
    local a = bins[b + 1]
    if a > 0 then list[#list + 1] = { a, b } end
  end
  table.sort(list, function(p, q) return p[1] > q[1] end)
  local cost = {}
  local nl = #list
  for t = 0, NC - 1 do
    local c = 0
    for i = 1, nl do
      local e = list[i]
      local a = e[1]
      if a <= c then break end
      local v = a * C[(e[2] - t + 720) % NC]
      if v > c then c = v end
    end
    cost[t] = c
  end
  return cost
end

-- RX criterion: cost[t] = sum_b s8[b] * |cos(phi_b - theta_t)|^8, s8 folded to 180 deg (1-based, NCAND entries)
function core.lp_curve(s8)
  local NC = core.NCAND
  local _, C8 = cos_tables()
  local list = {}
  for b = 0, NC - 1 do
    local v = s8[b + 1]
    if v > 0 then list[#list + 1] = { v, b } end
  end
  local cost = {}
  local nl = #list
  for t = 0, NC - 1 do
    local c = 0
    for i = 1, nl do
      local e = list[i]
      c = c + e[1] * C8[(e[2] - t + 720) % NC]
    end
    cost[t] = c
  end
  return cost
end

-- smallest |theta| whose cost is within a tolerance of the minimum; returns angle, t, best.
-- tol_rel is relative to the minimum; tol_range (optional) is relative to the curve's
-- max-min range, which makes the choice stable for flat curves (e.g. a pure sine, where
-- every angle is equivalent and the histogram noise would otherwise pick a random one).
function core.pick_min(cost, tol_rel, tol_range)
  local NC = core.NCAND
  local best, worst = math.huge, -math.huge
  for t = 0, NC - 1 do
    local c = cost[t]
    if c < best then best = c end
    if c > worst then worst = c end
  end
  local tol = best * (1 + tol_rel)
  if tol_range then tol = max(tol, best + tol_range * (worst - best)) end
  local bt, bd = 0, math.huge
  for t = 0, NC - 1 do
    if cost[t] <= tol then
      local ang = -90 + t * core.STEP_DEG
      if abs(ang) < bd then bd = abs(ang); bt = t end
    end
  end
  return -90 + bt * core.STEP_DEG, bt, best
end

function core.pick_angle(cost)  -- peak criterion (kept for compatibility)
  local ang, bt, best = core.pick_min(cost, 10 ^ (core.TIE_DB / 20) - 1)
  return ang, cost[bt], best
end

-- signed peaks after rotating by theta (degrees): returns pos_peak, neg_peak (both >= 0)
function core.peaks_after(bins, theta)
  local NB = core.NBINS
  local th = theta * PI / 180
  local pos, neg = 0, 0
  for b = 0, NB - 1 do
    local a = bins[b + 1]
    if a > 0 then
      local v = a * cos((b + 0.5) * 2 * PI / NB - th)
      if v > pos then pos = v elseif -v > neg then neg = -v end
    end
  end
  return pos, neg
end

-- 360-point polar shape (max envelope per degree) for display
function core.shape(bins)
  local NB = core.NBINS
  local per = NB // 360
  local s = {}
  for d = 0, 359 do
    local m = 0
    for j = 1, per do
      local v = bins[d * per + j]
      if v > m then m = v end
    end
    s[d + 1] = m
  end
  return s
end

-- Analyse a take. Returns a result table (see bottom) or nil, err.
-- opts.criterion = "rx" (default, RX-compatible L8) or "peak" (exact minimum sample peak).
-- progress(frac) is optional and is called once per block.
function core.analyze(take, opts, progress)
  opts = opts or {}
  local criterion = opts.criterion == "peak" and "peak" or "rx"
  local t_start = r.time_precise()
  local item = r.GetMediaItemTake_Item(take)
  local src = r.GetMediaItemTake_Source(take)
  local sr = r.GetMediaSourceSampleRate(src)
  if not sr or sr < 1000 then sr = r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false) end
  if not sr or sr < 1000 then sr = 48000 end
  sr = floor(sr + 0.5)
  local nch = core.effective_channels(take)

  local acc = r.CreateTakeAudioAccessor(take)
  if not acc then return nil, "could not create audio accessor" end
  local t0, t1 = r.GetAudioAccessorStartTime(acc), r.GetAudioAccessorEndTime(acc)
  local total = floor((t1 - t0) * sr + 0.5)
  if total < 1 then r.DestroyAudioAccessor(acc) return nil, "empty item" end

  local M = core.fir_length(sr)
  local D = (M - 1) // 2
  local N = 32768
  local HOP = N - (M - 1)
  local hspec = core.fir_spectrum(N, M)
  local inbuf, fftbuf, tmp, stage = r.new_array(2 * N), r.new_array(2 * N), r.new_array(2 * HOP), r.new_array(2 * (M - 1))
  inbuf.clear()

  local NB = core.NBINS
  local HALF = core.NCAND
  local K = NB / (2 * PI)
  local THR2 = core.THR_REL * core.THR_REL
  local bins1, bins2, s81, s82 = {}, {}, {}, {}
  for b = 1, NB do bins1[b] = 0; bins2[b] = 0 end
  for b = 1, HALF do s81[b] = 0; s82[b] = 0 end
  local max2_1, max2_2, thr2_1, thr2_2 = 0, 0, 0, 0
  local pp1, np1, pp2, np2 = 0, 0, 0, 0
  local stereo = nch >= 2

  local read = 0
  local nblocks = (total + HOP - 1) // HOP
  for blk = 1, nblocks do
    tmp.clear()
    r.GetAudioAccessorSamples(acc, sr, 2, t0 + read / sr, HOP, tmp)
    inbuf.copy(tmp, 1, 2 * HOP, 2 * (M - 1) + 1)
    fftbuf.copy(inbuf, 1, 2 * N, 1)
    fftbuf.fft(N, true)
    fftbuf.convolve(hspec, 1, 2 * N, 1)
    fftbuf.ifft(N, true)
    local wet = fftbuf.table(2 * (M - 1) + 1, 2 * HOP)
    local dry = inbuf.table(2 * D + 1, 2 * HOP)
    local nvalid = min(HOP, total - read)
    for n = 0, nvalid - 1 do
      local i2 = 2 * n + 1
      local x, h = dry[i2], wet[i2]
      if x > pp1 then pp1 = x elseif x < np1 then np1 = x end
      local a2 = x * x + h * h
      if a2 >= thr2_1 and a2 > 0 then
        if a2 > max2_1 then max2_1 = a2; thr2_1 = a2 * THR2 end
        local b = floor(atan(h, x) * K) % NB
        local a = sqrt(a2)
        if a > bins1[b + 1] then bins1[b + 1] = a end
        local a4 = a2 * a2
        local bf = b % HALF + 1
        s81[bf] = s81[bf] + a4 * a4
      end
      if stereo then
        x, h = dry[i2 + 1], wet[i2 + 1]
        if x > pp2 then pp2 = x elseif x < np2 then np2 = x end
        a2 = x * x + h * h
        if a2 >= thr2_2 and a2 > 0 then
          if a2 > max2_2 then max2_2 = a2; thr2_2 = a2 * THR2 end
          local b = floor(atan(h, x) * K) % NB
          local a = sqrt(a2)
          if a > bins2[b + 1] then bins2[b + 1] = a end
          local a4 = a2 * a2
          local bf = b % HALF + 1
          s82[bf] = s82[bf] + a4 * a4
        end
      end
    end
    read = read + nvalid
    -- keep the last M-1 complex samples as overlap for the next block
    stage.copy(inbuf, 2 * HOP + 1, 2 * (M - 1), 1)
    inbuf.copy(stage, 1, 2 * (M - 1), 1)
    if progress then progress(blk / nblocks) end
  end
  r.DestroyAudioAccessor(acc)

  -- results
  local res = { nch = nch, sr = sr, nsamples = total, duration = total / sr, channels = {},
                bins = { bins1, bins2 }, criterion = criterion }
  local NC = core.NCAND
  local costs, lps = {}, {}
  local function choose(costmax, cost8)
    local ang_peak, t_peak, best_peak = core.pick_min(costmax, 10 ^ (core.TIE_DB / 20) - 1)
    local ang_rx, t_rx = core.pick_min(cost8, 1e-6)
    local ang, t = ang_rx, t_rx
    if criterion == "peak" then ang, t = ang_peak, t_peak end
    return ang, costmax[t], ang_rx, ang_peak, best_peak
  end
  for c = 1, nch do
    local bins = c == 1 and bins1 or bins2
    local s8 = c == 1 and s81 or s82
    local pp, np = (c == 1 and pp1 or pp2), (c == 1 and np1 or np2)
    costs[c] = core.cost_curve(bins)
    lps[c] = core.lp_curve(s8)
    local ang, pk, ang_rx, ang_peak, best_peak = choose(costs[c], lps[c])
    local pos, neg = core.peaks_after(bins, ang)
    res.channels[c] = {
      pos_before = pp, neg_before = -np, peak_before = max(pp, -np),
      best_angle = ang, peak_after = pk, pos_after = pos, neg_after = neg,
      angle_rx = ang_rx, angle_peak = ang_peak, min_peak = best_peak,
      shape = core.shape(bins),
    }
  end
  if nch >= 2 then
    local cl, l8 = {}, {}
    for t = 0, NC - 1 do
      cl[t] = max(costs[1][t], costs[2][t])
      l8[t] = lps[1][t] + lps[2][t]
    end
    local ang, pk, ang_rx, ang_peak, best_peak = choose(cl, l8)
    local p1, n1 = core.peaks_after(bins1, ang)
    local p2, n2 = core.peaks_after(bins2, ang)
    res.linked = { angle = ang, peak_after = pk, pos_after = max(p1, p2), neg_after = max(n1, n2),
                   angle_rx = ang_rx, angle_peak = ang_peak, min_peak = best_peak }
    res.peak_before = max(res.channels[1].peak_before, res.channels[2].peak_before)
  else
    local ch = res.channels[1]
    res.linked = { angle = ch.best_angle, peak_after = ch.peak_after, pos_after = ch.pos_after, neg_after = ch.neg_after,
                   angle_rx = ch.angle_rx, angle_peak = ch.angle_peak, min_peak = ch.min_peak }
    res.peak_before = ch.peak_before
  end
  res.seconds = r.time_precise() - t_start
  return res
end

-- ----------------------------------------------------------------- render

-- Bake the take FX into the items (track FX are bypassed during the render so
-- that only the take FX chain is applied). Returns the number of rendered items.
function core.render(items, opts)
  opts = opts or {}
  local sel = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do sel[#sel + 1] = r.GetSelectedMediaItem(0, i) end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local n = 0
  for _, item in ipairs(items) do
    if r.ValidatePtr2(0, item, "MediaItem*") then
      local take = r.GetActiveTake(item)
      if take and core.find_fx(take) >= 0 then
        local tr = r.GetMediaItem_Track(item)
        -- bypass the track FX one by one (the track-level I_FXEN bypass would
        -- also bypass take FX, which is exactly what we want to render)
        local saved = {}
        for f = 0, r.TrackFX_GetCount(tr) - 1 do
          saved[f] = r.TrackFX_GetEnabled(tr, f)
          if saved[f] then r.TrackFX_SetEnabled(tr, f, false) end
        end
        local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local nch, src_nch = core.effective_channels(take)
        r.SelectAllMediaItems(0, false)
        r.SetMediaItemSelected(item, true)
        local cmd = 40209                                -- stereo output
        if nch == 1 then cmd = 40361 elseif src_nch > 2 then cmd = 41993 end
        r.Main_OnCommand(cmd, 0)
        r.SetMediaItemInfo_Value(item, "D_LENGTH", len)  -- drop the FX tail
        for f, en in pairs(saved) do if en then r.TrackFX_SetEnabled(tr, f, true) end end
        if opts.keep_original == false then r.Main_OnCommand(40131, 0) end -- Take: Crop to active take
        n = n + 1
      end
    end
  end
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(sel) do
    if r.ValidatePtr2(0, it, "MediaItem*") then r.SetMediaItemSelected(it, true) end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Phase Rotation: render", -1)
  return n
end


-- ------------------------------------------------ engine: reaper_phaserot extension
-- With the extension installed the rotation is applied to the take's SOURCE (playback,
-- render and waveform display) without any take FX or new files. Without it the JSFX
-- take-FX path above is used.

function core.has_ext()
  return r.APIExists ~= nil and r.APIExists("PhaseRot_SetTake") and r.APIExists("PhaseRot_Analyze")
end

function core.mode()
  return core.has_ext() and "source" or "fx"
end

function core.ext_get(take)
  local ok, al, ar, ad, sm, by, li = r.PhaseRot_GetTake(take, 0, 0, 0, 0, 0, 0)
  if not ok then return nil end
  return { angle_l = al, angle_r = ar, adaptive = ad ~= 0, smooth = sm, enabled = by == 0, link = li ~= 0, mode = "source" }
end

-- st fields optional (merged with the current state): angle_l, angle_r, adaptive, smooth, enabled
function core.ext_set(take, st)
  local cur = core.ext_get(take) or { angle_l = 0, angle_r = 0, adaptive = false, smooth = 0, enabled = true, link = true }
  local al = st.angle_l or cur.angle_l
  local ar = st.angle_r or cur.angle_r
  local ad = st.adaptive; if ad == nil then ad = cur.adaptive end
  local sm = st.smooth or cur.smooth or 0
  local en = st.enabled; if en == nil then en = cur.enabled end
  local li = st.link; if li == nil then li = cur.link end
  return r.PhaseRot_SetTake(take, al, ar, ad and 1 or 0, sm, en and 0 or 1, li and 1 or 0)
end

function core.ext_clear(take)
  return r.PhaseRot_ClearTake(take)
end

-- max envelope per degree -> signed peaks after rotating by theta (degrees)
function core.peaks_after_shape(shape, theta)
  local th = theta * PI / 180
  local pos, neg = 0, 0
  for d = 1, 360 do
    local a = shape[d]
    if a and a > 0 then
      local v = a * cos((d - 0.5) * PI / 180 - th)
      if v > pos then pos = v elseif -v > neg then neg = -v end
    end
  end
  return pos, neg
end

local function parse_kv(text)
  local t = {}
  for k, v in text:gmatch("([%w_]+)=([^%s]*)") do t[k] = v end
  return t
end

-- Analysis by the extension (on the ORIGINAL audio, even when the take is already rotated).
function core.analyze_ext(take, opts)
  opts = opts or {}
  local criterion = opts.criterion == "peak" and "peak" or "rx"
  local t0 = r.time_precise()
  if not r.PhaseRot_Analyze(take) then return nil, "analysis failed (not an audio take?)" end
  local kv = parse_kv(r.GetExtState("phaserot", "analysis"))
  local nch = tonumber(kv.nch) or 1
  local res = { nch = nch, sr = tonumber(kv.sr) or 48000, duration = tonumber(kv.length) or 0, channels = {},
                criterion = criterion, mode = "source", peak_before = tonumber(kv.peak_before) or 0 }
  res.nsamples = floor(res.duration * res.sr + 0.5)
  for c = 0, nch - 1 do
    local shape = {}
    local i = 0
    for v in (kv["shape" .. c] or ""):gmatch("[^,]+") do i = i + 1; shape[i] = tonumber(v) or 0 end
    for j = i + 1, 360 do shape[j] = 0 end
    local a_rx, a_pk = tonumber(kv["ch" .. c .. "_rx"]) or 0, tonumber(kv["ch" .. c .. "_peak"]) or 0
    local ang = criterion == "peak" and a_pk or a_rx
    local pos, neg = core.peaks_after_shape(shape, ang)
    res.channels[c + 1] = {
      pos_before = tonumber(kv["ch" .. c .. "_pos_before"]) or 0, neg_before = tonumber(kv["ch" .. c .. "_neg_before"]) or 0,
      peak_before = tonumber(kv["ch" .. c .. "_before"]) or 0,
      best_angle = ang, peak_after = criterion == "peak" and (tonumber(kv["ch" .. c .. "_minpeak"]) or 0) or (tonumber(kv["ch" .. c .. "_after_rx"]) or 0),
      pos_after = pos, neg_after = neg, angle_rx = a_rx, angle_peak = a_pk,
      min_peak = tonumber(kv["ch" .. c .. "_minpeak"]) or 0, shape = shape,
    }
  end
  local l_rx, l_pk = tonumber(kv.linked_rx) or 0, tonumber(kv.linked_peak) or 0
  local lang = criterion == "peak" and l_pk or l_rx
  local lpos, lneg = 0, 0
  for c = 1, nch do
    local p_, n_ = core.peaks_after_shape(res.channels[c].shape, lang)
    lpos, lneg = max(lpos, p_), max(lneg, n_)
  end
  res.linked = { angle = lang, peak_after = criterion == "peak" and (tonumber(kv.linked_minpeak) or 0) or (tonumber(kv.linked_after_rx) or 0),
                 pos_after = lpos, neg_after = lneg, angle_rx = l_rx, angle_peak = l_pk, min_peak = tonumber(kv.linked_minpeak) or 0 }
  res.seconds = r.time_precise() - t0
  return res
end

-- ------------------------------------------------------------ unified take API
-- state: { angle_l, angle_r, adaptive, smooth, enabled, mode } or nil when nothing is applied
function core.get_take_state(take)
  if core.mode() == "source" then return core.ext_get(take) end
  local fx = core.find_fx(take)
  if fx < 0 then return nil end
  return core.get_state(take, fx)
end

function core.set_take_state(take, st)
  if core.mode() == "source" then
    core.remove_fx(take)   -- a take FX left over from the JSFX engine would rotate twice
    return core.ext_set(take, st)
  end
  local fx, err = core.ensure_fx(take)
  if fx < 0 then return false, err end
  core.set_state(take, fx, st)
  return true
end

function core.clear_take(take)
  local a = core.remove_fx(take)
  if core.mode() == "source" then
    local b = core.ext_clear(take)
    return a or b
  end
  return a
end

function core.analyze_any(take, opts, progress)
  if core.mode() == "source" then return core.analyze_ext(take, opts) end
  return core.analyze(take, opts, progress)
end

return core
