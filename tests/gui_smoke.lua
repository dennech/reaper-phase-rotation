-- GUI smoke test: runs inside REAPER (isolated). Inserts two items, selects them,
-- then runs the GUI script with scripted actions (see PHASE_ROTATION_TEST_ACTIONS).
local REPO = os.getenv("PR_REPO")
local TD = os.getenv("PR_TEST_DIR")
local LOG = os.getenv("PR_TEST_OUT")
local f = io.open(LOG, "w") f:write("gui smoke start\n") f:close()
local function insert(file, idx)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  reaper.SetOnlyTrackSelected(tr)
  reaper.SetEditCurPos(0, false, false)
  reaper.InsertMedia(file, 0)
  return reaper.GetTrackMediaItem(tr, 0)
end
local a = insert(TD .. "/asym_mono.wav", 0)
local b = insert(TD .. "/asym_stereo.wav", 1)
reaper.SelectAllMediaItems(0, false)
reaper.SetMediaItemSelected(a, true)
reaper.SetMediaItemSelected(b, true)
local ok, err = pcall(dofile, REPO .. "/Items/Phase Rotation (RX-style).lua")
if not ok then local g = io.open(LOG, "a") g:write("ERROR loading gui: " .. tostring(err) .. "\n") g:close() end
-- poll for the gui to finish (the "quit" action returns from its defer loop), then quit REAPER
local t0 = reaper.time_precise()
local function poll()
  local g = io.open(LOG, "r"); local txt = g:read("*a"); g:close()
  if txt:find("\nquit") or txt:find("ERROR") or reaper.time_precise() - t0 > 90 then
    local h = io.open(LOG, "a")
    h:write(string.format("items=%d takes_a=%d takes_b=%d\n", reaper.CountMediaItems(0), reaper.CountTakes(a), reaper.CountTakes(b)))
    h:write("gui smoke end\n"); h:close()
    reaper.Main_SaveProjectEx(0, os.getenv("PR_PROJ"), 0)
    reaper.Main_OnCommand(40004, 0)
    return
  end
  reaper.defer(poll)
end
poll()
