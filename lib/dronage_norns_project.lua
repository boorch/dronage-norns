-- dronage-norns project save/load.
--
-- A "project" = a named norns .pset (all live param values) + its .scenes sidecar (the 8 scene
-- snapshots; the scenes module hooks params.action_write/read so the sidecar rides along). Files
-- live in the script data dir (norns.state.data). Random naming pulls from the wordlist module.

local W = include("dronage-norns/lib/dronage_norns_wordlist")

local M = {}
M.current = nil   -- name of the loaded project (nil = unsaved / fresh)
M.NAME_MAX = 20   -- max project-name length (chars incl. spaces) - fits the 128px list row

local function dir() return norns.state.data end
function M.path(name) return dir() .. name .. ".pset" end

-- sorted list of saved project names (strip ".pset"; the ".pset.scenes" sidecars don't match)
function M.list()
  local out = {}
  for _, f in ipairs(util.scandir(dir())) do
    local nm = f:match("^(.+)%.pset$")
    if nm then out[#out + 1] = nm end
  end
  table.sort(out)
  return out
end

function M.exists(name)
  for _, n in ipairs(M.list()) do if n == name then return true end end
  return false
end

-- save / load go through params:write/read, which fire the scenes sidecar hooks.
function M.save(name)
  params:write(M.path(name))
  M.current = name
end

function M.load(name)
  params:read(M.path(name))
  M.current = name
end

function M.delete(name)
  os.remove(M.path(name))
  os.remove(M.path(name) .. ".scenes")
  if M.current == name then M.current = nil end
end

-- random "adjective noun", re-rolling past any name already taken (~never loops at ~90k combos)
function M.random_name()
  local taken = {}
  for _, n in ipairs(M.list()) do taken[n] = true end
  local name
  repeat
    name = W.adjectives[math.random(#W.adjectives)] .. " " .. W.nouns[math.random(#W.nouns)]
  until #name <= M.NAME_MAX and not taken[name]   -- keep names within the cap (long words still pair with short ones)
  return name
end

return M
