-- dronage-norns update check: offer new releases at launch, never block, never surprise.
--
-- After init we ASYNCHRONOUSLY ask git whether the script's clone is behind its upstream.
-- The UPDATE AVAILABLE overlay appears ONLY when every one of these holds:
--   * the script dir is a git repo with an upstream   (manual SD-card copy installs: skip)
--   * no TRACKED file is modified (-uno: untracked extras are fine - maiden itself drops a
--     .project metadata file into every install, and ff-only pulls don't touch strays)
--   * the network answered within 5 s                 (offline norns: skip - `timeout 5`
--                                                      also stops a no-DNS fetch hanging)
--   * we are strictly BEHIND with no local commits    (diverged history: skip)
-- Any other outcome (git missing, no remote, errors) = silent skip, normal boot. The check
-- runs via norns.system_cmd (async callback), so the script is fully playable throughout.
--
-- Install (K3) runs `git pull --ff-only` (either fast-forwards cleanly or does nothing),
-- then reloads the script. If the update changed engine binaries the reload trips the
-- installer's content-hash gate and its proven K3-restart screen finishes the job; a
-- Lua-only update is completely seamless (no restart at all).

local M = {}

M.state = nil        -- nil | "offer" | "pulling" | "failed"
M.dir = norns.state.path   -- overridable, so the flow can be tested against a scratch clone

local function sh(cmd) return "cd '" .. M.dir .. "' 2>/dev/null && " .. cmd end

function M.check()
  -- one shell round-trip that classifies everything and prints a single machine-readable line
  local cmd = sh(
    "git rev-parse --git-dir >/dev/null 2>&1 || { echo NOGIT; exit 0; }; " ..
    "[ -n \"$(git status --porcelain -uno 2>/dev/null)\" ] && { echo DIRTY; exit 0; }; " ..
    "git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || { echo NOUPSTREAM; exit 0; }; " ..
    "timeout 5 git fetch -q 2>/dev/null || { echo OFFLINE; exit 0; }; " ..
    "b=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0); " ..
    "a=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0); " ..
    "echo \"STATUS $b $a\"")
  norns.system_cmd(cmd, function(out)
    local b, a = string.match(out or "", "STATUS (%d+) (%d+)")
    if b and tonumber(b) > 0 and tonumber(a) == 0 then
      M.state = "offer"
    end
    -- every other classification (NOGIT/DIRTY/NOUPSTREAM/OFFLINE/ahead/parse failure): stay silent
  end)
end

function M.pull(done)
  M.state = "pulling"
  norns.system_cmd(sh("timeout 60 git pull --ff-only -q 2>&1 && echo PULLOK"), function(out)
    if string.match(out or "", "PULLOK") then
      M.state = nil
      done(true)
    else
      M.state = "failed"   -- current version keeps running; K3 dismisses
      done(false)
    end
  end)
end

function M.dismiss() M.state = nil end

return M
