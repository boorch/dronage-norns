-- dronage-norns performance mode: FULL vs LITE DSP graph.
--
-- The full engine needs ~45% of one core at 48kHz - fine on a Pi 4, ~2.5x that on the
-- original norns' CM3 (Cortex-A53) = guaranteed xruns. LITE drops the heavy tape stages
-- (hysteresis saturation / loss / degrade) and runs the per-voice filter chain mono
-- (measured profile: _docs/dronage/10-cm3-perf-profile.md in the dev repo).
--
-- Resolution order:
--   1. `DRONAGE_FORCE_LITE = true/false` global, set at the top of dronage-norns.lua
--      (testing override; norns `include` does not cache, so a plain module flag would
--      not survive re-includes - a global does).
--   2. Auto-detect from /proc/device-tree/model: known-fast boards get FULL,
--      everything else (CM3, Pi 3, unknown) fails safe into LITE.
--
-- The resolved mode is written to <data>/perf-mode BEFORE the engine loads, so the SC
-- side (Engine_DronageNornsSC_Main.sc alloc) composes the matching SynthDefs. SC also
-- has its own model fallback in case the file is missing (e.g. renamed script folder).
--
-- This module is include-safe: every copy re-derives the identical answer.

local M = {}

local function read_model()
  local f = io.open("/proc/device-tree/model", "r")
  if not f then return "" end
  local m = f:read("*a") or ""
  f:close()
  return (m:gsub("%z", ""))   -- device-tree strings carry a trailing NUL
end

M.model = read_model()

-- Whitelist the fast boards; default everything else to LITE so an unknown slow board
-- degrades gracefully instead of glitching. Keep this list in sync with the SC fallback.
local FULL_BOARDS = { "Pi 4", "Pi 400", "Compute Module 4", "Pi 5", "Compute Module 5" }
local function detect_lite(model)
  for _, s in ipairs(FULL_BOARDS) do
    if model:find(s, 1, true) then return false end
  end
  return true
end

-- plain global read on purpose: matron keeps user globals behind a metatable on _G,
-- so rawget(_G, ...) misses them (verified on-device) - only the metatable path sees them
local force = DRONAGE_FORCE_LITE
if force ~= nil then M.lite = force else M.lite = detect_lite(M.model) end

-- hand the resolved mode to the SC engine (read once at engine alloc)
do
  local f = io.open(norns.state.data .. "perf-mode", "w")
  if f then
    f:write((M.lite and "lite" or "full") .. "\n" .. M.model .. "\n")
    f:close()
  end
end

return M
