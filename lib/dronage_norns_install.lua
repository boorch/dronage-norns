-- dronage-norns first-run / update installer for the custom SuperCollider UGen plugins.
--
-- scsynth loads UGen .so ONLY from ~/.local/share/SuperCollider/Extensions/, never from a script
-- folder. So we bundle the prebuilt .so in this script's ignore/ugens/ and copy them out, then ask
-- the user to restart (scsynth scans Extensions only at boot). Same pattern paracosms uses. The
-- matching wrapper .sc classes live in lib/ (compiled from dust at boot).
--
-- Update detection is by CONTENT: the bundle is its own version. We compare a combined md5 of the
-- shipped .so against the installed ones - so a rebuilt binary is auto-detected and reinstalled,
-- with no version number to hand-bump or let drift.

local M = {}

M.dest = "/home/we/.local/share/SuperCollider/Extensions/dronage-norns/"
M.src  = _path.code .. "dronage-norns/ignore/ugens/"

local function sh(cmd)
  local f = io.popen(cmd); if not f then return "" end
  local out = f:read("*a") or ""; f:close()
  return (out:gsub("%s+$", ""))
end

-- combined md5 of all *.so in dir (name-sorted for stable order), or "" if none / dir missing
local function so_hash(dir)
  return sh("cd '" .. dir .. "' 2>/dev/null && cat $(ls *.so 2>/dev/null | sort) 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1")
end

-- installed AND byte-identical to the shipped bundle?
function M.is_installed()
  local want = so_hash(M.src)
  if want == "" then return false end          -- bundle missing/empty -> can't verify
  return so_hash(M.dest) == want
end

-- copy the bundled .so out to Extensions. returns ok, message.
function M.install()
  if so_hash(M.src) == "" then return false, "UGen bundle missing" end
  os.execute("mkdir -p '" .. M.dest .. "'")
  os.execute("rm -f '" .. M.dest .. "'*.so")   -- clear stale UGens (handles renames/removals across updates)
  os.execute("cp -f '" .. M.src .. "'*.so '" .. M.dest .. "'")
  if M.is_installed() then return true, "installed" end
  return false, "copy failed"
end

return M
