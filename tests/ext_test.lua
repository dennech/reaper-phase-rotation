-- Extension integration test (runs inside the isolated REAPER, see run_tests.sh).
-- Env: PR_TEST_DIR (test signals), PR_TEST_OUT (log), PR_OUT_DIR (sample dumps), PR_RX_REF_DIR (optional)
local TD = os.getenv("PR_TEST_DIR")
local OUTD = os.getenv("PR_OUT_DIR")
local RX = os.getenv("PR_RX_REF_DIR")
local S = OUTD
local logf = io.open(os.getenv("PR_TEST_OUT"), "w")
local function log(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end logf:write(table.concat(t, " ") .. "\n"); logf:flush() end
local function result(k, v) log("RESULT " .. k .. " " .. tostring(v)) end
local function db(v) if v <= 1e-12 then return -240 end return 20 * math.log(v, 10) end
local function dump_take(take, path, seconds, nch)
  local sr = 48000
  local n = math.floor(seconds * sr)
  local acc = reaper.CreateTakeAudioAccessor(take)
  local buf = reaper.new_array(n * nch); buf.clear()
  reaper.GetAudioAccessorSamples(acc, sr, nch, 0, n, buf)
  reaper.DestroyAudioAccessor(acc)
  local t = buf.table()
  local f = assert(io.open(path, "wb"))
  local parts = {}
  for i = 1, #t do parts[#parts+1] = string.pack("<f", t[i]) if #parts >= 65536 then f:write(table.concat(parts)); parts = {} end end
  f:write(table.concat(parts)); f:close()
  local mx = 0; for i = 1, #t do local a = math.abs(t[i]) if a > mx then mx = a end end
  return mx
end
local function peaks_max(take, rate, secs)
  local n = math.floor(secs * rate)
  local buf = reaper.new_array(n * 3); buf.clear()
  local r = reaper.GetMediaItemTake_Peaks(take, rate, 0, 1, n, 0, buf)
  local out = r & 0xfffff
  local t = buf.table()
  local mx, mn = -1, 1
  for i = 1, out do if t[i] > mx then mx = t[i] end end
  for i = out + 1, 2 * out do if t[i] < mn then mn = t[i] end end   -- minvals follow when requested? (mode dependent)
  return out, mx, mn, r
end
local state = {}
local steps = {}
local function next_step() local f = table.remove(steps, 1); if f then f() else log("DONE"); logf:close(); reaper.Main_SaveProjectEx(0, S .. "/ext_final.rpp", 0) end end
local function wait_then(sec, f) local t0 = reaper.time_precise(); local function w() if reaper.time_precise() - t0 >= sec then f() else reaper.defer(w) end end; reaper.defer(w) end

table.insert(steps, function()
  result("ext.api", tostring(reaper.APIExists("PhaseRot_SetTake") and reaper.APIExists("PhaseRot_Analyze")))
  if not reaper.APIExists("PhaseRot_SetTake") then log("DONE"); logf:close(); return end
  log("version", reaper.PhaseRot_GetVersion())
  reaper.InsertTrackAtIndex(0, false); local tr = reaper.GetTrack(0, 0); reaper.SetOnlyTrackSelected(tr); reaper.SetEditCurPos(0, false, false)
  reaper.InsertMedia(TD .. "/asym_mono.wav", 0)
  state.item = reaper.GetTrackMediaItem(tr, 0); state.take = reaper.GetActiveTake(state.item)
  log("peak original", string.format("%.4f", dump_take(state.take, S .. "/ext_orig.f32", 6, 1)))
  local t0 = reaper.time_precise()
  local ok = reaper.PhaseRot_Analyze(state.take); local res = reaper.GetExtState("phaserot", "analysis")
  log("analyze", ok, string.format("%.3f s", reaper.time_precise() - t0), (res or ""):sub(1, 300))
  result("ext.analyze_rx", (res or ""):match("ch0_rx=([%-%d%.]+)") or "nan")
  result("ext.analyze_peak", (res or ""):match("ch0_peak=([%-%d%.]+)") or "nan")
  reaper.Undo_BeginBlock()
  log("set", reaper.PhaseRot_SetTake(state.take, 78, 78, 0, 0, 0))
  reaper.Undo_EndBlock("phaserot set", -1)
  local ok2, al, ar, ad, sm, by = reaper.PhaseRot_GetTake(state.take, 0, 0, 0, 0, 0)
  log("get", ok2, al, ar, ad, sm, by)
  local _, ext = reaper.GetSetMediaItemTakeInfo_String(state.take, "P_EXT:phaserot", "", false)
  log("P_EXT", ext)
  local src = reaper.GetMediaItemTake_Source(state.take)
  log("source type", reaper.GetMediaSourceType(src, ""), "file", reaper.GetMediaSourceFileName(src, ""), "len", reaper.GetMediaSourceLength(src))
  t0 = reaper.time_precise()
  log("peak rotated", string.format("%.4f", dump_take(state.take, S .. "/ext_rot78.f32", 6, 1)), string.format("(%.3f s)", reaper.time_precise() - t0))
  result("ext.rot78.dump", S .. "/ext_rot78.f32")
  t0 = reaper.time_precise()
  local out, mx, mn, r = peaks_max(state.take, 100, 6)
  log("peaks 100/s:", out, string.format("max %.4f min %.4f raw %d (%.3f s)", mx, mn, r, reaper.time_precise() - t0))
  result("ext.peaks100.max", string.format("%.4f", mx)); result("ext.peaks100.min", string.format("%.4f", mn))
  local out2, mx2, mn2 = peaks_max(state.take, 4000, 6)
  log("peaks 4000/s:", out2, string.format("max %.4f min %.4f", mx2, mn2))
  next_step()
end)
table.insert(steps, function()
  -- undo -> should unwrap
  log("undo point:", reaper.Undo_CanUndo2(0))
  reaper.Undo_DoUndo2(0)
  wait_then(0.6, function()
    if not reaper.ValidatePtr2(0, state.take, "MediaItem_Take*") then
      local it = reaper.GetMediaItem(0, 0); state.item = it; state.take = it and reaper.GetActiveTake(it)
      log("take pointer changed after undo; items now", reaper.CountMediaItems(0))
      if not state.take then log("DONE"); logf:close(); return end
    end
    local ok2 = reaper.PhaseRot_GetTake(state.take, 0, 0, 0, 0, 0)
    local pk = dump_take(state.take, S .. "/ext_tmp.f32", 6, 1)
    log("after undo: has params", ok2, "peak", string.format("%.4f", pk)); result("ext.undo.params", tostring(ok2)); result("ext.undo.peak", string.format("%.4f", pk))
    reaper.Undo_DoRedo2(0)
    wait_then(0.6, function()
      local ok3 = reaper.PhaseRot_GetTake(state.take, 0, 0, 0, 0, 0)
      local pk3 = dump_take(state.take, S .. "/ext_tmp.f32", 6, 1)
      log("after redo: has params", ok3, "peak", string.format("%.4f", pk3)); result("ext.redo.params", tostring(ok3)); result("ext.redo.peak", string.format("%.4f", pk3))
      next_step()
    end)
  end)
end)
table.insert(steps, function()
  -- duplicate item -> copy keeps rotation
  reaper.SelectAllMediaItems(0, false); reaper.SetMediaItemSelected(state.item, true)
  reaper.Main_OnCommand(41295, 0) -- duplicate items
  wait_then(0.4, function()
    local tr = reaper.GetTrack(0, 0)
    local it2 = reaper.GetTrackMediaItem(tr, 1)
    local tk2 = it2 and reaper.GetActiveTake(it2)
    if tk2 then
      local ok2, al = reaper.PhaseRot_GetTake(tk2, 0, 0, 0, 0, 0)
      local pkd = dump_take(tk2, S .. "/ext_tmp.f32", 6, 1)
      log("duplicate: has params", ok2, al, "peak", string.format("%.4f", pkd)); result("ext.dup.params", tostring(ok2)); result("ext.dup.peak", string.format("%.4f", pkd))
      reaper.DeleteTrackMediaItem(tr, it2)
    else log("duplicate: no item") end
    next_step()
  end)
end)
table.insert(steps, function()
  -- save, new project, reopen -> timer must re-wrap
  reaper.Main_SaveProjectEx(0, S .. "/ext_saved.rpp", 0)
  local f = io.open(S .. "/ext_saved.rpp"); local rpp = f:read("*a"); f:close()
  result("ext.rpp.wave", tostring(rpp:find("<SOURCE WAVE", 1, true) ~= nil)); result("ext.rpp.customtype", tostring(rpp:find("<SOURCE PHASEROT", 1, true) ~= nil)); result("ext.rpp.extline", tostring(rpp:find("phaserot", 1, true) ~= nil))
  local line = rpp:match("[^\n]*phaserot[^\n]*"); log("ext line:", line)
  reaper.Main_openProject("noprompt:" .. S .. "/ext_saved.rpp")
  wait_then(1.0, function()
    local it = reaper.GetMediaItem(0, 0); local tk = it and reaper.GetActiveTake(it)
    if tk then
      local ok2, al = reaper.PhaseRot_GetTake(tk, 0, 0, 0, 0, 0)
      local pkr = dump_take(tk, S .. "/ext_tmp.f32", 6, 1)
      log("after reload: has params", ok2, al, "peak", string.format("%.4f", pkr)); result("ext.reload.params", tostring(ok2)); result("ext.reload.peak", string.format("%.4f", pkr))
      state.item = it; state.take = tk
    else log("after reload: no item") end
    next_step()
  end)
end)
table.insert(steps, function()
  -- bypass + clear
  reaper.PhaseRot_SetTake(state.take, 78, 78, 0, 0, 1)
  result("ext.bypass.peak", string.format("%.4f", dump_take(state.take, S .. "/ext_tmp.f32", 6, 1)))
  reaper.PhaseRot_ClearTake(state.take)
  local ok2 = reaper.PhaseRot_GetTake(state.take, 0, 0, 0, 0, 0)
  result("ext.clear.params", tostring(ok2)); result("ext.clear.peak", string.format("%.4f", dump_take(state.take, S .. "/ext_tmp.f32", 6, 1)))
  next_step()
end)
table.insert(steps, function()
  -- adaptive on speech_ru
  reaper.InsertTrackAtIndex(1, false); local tr = reaper.GetTrack(0, 1); reaper.SetOnlyTrackSelected(tr); reaper.SetEditCurPos(0, false, false)
  local adfile = (RX and RX ~= "" and io.open(RX .. "/speech_ru_orig.wav")) and (RX .. "/speech_ru_orig.wav") or (TD .. "/adaptive_switch.wav")
  reaper.InsertMedia(adfile, 0)
  result("ext.adaptive.file", adfile)
  local it = reaper.GetTrackMediaItem(tr, 0); local tk = reaper.GetActiveTake(it)
  local t0 = reaper.time_precise()
  reaper.PhaseRot_SetTake(tk, 0, 0, 1, 0, 0)
  log("adaptive set in", string.format("%.3f s", reaper.time_precise() - t0))
  t0 = reaper.time_precise()
  local dur = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
  log("adaptive peak", string.format("%.4f", dump_take(tk, S .. "/ext_adaptive.f32", dur, 1)), string.format("(%.3f s)", reaper.time_precise() - t0))
  result("ext.adaptive.dump", S .. "/ext_adaptive.f32")
  reaper.PhaseRot_SetTake(tk, 78, 78, 0, 0, 0)
  log("fixed78 peak", string.format("%.4f", dump_take(tk, S .. "/ext_ru78.f32", dur, 1)))
  result("ext.fixed78.dump", S .. "/ext_ru78.f32")
  -- stereo file, unlinked angles
  reaper.InsertTrackAtIndex(2, false); local tr2 = reaper.GetTrack(0, 2); reaper.SetOnlyTrackSelected(tr2); reaper.SetEditCurPos(0, false, false)
  reaper.InsertMedia(TD .. "/asym_stereo.wav", 0)
  local it2 = reaper.GetTrackMediaItem(tr2, 0); local tk2 = reaper.GetActiveTake(it2)
  reaper.PhaseRot_SetTake(tk2, 30, -45, 0, 0, 0)
  log("stereo peak", string.format("%.4f", dump_take(tk2, S .. "/ext_stereo.f32", 6, 2)))
  result("ext.stereo.dump", S .. "/ext_stereo.f32")
  local ok = reaper.PhaseRot_Analyze(tk2); local res = reaper.GetExtState("phaserot", "analysis")
  log("stereo analyze", ok, (res or ""):gsub("shape%d=[^ ]*", ""):sub(1, 600))
  next_step()
end)
next_step()
