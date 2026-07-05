-- dronage-norns first-run / update installer for the custom SuperCollider UGen plugins.
--
-- scsynth loads UGen .so ONLY from ~/.local/share/SuperCollider/Extensions/, never from a script
-- folder. So we bundle the prebuilt .so in this script's ignore/ugens/ and copy them out, then ask
-- the user to restart (scsynth scans Extensions only at boot). Same pattern paracosms uses. The
-- matching wrapper .sc classes live in lib/ (compiled from dust at boot).
--
-- Update detection is by CONTENT: the bundle is its own version. We compare a combined md5 of
-- the shipped .so AND the script's SuperCollider class files (lib/*.sc) against a stamp written
-- at install time - so a rebuilt binary OR an engine/class change is auto-detected and walks the
-- user through the restart (sclang only recompiles classes at boot), with no version number to
-- hand-bump or let drift. A pure-Lua update stays restart-free: Lua hot-reloads completely.

local M = {}

M.dest = "/home/we/.local/share/SuperCollider/Extensions/dronage-norns/"
M.src  = _path.code .. "dronage-norns/ignore/ugens/"
M.libsc = _path.code .. "dronage-norns/lib/"

local function sh(cmd)
  local f = io.popen(cmd); if not f then return "" end
  local out = f:read("*a") or ""; f:close()
  return (out:gsub("%s+$", ""))
end

-- combined md5 of the SHIPPED SC side: bundle .so + lib/*.sc (name-sorted for stable order)
local function sc_hash()
  return sh("cat $(ls '" .. M.src .. "'*.so 2>/dev/null | sort) $(ls '" .. M.libsc .. "'*.sc 2>/dev/null | sort) 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1")
end

local function stamp_path() return M.dest .. "installed.md5" end

local function installed_hash()
  return sh("cat '" .. stamp_path() .. "' 2>/dev/null")
end

-- installed AND byte-identical to the shipped bundle + classes (verified via the install stamp,
-- which is only written after a successful copy)?
function M.is_installed()
  local want = sc_hash()
  if want == "" then return false end          -- bundle missing/empty -> can't verify
  return installed_hash() == want
end

-- wipe + copy the bundled .so out to Extensions and stamp the combined hash. returns ok, message.
function M.install()
  local want = sc_hash()
  if want == "" then return false, "UGen bundle missing" end
  os.execute("rm -rf '" .. M.dest .. "'")      -- full wipe: no stale UGens or stray files, ever
  os.execute("mkdir -p '" .. M.dest .. "'")
  os.execute("cp -f '" .. M.src .. "'*.so '" .. M.dest .. "'")
  -- verify the copied binaries byte-match the bundle before stamping
  local got = sh("cat $(ls '" .. M.dest .. "'*.so 2>/dev/null | sort) 2>/dev/null | md5sum | cut -d' ' -f1")
  local src = sh("cat $(ls '" .. M.src .. "'*.so 2>/dev/null | sort) 2>/dev/null | md5sum | cut -d' ' -f1")
  if got ~= src then return false, "copy failed" end
  os.execute("printf '%s' '" .. want .. "' > '" .. stamp_path() .. "'")
  return true, "installed"
end

return M
