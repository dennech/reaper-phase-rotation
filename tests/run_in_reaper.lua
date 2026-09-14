-- Integration test. Runs INSIDE REAPER (launched by tests/run_tests.sh with an
-- isolated resource directory). Reads env: PR_REPO, PR_TEST_DIR, PR_TEST_OUT.
local REPO = os.getenv("PR_REPO")
local TD = os.getenv("PR_TEST_DIR")
local OUT = os.getenv("PR_TEST_OUT")
local logf = assert(io.open(OUT, "w"))
local function log(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
  logf:write(table.concat(t, " ") .. "\n"); logf:flush()
end
local function result(key, val) log("RESULT " .. key .. " " .. tostring(val)) end
local function db(v) if v <= 1e-12 then return -240 end return 20 * math.log(v, 10) end

local ok, err = xpcall(function()
  local core = dofile(REPO .. "/Items/phase_rotation_core.lua")
  log("core version", core.VERSION, "reaper", reaper.GetAppVersion(), "respath", reaper.GetResourcePath())
  local rel, lerr = core.locate_jsfx()
  log("jsfx relpath", rel, lerr)
  assert(rel, "jsfx not located")

  local ntracks = 0
  local function insert(file)
    reaper.InsertTrackAtIndex(ntracks, false)
    local tr = reaper.GetTrack(0, ntracks)
    ntracks = ntracks + 1
    reaper.SetOnlyTrackSelected(tr)
    reaper.SetEditCurPos(0, false, false)
    assert(reaper.InsertMedia(file, 0) == 1, "InsertMedia failed for " .. file)
    local item = reaper.GetTrackMediaItem(tr, reaper.CountTrackMediaItems(tr) - 1)
    return item, reaper.GetActiveTake(item), tr
  end
  local function rendered_path(item)
    local take = reaper.GetActiveTake(item)
    return reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(take), "")
  end
  local function peak_of_take(take, seconds)
    local acc = reaper.CreateTakeAudioAccessor(take)
    local sr = 48000
    local n = math.floor(seconds * sr)
    local buf = reaper.new_array(2 * n); buf.clear()
    reaper.GetAudioAccessorSamples(acc, sr, 2, 0, n, buf)
    local t = buf.table()
    local mx = 0
    for i = 1, #t do local a = math.abs(t[i]) if a > mx then mx = a end end
    reaper.DestroyAudioAccessor(acc)
    return mx
  end

  -- A. suggestions -----------------------------------------------------------
  local items = {}
  for _, id in ipairs({ "asym_mono", "asym_stereo", "adaptive_switch", "sine" }) do
    local item, take = insert(TD .. "/" .. id .. ".wav")
    items[id] = item
    local res, aerr = core.analyze(take)
    assert(res, aerr)
    log(id, "nch", res.nch, "sr", res.sr, "n", res.nsamples, "seconds", string.format("%.3f", res.seconds))
    for c, ch in ipairs(res.channels) do
      result(id .. ".angle" .. (c - 1), string.format("%.4f", ch.best_angle))
      result(id .. ".minpeak_angle" .. (c - 1), string.format("%.4f", ch.angle_peak))
      result(id .. ".peak_after_db" .. (c - 1), string.format("%.4f", db(ch.peak_after)))
      log(id, "ch", c, string.format("before %.2f dB (pos %.2f neg %.2f) -> after %.2f dB (pos %.2f neg %.2f) angle %.3f",
        db(ch.peak_before), db(ch.pos_before), db(ch.neg_before), db(ch.peak_after), db(ch.pos_after), db(ch.neg_after), ch.best_angle))
    end
    if res.nch >= 2 then
      result(id .. ".linked_angle", string.format("%.4f", res.linked.angle))
      log(id, "linked", string.format("angle %.3f peak after %.2f dB", res.linked.angle, db(res.linked.peak_after)))
    end
  end

  -- B. fixed-angle renders --------------------------------------------------
  local function render_fixed(id, item, st)
    local take = reaper.GetActiveTake(item)
    local fx, ferr = core.ensure_fx(take)
    assert(fx >= 0, ferr)
    core.set_state(take, fx, st)
    local s = core.get_state(take, fx)
    log(id, "state", "L", s.angle_l, "R", s.angle_r, "link", s.link, "adaptive", s.adaptive)
    local n = core.render({ item }, { keep_original = true })
    assert(n == 1, "render count " .. n)
    local p = rendered_path(item)
    result(id .. ".render", p)
    result(id .. ".render_angles", st.angle_r and (st.angle_l .. "," .. st.angle_r) or tostring(st.angle_l))
    log(id, "takes", reaper.CountTakes(item), "len", reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
  end
  render_fixed("asym_mono", items.asym_mono, { link = true, adaptive = false, angle_l = 30, angle_r = 30 })
  render_fixed("asym_stereo", items.asym_stereo, { link = false, adaptive = false, angle_l = 30, angle_r = -45 })
  local click_item = insert(TD .. "/click.wav")
  render_fixed("click", click_item, { link = true, adaptive = false, angle_l = 0, angle_r = 0 })

  -- roundtrip: render asym_mono at its suggested angle, analyse the result
  do
    local item, take = insert(TD .. "/asym_mono.wav")
    local res = assert(core.analyze(take))
    local ang = res.channels[1].best_angle
    local fx = core.ensure_fx(take)
    core.set_state(take, fx, { link = true, adaptive = false, angle_l = ang, angle_r = ang })
    core.render({ item }, { keep_original = false })
    local take2 = reaper.GetActiveTake(item)
    log("roundtrip takes", reaper.CountTakes(item), "fx on new take", core.find_fx(take2))
    local res2 = assert(core.analyze(take2))
    result("asym_mono.roundtrip_angle", string.format("%.4f", res2.channels[1].best_angle))
    result("asym_mono.roundtrip_peak_before_db", string.format("%.4f", db(res2.channels[1].peak_before)))
    result("asym_mono.roundtrip_expected_peak_db", string.format("%.4f", db(res.channels[1].peak_after)))
  end

  -- C. adaptive render -------------------------------------------------------
  do
    local item = items.adaptive_switch
    local take = reaper.GetActiveTake(item)
    local fx = core.ensure_fx(take)
    core.set_state(take, fx, { link = true, adaptive = true, smooth = 0, angle_l = 0, angle_r = 0 })
    core.render({ item }, { keep_original = true })
    result("adaptive_switch.adaptive_render", rendered_path(item))
  end

  -- D. track FX must be bypassed while rendering ------------------------------
  do
    local item, take, tr = insert(TD .. "/asym_mono.wav")
    local tfx = reaper.TrackFX_AddByName(tr, "JS:PhaseRotation/probe.jsfx", false, 1)
    log("track probe fx idx", tfx)
    local fx = core.ensure_fx(take)
    core.set_state(take, fx, { link = true, adaptive = false, angle_l = 90, angle_r = 90 })
    core.render({ item }, { keep_original = true })
    local pk = peak_of_take(reaper.GetActiveTake(item), 6)
    result("trackfx_bypass_peak", string.format("%.4f", pk))
    result("trackfx_enabled_after", tostring(reaper.TrackFX_GetEnabled(tr, tfx)))
    result("trackfx.render", rendered_path(item))
    result("trackfx.render_angles", "90")
    result("trackfx.render_srcid", "asym_mono")
  end

  -- D2. optional: files measured in iZotope RX 10 (see RX_REFERENCE.md) ---------
  local rxdir = os.getenv("PR_RX_REF_DIR")
  if rxdir and rxdir ~= "" then
    for _, nm in ipairs({ "asym_mono", "speech_en", "speech_ru" }) do
      local f = io.open(rxdir .. "/" .. nm .. "_orig.wav", "rb")
      if f then
        f:close()
        local _, take = insert(rxdir .. "/" .. nm .. "_orig.wav")
        local res = assert(core.analyze(take))
        result("rxref." .. nm .. ".angle0", string.format("%.4f", res.channels[1].best_angle))
        log("rxref", nm, "rx-criterion", res.channels[1].angle_rx, "min-peak", res.channels[1].angle_peak,
          string.format("peak %.2f -> %.2f dB (min possible %.2f)", db(res.channels[1].peak_before), db(res.channels[1].peak_after), db(res.channels[1].min_peak)))
      end
    end
  end

  -- E. timing on a long stereo item -------------------------------------------
  do
    local _, take = insert(TD .. "/long_stereo.wav")
    local res = assert(core.analyze(take))
    result("long_stereo.analyze_seconds", string.format("%.2f", res.seconds))
    log("long_stereo angles", res.channels[1].best_angle, res.channels[2].best_angle, "linked", res.linked.angle)
  end
end, debug.traceback)
log("DONE ok=" .. tostring(ok), err or "")
logf:close()
reaper.Main_SaveProjectEx(0, os.getenv("PR_PROJ") or (TD .. "/test.rpp"), 0)
reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
