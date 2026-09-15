-- @description Phase Rotation (RX-style): suggest, audition and apply phase rotation to selected items
-- @author dennech
-- @version 1.2.0
-- @provides
--   [nomain] phase_rotation_core.lua
--   [effect] phase_rotation.jsfx
-- @link https://github.com/dennech/reaper-phase-rotation
-- @about
--   # Phase Rotation (RX-style)
--
--   A REAPER re-creation of the iZotope RX "Phase" module for media items:
--   Suggest (reproduces RX's own values), Left/Right rotation with Link,
--   Adaptive phase rotation, Preview / Bypass / Apply.
--
--   Nothing changes until you press Apply: Suggest and the sliders only stage
--   settings, Preview auditions them. An optional broadcast-style allpass
--   rotator (Orban 4 x 200 Hz, VoicePhaseRotator 8 x 200 Hz ...) can be chosen
--   instead of / in front of the transparent RX-style rotation.
--
--   With the reaper_phaserot extension installed (recommended) the rotation is
--   applied to the item's source: no files are written, no FX is added, the
--   waveform display updates immediately, the project file stays a plain
--   project. Without the extension the bundled JSFX is used as a take FX.
--
--   Keys: S = Suggest, Space = Preview, A = Apply, B = Bypass, Esc = close.

local r = reaper
local SCRIPT_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
local SEP = package.config:sub(1, 1)
local ok_core, core = pcall(dofile, SCRIPT_DIR .. SEP .. "phase_rotation_core.lua")
if not ok_core then
  r.ShowMessageBox("phase_rotation_core.lua must be next to this script.\n\n" .. tostring(core), "Phase Rotation", 0)
  return
end

local TITLE = "Phase Rotation (RX-style)"
local SECTION = core.SECTION
local floor, abs, max, min, cos, sin = math.floor, math.abs, math.max, math.min, math.cos, math.sin
local MODE = core.mode()          -- "source" (extension) or "fx" (JSFX take FX)
local HAS_PREVIEW = MODE == "source" and core.has_preview_api()

-- ------------------------------------------------------------------ settings
local S = { link = true, adaptive = false, smooth = 0, keep_original = true, solo_preview = false, criterion = "rx",
            instant = false, show_plot = false, ap = core.ap_copy(core.AP_OFF) }
do
  local function getb(k, d) local v = r.GetExtState(SECTION, k) if v == "" then return d end return v == "1" end
  local function getn(k, d) local v = tonumber(r.GetExtState(SECTION, k)) return v or d end
  S.link = getb("link", true)
  S.smooth = floor(getn("smooth", 0) + 0.5)
  S.keep_original = getb("keep_original", true)
  S.solo_preview = getb("solo_preview", false)
  S.criterion = r.GetExtState(SECTION, "criterion") == "peak" and "peak" or "rx"
  S.instant = getb("instant", false)
  S.show_plot = getb("show_plot", false)
end
local function save_settings()
  r.SetExtState(SECTION, "link", S.link and "1" or "0", true)
  r.SetExtState(SECTION, "smooth", tostring(S.smooth), true)
  r.SetExtState(SECTION, "keep_original", S.keep_original and "1" or "0", true)
  r.SetExtState(SECTION, "solo_preview", S.solo_preview and "1" or "0", true)
  r.SetExtState(SECTION, "criterion", S.criterion, true)
  r.SetExtState(SECTION, "instant", S.instant and "1" or "0", true)
  r.SetExtState(SECTION, "show_plot", S.show_plot and "1" or "0", true)
end

-- --------------------------------------------------------------------- state
-- Every selected item has a STAGED setting (what the sliders show) and an APPLIED state
-- (what is in the project). Suggest and the sliders change the staged values only;
-- Preview auditions them; Apply writes them to the items (one undo step).
local items = {}          -- { item, guid, take, info, res, st, staged = { angle_l, angle_r } }
local cur = 1
local cache = {}          -- guid..take -> { res = analysis, staged = {...} }
local sel_sig = ""
local status, status_t = "", 0
local busy = nil
local preview = { on = false }
local frame = 0

local function set_status(s) status = s; status_t = r.time_precise() end

local function item_guid(item)
  local _, g = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return g
end

local function take_state(e)
  e.st = core.get_take_state(e.take)
  return e.st
end

-- staged angles start from the applied state (or 0)
local function init_staged(e)
  local key = e.guid .. tostring(e.take)
  local c = cache[key]
  if c and c.staged then e.staged = c.staged return end
  local st = take_state(e)
  e.staged = { angle_l = st and st.angle_l or 0, angle_r = st and st.angle_r or 0 }
  cache[key] = cache[key] or {}
  cache[key].staged = e.staged
end

local function refresh_items(force)
  local n = r.CountSelectedMediaItems(0)
  local sig, list = {}, {}
  for i = 0, n - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    local take = r.GetActiveTake(item)
    if take and not r.TakeIsMIDI(take) then
      local g = item_guid(item)
      sig[#sig + 1] = g .. tostring(take)
      list[#list + 1] = { item = item, guid = g, take = take }
    end
  end
  sig = table.concat(sig, "|")
  if not force and sig == sel_sig then return end
  sel_sig = sig
  items = list
  for _, e in ipairs(items) do
    e.info = core.take_info(e.take)
    local c = cache[e.guid .. tostring(e.take)]
    e.res = c and c.res
    init_staged(e)
    -- pick up the applied rotator type / adaptive flag of the selection
    local st = take_state(e)
    if st and not S.applied_seen then S.adaptive = st.adaptive; S.ap = core.ap_copy(st.ap); S.applied_seen = true end
  end
  if cur > #items then cur = max(1, #items) end
end

local function staged_state(e)
  return { angle_l = e.staged.angle_l, angle_r = e.staged.angle_r, adaptive = S.adaptive, smooth = S.smooth,
           link = S.link, ap = core.ap_copy(S.ap), enabled = true }
end

-- does the staged setting differ from what is applied?
local function is_dirty(e)
  local st = e.st
  local sg = staged_state(e)
  local stereo = e.info and e.info.nch >= 2
  if not st then
    return sg.angle_l ~= 0 or (stereo and sg.angle_r ~= 0) or sg.adaptive or core.ap_on(sg.ap)
  end
  if sg.adaptive ~= st.adaptive then return true end
  if not core.ap_equal(st.ap, sg.ap) then return true end
  if sg.adaptive then return st.smooth ~= sg.smooth or st.link ~= sg.link end
  if abs(st.angle_l - sg.angle_l) > 0.05 then return true end
  if stereo and abs(st.angle_r - sg.angle_r) > 0.05 then return true end
  return false
end

local function any_dirty()
  for _, e in ipairs(items) do take_state(e); if is_dirty(e) then return true end end
  return false
end

local function invalidate_analyses()
  for _, e in ipairs(items) do
    if e.res and not core.ap_equal(e.res.ap, S.ap) then e.res = nil; local c = cache[e.guid .. tostring(e.take)]; if c then c.res = nil end end
  end
end

-- ------------------------------------------------------------------ actions
local function report_error(err)
  set_status("Error: " .. tostring(err))
  r.ShowMessageBox(tostring(err), TITLE, 0)
end

local function set_state(e, st)
  local ok, err = core.set_take_state(e.take, st)
  if not ok and err then report_error(err) end
  return ok
end

local push_preview   -- forward

local function apply_all(undo_name)
  if #items == 0 then return 0 end
  r.Undo_BeginBlock()
  local n = 0
  for _, e in ipairs(items) do if set_state(e, staged_state(e)) then n = n + 1 end end
  r.Undo_EndBlock(undo_name or "Phase Rotation: apply", -1)
  r.UpdateArrange()
  if preview.on and MODE == "fx" then preview.restore = {} end   -- the FX now holds the applied state: nothing to undo on stop
  return n
end

local function angles_from_result(res)
  if not res then return 0, 0 end
  if S.link or res.nch < 2 then
    local a = res.linked.angle
    return a, a
  end
  return res.channels[1].best_angle, res.channels[2].best_angle
end

local draw = function() end -- forward

local function do_suggest()
  if #items == 0 then return end
  local t0 = r.time_precise()
  local errs = 0
  for i, e in ipairs(items) do
    busy = { text = string.format("Analyzing item %d of %d ...", i, #items), frac = 0 }
    draw(); gfx.update()
    local res, err = core.analyze_any(e.take, { criterion = S.criterion, ap = S.ap }, function(f) busy.frac = f; draw(); gfx.update() end)
    if res then
      e.res = res
      local key = e.guid .. tostring(e.take)
      cache[key] = cache[key] or {}; cache[key].res = res
      local al, ar = angles_from_result(res)
      e.staged.angle_l, e.staged.angle_r = al, ar
    else
      errs = errs + 1
      set_status("Analysis failed: " .. tostring(err))
    end
  end
  busy = nil
  if errs > 0 then return end
  if S.instant then
    apply_all("Phase Rotation: suggest")
    set_status(string.format("Suggested and applied to %d item(s) in %.2f s", #items, r.time_precise() - t0))
  else
    push_preview()
    set_status(string.format("Suggested for %d item(s) · Preview to audition, Apply to commit", #items))
  end
end

local function do_apply()
  if #items == 0 then return end
  local n = apply_all("Phase Rotation: apply")
  set_status(string.format("Applied to %d item(s)%s", n, MODE == "source" and "" or " as take FX"))
end

local function do_revert()
  local e0 = items[cur]
  if not e0 then return end
  local st0 = take_state(e0)
  S.adaptive = st0 and st0.adaptive or false
  S.ap = core.ap_copy(st0 and st0.ap or core.AP_OFF)
  for _, e in ipairs(items) do
    local st = take_state(e)
    e.staged.angle_l, e.staged.angle_r = st and st.angle_l or 0, st and st.angle_r or 0
  end
  invalidate_analyses()
  push_preview()
  set_status("Reverted to the applied settings")
end

local function stop_preview()
  if not preview.on then return end
  if r.GetPlayState() & 1 == 1 then r.OnStopButton() end
  if preview.cursor then r.SetEditCurPos(preview.cursor, false, false) end
  if preview.solo then
    for tr, v in pairs(preview.solo) do
      if r.ValidatePtr2(0, tr, "MediaTrack*") then r.SetMediaTrackInfo_Value(tr, "I_SOLO", v) end
    end
  end
  for _, e in ipairs(items) do
    if r.ValidatePtr2(0, e.take, "MediaItem_Take*") then
      if HAS_PREVIEW then core.ext_clear_preview(e.take)
      elseif MODE == "fx" and preview.restore then
        local rs = preview.restore[tostring(e.take)]
        if rs == false then core.remove_fx(e.take)
        elseif rs then local fx = core.find_fx(e.take) if fx >= 0 then core.set_state(e.take, fx, rs) end end
      end
    end
  end
  preview = { on = false }
  r.UpdateArrange()
end

local function do_bypass()
  local e = items[cur]
  if not e then return end
  stop_preview()
  local st = take_state(e)
  local new_enabled = not (st and st.enabled)
  r.Undo_BeginBlock()
  for _, it in ipairs(items) do
    if core.get_take_state(it.take) then core.set_take_state(it.take, { enabled = new_enabled }) end
  end
  r.Undo_EndBlock(new_enabled and "Phase Rotation: enable" or "Phase Rotation: bypass", -1)
  r.UpdateArrange()
  set_status(new_enabled and "Rotation active" or "Bypassed (original plays)")
end

local function do_remove()
  stop_preview()
  r.Undo_BeginBlock()
  local n = 0
  for _, it in ipairs(items) do
    if core.clear_take(it.take) then n = n + 1 end
    it.staged.angle_l, it.staged.angle_r = 0, 0
  end
  r.Undo_EndBlock("Phase Rotation: reset", -1)
  S.adaptive = false; S.ap = core.ap_copy(core.AP_OFF)
  invalidate_analyses()
  r.UpdateArrange()
  set_status(string.format("Reset %d item(s) to the original", n))
end

-- send the staged settings to the audition path (source engine: playback-only override;
-- take-FX engine: the FX parameters themselves, restored when the preview stops)
push_preview = function()
  if not preview.on then return end
  for _, e in ipairs(items) do
    if HAS_PREVIEW then
      core.ext_preview(e.take, staged_state(e))
    elseif MODE == "fx" then
      preview.restore = preview.restore or {}
      local key = tostring(e.take)
      if preview.restore[key] == nil then
        local fx = core.find_fx(e.take)
        preview.restore[key] = fx >= 0 and core.get_state(e.take, fx) or false
      end
      core.set_take_state(e.take, staged_state(e))
    end
  end
end

local function start_preview()
  local e = items[cur]
  if not e then return end
  stop_preview()
  preview.on = true
  preview.cursor = r.GetCursorPosition()
  preview.item = e.item
  local pos = r.GetMediaItemInfo_Value(e.item, "D_POSITION")
  preview.stop_at = pos + r.GetMediaItemInfo_Value(e.item, "D_LENGTH")
  if S.solo_preview then
    preview.solo = {}
    local tr = r.GetMediaItem_Track(e.item)
    for i = 0, r.CountTracks(0) - 1 do
      local t = r.GetTrack(0, i)
      preview.solo[t] = r.GetMediaTrackInfo_Value(t, "I_SOLO")
      r.SetMediaTrackInfo_Value(t, "I_SOLO", t == tr and 2 or 0)
    end
  end
  push_preview()
  r.SetEditCurPos(pos, false, false)
  r.OnPlayButton()
end

local function tick_preview()
  if not preview.on then return end
  local ps = r.GetPlayState()
  if ps & 1 == 0 or r.GetPlayPosition() >= preview.stop_at - 0.02 then stop_preview() end
end

local function do_render()   -- take-FX mode only: bake the FX into a new take
  if #items == 0 or MODE ~= "fx" then return end
  stop_preview()
  local list = {}
  for _, e in ipairs(items) do list[#list + 1] = e.item end
  local n = core.render(list, { keep_original = S.keep_original })
  for _, e in ipairs(items) do cache[e.guid .. tostring(e.take)] = nil end
  refresh_items(true)
  set_status(n > 0 and string.format("Rendered %d item(s)%s", n, S.keep_original and " (original kept as a take)" or "")
    or "Nothing to render: apply a rotation first")
end

-- a staged change happened: instant mode applies it, a running preview hears it
local last_push = 0
local function staged_changed(undo_name, final)
  if S.instant then
    if final then apply_all(undo_name) end
  elseif preview.on then
    local now = r.time_precise()
    if final or now - last_push > 0.06 then push_preview(); last_push = now end
  end
end

local function set_link(v)
  S.link = v; save_settings()
  if v then for _, e in ipairs(items) do e.staged.angle_r = e.staged.angle_l end end
  staged_changed("Phase Rotation: link", true)
end
local function toggle_link() set_link(not S.link) end

local function set_adaptive(v)
  S.adaptive = v
  staged_changed("Phase Rotation: adaptive", true)
end

local drag_undo = false
local function set_angle(e, which, v, final)
  v = max(-180, min(180, v))
  if S.link then e.staged.angle_l, e.staged.angle_r = v, v
  elseif which == "l" then e.staged.angle_l = v else e.staged.angle_r = v end
  if S.instant then
    if not drag_undo then r.Undo_BeginBlock(); drag_undo = true end
    set_state(e, staged_state(e))
    if final then r.Undo_EndBlock("Phase Rotation: set rotation", -1); drag_undo = false; r.UpdateArrange() end
  else
    staged_changed(nil, final)
  end
end

local function set_rotator(ap)
  S.ap = core.ap_copy(ap)
  invalidate_analyses()
  staged_changed("Phase Rotation: rotator type", true)
end

-- --------------------------------------------------------------------- gfx
local sc = 1
local BASE_W, BASE_H, PLOT_W = 640, 290, 170
local W, H = BASE_W, BASE_H
local mouse = { x = 0, y = 0, down = false, pdown = false, dbl = false, last_click = 0, cap = 0, wheel = 0 }
local active_id, hot_id = nil, nil
local drag = nil
local last_slider_apply = 0

local C = {
  bg = { 0.20, 0.21, 0.24 }, panel = { 0.25, 0.26, 0.30 }, line = { 0.33, 0.35, 0.40 },
  text = { 0.92, 0.93, 0.95 }, dim = { 0.60, 0.62, 0.66 }, accent = { 0.40, 0.75, 0.98 },
  accent2 = { 0.98, 0.72, 0.35 }, btn = { 0.31, 0.33, 0.38 }, btn_hot = { 0.38, 0.40, 0.46 },
  btn_on = { 0.24, 0.50, 0.72 }, good = { 0.45, 0.80, 0.55 }, primary = { 0.30, 0.58, 0.82 }, primary_hot = { 0.36, 0.64, 0.88 },
  warn = { 0.85, 0.55, 0.25 }, warn_hot = { 0.92, 0.62, 0.32 },
}
local function mix(c, bgc, a) return { c[1] * a + bgc[1] * (1 - a), c[2] * a + bgc[2] * (1 - a), c[3] * a + bgc[3] * (1 - a) } end
local function col(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
local function font(sz, flags) gfx.setfont(1, "Arial", floor(sz * sc + 0.5), flags or 0) end
local function rect(x, y, w, h, fill) gfx.rect(x * sc, y * sc, w * sc, h * sc, fill ~= false and 1 or 0) end
local function rrect(x, y, w, h, rad)   -- opaque only (overlapping primitives)
  x, y, w, h, rad = x * sc, y * sc, w * sc, h * sc, rad * sc
  gfx.rect(x + rad, y, w - 2 * rad, h, 1)
  gfx.rect(x, y + rad, w, h - 2 * rad, 1)
  gfx.circle(x + rad, y + rad, rad, 1, 1); gfx.circle(x + w - rad - 1, y + rad, rad, 1, 1)
  gfx.circle(x + rad, y + h - rad - 1, rad, 1, 1); gfx.circle(x + w - rad - 1, y + h - rad - 1, rad, 1, 1)
end
local function line(x1, y1, x2, y2) gfx.line(x1 * sc, y1 * sc, x2 * sc, y2 * sc, 1) end
local function text(x, y, s, w, h, flags)
  gfx.x, gfx.y = x * sc, y * sc
  if w then gfx.drawstr(s, flags or 0, (x + w) * sc, (y + (h or 20)) * sc) else gfx.drawstr(s) end
end
-- Truncates s with an ellipsis so it fits into wmax (logical pixels); uses the current font.
local function fit_text(s, wmax)
  if gfx.measurestr(s) / sc <= wmax then return s end
  local n = #s
  while n > 1 do
    n = n - 1
    local nb = s:byte(n + 1)
    if nb < 0x80 or nb >= 0xC0 then -- do not cut inside a UTF-8 sequence
      local t = s:sub(1, n):gsub("%s+$", "") .. "…"
      if gfx.measurestr(t) / sc <= wmax then return t end
    end
  end
  return s
end
local function inside(x, y, w, h) return mouse.x >= x and mouse.x < x + w and mouse.y >= y and mouse.y < y + h end

local function button(id, x, y, w, h, label, o)
  o = o or {}
  local bgc = o.bar and C.panel or C.bg
  local hot = inside(x, y, w, h) and not busy and not o.disabled
  if hot then hot_id = id end
  local clicked = false
  if hot and mouse.down and not mouse.pdown then active_id = id end
  if active_id == id and not mouse.down then
    if hot then clicked = true end
    active_id = nil
  end
  local c = o.on and C.btn_on or (o.warn and C.warn or (o.primary and C.primary or C.btn))
  if hot then c = o.on and { 0.28, 0.56, 0.80 } or (o.warn and C.warn_hot or (o.primary and C.primary_hot or C.btn_hot)) end
  if active_id == id then c = { c[1] * 0.8, c[2] * 0.8, c[3] * 0.8 } end
  if o.disabled then c = mix(c, bgc, 0.45) end
  col(c); rrect(x, y, w, h, 6)
  col(o.disabled and mix(C.text, bgc, 0.45) or C.text)
  font(14)
  text(x, y, label, w, h, 1 | 4)
  return clicked
end

local function checkbox(id, x, y, label, value, disabled)
  local w = 18
  font(15)
  local tw = gfx.measurestr(label) / sc
  local hot = inside(x, y - 2, w + 8 + tw, 22) and not busy and not disabled
  local clicked = false
  if hot and mouse.down and not mouse.pdown then active_id = id end
  if active_id == id and not mouse.down then
    if hot then clicked = true end
    active_id = nil
  end
  col(disabled and mix(C.btn, C.bg, 0.5) or (hot and C.btn_hot or C.btn)); rrect(x, y, w, w, 4)
  if value then col(disabled and mix(C.accent, C.bg, 0.5) or C.accent); rrect(x + 4, y + 4, w - 8, w - 8, 2) end
  col(disabled and mix(C.text, C.bg, 0.5) or C.text)
  text(x + w + 8, y - 1, label)
  return clicked
end

-- returns changed, value, final (final = mouse released / wheel / double click)
local function slider(id, x, y, w, value, disabled, mark)
  local h = 22
  local hot = inside(x - 4, y, w + 8, h) and not busy and not disabled
  local changed, newv, final = false, value, false
  if hot and mouse.down and not mouse.pdown then
    active_id = id
    drag = { id = id, start_v = value, start_x = mouse.x }
    if mouse.dbl then newv = 0; changed = true; final = true; drag = nil; active_id = nil end
  end
  if active_id == id and drag and drag.id == id then
    local fine = (mouse.cap & 8) == 8
    if fine then newv = drag.start_v + (mouse.x - drag.start_x) * 0.1
    else newv = (mouse.x - x) / w * 360 - 180 end
    newv = floor(max(-180, min(180, newv)) * 10 + 0.5) / 10
    if not mouse.down then
      active_id = nil; drag = nil; changed = true; final = true
    else
      changed = newv ~= value
    end
  elseif hot and mouse.wheel ~= 0 then
    local step = (mouse.cap & 8) == 8 and 0.1 or 1
    newv = max(-180, min(180, floor((value + (mouse.wheel > 0 and step or -step)) * 10 + 0.5) / 10))
    changed = newv ~= value; final = true
    mouse.wheel = 0
  end
  -- draw
  col(disabled and mix(C.line, C.bg, 0.5) or C.line); rrect(x, y + h / 2 - 3, w, 6, 3)
  local cx = x + w / 2
  local kx = x + (newv + 180) / 360 * w
  col(disabled and mix(C.accent, C.bg, 0.4) or C.accent)
  if kx > cx then rrect(cx, y + h / 2 - 3, kx - cx, 6, 3) else rrect(kx, y + h / 2 - 3, cx - kx, 6, 3) end
  col(C.dim, 0.7); line(cx, y + 2, cx, y + h - 2)
  if mark then   -- applied value
    local mx = x + (mark + 180) / 360 * w
    col(C.accent2, 0.9); line(mx, y + 1, mx, y + h - 1)
  end
  col(disabled and mix(C.text, C.bg, 0.5) or C.text)
  gfx.circle(kx * sc, (y + h / 2) * sc, 8 * sc, 1, 1)
  col(C.bg); gfx.circle(kx * sc, (y + h / 2) * sc, 3 * sc, 1, 1)
  return changed, newv, final
end

local function value_box(id, x, y, w, h, v, disabled, fmt)
  local hot = inside(x, y, w, h) and not busy and not disabled
  local clicked = false
  if hot and mouse.down and not mouse.pdown then active_id = id end
  if active_id == id and not mouse.down then
    if hot then clicked = true end
    active_id = nil
  end
  col(C.panel); rrect(x, y, w, h, 4)
  col(hot and C.accent or C.line, 0.9); gfx.roundrect(x * sc, y * sc, w * sc, h * sc, 4 * sc, 1)
  col(disabled and mix(C.text, C.panel, 0.6) or C.text)
  font(15)
  text(x, y, string.format(fmt or "%+.1f", v), w, h, 1 | 4)
  return clicked
end

local function draw_plot(x, y, size, e)
  local res = e and e.res
  col(C.panel); rrect(x, y, size, size, 8)
  local cx, cy, R = x + size / 2, y + size / 2, size / 2 - 10
  col(C.line, 0.8)
  gfx.circle(cx * sc, cy * sc, R * sc, 0, 1)
  gfx.circle(cx * sc, cy * sc, R * sc / 2, 0, 1)
  line(cx - R, cy, cx + R, cy); line(cx, cy - R, cx, cy + R)
  if not res then
    col(C.dim); font(12); text(x, cy - 8, "no analysis yet", size, 16, 1)
    return
  end
  local shape, mx = {}, 0
  for d = 1, 360 do
    local v = res.channels[1].shape[d] or 0
    if res.nch >= 2 then v = max(v, res.channels[2].shape[d] or 0) end
    shape[d] = v
    if v > mx then mx = v end
  end
  if mx <= 0 then return end
  local al, ar = e.staged.angle_l, e.staged.angle_r
  local theta = (al + (res.nch >= 2 and ar or al)) / 2
  local function poly(rot, c, a)
    col(c, a)
    local px, py
    for d = 0, 360 do
      local i = d % 360
      local ang = (i + 0.5 + rot) * math.pi / 180
      local rr = shape[i + 1] / mx * R
      local qx, qy = cx + rr * cos(ang), cy - rr * sin(ang)
      if px then line(px, py, qx, qy) end
      px, py = qx, qy
    end
  end
  poly(0, C.dim, 0.55)
  poly(theta, C.accent, 1)
  local pb, nb = 0, 0
  for c = 1, res.nch do pb = max(pb, res.channels[c].pos_before); nb = max(nb, res.channels[c].neg_before) end
  col(C.dim, 0.6); line(cx + pb / mx * R, y + 6, cx + pb / mx * R, y + size - 6); line(cx - nb / mx * R, y + 6, cx - nb / mx * R, y + size - 6)
  local pa, na = 0, 0
  for c = 1, res.nch do
    local p_, n_ = core.peaks_after_shape(res.channels[c].shape, theta)
    pa, na = max(pa, p_), max(na, n_)
  end
  col(C.accent2, 0.9); line(cx + pa / mx * R, y + 6, cx + pa / mx * R, y + size - 6); line(cx - na / mx * R, y + 6, cx - na / mx * R, y + size - 6)
end

local function draw_progress()
  if not busy then return end
  col({ 0, 0, 0 }, 0.55); rect(0, 0, W, H)
  col(C.panel); rrect(W / 2 - 160, H / 2 - 34, 320, 68, 8)
  col(C.text); font(15); text(W / 2 - 160, H / 2 - 28, busy.text, 320, 20, 1)
  col(C.line); rrect(W / 2 - 140, H / 2 + 4, 280, 12, 6)
  col(C.accent); rrect(W / 2 - 140, H / 2 + 4, max(12, 280 * (busy.frac or 0)), 12, 6)
end

local function resize_window()
  local want = BASE_W + (S.show_plot and PLOT_W or 0)
  gfx.init("", want * sc, H * sc)
end

local function open_url(url)
  if r.CF_ShellExecute then r.CF_ShellExecute(url)
  else
    local os_name = r.GetOS()
    if os_name:match("^Win") then os.execute('start "" "' .. url .. '"')
    elseif os_name:match("^OSX") or os_name:match("^macOS") then os.execute('open "' .. url .. '"')
    else os.execute('xdg-open "' .. url .. '" &') end
  end
end

local function open_settings_menu()
  local m = {
    ">Suggest criterion",
    (S.criterion == "rx" and "!" or "") .. "RX-compatible (minimise sum |y|^8, same numbers as iZotope RX)",
    "<" .. (S.criterion == "peak" and "!" or "") .. "Minimum sample peak (most headroom)",
    ">Adaptive smoothing",
    (S.smooth == 0 and "!" or "") .. "Off",
    (S.smooth == 1 and "!" or "") .. "Light (median of 3 blocks)",
    "<" .. (S.smooth == 2 and "!" or "") .. "Strong (median of 5 blocks)",
    (S.solo_preview and "!" or "") .. "Preview: solo the item's track",
    (S.instant and "!" or "") .. "Apply changes instantly (no Apply button, waveform follows the sliders)",
    (S.show_plot and "!" or "") .. "Show phase plot (envelope vs phase)",
  }
  if MODE == "fx" then
    m[#m + 1] = (S.keep_original and "!" or "") .. "Render: keep the original as a take (uncheck to crop to the rendered take)"
    m[#m + 1] = "Open JSFX window for this item"
  end
  m[#m + 1] = "|About / GitHub page"
  gfx.x, gfx.y = mouse.x * sc, mouse.y * sc
  local sel = gfx.showmenu(table.concat(m, "|"))
  local nfixed = 8
  if sel == 1 or sel == 2 then S.criterion = sel == 1 and "rx" or "peak"
  elseif sel >= 3 and sel <= 5 then S.smooth = sel - 3; staged_changed("Phase Rotation: adaptive smoothing", true)
  elseif sel == 6 then S.solo_preview = not S.solo_preview
  elseif sel == 7 then
    S.instant = not S.instant
    if S.instant and any_dirty() then apply_all("Phase Rotation: apply") end
  elseif sel == 8 then S.show_plot = not S.show_plot; resize_window()
  elseif MODE == "fx" and sel == nfixed + 1 then S.keep_original = not S.keep_original
  elseif MODE == "fx" and sel == nfixed + 2 then
    local e = items[cur]
    if e then local fx = core.ensure_fx(e.take) if fx >= 0 then r.TakeFX_Show(e.take, fx, 3) end end
  elseif (MODE == "fx" and sel == nfixed + 3) or (MODE ~= "fx" and sel == nfixed + 1) then
    open_url("https://github.com/dennech/reaper-phase-rotation")
  end
  save_settings()
end

local function ap_short(ap)
  ap = core.ap_copy(ap)
  if ap.type == 0 then return "RX-style" end
  local i = core.ap_preset_index(ap)
  if i == 3 then return "Orban 4 × 200 Hz" end
  if i == 5 then return "VoicePhaseRotator 8 × 200 Hz" end
  if ap.type == 1 then return string.format("Allpass %d × %.0f Hz", ap.stages, ap.freq) end
  return string.format("Allpass %d × %.0f Hz Q %.2f", ap.stages, ap.freq, ap.q)
end

local function open_rotator_menu()
  local m = {}
  local cur_i = core.ap_preset_index(S.ap)
  for i, p in ipairs(core.AP_PRESETS) do
    m[#m + 1] = (cur_i == i and "!" or "") .. p.name
    if i == 1 then m[#m] = m[#m] .. "|" end   -- separator after "RX-style only"
  end
  m[#m + 1] = ((not cur_i and core.ap_on(S.ap)) and "!" or "") .. "Custom allpass..."
  gfx.x, gfx.y = mouse.x * sc, mouse.y * sc
  local sel = gfx.showmenu(table.concat(m, "|"))
  if sel >= 1 and sel <= #core.AP_PRESETS then
    set_rotator(core.AP_PRESETS[sel])
  elseif sel == #core.AP_PRESETS + 1 then
    local ap = core.ap_copy(core.ap_on(S.ap) and S.ap or core.AP_PRESETS[3])
    local okv, s = r.GetUserInputs("Custom allpass rotator", 4, "Section order (1 or 2),Stages (1-16),Frequency (Hz),Q (2nd order only)",
      string.format("%d,%d,%.0f,%.2f", ap.type == 2 and 2 or 1, ap.stages, ap.freq, ap.q))
    if okv then
      local t = {}
      for v in s:gmatch("[^,]+") do t[#t + 1] = tonumber(v) end
      if #t >= 3 then
        set_rotator({ type = (t[1] or 1) >= 2 and 2 or 1, stages = max(1, min(16, floor((t[2] or 4) + 0.5))),
                      freq = max(20, min(2000, t[3] or 200)), q = max(0.1, min(10, t[4] or 0.35)) })
      end
    end
  end
  save_settings()
end

draw = function()
  col(C.bg); rect(0, 0, W, H)
  local e = items[cur]
  local st = e and take_state(e) or nil
  local no_items = #items == 0
  local dirty = e and is_dirty(e) or false
  local any_dirty_now = any_dirty()

  -- header row: Suggest, rotator type, item navigation, settings
  if button("suggest", 16, 16, 112, 32, "Suggest", { primary = true, disabled = no_items }) then do_suggest() end
  if button("rotator", 140, 16, 250, 32, "Rotator ▾   " .. ap_short(S.ap), { disabled = no_items, on = core.ap_on(S.ap) }) then open_rotator_menu() end
  font(13); col(C.dim)
  local nav_x = BASE_W
  if #items > 1 then
    text(nav_x - 214, 24, string.format("Item %d / %d", cur, #items), 90, 20, 1 | 4)
    if button("prev", nav_x - 120, 18, 28, 28, "<", {}) then cur = cur > 1 and cur - 1 or #items end
    if button("next", nav_x - 88, 18, 28, 28, ">", {}) then cur = cur < #items and cur + 1 or 1 end
  end
  if button("settings", nav_x - 52, 18, 36, 28, "...", {}) then open_settings_menu() end

  -- sliders (staged values; the orange tick marks the applied value)
  local disabled = no_items or S.adaptive
  local al, ar = e and e.staged.angle_l or 0, e and e.staged.angle_r or 0
  local stereo = e and e.info.nch >= 2
  font(15); col(C.dim)
  text(16, 64, "Left rotation [°]")
  text(322, 64, stereo and "Right rotation [°]" or "Right rotation [°]  (mono item)")
  local chg, nv, fin = slider("sl_l", 16, 88, 176, al, disabled, st and not st.adaptive and st.angle_l or nil)
  if chg and e then
    local now = r.time_precise()
    if fin or now - last_slider_apply > 0.06 then set_angle(e, "l", nv, fin); last_slider_apply = now end
  end
  if value_box("vb_l", 200, 88, 58, 22, al, disabled) and e then
    local okv, s = r.GetUserInputs("Left rotation", 1, "Degrees (-180 .. 180)", string.format("%.1f", al))
    if okv and tonumber(s) then set_angle(e, "l", tonumber(s), true) end
  end
  if button("link", 266, 86, 46, 26, "Link", { on = S.link, disabled = no_items }) then toggle_link() end
  local disabled_r = disabled or not stereo
  chg, nv, fin = slider("sl_r", 322, 88, 176, ar, disabled_r, st and stereo and not st.adaptive and st.angle_r or nil)
  if chg and e then
    local now = r.time_precise()
    if fin or now - last_slider_apply > 0.06 then set_angle(e, "r", nv, fin); last_slider_apply = now end
  end
  if value_box("vb_r", 506, 88, 58, 22, ar, disabled_r) and e then
    local okv, s = r.GetUserInputs("Right rotation", 1, "Degrees (-180 .. 180)", string.format("%.1f", ar))
    if okv and tonumber(s) then set_angle(e, "r", tonumber(s), true) end
  end

  -- adaptive
  if checkbox("adaptive", 16, 126, "Adaptive phase rotation", S.adaptive, no_items) then set_adaptive(not S.adaptive) end

  -- info block
  font(14)
  if e then
    local inf = e.info
    local name = inf.name ~= "" and inf.name or "(unnamed take)"
    col(C.text); text(16, 158, fit_text(string.format("%s   ·   %s", name, inf.nch >= 2 and "stereo" or "mono"), BASE_W - 32))
    if e.res and not S.adaptive then
      local res = e.res
      local pa_pos, pa_neg = 0, 0
      for c = 1, res.nch do
        local p, n = core.peaks_after_shape(res.channels[c].shape, c == 1 and al or ar)
        pa_pos, pa_neg = max(pa_pos, p), max(pa_neg, n)
      end
      local pa = max(pa_pos, pa_neg)
      local before = res.peak_orig or res.peak_before
      local gain = core.db(before) - core.db(pa)
      col(C.dim); text(16, 180, "Peak")
      col(C.text); text(56, 180, string.format("%s dBFS  →  %s dBFS", core.fmt_db(before), core.fmt_db(pa)))
      col(gain > 0.05 and C.good or (gain < -0.05 and C.accent2 or C.dim)); text(230, 180, string.format("%+.2f dB", gain))
    elseif e.res and S.adaptive then
      col(C.dim); text(16, 180, "Adaptive: the angle follows the signal (about every 43 ms)")
    else
      col(C.dim); text(16, 180, "Press Suggest to analyze, or set a rotation by hand")
    end
    -- state line
    local msg, c
    if not st then
      if dirty then msg, c = "Not applied yet  ·  Preview to audition, Apply to commit", C.accent2
      else msg, c = "Original (nothing applied)", C.dim end
    elseif not st.enabled then msg, c = "Bypassed  ·  the original plays", C.accent2
    elseif dirty then msg, c = "Applied  ·  settings changed, press Apply to update", C.accent2
    else msg, c = MODE == "source" and "Applied to the source  ·  non-destructive" or "Applied as take FX", C.accent end
    col(c); text(16, 202, msg)
  else
    col(C.dim); text(16, 158, "Select one or more audio items in the arrange view.")
  end

  if S.show_plot and W >= BASE_W + PLOT_W - 10 then
    draw_plot(W - 168, 60, 152, e)
    font(11); col(C.dim); text(W - 168, 216, "envelope vs phase", 152, 14, 1); text(W - 168, 229, "grey = original · blue = staged", 152, 14, 1)
  end

  -- bottom bar
  col(C.panel); rect(0, H - 60, W, 60)
  local has = st ~= nil
  if button("preview", 16, H - 48, 90, 32, preview.on and "Stop" or "Preview", { on = preview.on, disabled = no_items, bar = true }) then
    if preview.on then stop_preview() else start_preview() end
  end
  if button("bypass", 112, H - 48, 80, 32, "Bypass", { on = st and not st.enabled, disabled = not has, bar = true }) then do_bypass() end
  if not S.instant then
    if button("apply", 198, H - 48, 96, 32, "Apply", { primary = true, warn = any_dirty_now, disabled = no_items or not any_dirty_now, bar = true }) then do_apply() end
    if button("revert", 300, H - 48, 76, 32, "Revert", { disabled = no_items or not any_dirty_now, bar = true }) then do_revert() end
  end
  local reset_x = S.instant and 198 or 382
  if button("remove", reset_x, H - 48, 80, 32, "Reset", { disabled = not has, bar = true }) then do_remove() end
  if MODE == "fx" then
    if button("render", W - 116, H - 48, 100, 32, "Render", { primary = true, disabled = not has, bar = true }) then do_render() end
  end
  font(12); col(C.dim)
  local right = MODE == "fx" and "take-FX engine · install reaper_phaserot for the waveform" or (S.instant and "instant apply" or "")
  if right ~= "" then text(W - 340, H - 14, right, 324, 14, 2) end
  if status ~= "" then
    text(16, H - 14, fit_text(status, W - 32 - (right ~= "" and 340 or 0)), W - 32, 14, 0)
  end
  draw_progress()
end

-- --------------------------------------------------------------------- loop
local function read_mouse()
  mouse.pdown = mouse.down
  mouse.cap = gfx.mouse_cap
  mouse.down = (mouse.cap & 1) == 1
  mouse.x, mouse.y = gfx.mouse_x / sc, gfx.mouse_y / sc
  mouse.dbl = false
  if mouse.down and not mouse.pdown then
    local t = r.time_precise()
    mouse.dbl = (t - mouse.last_click) < 0.35
    mouse.last_click = t
  end
  mouse.wheel = mouse.wheel + gfx.mouse_wheel
  gfx.mouse_wheel = 0
end

local function save_window()
  local d, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
  r.SetExtState(SECTION, "wnd", string.format("%d,%d,%d,%d,%d", d, x, y, w, h), true)
end

-- Optional automation hooks used by tests/gui_smoke.lua (env vars, ignored otherwise)
local TEST_ACTIONS = os.getenv("PHASE_ROTATION_TEST_ACTIONS")
local TEST_LOG = os.getenv("PHASE_ROTATION_TEST_LOG")
local test_queue = {}
if TEST_ACTIONS then for a in TEST_ACTIONS:gmatch("[^,]+") do test_queue[#test_queue + 1] = a end end
local function test_log(msg)
  if not TEST_LOG then return end
  local f = io.open(TEST_LOG, "a")
  if f then f:write(msg, "\n") f:close() end
end
local function dump_audio(e, path)
  local nch = e.info.nch
  local sr = floor(e.info.sr + 0.5)
  local n = floor(e.info.length * sr + 0.5)
  local acc = r.CreateTakeAudioAccessor(e.take)
  local buf = r.new_array(n * nch); buf.clear()
  r.GetAudioAccessorSamples(acc, sr, nch, 0, n, buf)
  r.DestroyAudioAccessor(acc)
  local t = buf.table()
  local f = assert(io.open(path, "wb"))
  local parts = {}
  for i = 1, #t do parts[#parts + 1] = string.pack("<f", t[i]) if #parts >= 65536 then f:write(table.concat(parts)); parts = {} end end
  f:write(table.concat(parts)); f:close()
  return nch, n
end
local function run_test_action(a)
  test_log("action " .. a .. " items=" .. #items .. " cur=" .. cur .. " mode=" .. MODE)
  if a == "suggest" then do_suggest()
  elseif a == "apply" then do_apply()
  elseif a == "revert" then do_revert()
  elseif a == "bypass" then do_bypass()
  elseif a == "render" then do_render()
  elseif a == "remove" then do_remove()
  elseif a == "link" then toggle_link()
  elseif a == "link_on" then set_link(true)
  elseif a == "link_off" then set_link(false)
  elseif a == "instant_on" then S.instant = true
  elseif a == "instant_off" then S.instant = false
  elseif a == "adaptive" then set_adaptive(not S.adaptive)
  elseif a == "next" then cur = cur < #items and cur + 1 or 1
  elseif a == "preview" then if preview.on then stop_preview() else start_preview() end
  elseif a:match("^angle=") then local e = items[cur] if e then set_angle(e, "l", tonumber(a:sub(7)), true) end
  elseif a:match("^rotator=") then local i = tonumber(a:sub(9)) set_rotator(core.AP_PRESETS[i] or core.AP_OFF)
  elseif a:match("^dumpaudio=") then
    local e = items[cur]
    if e then local nch, n = dump_audio(e, a:sub(11)) test_log(string.format("dumpaudio %s nch=%d n=%d", a:sub(11), nch, n)) end
  elseif a == "dump" then
    local e = items[cur]
    local st = e and take_state(e)
    test_log(string.format("dump cur=%d mode=%s staged=%s/%s ap=%s applied=%s adaptive=%s enabled=%s dirty=%s res=%s", cur, MODE,
      e and string.format("%.3f", e.staged.angle_l) or "-", e and string.format("%.3f", e.staged.angle_r) or "-", ap_short(S.ap),
      st and string.format("L=%.1f R=%.1f %s", st.angle_l, st.angle_r, ap_short(st.ap)) or "-",
      tostring(st and st.adaptive), tostring(st and st.enabled), tostring(e and is_dirty(e)),
      e and e.res and string.format("%.3f", e.res.linked.angle) or "-"))
  elseif a == "quit" then return "quit" end
end

local main
local function main_body()
  frame = frame + 1
  if frame == 1 or frame == 2 or frame == 14 then test_log("frame " .. frame) end
  if TEST_ACTIONS and frame % 15 == 0 and #test_queue > 0 then
    local a = table.remove(test_queue, 1)
    local okA, res = xpcall(run_test_action, debug.traceback, a)
    if not okA then test_log("ERROR " .. tostring(res)) return end
    if res == "quit" then test_log("quit") return end
  end
  if frame % 10 == 1 then refresh_items(false) end
  read_mouse()
  tick_preview()
  local ch = gfx.getchar()
  if ch == -1 or ch == 27 then return end
  if not busy then
    if ch == 32 then if preview.on then stop_preview() else start_preview() end
    elseif ch == 115 or ch == 83 then do_suggest()
    elseif ch == 98 or ch == 66 then do_bypass()
    elseif (ch == 97 or ch == 65) and not S.instant then do_apply() end
  end
  if gfx.w / sc ~= W or gfx.h / sc ~= H then W, H = max(600, gfx.w / sc), max(280, gfx.h / sc) end
  hot_id = nil
  if TEST_LOG then
    local okD, errD = xpcall(draw, debug.traceback)
    if not okD then test_log("ERROR " .. tostring(errD)) return end
  else
    draw()
  end
  mouse.wheel = 0
  gfx.update()
  r.defer(main)
end
main = function()
  if TEST_LOG then
    local okM, errM = xpcall(main_body, debug.traceback)
    if not okM then test_log("ERROR " .. tostring(errM)) end
  else
    main_body()
  end
end

local function init()
  test_log("init: mode=" .. MODE .. " items_selected=" .. r.CountSelectedMediaItems(0) .. " preview_api=" .. tostring(HAS_PREVIEW))
  gfx.ext_retina = 1
  W = BASE_W + (S.show_plot and PLOT_W or 0)
  local d, x, y, w, h = 0, -1, -1, W, H
  local saved = r.GetExtState(SECTION, "wnd")
  if saved ~= "" then
    local a = {}
    for v in saved:gmatch("-?%d+") do a[#a + 1] = tonumber(v) end
    if #a == 5 then d, x, y = a[1], a[2], a[3] end
  end
  if x < 0 then
    local _, _, sw, sh = r.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)
    x, y = floor((sw - W) / 2), floor((sh - H) / 2)
  end
  test_log(string.format("init: gfx.init dock=%d pos=%d,%d size=%dx%d", d, x, y, w, h))
  gfx.init(TITLE, w, h, d, x, y)
  test_log("init: gfx.init done, w=" .. gfx.w .. " h=" .. gfx.h .. " retina=" .. tostring(gfx.ext_retina))
  sc = gfx.ext_retina > 1 and gfx.ext_retina or 1
  if gfx.w / sc ~= W or gfx.h / sc ~= H then W, H = max(600, gfx.w / sc), max(280, gfx.h / sc) end
  refresh_items(true)
  test_log("init: refresh done, items=" .. #items)
  set_status(#items > 0 and "S = Suggest · Space = Preview · A = Apply" or "")
end

r.atexit(function()
  stop_preview()
  if HAS_PREVIEW then core.ext_clear_all_previews() end
  if drag_undo then r.Undo_EndBlock("Phase Rotation: set rotation", -1) end
  save_window()
  save_settings()
  gfx.quit()
end)
init()
main()
