-- @description Phase Rotation (RX-style): suggest, audition and apply broadband phase rotation to selected items
-- @author dennech
-- @version 1.1.2
-- @provides
--   [nomain] phase_rotation_core.lua
--   [effect] phase_rotation.jsfx
-- @link https://github.com/dennech/reaper-phase-rotation
-- @about
--   # Phase Rotation (RX-style)
--
--   A REAPER re-creation of the iZotope RX "Phase" module for media items:
--   Suggest (reproduces RX's own values), Left/Right rotation with Link,
--   Adaptive phase rotation, Preview / Bypass.
--
--   With the reaper_phaserot extension installed (recommended) the rotation is
--   applied to the item's source: no files are written, no FX is added, the
--   waveform display updates immediately, the project file stays a plain
--   project. Without the extension the bundled JSFX is used as a take FX.
--
--   Keys: S = Suggest, Space = Preview, B = Bypass, Esc = close.

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

-- ------------------------------------------------------------------ settings
local S = { link = true, adaptive = false, smooth = 0, keep_original = true, solo_preview = false, criterion = "rx" }
do
  local function getb(k, d) local v = r.GetExtState(SECTION, k) if v == "" then return d end return v == "1" end
  local function getn(k, d) local v = tonumber(r.GetExtState(SECTION, k)) return v or d end
  S.link = getb("link", true)
  S.adaptive = getb("adaptive", false)
  S.smooth = floor(getn("smooth", 0) + 0.5)
  S.keep_original = getb("keep_original", true)
  S.solo_preview = getb("solo_preview", false)
  S.criterion = r.GetExtState(SECTION, "criterion") == "peak" and "peak" or "rx"
end
local function save_settings()
  r.SetExtState(SECTION, "link", S.link and "1" or "0", true)
  r.SetExtState(SECTION, "adaptive", S.adaptive and "1" or "0", true)
  r.SetExtState(SECTION, "smooth", tostring(S.smooth), true)
  r.SetExtState(SECTION, "keep_original", S.keep_original and "1" or "0", true)
  r.SetExtState(SECTION, "solo_preview", S.solo_preview and "1" or "0", true)
  r.SetExtState(SECTION, "criterion", S.criterion, true)
end

-- --------------------------------------------------------------------- state
local items = {}          -- { item, guid, take, info, res, st }
local cur = 1
local cache = {}          -- guid..take -> analysis result
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
    e.res = cache[e.guid .. tostring(e.take)]
  end
  if cur > #items then cur = max(1, #items) end
end

local function take_state(e)
  e.st = core.get_take_state(e.take)
  return e.st
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

local function apply_mode_to_all()
  for _, e in ipairs(items) do
    if core.get_take_state(e.take) then core.set_take_state(e.take, { adaptive = S.adaptive, smooth = S.smooth, link = S.link }) end
  end
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
  r.Undo_BeginBlock()
  local t0 = r.time_precise()
  local errs = 0
  for i, e in ipairs(items) do
    busy = { text = string.format("Analyzing item %d of %d ...", i, #items), frac = 0 }
    draw(); gfx.update()
    local res, err = core.analyze_any(e.take, { criterion = S.criterion }, function(f) busy.frac = f; draw(); gfx.update() end)
    if res then
      e.res = res
      cache[e.guid .. tostring(e.take)] = res
      local al, ar = angles_from_result(res)
      set_state(e, { link = S.link, adaptive = S.adaptive, smooth = S.smooth, angle_l = al, angle_r = ar, enabled = true })
    else
      errs = errs + 1
      set_status("Analysis failed: " .. tostring(err))
    end
  end
  busy = nil
  r.Undo_EndBlock("Phase Rotation: suggest", -1)
  r.UpdateArrange()
  if errs == 0 then
    set_status(string.format("Suggested rotation for %d item(s) in %.2f s%s", #items, r.time_precise() - t0,
      MODE == "source" and " · applied to the source" or " · applied as take FX"))
  end
end

local function do_bypass()
  local e = items[cur]
  if not e then return end
  local st = take_state(e)
  local new_enabled = not (st and st.enabled)
  r.Undo_BeginBlock()
  for _, it in ipairs(items) do
    if core.get_take_state(it.take) then core.set_take_state(it.take, { enabled = new_enabled }) end
  end
  r.Undo_EndBlock(new_enabled and "Phase Rotation: enable" or "Phase Rotation: bypass", -1)
  r.UpdateArrange()
  set_status(new_enabled and "Phase rotation active" or "Bypassed")
end

local function do_remove()
  r.Undo_BeginBlock()
  local n = 0
  for _, it in ipairs(items) do if core.clear_take(it.take) then n = n + 1 end end
  r.Undo_EndBlock("Phase Rotation: reset", -1)
  r.UpdateArrange()
  set_status(string.format("Reset %d item(s) to the original", n))
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
  preview = { on = false }
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
    or "Nothing to render: press Suggest or move a slider first")
end

local function set_link(v)
  S.link = v; save_settings()
  r.Undo_BeginBlock()
  for _, it in ipairs(items) do
    local s2 = core.get_take_state(it.take)
    if s2 then core.set_take_state(it.take, { link = S.link, angle_l = s2.angle_l, angle_r = S.link and s2.angle_l or s2.angle_r }) end
  end
  r.Undo_EndBlock("Phase Rotation: link", -1); r.UpdateArrange()
end
local function toggle_link() set_link(not S.link) end

local drag_undo = false
local function set_angle(e, which, v, final)
  v = max(-180, min(180, v))
  local st = { link = S.link }
  if not take_state(e) then st.adaptive = S.adaptive; st.smooth = S.smooth end
  if S.link then st.angle_l, st.angle_r = v, v
  elseif which == "l" then st.angle_l = v else st.angle_r = v end
  if not drag_undo then r.Undo_BeginBlock(); drag_undo = true end
  set_state(e, st)
  if final then r.Undo_EndBlock("Phase Rotation: set rotation", -1); drag_undo = false; r.UpdateArrange() end
end

-- --------------------------------------------------------------------- gfx
local sc = 1
local W, H = 760, 330
local mouse = { x = 0, y = 0, down = false, pdown = false, dbl = false, last_click = 0, cap = 0, wheel = 0 }
local active_id, hot_id = nil, nil
local drag = nil
local last_slider_apply = 0

local C = {
  bg = { 0.20, 0.21, 0.24 }, panel = { 0.25, 0.26, 0.30 }, line = { 0.33, 0.35, 0.40 },
  text = { 0.92, 0.93, 0.95 }, dim = { 0.60, 0.62, 0.66 }, accent = { 0.40, 0.75, 0.98 },
  accent2 = { 0.98, 0.72, 0.35 }, btn = { 0.31, 0.33, 0.38 }, btn_hot = { 0.38, 0.40, 0.46 },
  btn_on = { 0.24, 0.50, 0.72 }, good = { 0.45, 0.80, 0.55 }, primary = { 0.30, 0.58, 0.82 }, primary_hot = { 0.36, 0.64, 0.88 },
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
  local c = o.on and C.btn_on or (o.primary and C.primary or C.btn)
  if hot then c = o.on and { 0.28, 0.56, 0.80 } or (o.primary and C.primary_hot or C.btn_hot) end
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
local function slider(id, x, y, w, value, disabled)
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

local function fmt_time(sec)
  local m = floor(sec / 60)
  return string.format("%d:%05.2f", m, sec - m * 60)
end

local function current_angles(e, st, res)
  local live = st and st.mode == "fx" and st.adaptive
  local al = st and (live and st.cur_l or st.angle_l) or (res and select(1, angles_from_result(res)) or 0)
  local ar = st and (live and st.cur_r or st.angle_r) or (res and select(2, angles_from_result(res)) or 0)
  return al, ar
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
  local st = e.st
  local al, ar = current_angles(e, st, res)
  local theta = (st and st.enabled ~= false) and (al + (res.nch >= 2 and ar or al)) / 2 or 0
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
  -- vertical guides = positive / negative peak before (grey) and now (orange)
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
  }
  if MODE == "fx" then
    m[#m + 1] = (S.keep_original and "!" or "") .. "Render: keep the original as a take (uncheck to crop to the rendered take)"
    m[#m + 1] = "Open JSFX window for this item"
  end
  m[#m + 1] = "|About / GitHub page"
  gfx.x, gfx.y = mouse.x * sc, mouse.y * sc
  local sel = gfx.showmenu(table.concat(m, "|"))
  if sel == 1 or sel == 2 then S.criterion = sel == 1 and "rx" or "peak"
  elseif sel >= 3 and sel <= 5 then S.smooth = sel - 3; apply_mode_to_all()
  elseif sel == 6 then S.solo_preview = not S.solo_preview
  elseif MODE == "fx" and sel == 7 then S.keep_original = not S.keep_original
  elseif MODE == "fx" and sel == 8 then
    local e = items[cur]
    if e then local fx = core.ensure_fx(e.take) if fx >= 0 then r.TakeFX_Show(e.take, fx, 3) end end
  elseif (MODE == "fx" and sel == 9) or (MODE ~= "fx" and sel == 7) then
    local url = "https://github.com/dennech/reaper-phase-rotation"
    if r.CF_ShellExecute then r.CF_ShellExecute(url)
    else
      local os_name = r.GetOS()
      if os_name:match("^Win") then os.execute('start "" "' .. url .. '"')
      elseif os_name:match("^OSX") or os_name:match("^macOS") then os.execute('open "' .. url .. '"')
      else os.execute('xdg-open "' .. url .. '" &') end
    end
  end
  save_settings()
end

draw = function()
  col(C.bg); rect(0, 0, W, H)
  local e = items[cur]
  local st = e and take_state(e) or nil
  local no_items = #items == 0
  local adaptive_live = st and st.adaptive and st.mode == "fx"

  -- header row
  if button("suggest", 16, 16, 112, 32, "Suggest", { primary = true, disabled = no_items }) then do_suggest() end
  if checkbox("adaptive", 146, 22, "Adaptive phase rotation", S.adaptive, no_items) then
    S.adaptive = not S.adaptive; save_settings()
    r.Undo_BeginBlock(); apply_mode_to_all(); r.Undo_EndBlock("Phase Rotation: adaptive", -1); r.UpdateArrange()
  end
  font(13); col(C.dim)
  if #items > 1 then
    text(W - 214, 24, string.format("Item %d / %d", cur, #items), 90, 20, 1 | 4)
    if button("prev", W - 120, 18, 28, 28, "<", {}) then cur = cur > 1 and cur - 1 or #items end
    if button("next", W - 88, 18, 28, 28, ">", {}) then cur = cur < #items and cur + 1 or 1 end
  end
  if button("settings", W - 52, 18, 36, 28, "...", {}) then open_settings_menu() end

  -- sliders
  local disabled = no_items or (st and st.adaptive) or false
  local al, ar = current_angles(e, st, e and e.res)
  local stereo = e and e.info.nch >= 2
  font(15); col(C.dim)
  text(16, 72, "Left rotation [°]")
  text(322, 72, stereo and "Right rotation [°]" or "Right rotation [°]  (mono item)")
  local chg, nv, fin = slider("sl_l", 16, 96, 176, al, disabled)
  if chg and e then
    local now = r.time_precise()
    if fin or now - last_slider_apply > 0.06 then set_angle(e, "l", nv, fin); last_slider_apply = now end
  end
  if value_box("vb_l", 200, 96, 58, 22, al, disabled) and e then
    local okv, s = r.GetUserInputs("Left rotation", 1, "Degrees (-180 .. 180)", string.format("%.1f", al))
    if okv and tonumber(s) then set_angle(e, "l", tonumber(s), true) end
  end
  if button("link", 266, 94, 46, 26, "Link", { on = S.link, disabled = no_items }) then toggle_link() end
  local disabled_r = disabled or not stereo
  chg, nv, fin = slider("sl_r", 322, 96, 176, ar, disabled_r)
  if chg and e then
    local now = r.time_precise()
    if fin or now - last_slider_apply > 0.06 then set_angle(e, "r", nv, fin); last_slider_apply = now end
  end
  if value_box("vb_r", 506, 96, 58, 22, ar, disabled_r) and e then
    local okv, s = r.GetUserInputs("Right rotation", 1, "Degrees (-180 .. 180)", string.format("%.1f", ar))
    if okv and tonumber(s) then set_angle(e, "r", tonumber(s), true) end
  end

  -- info block
  font(14)
  if e then
    local inf = e.info
    col(C.text)
    local name = inf.name ~= "" and inf.name or "(unnamed take)"
    if #name > 48 then name = name:sub(1, 46) .. "…" end
    text(16, 146, string.format("%s   ·   %s   ·   %d Hz   ·   %s", name, inf.nch >= 2 and "stereo" or "mono", floor(inf.sr + 0.5), fmt_time(inf.length)))
    if e.res then
      local res = e.res
      local pa_pos, pa_neg = 0, 0
      for c = 1, res.nch do
        local p, n = core.peaks_after_shape(res.channels[c].shape, c == 1 and al or ar)
        pa_pos, pa_neg = max(pa_pos, p), max(pa_neg, n)
      end
      local pa = max(pa_pos, pa_neg)
      local gain = core.db(res.peak_before) - core.db(pa)
      col(C.dim); text(16, 170, "Peak")
      col(C.text); text(60, 170, string.format("%s dBFS  →  %s dBFS", core.fmt_db(res.peak_before), core.fmt_db(pa)))
      col(gain > 0.05 and C.good or C.dim); text(250, 170, string.format("%+.2f dB headroom", gain))
      col(C.dim); text(16, 192, "Pos / Neg")
      local pb, nb = 0, 0
      for c = 1, res.nch do pb = max(pb, res.channels[c].pos_before); nb = max(nb, res.channels[c].neg_before) end
      col(C.text); text(90, 192, string.format("%s / %s dBFS  →  %s / %s dBFS", core.fmt_db(pb), core.fmt_db(nb), core.fmt_db(pa_pos), core.fmt_db(pa_neg)))
      col(C.dim)
      local sug = res.nch >= 2 and (S.link and string.format("linked %+.1f°", res.linked.angle) or string.format("L %+.1f°  R %+.1f°", res.channels[1].best_angle, res.channels[2].best_angle)) or string.format("%+.1f°", res.linked.angle)
      text(16, 214, string.format("Suggested (%s): %s   (analysis %.2f s)", res.criterion == "peak" and "min peak" or "RX-style", sug, res.seconds))
    else
      col(C.dim); text(16, 170, "Press Suggest to analyze this item, or set a rotation by hand.")
    end
    if st then
      col(st.enabled and C.accent or C.accent2)
      local msg
      if not st.enabled then msg = "Bypassed"
      elseif MODE == "source" then msg = st.adaptive and "Applied to the source (adaptive) · non-destructive, waveform shows the result" or "Applied to the source · non-destructive, waveform shows the result"
      else msg = adaptive_live and "Take FX active · adaptive rotation follows the signal" or "Take FX active (non-destructive) · Render bakes it into a new take" end
      text(16, 236, msg)
    end
  else
    col(C.dim); text(16, 146, "Select one or more audio items in the arrange view.")
  end

  draw_plot(W - 168, 64, 152, e)
  font(11); col(C.dim); text(W - 168, 220, "envelope vs phase", 152, 14, 1); text(W - 168, 233, "grey = original · blue = now", 152, 14, 1)

  -- bottom bar
  col(C.panel); rect(0, H - 60, W, 60)
  local has = st ~= nil
  if button("preview", 16, H - 46, 96, 32, preview.on and "Stop" or "Preview", { on = preview.on, disabled = no_items, bar = true }) then
    if preview.on then stop_preview() else start_preview() end
  end
  if button("bypass", 118, H - 46, 88, 32, "Bypass", { on = st and not st.enabled, disabled = not has, bar = true }) then do_bypass() end
  if button("remove", 212, H - 46, 100, 32, MODE == "source" and "Reset" or "Remove FX", { disabled = not has, bar = true }) then do_remove() end
  if MODE == "fx" then
    if button("render", W - 126, H - 46, 110, 32, "Render", { primary = true, disabled = not has, bar = true }) then do_render() end
  end
  font(12); col(C.dim)
  text(W - 250, H - 16, MODE == "source" and "engine: source (reaper_phaserot)" or "engine: take FX · install reaper_phaserot for waveform display", 236, 14, 2)
  if status ~= "" then
    col(C.dim); font(13)
    text(324, H - 44, fit_text(status, W - 324 - 20), W - 324 - 20, 20, 4)
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
local function run_test_action(a)
  test_log("action " .. a .. " items=" .. #items .. " cur=" .. cur .. " mode=" .. MODE)
  if a == "suggest" then do_suggest()
  elseif a == "bypass" then do_bypass()
  elseif a == "render" then do_render()
  elseif a == "remove" then do_remove()
  elseif a == "link" then toggle_link()
  elseif a == "link_on" then set_link(true)
  elseif a == "link_off" then set_link(false)
  elseif a == "adaptive" then S.adaptive = not S.adaptive; apply_mode_to_all()
  elseif a == "next" then cur = cur < #items and cur + 1 or 1
  elseif a == "preview" then if preview.on then stop_preview() else start_preview() end
  elseif a:match("^angle=") then local e = items[cur] if e then set_angle(e, "l", tonumber(a:sub(7)), true) end
  elseif a == "dump" then
    local e = items[cur]
    local st = e and take_state(e)
    test_log(string.format("dump cur=%d mode=%s L=%s R=%s adaptive=%s enabled=%s res=%s", cur, MODE,
      st and st.angle_l or "-", st and st.angle_r or "-", tostring(st and st.adaptive), tostring(st and st.enabled),
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
    elseif ch == 98 or ch == 66 then do_bypass() end
  end
  if gfx.w / sc ~= W or gfx.h / sc ~= H then W, H = max(600, gfx.w / sc), max(300, gfx.h / sc) end
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
  test_log("init: mode=" .. MODE .. " items_selected=" .. r.CountSelectedMediaItems(0))
  gfx.ext_retina = 1
  local d, x, y, w, h = 0, -1, -1, W, H
  local saved = r.GetExtState(SECTION, "wnd")
  if saved ~= "" then
    local a = {}
    for v in saved:gmatch("-?%d+") do a[#a + 1] = tonumber(v) end
    if #a == 5 then d, x, y, w, h = a[1], a[2], a[3], a[4], a[5] end
  end
  if x < 0 then
    local _, _, sw, sh = r.my_getViewport(0, 0, 0, 0, 0, 0, 0, 0, true)
    x, y = floor((sw - W) / 2), floor((sh - H) / 2)
  end
  test_log(string.format("init: gfx.init dock=%d pos=%d,%d size=%dx%d", d, x, y, w, h))
  gfx.init(TITLE, w, h, d, x, y)
  test_log("init: gfx.init done, w=" .. gfx.w .. " h=" .. gfx.h .. " retina=" .. tostring(gfx.ext_retina))
  sc = gfx.ext_retina > 1 and gfx.ext_retina or 1
  if gfx.w / sc ~= W or gfx.h / sc ~= H then W, H = max(600, gfx.w / sc), max(300, gfx.h / sc) end
  refresh_items(true)
  test_log("init: refresh done, items=" .. #items)
  set_status(#items > 0 and "Press Suggest (S) to analyze, Space to preview" or "")
end

r.atexit(function()
  stop_preview()
  if drag_undo then r.Undo_EndBlock("Phase Rotation: set rotation", -1) end
  save_window()
  save_settings()
  gfx.quit()
end)
init()
main()
