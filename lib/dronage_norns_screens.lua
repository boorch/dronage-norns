-- dronage-norns SCREENS: the grid UI.
-- A column of ROWS, each a strip of VIEWS. E1 = view within row · K1-hold = minimap, E1 linear-
-- scrolls all 26 cells, release = jump · E2 = scroll cursor within a view · E3 = edit · K2/K3 =
-- per-view actions. Most views are scrollable param panels (any length); HOME/MATRIX/MODSEQ/
-- SCENES/PROJECT are bespoke. Modulation shows as an inline filled circle on every modulated param.

local textentry = require "textentry"   -- built-in name entry, for the PROJECT browser
local S = {}
local C   -- injected context: { eng, mtx, seq, mac, scenes, euclid, scales, project, project_new, ... }

-- ---------- param-id lists (built per voice/lfo at init) ----------
-- Voice view: curated subset + order + labels. id = stable engine/save key (never changes).
-- Omitted: hpq (still in the engine, in saves, and on the norns PARAMETERS screen). lpgdecay/lpgcol
-- moved here from EUCLID (sound params, not sequencer). gate renders OFF/ON (see vstr).
local VOICE_PARAMS = {
  { id = "gate",       label = "Gate"        },
  { id = "model",      label = "Model"       },
  { id = "pitch",      label = "Pitch"       },
  { id = "tune",       label = "Tune"        },
  { id = "harm",       label = "Harmonics"   },
  { id = "timbre",     label = "Timbre"      },
  { id = "morph",      label = "Morph"       },
  { id = "cut",        label = "LP Cut"      },
  { id = "res",        label = "LP Res"      },
  { id = "hpcut",      label = "HP Cut"      },
  { id = "drive",      label = "Drive"       },
  { id = "chorus",     label = "Chorus"      },
  { id = "dlysend",    label = "Delay Send"  },
  { id = "reverbsend", label = "Reverb Send" },
  { id = "attack",     label = "Fade In"     },
  { id = "decay",      label = "Fade Out"    },
  { id = "lpgdecay",   label = "LPG Decay"   },
  { id = "lpgcol",     label = "LPG Color"   },
  { id = "out_mode",   label = "Out"         },
  { id = "pan",        label = "Pan"         },
  { id = "level",      label = "Level"       },
}
local VLABEL = {}   -- suffix -> display label, for short() (voice suffixes are unique across panels)
for _, p in ipairs(VOICE_PARAMS) do VLABEL[p.id] = p.label end
-- EUCLID view param labels (sequencer params; LPG moved to Voice)
VLABEL.esteps = "Steps"; VLABEL.etrig = "Triggers"; VLABEL.eshift = "Shift"; VLABEL.epad = "Padding"
VLABEL.ereset = "Reset Beats"; VLABEL.erate = "Rate"; VLABEL.eprob = "Probability"
-- LFO view
VLABEL.shape="Shape"; VLABEL.sync="Sync"; VLABEL.rate="Rate"; VLABEL.div="Div"; VLABEL.phase="Phase"
VLABEL.skew="Skew"; VLABEL.smooth="Smooth"; VLABEL.length="Length"; VLABEL.variation="Variation"; VLABEL.mutate="Mutate"; VLABEL.polarity="Polarity"
-- Delay (forward) + Reverb + Tape (single-word suffixes; some shared)
VLABEL.fb="FB"; VLABEL.tone="Tone"; VLABEL.mod="Mod"; VLABEL.gran="Gran"
VLABEL.mix="Mix"; VLABEL.shimmer="Shimmer"; VLABEL.size="Size"; VLABEL.time="Time"; VLABEL.damp="Damp"; VLABEL.diff="Diff"
VLABEL.amount="Tape Amount"; VLABEL.saturation="Saturation"; VLABEL.compression="Compression"
-- Macro slots
VLABEL.macro1_tracks="M1 Tracks"; VLABEL.macro1_dest="M1 Dest"; VLABEL.macro1_depth="M1 Depth"
VLABEL.macro2_tracks="M2 Tracks"; VLABEL.macro2_dest="M2 Dest"; VLABEL.macro2_depth="M2 Depth"
VLABEL.macro3_tracks="M3 Tracks"; VLABEL.macro3_dest="M3 Dest"; VLABEL.macro3_depth="M3 Depth"
-- Global
VLABEL.tempo="Tempo"; VLABEL.root="Root"; VLABEL.scale="Scale"; VLABEL.mod_depth="Mod Depth"; VLABEL.seed="Seed"
VLABEL.anchor="S&H SEED START 0"

-- EUCLID step sprites (7x7; separate active/idle art per state, loaded in S.init)
local STEPIMG = {}

local function vids(i)
  local out = {}
  for _, p in ipairs(VOICE_PARAMS) do out[#out+1] = "v"..i.."_"..p.id end
  return out
end
local function eids(i)
  local p, out = {"esteps","etrig","eshift","epad","ereset","erate","eprob"}, {}  -- LPG moved to Voice
  for _,c in ipairs(p) do out[#out+1] = "v"..i.."_"..c end
  return out
end
local function lids(s)
  local p, out = {"shape","sync","rate","div","phase","skew","smooth","length","variation","mutate","polarity"}, {}
  for _,c in ipairs(p) do out[#out+1] = "lfo"..s.."_"..c end
  return out
end
local DELAY = {"dronage_delay_div","dronage_delay_fb","dronage_delay_tone","dronage_delay_mod","dronage_delay_gran","dronage_delay_rvbsend","dronage_delay_revfwd"}
               -- reverse delay params are mirrored from these + hidden (shared for now)
-- reverb "return"/mix omitted from the UI: redundant with per-voice reverb send, pinned at 100%.
local REVERB = {"dronage_reverb_shimmer","dronage_reverb_size","dronage_reverb_time",
                "dronage_reverb_damp","dronage_reverb_diff","dronage_reverb_fb","dronage_reverb_mod"}
local TAPE = {"dronage_tape_age","dronage_tape_hiss","dronage_tape_compression","dronage_master_vol"}   -- chain order
-- MACRO is now a custom view (kind "macro"); only the master amount remains a param.
local GLOBAL = {"clock_tempo","dronage_root","dronage_scale","mod_depth","dronage_seed","dronage_sh_anchor","dronage_keep_bpm","dronage_grid_bright"}

-- ---------- view registry (flat, linear order = K1 scroll order) ----------
local VIEWS = {}      -- [lin] = {name, tag, kind, row, col, ids?, n?, src?}
local ROWVIEWS = {}   -- [row] = { lin, ... }
local function add(row, col, name, tag, kind, extra)
  local v = { name=name, tag=tag, kind=kind, row=row, col=col }
  if extra then for k,x in pairs(extra) do v[k]=x end end
  VIEWS[#VIEWS+1] = v
  ROWVIEWS[row] = ROWVIEWS[row] or {}
  ROWVIEWS[row][#ROWVIEWS[row]+1] = #VIEWS
end

-- ---------- nav state ----------
local cur = 1            -- current linear view index
local k1held = false
local k2held, k3held = false, false   -- for K1+K2+K3 combos
local k3_used = false     -- K3 hold spent as the E3 snap modifier -> swallow its release (no gate toggle)
local k1_consumed = false   -- a K1 combo consumed the hold -> suppress minimap + skip nav on release
local k2_eaten, k3_eaten = false, false   -- K2/K3 eaten by a matrix/scenes chord -> skip their release action
local jump = 1           -- highlighted cell while K1 held
local map_held = false   -- grid MAP pad hold: minimap overlay WITHOUT k1 semantics (shares `jump`)
local toast_msg, toast_until = "", 0  -- transient on-screen popup
local function toast(msg) toast_msg = msg; toast_until = util.time() + 1.0 end
-- undo dirty-marking for edits that bypass params (matrix cells, CV-seq tracks, macro slots)
local function touched() if C.undo then C.undo.touch() end end
-- K2+E1 undo/redo latch: ONE step per deliberate turn, however fast the spin. The first tick
-- fires, then same-direction ticks are swallowed until ~300ms of no motion; reversing fires
-- immediately (fluid A/B compares). undo_dir resets on each K2 press. (Declared BEFORE
-- undo_step so they're captured as upvalues, not runtime globals.)
local UNDO_GAP = 0.3
local undo_dir, undo_at = 0, 0
-- one undo (CCW) / redo (CW) step per turn burst
local function undo_step(d)
  local dir = d > 0 and 1 or -1
  local now = util.time()
  local fire = (dir ~= undo_dir) or (now - undo_at > UNDO_GAP)
  undo_dir, undo_at = dir, now
  if not fire then return end
  local label = (dir > 0) and C.undo.redo() or C.undo.undo()
  if label then toast((dir > 0 and "REDO " or "UNDO ") .. label)
  else toast(dir > 0 and "NOTHING TO REDO" or "NOTHING TO UNDO") end
end
local cursor = {}        -- [lin] = panel cursor pos
local top = {}           -- [lin] = panel scroll top
-- matrix: the LFO column IS the view (8 MM sibling views carry .src), so E1/minimap/grid
-- pagination all move columns for free; ONE dest-row cursor shared across all 8 so a
-- column jump keeps your place on the same voice/param row.
local function mcol() local v = VIEWS[cur]; return (v and v.src) or 1 end
local mrow = 1
local mtop = 1   -- shared scroll top too: per-view top[] would make the window jump on column changes
local scur = 1           -- scenes cursor
local seqcol = 1         -- modseq: selected column (1-5 steps, 6 div, 7 len, 8-13 = 2x(osc,par,amt))
local macro_sel = 0      -- macro: linear focus - 0 = AMOUNT, 1-9 = the 9 destination cells (3 slots x osc/param/depth)
local looper_sel = 0     -- looper: linear focus - 0 = the crossfade gauge, 1-3 = length/quantize/od fb, 4 = erase row
local PANEL_VIS = 6   -- reclaimed top margin lets us show 6 param rows
local oct_acc = 0     -- K2+E3 octave-jump accumulator (2 detents per jump, direction-reset)

-- ---------- helpers ----------
-- full-id labels for the delay/reverb panels (suffixes like div/fb/mod collide across panels, so key
-- by the whole id and check this before the suffix map).
local PLABEL = {
  dronage_delay_div = "Rate", dronage_delay_fb = "Feedback", dronage_delay_tone = "Tone",
  dronage_delay_mod = "Mod", dronage_delay_gran = "Granular",
  dronage_delay_rvbsend = "Delay > Rvb Send", dronage_delay_revfwd = "Rev > Fwd Send",
  dronage_reverb_shimmer = "Shimmer", dronage_reverb_size = "Size", dronage_reverb_time = "Time",
  dronage_reverb_damp = "Damping", dronage_reverb_diff = "Diffusion",
  dronage_reverb_fb = "Feedback", dronage_reverb_mod = "Modulation",
  dronage_tape_age = "Tape Age", dronage_tape_hiss = "Hiss",
  dronage_tape_compression = "Compression", dronage_master_vol = "Master Volume",
  dronage_grid_bright = "Grid Brightness",
  dronage_keep_bpm = "Keep BPM On Load",
}
local function short(id)
  local s = id:gsub("^v%d+_",""):gsub("^lfo%d+_",""):gsub("^dronage_%a+_",""):gsub("^dronage_",""):gsub("^clock_","")
  return PLABEL[id] or VLABEL[s] or s   -- curated voice labels (Gate, LP Cut, Fade In…); else the bare suffix
end
-- total mod depth on a voice param (0 if not a matrix dest)
local function mod_depth_of(id)
  local v, cmd = id:match("^v(%d+)_(%a+)$")
  if not v then return 0 end
  local d = C.mtx.find_dest(tonumber(v), cmd)
  if not d then return 0 end
  local s = 0
  for i = 1, C.mtx.NUM_SRC do s = s + math.abs(C.mtx.cell[d][i] or 0) end
  return math.min(s, 1)
end
-- norns screen.circle adds its arc to cairo's current point (left at the previous text), which draws
-- a stray connector line. Move to the arc's start (angle 0 = x+r) first so that line is zero-length.
local function ring(x, y, r) screen.move(x + r, y); screen.circle(x, y, r); screen.stroke() end
local function disc(x, y, r) screen.move(x + r, y); screen.circle(x, y, r); screen.fill() end
-- signed radial fill (clock pie from 12 o'clock): CW + bright white for +, CCW + gray for -,
-- |v|=1 = full 360. Faint base ring always, so empty cells still read as a dot. (aa caller's job.)
local TOP = -math.pi / 2
local function radial(cx, cy, r, v, rl)
  screen.level(rl or 2); ring(cx, cy, r)
  local m = util.clamp(math.abs(v), 0, 1)
  if m > 0.01 then
    local sw = m * 2 * math.pi
    local a0 = (v >= 0) and TOP or (TOP - sw)     -- + sweeps CW from 12 o'clock, - sweeps CCW
    local steps = math.max(2, math.ceil(m * 18))
    screen.level(v >= 0 and 15 or 4)               -- + bright white, - gray (shared by matrix + modseq)
    screen.move(cx, cy)                            -- explicit wedge: centre -> arc points -> close
    for i = 0, steps do
      local a = a0 + (i / steps) * sw
      screen.line(cx + r * math.cos(a), cy + r * math.sin(a))
    end
    screen.close(); screen.fill()
  end
end
local function circle(x, y, d)
  screen.level(3); ring(x, y, 3)
  if d > 0.01 then screen.level(15); disc(x, y, 0.7 + util.clamp(d, 0, 1) * 2.3) end
end
local function pstr(id)
  local ok, s = pcall(function() return params:string(id) end)
  return ok and s or "?"
end
-- format a param value. val defaults to the live param value; pass a value to format a modulated
-- RESULT instead. pitch/cut/hpcut -> 2-decimal Hz; euclid counts -> int; probability -> %.
local function vstr(id, val)
  local x = val or params:get(id)
  if id:match("_gate$") then return x == 1 and "ON" or "OFF" end
  if id:match("_pitch$") then   -- scale-quantized frequency, 2-decimal Hz (not semitones)
    local m = (C.scales and C.scales.quantize and C.scales.quantize(x)) or x
    return string.format("%.2f Hz", 440 * 2 ^ ((m - 69) / 12))
  end
  if id:match("_cut$") or id:match("_hpcut$") then return string.format("%.2f Hz", x) end
  if id:match("_eprob$") or id:match("_variation$") or id:match("_mutate$") then return util.round(x * 100) .. "%" end
  if id:match("_phase$") then return string.format("%.3f%%", x * 100) end
  if id:match("_etrig$") or id:match("_eshift$") or id:match("_epad$") or id:match("_ereset$") then
    return tostring(util.round(x))
  end
  -- linear, no-unit control params whose range is within [-2,2] -> integer percentage. More readable
  -- than a float and kills the right-aligned width jitter ("1.4" vs "1.39"). The +-2 bound also covers
  -- the macro depth (-200%..+200%); reverb size (0.5..3) and integer counts (max >= 16) stay floats.
  local p = params:lookup_param(id)
  local sp = p and p.controlspec
  if sp and sp.units == "" and sp.maxval <= 2 and sp.minval >= -2 then
    return util.round(x * 100) .. "%"
  end
  if val ~= nil then   -- modulated result of another control (e.g. seconds): 2 decimals + units
    return string.format("%.2f", x) .. (sp and sp.units ~= "" and (" " .. sp.units) or "")
  end
  return pstr(id)
end
local function pdelta(id, d) pcall(function() params:delta(id, d) end) end

-- reset a param to its default (control = controlspec.default; option/number/binary/taper = .default)
local function reset_param(id)
  local p = params:lookup_param(id)
  if not p then return end
  local def = (p.controlspec and p.controlspec.default) or p.default
  if def ~= nil then pcall(function() params:set(id, def) end) end
end

-- frequency-knob feel (nullSEK standard): the controlspec quantum is the fine slow-detent step
-- (~0.01 Hz); turn SPEED - measured by real time between detents, not norns's capped ×6 ramp -
-- then accelerates hard so a fast flick sweeps the range. dtv≈1 (fast) -> ×(1+ACCK); dtv≈20 (slow)
-- -> ×1 (the bare quantum). ponytail: tune FREQ_ACCK / FREQ_FASTDT by feel.
local FREQ_ACCK, FREQ_FASTDT, last_freq_turn = 150, 0.01, 0
local CUT_ACCK, CUT_FASTDT = 500, 0.025   -- filter cutoffs only: hotter accel + wider window ("curve B")
local PITCH_ACCK = 500                    -- pitch: hotter fast flick, original narrow window (slows unchanged)
local TUNE_ACCK = 30                      -- tune: gentle accel (max ~x31 the 0.01 st detent)
local PHASE_ACCK = 40                     -- lfo phase: gentle accel over the 0.125% detent
local function accmul(k, t)   -- turn-speed multiplier (shared timestamp): slow -> x1, fast flick -> x(1+k)
  local now = util.time()
  local dtv = util.clamp((now - last_freq_turn) / t, 1, 20)
  last_freq_turn = now
  return 1 + k * math.exp(1 - dtv)
end
local function fdelta(id, d, k, t)
  pdelta(id, d * accmul(k or FREQ_ACCK, t or FREQ_FASTDT))   -- *quantum applied inside params:delta
end
-- mod-depth edits (matrix cells, CV-seq amounts, macro slot depths): 0.1% per slow detent,
-- gentle accel so a flick still sweeps (~2.5%/detent fast, x6 more with norns enc accel).
local DEPTH_ACCK = 25
local function ddelta(d) return d * 0.001 * accmul(DEPTH_ACCK, FREQ_FASTDT) end

-- ---------- chrome ----------
local TY = 5   -- title baseline: caps are 5px, so y5 puts cap-tops at y0 - no wasted top margin
local function header(name, lin)
  screen.level(15); screen.move(2, TY); screen.text(name)
  local rv = ROWVIEWS[VIEWS[lin].row]
  if #rv > 1 then           -- view-position dots, top right
    local x = 128 - #rv * 5
    for i, l in ipairs(rv) do
      screen.level(l == lin and 15 or 3)
      screen.rect(x + (i-1)*5, 0, 3, 3); screen.fill()
    end
  end
end

-- ---------- scrollable param panel ----------
local lfo_ids   -- forward decl (defined with the LFO view code below)
-- ids for a view, context-filtered: LFO lists follow sync/shape; GLOBAL hides the
-- grid-brightness row when no grid is attached (C.grid_connected, injected by the host).
local function view_ids(v)
  if v.kind == "lfo" then return lfo_ids(v) end
  if v.name == "GLOBAL" and C.grid_connected and not C.grid_connected() then
    local out = {}
    for _, id in ipairs(v.ids) do
      if id ~= "dronage_grid_bright" then out[#out + 1] = id end
    end
    return out
  end
  return v.ids
end

local function draw_panel(lin)
  local v = VIEWS[lin]
  local ids = view_ids(v)
  local c = util.clamp(cursor[lin] or 1, 1, #ids); cursor[lin] = c
  local t = top[lin] or 1
  if c < t then t = c elseif c > t + PANEL_VIS - 1 then t = c - PANEL_VIS + 1 end
  t = util.clamp(t, 1, math.max(1, #ids - PANEL_VIS + 1)); top[lin] = t
  for row = 0, PANEL_VIS - 1 do
    local idx = t + row
    if idx > #ids then break end
    local id = ids[idx]
    local y = 15 + row * 9
    local on = (idx == c)
    screen.level(on and 15 or 4); screen.move(4, y); screen.text(short(id))
    -- value: live post-mod result when modulated + unfocused; base value when focused (so you see it)
    local res, base = C.mod_result and C.mod_result[id], params:get(id)
    screen.move(112, y); screen.text_right((res ~= nil and idx ~= c) and vstr(id, res) or vstr(id))
    if res ~= nil and res ~= base then   -- +/- direction (result vs base) in the old circle column
      screen.move(122, y); screen.text(res > base and "+" or "-")
    end
  end
  -- scrollbar
  if #ids > PANEL_VIS then
    local h = math.max(3, util.round(56 * PANEL_VIS / #ids))
    local yy = 8 + util.round((54 - h) * (t - 1) / math.max(1, #ids - PANEL_VIS))
    screen.level(2); screen.rect(126, yy, 1, h); screen.fill()
  end
end

-- ---------- HOME main-out visualizers (E1 cycles) ----------
-- The engine streams 40 log-band powers of the master out (/dr_spec, ~20 Hz) to matron's OSC-in; we
-- ring-buffer them into a scrolling spectrogram. Viz 2-5 (vectorscope + styx/cocytus/lethe) are stubs.
local VIZ_NAMES = { "spectrogram", "vectorscope", "styx", "cocytus", "lethe" }
local home_viz = 1
local SPEC_BANDS, SPEC_COLS = 40, 128
local spec_hist, spec_ptr = {}, 0   -- ring of columns (each = 40 grey levels); newest at spec_ptr
local spec_buckets = {}             -- reused per frame: [level] = {n, x1,y1,h1, x2,y2,h2, ...}
local scope_data = nil              -- latest 512 interleaved L,R master-out samples (vectorscope)

-- band power -> grey level 0..15. dB-normalized (-55..-5 dB) then a gamma curve: the exponent > 1
-- crushes quiet bands (noise floor + FFT leakage) toward black while peaks stay bright, so the
-- fundamentals read clearly instead of the whole spectrum washing grey.
local SPEC_FLOOR, SPEC_CEIL, SPEC_GAMMA = -50, -5, 3.0   -- dB floor->black, dB ceil->white, contrast
local function spec_level(p)
  if not p or p <= 1e-9 then return 0 end
  local norm = util.clamp((10 * math.log(p, 10) - SPEC_FLOOR) / (SPEC_CEIL - SPEC_FLOOR), 0, 1)
  return util.round(norm ^ SPEC_GAMMA * 15)
end

local function push_spec_column(args)
  spec_ptr = (spec_ptr % SPEC_COLS) + 1
  local col = spec_hist[spec_ptr]; if not col then col = {}; spec_hist[spec_ptr] = col end
  for b = 1, SPEC_BANDS do col[b] = spec_level(args[b]) end   -- store the grey level (no log in the draw loop)
end

-- 128x40 scrolling spectrogram in the inset (x0..127, y8..47): X = time (newest right), Y = freq
-- (low band at the bottom). Merge vertical same-level runs into tall rects, bucketed by grey level,
-- so the whole frame is just <=15 cairo fills (one per level) - the rest is cheap path-building.
local function draw_spectrogram()
  for lvl = 1, 15 do local bk = spec_buckets[lvl]; if bk then bk[1] = 0 end end   -- reset counters (reuse arrays)
  for x = 0, SPEC_COLS - 1 do
    local col = spec_hist[((spec_ptr - SPEC_COLS + x) % SPEC_COLS) + 1]
    if col then
      local b = 1
      while b <= SPEC_BANDS do
        local lvl = col[b]
        if lvl and lvl > 0 then
          local run = 1
          while b + run <= SPEC_BANDS and col[b + run] == lvl do run = run + 1 end
          local bk = spec_buckets[lvl]; if not bk then bk = {0}; spec_buckets[lvl] = bk end
          local n = bk[1]; bk[n + 2] = x; bk[n + 3] = 49 - b - run; bk[n + 4] = run; bk[1] = n + 3
          b = b + run
        else b = b + 1 end
      end
    end
  end
  for lvl = 1, 15 do
    local bk = spec_buckets[lvl]
    if bk and bk[1] > 0 then
      screen.level(lvl)
      for i = 2, bk[1] + 1, 3 do screen.rect(bk[i], bk[i + 1], 1, bk[i + 2]) end
      screen.fill()
    end
  end
end

-- Semicircle vectorscope (Ozone Imager style): an upper half-circle on the inset baseline. Each
-- master-out sample is a dot - angle = stereo balance (|L| vs |R|; mono = straight up, hard pan =
-- to the sides), radius = its level. Sign-independent so the lobe doesn't flicker with the waveform.
local VS_CX, VS_CY, VS_R, VS_GAIN = 64, 47, 38, 1.5
local function draw_vectorscope()
  screen.level(2)
  screen.move(VS_CX - VS_R, VS_CY)                                             -- break the path (arc joins
  screen.arc(VS_CX, VS_CY, VS_R, math.pi, 2 * math.pi); screen.stroke()        -- from the current point) -> dome
  screen.move(VS_CX - VS_R, VS_CY); screen.line(VS_CX + VS_R, VS_CY); screen.stroke()  -- baseline
  if scope_data then
    screen.aa(1); screen.level(15)   -- aa: dots at their true sub-pixel position (+brightness to offset the spread)
    for i = 1, #scope_data - 1, 2 do
      local aL, aR = math.abs(scope_data[i]), math.abs(scope_data[i + 1])
      local sum = aL + aR
      if sum > 1e-4 then
        local ang = (aR - aL) / sum * (math.pi / 2)     -- -pi/2 (hard L) .. +pi/2 (hard R)
        local r = util.clamp(sum * VS_GAIN, 0, 1) * VS_R
        screen.rect(VS_CX + r * math.sin(ang), VS_CY - r * math.cos(ang), 1, 1)
      end
    end
    screen.fill()
    screen.aa(0)
  end
end

-- LFO visualizers (viz 3-5), revived from the old "mod views". All driven by the matrix LFO ring
-- (C.mtx.src[s].value + C.mtx.hist[s]) - no engine. Drawn in the inset y8..47, no source cursor.
-- styx: 8 stacked scrolling LFO scopes from the history ring.
local function draw_styx()
  screen.aa(1); screen.line_join("round")
  local H, ptr = C.mtx.HIST_LEN, C.mtx.hist_ptr
  local top, lane, amp = 10, 5, 2.2
  screen.level(8)
  for s = 1, C.mtx.NUM_SRC do
    local cy, hist = top + (s - 1) * lane, C.mtx.hist[s]
    for i = 0, 63 do
      local v = hist[((ptr + i * 2) % H) + 1] or 0
      if i == 0 then screen.move(0, cy - v * amp) else screen.line(i * 2, cy - v * amp) end
    end
    screen.stroke()
  end
  screen.aa(0); screen.line_join("miter")
end

-- cocytus: 8 narrow tiles (16px), each = the recent quarter-window compressed to 15 columns.
local function draw_cocytus()
  screen.aa(1); screen.line_join("round")
  local H, ptr = C.mtx.HIST_LEN, C.mtx.hist_ptr
  local W, base, cy, A = math.floor(H / 4), H - math.floor(H / 4), 27, 18
  screen.level(8)
  for s = 1, C.mtx.NUM_SRC do
    local x0, hist = (s - 1) * 16, C.mtx.hist[s]
    for px = 0, 14 do
      local v = hist[((ptr + base + math.floor(px * (W - 1) / 14)) % H) + 1] or 0
      if px == 0 then screen.move(x0, cy - v * A) else screen.line(x0 + px, cy - v * A) end
    end
    screen.stroke()
  end
  screen.aa(0); screen.line_join("miter")
end

-- lethe: 8 bipolar bars, height = each LFO's current value.
local function draw_lethe()
  local cy = 27
  screen.level(8)
  for s = 1, C.mtx.NUM_SRC do
    local x = 2 + (s - 1) * 16
    local h = util.round((C.mtx.src[s].value or 0) * 18)
    if h >= 0 then screen.rect(x, cy - h, 12, h + 1) else screen.rect(x, cy, 12, -h + 1) end
  end
  screen.fill()
end

-- ---------- bespoke views ----------
-- HOME: title + play status up top, a main-out visualizer in the middle (E1 cycles 5), and a bottom
-- row of 4 gate toggles (= per-voice gate on/off, the same param as each V1-V4 view). E2 picks a
-- toggle, K3 flips it, K2 = play/stop.
local function draw_home()
  screen.level(15); screen.move(2, 5); screen.text("DRONAGE-NORNS")
  -- PLAY is beat-quantized: "armed" blinks until the boundary lands (STOP stays instant)
  local armed = C.transport_armed and C.transport_armed()
  if armed then
    screen.level((util.time() * 3) % 1 < 0.6 and 15 or 2); screen.move(126, 5)
    screen.text_right("play")
  else
    screen.level(C.transport() and 15 or 4); screen.move(126, 5)
    screen.text_right(C.transport() and "play" or "stop")
  end
  if home_viz == 1 then draw_spectrogram()   -- middle: main-out visualizer (E1 cycles)
  elseif home_viz == 2 then draw_vectorscope()
  elseif home_viz == 3 then draw_styx()
  elseif home_viz == 4 then draw_cocytus()
  else draw_lethe() end
  local sel = util.clamp(cursor[cur] or 1, 1, C.eng.NUM_VOICES); cursor[cur] = sel
  for i = 1, C.eng.NUM_VOICES do
    local x = 4 + (i - 1) * 32
    local on = (params:get("v" .. i .. "_gate") or 0) == 1
    local cur2 = (i == sel)
    screen.level(cur2 and 15 or (on and 10 or 4))
    screen.rect(x, 50, 26, 12)
    if on then screen.fill() else screen.stroke() end
    screen.level(on and 0 or (cur2 and 15 or 6))
    screen.move(x + 13, 59); screen.text_center("V" .. i)
  end
end

-- mod-matrix visible destinations: curated subset + order + labels. The hidden params
-- (drive/chorus/dlysend/hpcut/reverbsend) still route + persist in the engine - they're just not
-- shown here, to streamline the screen. cmd = engine/persistence key; label = what the matrix shows.
local MATRIX_DESTS = {
  { cmd = "pitch",    label = "Pitch"     },
  { cmd = "tune",     label = "Tune"      },
  { cmd = "harm",     label = "Harmonics" },
  { cmd = "timbre",   label = "Timbre"    },
  { cmd = "morph",    label = "Morph"     },
  { cmd = "cut",      label = "LP Cut"    },
  { cmd = "res",      label = "LP Res"    },
  { cmd = "lpgdecay", label = "LPG Decay" },
  { cmd = "pan",      label = "Pan"       },
  { cmd = "level",    label = "Level"     },
}
local mvis = {}   -- flat visible-dest list, built in S.init: [i] = { di = mtx dest index, label }
-- fixed row of 8 mini LFO scopes under the title, aligned with the dest circle columns. Live: the
-- most-recent 8 history samples (1 px each = same time-density as a full 128px scope, i.e. 1/16 the
-- timeframe). Active LFO (the one named in the title) = full white; the others dark gray. 0 line in
-- the middle so bipolar shows above/below.
local SCY, SCA = 11, 5   -- scope 0-line y, amplitude (band y6..16)
local function matrix_scopes()
  local H, ptr = C.mtx.HIST_LEN, C.mtx.hist_ptr
  for s = 1, C.mtx.NUM_SRC do
    local x0 = 56 + (s-1) * 9
    local hist, act = C.mtx.hist[s], (s == mcol())
    screen.aa(0)
    if act then screen.level(1); screen.rect(x0, SCY - SCA, 8, SCA * 2 + 1); screen.fill() end  -- focused: faint bg box
    screen.level(act and 0 or 1); screen.move(x0, SCY); screen.line(x0 + 7, SCY); screen.stroke()  -- 0 line (black on the focused box)
    screen.aa(1); screen.level(act and 15 or 4)
    for i = 0, 7 do
      local v = util.clamp(hist[((ptr - 8 + i) % H) + 1] or 0, -1, 1)
      local yy = SCY - v * SCA
      if i == 0 then screen.move(x0 + i, yy) else screen.line(x0 + i, yy) end
    end
    screen.stroke()
  end
  screen.aa(0)
end

local DR0 = 24   -- first dest-row baseline, below the fixed scope row (uses bottom margin)
-- EUCLID: a fixed 2-row step grid (16 cols x 8px slots = 128x16) above a scrollable param list.
-- Per cell, blit the sprite for its (filled/empty/padding) x (active/idle) state. Padding is
-- detected by mirroring build_pattern's pad-then-rotate, so it moves with Shift. Drone mode (no
-- pattern) draws no steps. Playhead highlight only while playing.
local STEPY, EPY, EVIS = 7, 29, 5   -- steps grid top; param-list baseline (2px gap under steps); visible rows
local function draw_steps(v)
  local e = C.euclid.tracks and C.euclid.tracks[v]
  if not (e and e.patLen and e.patLen > 0) then return end
  -- armed (quantized PLAY pending) is not playing yet: cur_step is stale from the last run
  local playing = C.transport() and not (C.transport_armed and C.transport_armed())
  for idx = 0, math.min(e.patLen, 32) - 1 do
    local x = (idx % 16) * 8
    local y = STEPY + (idx >= 16 and 8 or 0)
    local act = playing and idx == e.cur_step
    local src = (idx - e.shift) % e.patLen
    local img
    if src >= e.steps then         img = act and STEPIMG.padding_active or STEPIMG.padding_idle
    elseif e.pattern[idx + 1] then img = act and STEPIMG.filled_active  or STEPIMG.filled_idle
    else                          img = act and STEPIMG.empty_active   or STEPIMG.empty_idle end
    if img then screen.display_image(img, x, y) end
  end
end

-- scrollable param list below a fixed top section. py = first row baseline, vis = visible rows,
-- sbtop/sbspan = the 1px scrollbar track's top y and height. Shared by the Euclid + LFO views.
local function draw_param_list(lin, ids, py, vis, sbtop, sbspan)
  local c = util.clamp(cursor[lin] or 1, 1, #ids); cursor[lin] = c
  local t = top[lin] or 1
  if c < t then t = c elseif c > t + vis - 1 then t = c - vis + 1 end
  t = util.clamp(t, 1, math.max(1, #ids - vis + 1)); top[lin] = t
  for row = 0, vis - 1 do
    local idx = t + row
    if idx > #ids then break end
    local id = ids[idx]
    local y = py + row * 8
    screen.level(idx == c and 15 or 4); screen.move(4, y); screen.text(short(id))
    -- value: live post-mod result when modulated + unfocused; base value when focused (so you see it)
    local res, base = C.mod_result and C.mod_result[id], params:get(id)
    screen.move(112, y); screen.text_right((res ~= nil and idx ~= c) and vstr(id, res) or vstr(id))
    if res ~= nil and res ~= base then   -- +/- direction (result vs base) in the old circle column
      screen.move(122, y); screen.text(res > base and "+" or "-")
    end
  end
  if #ids > vis then   -- 1px scrollbar at the right edge
    local h = math.max(3, util.round(sbspan * vis / #ids))
    local yy = sbtop + util.round((sbspan - h) * (t - 1) / math.max(1, #ids - vis))
    screen.level(2); screen.rect(126, yy, 1, h); screen.fill()
  end
end

local function draw_euclid(lin)
  local view = VIEWS[lin]
  header(view.name, lin)
  draw_steps(view.v)
  draw_param_list(lin, view.ids, EPY, EVIS, 24, 38)   -- params below the step grid
end

local function draw_matrix(lin)
  local mc = mcol()
  header("MOD MATRIX", lin)
  -- LFO title left of the position dots (dots start at x88; a little air between them)
  screen.level(8); screen.move(78, TY); screen.text_right("LFO" .. mc)
  matrix_scopes()
  local n = #mvis
  local c = util.clamp(mrow, 1, n); mrow = c
  -- focused-cell depth as a percentage, in the empty band just below the title (left of the scopes)
  screen.level(8); screen.move(2, 13); screen.text(string.format("%.1f%%", (C.mtx.cell[mvis[c].di][mc] or 0) * 100))
  local t = mtop
  if c < t then t = c elseif c > t + 4 then t = c - 4 end
  t = util.clamp(t, 1, math.max(1, n - 4)); mtop = t
  screen.aa(1)
  for row = 0, 4 do
    local i = t + row
    if i > n then break end
    local e = mvis[i]
    local y = DR0 + row * 9
    screen.level(i == c and 15 or 4); screen.move(4, y); screen.text(e.label)
    for s = 1, C.mtx.NUM_SRC do
      -- wire: column from the top down to the cell + row from the label across to the cell (not past it)
      local hl = ((s == mc and i <= c) or (i == c and s <= mc)) and 4 or 2
      radial(56 + (s-1) * 9 + 4, y - 2, 3.5, C.mtx.cell[e.di][s] or 0, hl)
    end
  end
  screen.aa(0)
  if c >= t and c <= t + 4 then
    screen.level(15); screen.rect(56 + (mc-1) * 9, DR0 + (c-t) * 9 - 6, 9, 9); screen.stroke()
  end
end

-- MOD SEQ: per-track row = 5 bipolar step bars + RT(div) + L(len) + 3 destinations (osc:param text +
-- amount circle). Controls mirror the MATRIX exactly: E2 = row (track), K2/K3 = column, E3 = tweak.
-- 13 columns: 1-5 steps, 6 div, 7 len, then 2x(osc, param, amount). Tooltip line expands the hover.
-- Param short names come from the shared targets registry (C.seq.params_short), the app's single source.
local SEQ_NCOL = 13
local MS_BARX, MS_BARP, MS_BARW, MS_BARH = 2, 4, 3, 4   -- step-bar x; pitch; width; bipolar half-height (9 levels)
local MS_DIVX, MS_LENX = 24, 37         -- RT (div name) and L (length) text x
local MS_DSTX = {47, 90}                -- per-destination block left x (2 destinations, widely spaced)
local MS_CIRCDX = 28                     -- amount-circle x offset; clears the widest osc:param ("2:Mor" = 21px)
local MS_ROW0, MS_RPITCH = 13, 10        -- first row baseline; row pitch (5 rows: 13,23,33,43,53)
local function seq_osc_label(o) return (o and o >= 0) and (C.seq.osc_names[o + 1] or "?") or nil end
local function pascal(s) return (s:gsub("(%a)(%a*)", function(a, b) return a:upper() .. b end)) end  -- "hp cutoff" -> "Hp Cutoff"

-- bottom-line expansion of the hovered cell (track + column)
local function seq_tooltip(tk, col)
  local tr = C.seq.tracks[tk]
  if col <= 5 then return string.format("CV%d  step %d = %+.2f", tk, col, tr.steps[col] or 0)
  elseif col == 6 then return string.format("CV%d  rate %s", tk, C.seq.div_names[tr.div] or "?")
  elseif col == 7 then return string.format("CV%d  length %d", tk, tr.length) end
  local g = math.floor((col - 8) / 3) + 1
  local o = tr.targets[g]
  local osc = (o and o >= 0) and table.concat(C.seq.osc_voices(o), "+") or "-"   -- "2+3"; "-" = no track
  local pl = (tr.param[g] >= 1) and pascal(C.seq.param_labels[tr.param[g]] or "?") or "---"   -- "---" = no param
  return string.format("%s: %s  %+.1f%%", osc, pl, (tr.amount[g] or 0) * 100)
end

-- E3 on the focused cell. Routing edits (osc/param/amount) re-derive the active-dest set.
local function seq_edit(tk, col, d)
  local tr = C.seq.tracks[tk]
  if col <= 5 then tr.steps[col] = util.clamp((tr.steps[col] or 0) + d * 0.05, -1, 1)
  elseif col == 6 then tr.div = util.clamp(tr.div + (d > 0 and 1 or -1), 1, #C.seq.divisions)
  elseif col == 7 then tr.length = util.clamp(tr.length + (d > 0 and 1 or -1), 2, C.seq.NUM_STEPS)
  else
    local g, sub = math.floor((col - 8) / 3) + 1, (col - 8) % 3
    if sub == 0 then tr.targets[g] = util.clamp(tr.targets[g] + (d > 0 and 1 or -1), -1, 9)
    elseif sub == 1 then tr.param[g] = util.clamp(tr.param[g] + (d > 0 and 1 or -1), 0, #C.seq.params_list)  -- 0 = none
    else tr.amount[g] = util.clamp((tr.amount[g] or 0) + ddelta(d), -1, 1) end   -- 0.1% steps + accel
    C.seq.rebuild_active()
  end
end

-- K2+K3 in CV SEQ: reset the focused cell to its default (step 0, div x1, len 5, track/param empty).
local function seq_reset_cell(tk, col)
  local tr = C.seq.tracks[tk]
  if col <= 5 then tr.steps[col] = 0
  elseif col == 6 then tr.div = 3
  elseif col == 7 then tr.length = C.seq.NUM_STEPS
  else
    local g, sub = math.floor((col - 8) / 3) + 1, (col - 8) % 3
    if sub == 0 then tr.targets[g] = -1
    elseif sub == 1 then tr.param[g] = 0
    else tr.amount[g] = 0 end
    C.seq.rebuild_active()
  end
end

local function draw_modseq(lin)
  header("CV SEQUENCER", lin)
  local strk = util.clamp(cursor[lin] or 1, 1, C.seq.NUM_TRACKS); cursor[lin] = strk
  seqcol = util.clamp(seqcol, 1, SEQ_NCOL)

  for tk = 1, C.seq.NUM_TRACKS do
    local tr = C.seq.tracks[tk]
    local sel = (tk == strk)
    local ry = MS_ROW0 + (tk - 1) * MS_RPITCH   -- text baseline
    local yz = ry - 3                             -- bar 0-line (centered, bars swing +-MS_BARH)

    screen.level(1); screen.rect(MS_BARX, yz, (C.seq.NUM_STEPS - 1) * MS_BARP + MS_BARW, 1); screen.fill()  -- 0 line
    for s = 1, C.seq.NUM_STEPS do
      local x = MS_BARX + (s - 1) * MS_BARP
      local h = util.round(util.clamp(tr.steps[s] or 0, -1, 1) * MS_BARH)
      screen.level((s > tr.length) and 1 or ((s == tr.current_step) and 15 or (sel and 6 or 4)))
      if h > 0 then screen.rect(x, yz - h, MS_BARW, h); screen.fill()
      elseif h < 0 then screen.rect(x, yz + 1, MS_BARW, -h); screen.fill() end
    end

    screen.level(sel and 12 or 3)
    screen.move(MS_DIVX, ry); screen.text(C.seq.div_names[tr.div] or "?")
    screen.move(MS_LENX, ry); screen.text(tostring(tr.length))

    screen.aa(1)
    for g = 1, C.seq.NUM_TARGETS do
      local bx, o, p = MS_DSTX[g], tr.targets[g], tr.param[g]
      local oa, pa = (o and o >= 0), (p and p >= 1)               -- track (osc) / param assigned?
      screen.level(sel and ((oa or pa) and 12 or 5) or ((oa or pa) and 4 or 2))   -- dim while empty
      local oc = oa and seq_osc_label(o) or "-"
      local pc = pa and (C.seq.params_short[p] or "?") or "---"
      screen.move(bx, ry); screen.text(oc .. ((oa or pa) and ":" or " ") .. pc)   -- "1:Tim" / "-:Mor" / "- ---"
      radial(bx + MS_CIRCDX, ry - 3, 2.5, tr.amount[g] or 0, sel and 3 or 2)   -- 1px up: centered in the cell
    end
    screen.aa(0)
  end

  -- cursor box around the focused cell of the focused row
  local ry = MS_ROW0 + (strk - 1) * MS_RPITCH
  local bx, bw, by, bh = MS_BARX, 9, ry - 7, 9
  if seqcol <= 5 then bx, bw, bh = MS_BARX + (seqcol - 1) * MS_BARP, MS_BARW, 10  -- bars: left edge in 1px, +1 down
  elseif seqcol == 6 then bx, bw, by, bh = MS_DIVX - 1, 11, ry - 6, 8     -- rate: 1px shorter on top
  elseif seqcol == 7 then bx, bw, by, bh = MS_LENX - 1, 6, ry - 6, 8      -- length: shorter top, +1px right
  else
    local g, sub = math.floor((seqcol - 8) / 3) + 1, (seqcol - 8) % 3
    local base = MS_DSTX[g]
    if sub == 0 then bx, bw, by, bh = base - 1, 7, ry - 6, 8              -- track (osc): shorter top, +2px right
    elseif sub == 1 then bx, bw, by, bh = base + 5, 17, ry - 6, 8         -- param: 1px shorter on top
    else bx, bw = base + MS_CIRCDX - 4, 9 end                            -- amount: circle box (unchanged)
  end
  screen.level(15); screen.rect(bx, by, bw, bh); screen.stroke()

  screen.level(8); screen.move(2, 62); screen.text(seq_tooltip(strk, seqcol))
end

-- MACRO CONTROLLER: a big bipolar AMOUNT gauge (-200%..+200%, the Control-All performance knob) over
-- 3 destination slots IDENTICAL to a CV-seq destination (osc:param + bipolar depth circle). E2 toggles
-- focus AMOUNT<->destinations; on AMOUNT E3 = amount + a big focus rect; on destinations K2/K3 = column,
-- E3 = tweak, K2+K3 = reset (the shared deferred-release chord, like every grid view).
local MAC_DSTX = {8, 49, 90}      -- 3 destination block x (reuses the CV-seq cell recipe + MS_CIRCDX)
local MAC_DSTY = 50               -- destination text baseline
local MAC_BARX, MAC_BARW = 4, 120 -- bipolar amount bar: x and full width (center = MAC_BARX+MAC_BARW/2)

-- E3 on the focused destination cell (osc/param/depth), identical to seq_edit.
local function macro_edit(col, d)
  local g, sub = math.floor((col - 1) / 3) + 1, (col - 1) % 3
  local s = C.mac.slots[g]
  if sub == 0 then s.osc = util.clamp(s.osc + (d > 0 and 1 or -1), -1, 9)
  elseif sub == 1 then s.param = util.clamp(s.param + (d > 0 and 1 or -1), 0, #C.mac.targets.target_cmds)
  else s.depth = util.clamp((s.depth or 0) + ddelta(d), -1, 1) end   -- 0.1% steps + accel
  C.mac.rebuild_active()
end

-- K2+K3 reset: AMOUNT -> 0, or the focused destination cell -> empty.
local function macro_reset()
  if macro_sel == 0 then params:set("dronage_macro_amount", 0); return end
  local g, sub = math.floor((macro_sel - 1) / 3) + 1, (macro_sel - 1) % 3
  local s = C.mac.slots[g]
  if sub == 0 then s.osc = -1
  elseif sub == 1 then s.param = 0
  else s.depth = 0 end
  C.mac.rebuild_active()
end

local function macro_tooltip()
  if macro_sel == 0 then
    return string.format("AMOUNT  %+d%%", util.round(params:get("dronage_macro_amount") * 100))
  end
  local s = C.mac.slots[math.floor((macro_sel - 1) / 3) + 1]
  local osc = (s.osc >= 0) and table.concat(C.seq.osc_voices(s.osc), "+") or "-"
  local pl = (s.param >= 1) and pascal(C.seq.param_labels[s.param] or "?") or "---"
  return string.format("%s: %s  %+.1f%%", osc, pl, (s.depth or 0) * 100)
end

local function draw_macro(lin)
  header("MACRO CONTROLLER", lin)
  local amt = params:get("dronage_macro_amount")   -- -2..2
  local af = (macro_sel == 0)                        -- AMOUNT focused?

  screen.level(af and 15 or 6); screen.move(64, 15); screen.text_center("AMOUNT")
  local bcx = MAC_BARX + MAC_BARW / 2                -- bar center x
  screen.level(2); screen.rect(MAC_BARX, 20, MAC_BARW, 6); screen.stroke()   -- faint track frame
  local fw = util.round((amt / 2) * (MAC_BARW / 2))  -- amt/2 = normalized -1..1
  screen.level(af and 15 or 8)
  if fw > 0 then screen.rect(bcx, 21, fw, 4); screen.fill()
  elseif fw < 0 then screen.rect(bcx + fw, 21, -fw, 4); screen.fill() end
  screen.level(4); screen.rect(bcx, 20, 1, 6); screen.fill()                 -- center tick
  screen.level(af and 15 or 6); screen.move(64, 36); screen.text_center(string.format("%+d%%", util.round(amt * 100)))

  screen.aa(1)
  for g = 1, C.mac.NUM_SLOTS do
    local s, bx = C.mac.slots[g], MAC_DSTX[g]
    local oa, pa = (s.osc >= 0), (s.param >= 1)
    screen.level((not af) and ((oa or pa) and 12 or 5) or ((oa or pa) and 4 or 2))
    local oc = oa and seq_osc_label(s.osc) or "-"
    local pc = pa and (C.seq.params_short[s.param] or "?") or "---"
    screen.move(bx, MAC_DSTY); screen.text(oc .. ((oa or pa) and ":" or " ") .. pc)
    radial(bx + MS_CIRCDX, MAC_DSTY - 3, 2.5, s.depth or 0, (not af) and 3 or 2)
  end
  screen.aa(0)

  if af then
    screen.level(15); screen.rect(2, 8, 124, 31); screen.stroke()   -- covers title + bar + %
  else
    local g, sub = math.floor((macro_sel - 1) / 3) + 1, (macro_sel - 1) % 3
    local base = MAC_DSTX[g]
    local bx, bw, by, bh = base - 1, 5, MAC_DSTY - 7, 9
    if sub == 0 then bx, bw, by, bh = base - 1, 7, MAC_DSTY - 6, 8        -- track (osc): +2px right, like CV SEQ
    elseif sub == 1 then bx, bw, by, bh = base + 5, 17, MAC_DSTY - 6, 8
    else bx, bw = base + MS_CIRCDX - 4, 9 end
    screen.level(15); screen.rect(bx, by, bw, bh); screen.stroke()
  end

  screen.level(8); screen.move(2, 62); screen.text(macro_tooltip())
end

-- generic full-screen yes/no confirmation, shared by destructive actions (project overwrite/delete,
-- scene initialize). { kind = the view it belongs to, prompt = 1-2 centered lines, action = the fn to
-- run on K3 = yes }. Drawn by the owning view; resolved in S.key (K3 = yes, K2 = no).
local confirm = nil
local function draw_confirm(c)
  screen.level(15)
  local y0 = (#c.prompt == 1) and 28 or 22
  for i, line in ipairs(c.prompt) do screen.move(64, y0 + (i - 1) * 12); screen.text_center(line) end
  screen.level(4); screen.move(64, 54); screen.text_center("K2 = no      K3 = yes")
end

local function draw_scenes(lin)
  if confirm and confirm.kind == "scenes" then draw_confirm(confirm); return end
  header("SCENES", lin)
  for i = 1, C.scenes.NUM do
    local x = 10 + ((i-1) % 4) * 28
    local y = 18 + math.floor((i-1)/4) * 18
    local active, cur2 = (i == C.scenes.current), (i == scur)
    screen.level(cur2 and 15 or (C.scenes.modified(i) and 5 or 2))
    screen.rect(x, y, 22, 13)
    if active then screen.fill() else screen.stroke() end
    screen.level(active and 0 or (cur2 and 15 or 6))
    screen.move(x + 11, y + 9); screen.text_center(tostring(i))
  end
  screen.level(3); screen.move(2, 62); screen.text("E2 sel  K2 recall  K3 store")
end

-- LIVE LOOPER: crossfade gauge on top (MACRO's AMOUNT recipe, unipolar live->loop), loop
-- status + playhead strip under it, then the setting rows + the ERASE action row. One master
-- loop of the engine output - no slots, no per-voice anything (lib/dronage_norns_looper.lua).
local LP_ROWS = { "LENGTH", "QUANTIZE", "OVERDUB FB", "ERASE BUFFER" }
local LP_IDS  = { "lp_len", "lp_quant", "lp_od_pre" }   -- row 4 (erase) has no param

local function confirm_erase()
  confirm = { kind = "looper", prompt = { "ERASE LOOP BUFFER?" },
    action = function()
      local ok, msg = C.looper.erase()
      toast(ok and "BUFFER ERASED" or msg)
    end }
end

local function draw_looper(lin)
  if confirm and confirm.kind == "looper" then draw_confirm(confirm); return end
  header("LIVE LOOPER", lin)
  local lp = C.looper
  local x = params:get("lp_xfade")
  local xf = (looper_sel == 0)

  -- gauge: LIVE ... state ... LOOP labels, then the fader bar with a handle
  screen.level(x < 0.5 and 10 or 3); screen.move(10, 15); screen.text("LIVE")
  screen.level(x >= 0.5 and 10 or 3); screen.move(118, 15); screen.text_right("LOOP")
  -- the status slot doubles as the key legend (the footer line is spent on the rows)
  local st
  if lp.state == "armed" then st = "ARMED"
  elseif lp.state == "rec" then st = lp.out_pending and "REC > OUT" or "REC (K3 OUT)"
  elseif lp.filled then st = string.format("%gb (K3 DUB)", lp.beats)
  else st = "K3 = REC" end
  local blink = (lp.state == "idle") or ((util.time() * (lp.state == "rec" and 3 or 1.5)) % 1 < 0.6)
  screen.level(blink and (lp.state == "idle" and 6 or 15) or 2)
  screen.move(64, 15); screen.text_center(st)
  screen.level(2); screen.rect(10, 20, 108, 7); screen.stroke()
  local fw = util.round(x * 104)
  screen.level(xf and 15 or 8)
  if fw > 0 then screen.rect(12, 22, fw, 3); screen.fill() end
  screen.rect(11 + fw, 19, 2, 9); screen.fill()                   -- handle
  if xf then screen.level(15); screen.rect(8, 10, 112, 20); screen.stroke() end

  -- playhead strip: the loop cycle sweeping left to right (only when something is recorded)
  if lp.filled then
    screen.level(1); screen.rect(10, 32, 108, 2); screen.fill()
    screen.level(12); screen.rect(10 + util.round(lp.phase * 106), 31, 2, 4); screen.fill()
  end

  -- rows: LENGTH / QUANTIZE / OVERDUB FB / ERASE BUFFER
  local LP_LEN, LP_Q = { "4", "8", "16", "32", "64", "128" }, { "1", "2", "4", "8" }
  local vals = {
    LP_LEN[params:get("lp_len")] .. " beats",
    LP_Q[params:get("lp_quant")] .. (params:get("lp_quant") == 1 and " beat" or " beats"),
    util.round(params:get("lp_od_pre") * 100) .. "%",
    "",
  }
  for i = 1, 4 do
    local y = 41 + (i - 1) * 7
    local f = (looper_sel == i)
    screen.level(f and 15 or 4)
    screen.move(10, y); screen.text(LP_ROWS[i])
    screen.move(118, y); screen.text_right(vals[i])
  end
end

-- PROJECT browser: a scrollable list of saved projects + a "new" entry. E2 scroll · K3 load (or NEW
-- on the top entry) · K2 save (overwrite the loaded project, or name a new one) · K2+K3 delete ·
-- K1+K3 save under a fresh random name. Naming uses the built-in textentry (random pre-fill + an
-- "EXISTS" overwrite warning via its check hook).
local function project_items()
  local items = { "+ new project" }
  for _, n in ipairs(C.project.list()) do items[#items + 1] = n end
  return items
end

local function project_save_named()
  local function check(txt)
    if #txt > C.project.NAME_MAX then return "MAX " .. C.project.NAME_MAX end
    return (txt ~= "" and C.project.exists(txt)) and "EXISTS" or nil
  end
  textentry.enter(function(txt)
    if txt and txt ~= "" then
      txt = txt:sub(1, C.project.NAME_MAX)   -- enforce the cap
      C.project.save(txt); toast("SAVED " .. txt)
    end
  end, C.project.random_name(), "project name", check)   -- K2 cancels (norns built-in)
end

-- K2 = save, acting on the HOVERED entry: "+ new project" -> name a new one; an existing project ->
-- overwrite it, behind an "are you sure" confirmation.
local function project_save()
  local idx = util.clamp(cursor[cur] or 1, 1, #project_items())
  if idx == 1 then project_save_named()
  else
    local name = project_items()[idx]
    confirm = { kind = "project", prompt = { "overwrite project", '"' .. name .. '"?' },
                action = function() C.project.save(name); toast("SAVED " .. name) end }
  end
end

-- "Keep BPM On Load" (GLOBAL): hold the room's tempo through project loads and NEW - the
-- incoming pset would otherwise re-tempo a sounding live loop mid-crossfade. Live-room
-- toggle (never saved); normal per-scene tempo switching is untouched.
local function hold_bpm(fn)
  return function()
    local keep = params:get("dronage_keep_bpm") == 2
    local t = keep and params:get("clock_tempo")
    fn()
    if keep then params:set("clock_tempo", t) end
  end
end

local function project_activate(idx)
  -- both paths replace the live (possibly unsaved) state -> ask first, like overwrite/delete.
  -- Both are undo-checkpointed too (the entry carries the scene slots), so even a confirmed
  -- wrong LOAD is one K2+E1 turn from recovery.
  local go
  if idx == 1 then
    go = function() C.undo.around("NEW PROJECT", C.project_new); toast("NEW PROJECT") end
  else
    local n = project_items()[idx]; if not n then return end
    go = function()
      C.undo.around("PROJECT LOAD", function() C.project.load(n) end); toast("LOADED " .. n)
    end
  end
  confirm = { kind = "project", prompt = { "LOSE UNSAVED CHANGES?" }, action = hold_bpm(go) }
end

local function draw_project(lin)
  if confirm and confirm.kind == "project" then draw_confirm(confirm); return end
  header("PROJECT", lin)
  local items = project_items()
  local c = util.clamp(cursor[lin] or 1, 1, #items); cursor[lin] = c
  local vis, t = 5, top[lin] or 1
  if c < t then t = c elseif c > t + vis - 1 then t = c - vis + 1 end
  t = util.clamp(t, 1, math.max(1, #items - vis + 1)); top[lin] = t
  for row = 0, vis - 1 do
    local idx = t + row
    if idx > #items then break end
    local y, name = 16 + row * 9, items[idx]
    screen.level(idx == c and 15 or 4)
    screen.move(6, y); screen.text((idx == c and ">" or " ") .. name)
    if idx > 1 and name == C.project.current then screen.level(idx == c and 15 or 6); disc(123, y - 2, 1.5) end
  end
  if #items == 1 then screen.level(2); screen.move(6, 25); screen.text("no saved projects yet") end
  if #items > vis then
    local h = math.max(3, util.round(38 * vis / #items))
    local yy = 16 + util.round((38 - h) * (t - 1) / math.max(1, #items - vis))
    screen.level(2); screen.rect(126, yy, 1, h); screen.fill()
  end
  screen.level(3); screen.move(2, 62); screen.text("E2 sel  K2 save  K3 load")
end

-- full-width LFO scope (128x17, right below the title): the most-recent 128 history samples,
-- 1px each = 16x the matrix mini-scope's 8-sample window. Newest on the right, 0-line in the middle.
local LSY, LSA = 15, 8   -- 0-line y, amplitude (band y7..23)
local function draw_lfo_wave(s)
  local H, ptr = C.mtx.HIST_LEN, C.mtx.hist_ptr
  local hist = C.mtx.hist[s]
  screen.aa(0); screen.level(1); screen.move(0, LSY); screen.line(127, LSY); screen.stroke()  -- 0 line
  screen.aa(1); screen.level(15)
  for x = 0, H - 1 do
    local v = util.clamp(hist[((ptr - H + x) % H) + 1] or 0, -1, 1)
    local y = LSY - v * LSA
    if x == 0 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke(); screen.aa(0)
end

-- LFO param list, context-filtered like the PARAMETERS menu (matrix lfo_visibility): Rate when free
-- / Div when synced; Length + Variation only for S&H shapes. Both still exist + save (display-only).
lfo_ids = function(view)
  local s = view.src
  local synced = C.mtx.src[s].sync          -- resolved sync bool (option value, reorder-safe)
  local shape = C.mtx.src[s].shape          -- resolved waveform id 1..7 (option value, reorder-safe)
  local out = {}
  for _, id in ipairs(view.ids) do
    local keep = true
    if id:match("_rate$") then keep = not synced
    elseif id:match("_div$") then keep = synced
    elseif id:match("_length$") then keep = (shape == 7)      -- loop length: S&H SEED only
    elseif id:match("_variation$") then keep = (shape == 6)   -- walk distance: S&H RND only
    elseif id:match("_mutate$") then keep = (shape == 7) end  -- Turing mutation: S&H SEED only
    if keep then out[#out + 1] = id end
  end
  return out
end

local function draw_lfo(lin)
  local view = VIEWS[lin]
  header(view.name, lin)
  draw_lfo_wave(view.src)
  draw_param_list(lin, lfo_ids(view), EPY, EVIS, 24, 38)   -- params below the waveform
end

-- ---------- minimap (K1 held) ----------
local function draw_minimap()
  for lin, v in ipairs(VIEWS) do
    local x, y = 1 + v.col * 16, 1 + (v.row - 1) * 8   -- +1 inset so left/top borders aren't clipped
    if lin == jump then
      screen.level(15); screen.rect(x - 1, y - 1, 15, 7); screen.fill()  -- +1 up/left: match the stroke outline
      screen.level(0)
    else
      screen.level(3); screen.rect(x, y, 14, 6); screen.stroke()
      screen.level(8)
    end
    screen.move(x + 6, y + 5); screen.text_center(v.tag)   -- centered, nudged 1px left
  end
  if k3held then   -- K3 held: master-volume overlay replaces the title (E1 tweaks it)
    screen.level(15); screen.move(126, 6)
    screen.text_right("MASTER VOL: " .. util.round((params:get("dronage_master_vol") or 1) * 100) .. "%")
  else
    screen.level(2); screen.move(126, 6); screen.text_right("minimap")   -- title, empty top-right
  end
  -- full name of the hovered cell, bottom-right (the empty corner - no cells there to overlap)
  screen.level(15); screen.move(126, 63); screen.text_right(VIEWS[jump].name)
end

-- ---------- public ----------
function S.init(ctx)
  C = ctx
  -- receive the engine's master-out spectrum (forwarded to matron's OSC-in) for the HOME visualizer
  osc.event = function(path, args)
    if path == "/dr_spec" then push_spec_column(args)
    elseif path == "/dr_scope" then scope_data = args end
  end
  -- euclid step sprites (7x7). active = playhead on the step, idle = otherwise.
  local function _li(n)
    if not (norns.state and norns.state.path) then return nil end
    local ok, im = pcall(screen.load_png, norns.state.path .. "images/" .. n .. ".png")
    return ok and im or nil
  end
  STEPIMG.empty_active   = _li("step_empty_active");   STEPIMG.empty_idle   = _li("step_empty_idle")
  STEPIMG.filled_active  = _li("step_filled_active");  STEPIMG.filled_idle  = _li("step_filled_idle")
  STEPIMG.padding_active = _li("step_padding_active"); STEPIMG.padding_idle = _li("step_padding_idle")
  -- flatten the curated matrix dests across voices: per voice, the MATRIX_DESTS order.
  for i = #mvis, 1, -1 do mvis[i] = nil end
  for v = 1, C.eng.NUM_VOICES do
    for _, md in ipairs(MATRIX_DESTS) do
      local di = C.mtx.find_dest(v, md.cmd)
      if di then mvis[#mvis + 1] = { di = di, label = v .. " " .. md.label } end
    end
  end
  for i = #VIEWS, 1, -1 do VIEWS[i] = nil end   -- clear in place (keep S.VIEWS reference valid)
  for k in pairs(ROWVIEWS) do ROWVIEWS[k] = nil end
  add(1, 0, "HOME", "H", "home")
  for i = 1, 4 do add(2, i-1, "VOICE "..i, "V"..i, "panel", {ids = vids(i)}) end
  for i = 1, 4 do add(3, i-1, "EUCLID "..i, "E"..i, "euclid", {ids = eids(i), v = i}) end
  for s = 1, 8 do add(4, s-1, "LFO "..s, "L"..s, "lfo", {ids = lids(s), src = s}) end
  -- 8 MM cells, one per LFO column: jumping into any of them from the minimap/grid lands on
  -- the SAME dest row (shared mrow) with that cell's LFO column focused. E1 walks columns.
  for s = 1, 8 do add(5, s - 1, "MOD MATRIX", "MM", "matrix", { src = s }) end
  add(6, 0, "DELAY", "DL", "panel", {ids = DELAY}); add(6, 1, "REVERB", "RV", "panel", {ids = REVERB})
  add(6, 2, "MASTER FX", "M", "panel", {ids = TAPE})
  add(7, 0, "MACRO CONTROLLER", "MC", "macro"); add(7, 1, "CV SEQUENCER", "CS", "modseq"); add(7, 2, "SCENES", "S", "scenes")
  if C.looper then add(7, 3, "LIVE LOOPER", "LL", "looper") end   -- absent on LITE (flag-gated)
  add(8, 0, "GLOBAL", "GL", "panel", {ids = GLOBAL}); add(8, 1, "PROJECT", "PR", "project")
end

-- transient popup (centered box + text), e.g. "RANDOMIZED SEED"; auto-clears after ~1 s
local function draw_toast()
  if util.time() >= toast_until then return end
  local w, h = math.ceil(screen.text_extents(toast_msg)) + 11, 12
  local x, y = util.round(64 - w / 2), 27   -- top trimmed 1px vs a 13-tall box; bottom stays at 38
  screen.level(0); screen.rect(x, y, w, h); screen.fill()       -- black box covers what's behind
  screen.level(15); screen.rect(x, y, w, h); screen.stroke()    -- white border
  screen.move(64, y + 8); screen.text_center(toast_msg)         -- white, centered
end

function S.redraw()
  screen.clear(); screen.aa(0); screen.font_face(1); screen.font_size(8)
  if (k1held and not k1_consumed) or map_held then draw_minimap()   -- a combo consumes the hold -> show the view instead
  else
    local v = VIEWS[cur]
    local k = v.kind
    if k == "home" then draw_home()
    elseif k == "matrix" then draw_matrix(cur)
    elseif k == "modseq" then draw_modseq(cur)
    elseif k == "macro" then draw_macro(cur)
    elseif k == "looper" then draw_looper(cur)
    elseif k == "scenes" then draw_scenes(cur)
    elseif k == "project" then draw_project(cur)
    elseif k == "lfo" then draw_lfo(cur)
    elseif k == "euclid" then draw_euclid(cur)
    else header(v.name, cur); draw_panel(cur) end
  end
  draw_toast()
  screen.update()
end

-- E3-equivalent value edit on view v's focused thing - the ONE per-param feel dispatch,
-- shared by the encoder (S.enc n==3) and the grid's +/- pads so both stay identical.
local function tweak_view(v, d)
  local k = v.kind
  if k == "matrix" then
    local di = mvis[util.clamp(mrow, 1, #mvis)].di
    local mc = mcol()
    C.mtx.set_cell(di, mc, (C.mtx.cell[di][mc] or 0) + ddelta(d)); touched()   -- 0.1% steps + accel
  elseif k == "modseq" then
    seq_edit(cursor[cur] or 1, seqcol, d); touched()
  elseif k == "macro" then
    if macro_sel == 0 then pdelta("dronage_macro_amount", d)   -- amount = live knob, not undo-tracked
    else macro_edit(macro_sel, d); touched() end
  elseif k == "looper" then
    if k3held then k3_used = true end   -- editing during a K3 hold: release must not fire record
    if looper_sel == 0 then pdelta("lp_xfade", d)              -- fader = live knob, not undo-tracked
    elseif looper_sel <= 2 then pdelta(LP_IDS[looper_sel], d > 0 and 1 or -1)   -- option lists: one entry per detent
    elseif looper_sel == 3 then pdelta("lp_od_pre", d) end
    -- erase row: nothing to tweak
  elseif k == "panel" or k == "lfo" or k == "euclid" then
    local ids = view_ids(v)   -- LFO sync/shape filtering + GLOBAL grid-row filtering
    local id = ids[util.clamp(cursor[cur] or 1, 1, #ids)]
    if k3held then k3_used = true end   -- editing during a K3 hold: release must not gate-toggle
    if id:match("_pitch$") and k3held then
      -- K3 + E3 on Pitch: jump whole octaves (CW = up). Deliberately blunter than the normal
      -- pitch feel: enc accel is ignored and it takes 2 detents per jump, so a gentle touch
      -- can't skip several octaves.
      k3_used = true
      if d * oct_acc < 0 then oct_acc = 0 end
      oct_acc = oct_acc + (d > 0 and 1 or -1)
      if math.abs(oct_acc) >= 2 then
        params:set(id, params:get(id) + (oct_acc > 0 and 12 or -12)); oct_acc = 0
      end
    elseif id:match("_pitch$") and C.scales.idx and C.scales.idx > 1 then
      params:set(id, C.scales.next(params:get(id), d > 0 and 1 or -1))   -- scale on: step note by note
    elseif id:match("_pitch$") then
      fdelta(id, d, PITCH_ACCK)   -- pitch: fine slow detent, hotter fast flick
    elseif id:match("_tune$") and k3held then
      -- K3 + E3 on Tune: snap to whole semitones - next integer in the turn direction, then 1/detent
      k3_used = true
      local val = params:get(id)
      params:set(id, util.clamp(d > 0 and (math.floor(val + 1e-6) + 1) or (math.ceil(val - 1e-6) - 1), -12, 12))
    elseif id:match("_tune$") then
      fdelta(id, d, TUNE_ACCK)   -- tune: 0.01 st detents with a gentle fast-flick curve
    elseif id:match("_cut$") or id:match("_hpcut$") then
      fdelta(id, d, CUT_ACCK, CUT_FASTDT)   -- filter freqs: same curve, hotter K + wider window
    elseif id:match("_phase$") and k3held then
      -- K3 + E3 on Phase: snap to multiples of 3.125% (= one S&H step at the max Length of 32)
      local q, val = 0.03125, params:get(id)
      params:set(id, util.clamp(d > 0 and (math.floor(val / q + 1e-6) + 1) * q or (math.ceil(val / q - 1e-6) - 1) * q, 0, 1))
    elseif id:match("_phase$") then
      fdelta(id, d, PHASE_ACCK)   -- 0.125% detents with a gentle fast-flick curve
    elseif id:match("_esteps$") or id:match("_erate$") then
      pdelta(id, d > 0 and 1 or -1)   -- euclid option params: one entry per detent (no enc-accel jumps)
    else
      pdelta(id, d)
    end
  end
  -- home / scenes / project: no focused value to tweak
end

-- move to prev/next view inside the current row (E1, no K1)
local function step_in_row(d)
  local rv = ROWVIEWS[VIEWS[cur].row]
  local i = 1
  for k, l in ipairs(rv) do if l == cur then i = k break end end
  i = util.clamp(i + d, 1, #rv)
  cur = rv[i]
  if C.rand then C.rand.nav() end   -- leaving a page re-arms its randomize-press alternation
end

-- ---------- shared action bodies (physical keys AND the grid route through these) ----------
-- roll the current page's curated dice (the K1+K2+K3 chord body; grid RND too)
local function do_randomize()
  if not C.rand then return end
  local vw = VIEWS[cur]
  local focus   -- matrix: the focused row's voice; CV seq: the cursor's track
  if vw.kind == "matrix" then
    focus = C.mtx.dests[mvis[util.clamp(mrow, 1, #mvis)].di].voice
  elseif vw.kind == "modseq" then
    focus = util.clamp(cursor[cur] or 1, 1, C.seq.NUM_TRACKS)
  end
  local msg = C.rand.page(vw, focus)
  if msg then toast(msg) end
end

-- recall the highlighted scene (scenes K2 release; grid YES on SCENES)
local function scene_recall()
  if scur ~= C.scenes.current then   -- same slot = no-op in switch(); don't checkpoint it
    C.undo.around("SCENE", function() C.scenes.switch(scur) end)
  end
  toast("RECALLED " .. scur)
end

-- store into the highlighted scene slot (scenes K3 release; grid SHIFT-tap on SCENES).
-- Storing over ANOTHER slot's snapshot asks first; the current slot is the routine save.
local function scene_store()
  local function store()
    C.undo.around("SCENE STORE", function() C.scenes.store(scur) end); toast("STORED " .. scur)
  end
  if C.scenes.slots[scur] ~= nil and scur ~= C.scenes.current then
    confirm = { kind = "scenes", prompt = { "OVERWRITE SCENE " .. scur .. "?" }, action = store }
  else store() end
end

-- scene clipboard verbs (norns: K1+K2 copy current / K1+K3 paste to focused, SCENES view
-- only; grid: SHIFT+scene-pad hold = copy that slot / tap = paste to it). Copy of the
-- active scene captures the LIVE state (unsaved tweaks travel); paste is undoable.
local function scene_copy(i)
  if C.scenes.copy(i) then toast("COPIED SCENE " .. i)
  else toast("SCENE " .. i .. " EMPTY") end
end
local function scene_paste(i)
  if not C.scenes.clip then toast("NOTHING COPIED"); return end
  scur = i
  C.undo.around("SCENE PASTE", function() C.scenes.paste(i) end)
  toast("PASTED TO " .. i)
end

-- open the INITIALIZE SCENE confirm (scenes K2+K3; grid RST on SCENES)
local function confirm_scene_init()
  local slot = scur
  confirm = { kind = "scenes", prompt = { "INITIALIZE SCENE " .. slot .. "?" },
              action = function()
                C.undo.around("SCENE INIT", function() C.scenes.clear(slot) end)
                toast("CLEARED " .. slot)
              end }
end

-- open the delete-project confirm (project K2+K3; grid RST on PROJECT). No-op on "+ new".
local function confirm_project_delete()
  local pidx = util.clamp(cursor[cur] or 1, 1, #project_items())
  if pidx > 1 then
    local name = project_items()[pidx]
    confirm = { kind = "project", prompt = { "delete project", '"' .. name .. '"?' },
                action = function() C.project.delete(name); toast("DELETED " .. name) end }
  end
end

-- minimap E2: move the highlighted cell one row up/down, to the column closest to the current one
-- (ties prefer the rightmost). No such row (top/bottom edge) -> stay put.
local function minimap_row_move(d)
  local cr, cc = VIEWS[jump].row, VIEWS[jump].col
  local target = cr + (d > 0 and 1 or -1)
  local best, bestd
  for lin, vw in ipairs(VIEWS) do
    if vw.row == target then
      local dd = math.abs(vw.col - cc)
      if not bestd or dd < bestd or (dd == bestd and vw.col > VIEWS[best].col) then best, bestd = lin, dd end
    end
  end
  if best then jump = best end
end

-- minimap E3: move within the current row only, clamped at the row ends (no wrap to another row).
local function minimap_col_move(d)
  local rv = ROWVIEWS[VIEWS[jump].row]
  local i = 1
  for k, l in ipairs(rv) do if l == jump then i = k; break end end
  jump = rv[util.clamp(i + (d > 0 and 1 or -1), 1, #rv)]
end

function S.enc(n, d)
  local v = VIEWS[cur]
  if k1held then   -- minimap nav: E1 = linear (all) · E2 = row change · E3 = within-row (clamped)
    -- (K1+K3 on SCENES is the paste chord, so no master-vol overlay there)
    if k3held and n == 1 and VIEWS[cur].kind ~= "scenes" then pdelta("dronage_master_vol", d)   -- +K3: E1 = master volume (overlay)
    elseif n == 2 then minimap_row_move(d)
    elseif n == 3 then minimap_col_move(d)
    else jump = util.clamp(jump + (d > 0 and 1 or -1), 1, #VIEWS) end
    return
  end
  if k2held and n == 1 then   -- K2 + E1: undo (CCW) / redo (CW); eat K2's release (no transport)
    k2_eaten = true
    undo_step(d)
    return
  end
  if n == 1 then
    if v.kind == "home" then home_viz = (home_viz - 1 + (d > 0 and 1 or -1)) % #VIZ_NAMES + 1   -- E1 cycles the HOME viz
    else step_in_row(d) end   -- matrix included: its siblings ARE the 8 LFO columns
    return
  end
  if n == 3 then tweak_view(v, d); return end   -- the shared per-param feel dispatch (grid +/- too)
  -- from here n == 2: cursor / selection movement per view kind
  local k = v.kind
  if k == "home" then
    cursor[cur] = util.clamp((cursor[cur] or 1) + (d > 0 and 1 or -1), 1, C.eng.NUM_VOICES)   -- pick a gate toggle
  elseif k == "matrix" then
    mrow = util.clamp(mrow + d, 1, #mvis)
  elseif k == "modseq" then
    -- E2 = one linear walk over every cell, track by track (like MACRO's E2)
    local lin = util.clamp(((cursor[cur] or 1) - 1) * SEQ_NCOL + seqcol + d, 1, C.seq.NUM_TRACKS * SEQ_NCOL)
    cursor[cur] = math.floor((lin - 1) / SEQ_NCOL) + 1
    seqcol = (lin - 1) % SEQ_NCOL + 1
  elseif k == "macro" then
    macro_sel = util.clamp(macro_sel + (d > 0 and 1 or -1), 0, C.mac.NUM_SLOTS * 3)  -- linear: AMOUNT + 9 cells
  elseif k == "looper" then
    looper_sel = util.clamp(looper_sel + (d > 0 and 1 or -1), 0, #LP_ROWS)   -- gauge + 3 settings + erase
  elseif k == "scenes" then
    scur = util.clamp(scur + d, 1, C.scenes.NUM)
  elseif k == "project" then
    cursor[cur] = util.clamp((cursor[cur] or 1) + d, 1, #project_items())
  else  -- panel / lfo / euclid
    local ids = view_ids(v)   -- LFO sync/shape filtering + GLOBAL grid-row filtering
    cursor[cur] = util.clamp((cursor[cur] or 1) + d, 1, #ids)
  end
end

function S.key(n, z)
  if n == 1 then
    if z == 1 then k1held = true; jump = cur; k1_consumed = false   -- fall through to the combo check
    else
      if not k1_consumed and cur ~= jump then
        cur = jump
        if C.rand then C.rand.nav() end   -- leaving a page re-arms its randomize alternation
      end
      k1held = false; k1_consumed = false       -- release always clears the consumed flag
      return
    end
  elseif n == 2 then k2held = (z == 1); if z == 1 then undo_dir = 0 end   -- fresh hold = fresh undo latch
  elseif n == 3 then k3held = (z == 1); if z == 1 then k3_used = false end end
  -- K1+K2+K3 = randomize the CURRENT PAGE (curated per-view dice, lib/dronage_norns_random),
  -- fired by whichever press completes the trio (norns gates K1 by 0.25s so it can arrive last).
  -- Consume the hold: no minimap, and release skips navigation. Undoable (K2+E1).
  if k1held and k2held and k3held then
    k1_consumed = true
    do_randomize()
    return
  end
  -- SCENES view: K1+K2 = copy the CURRENT scene (live state), K1+K3 = paste into the
  -- FOCUSED slot. Both consume the hold (no minimap transport / master-vol on this view).
  if k1held and k2held and not k1_consumed and VIEWS[cur].kind == "scenes" and not confirm then
    scene_copy(C.scenes.current); k1_consumed = true
    return
  end
  if k1held and k3held and not k1_consumed and VIEWS[cur].kind == "scenes" and not confirm then
    scene_paste(scur); k1_consumed = true
    return
  end
  -- PROJECT view: K1+K2 = save under a fresh random name (no keyboard); wins over minimap transport
  if k1held and k2held and not k1_consumed and VIEWS[cur].kind == "project" and not confirm then
    C.project.save(C.project.random_name()); toast("SAVED " .. C.project.current); k1_consumed = true
    return
  end
  -- minimap: K2 = transport play/stop, like HOME. On RELEASE + the consumed guard, so it never
  -- double-fires with the seed trio or the PROJECT quick-save (both consume the hold first).
  if k1held and n == 2 and z == 0 and not k1_consumed then
    C.set_transport(not C.transport())
    return
  end
  if k1held then return end   -- K1 held: K2/K3 are reserved for combos (no per-view action)
  local v = VIEWS[cur]

  -- destructive-action confirmation modal (project overwrite/delete, scene initialize): K3 = yes,
  -- K2 = no, on PRESS. On press so the K2+K3 chord that opened it doesn't fire on its own releases.
  if confirm and confirm.kind == v.kind then
    k2_eaten, k3_eaten = false, false   -- drop the chord-eat; re-armed below to swallow the chosen key's release
    if z == 1 then
      if n == 3 then confirm.action(); confirm = nil; k3_eaten = true   -- yes; eat this K3's release (underneath = load/store)
      elseif n == 2 then confirm = nil; k2_eaten = true end             -- no; eat this K2's release (underneath = save/recall)
    end
    return
  end

  -- list views: K2+K3 on the completing press = reset the focused param. K2 alone (release) =
  -- transport. K3 alone (release) = gate toggle on VOICE and EUCLID (their bound voice) - unless
  -- the K3 hold was spent as the E3 snap modifier (octave/semitone jumps).
  if v.kind == "panel" or v.kind == "lfo" or v.kind == "euclid" then
    local vnum = (v.kind == "panel" and v.ids and v.ids[1] and v.ids[1]:match("^v(%d+)_")) or (v.kind == "euclid" and v.v)
    if z == 1 and k2held and k3held then
      local ids = view_ids(v)
      reset_param(ids[util.clamp(cursor[cur] or 1, 1, #ids)])
      k2_eaten, k3_eaten = true, true   -- swallow both releases (gate/transport must not also fire)
    elseif n == 3 and z == 0 then
      if k3_eaten then k3_eaten = false
      elseif k3_used then k3_used = false
      elseif vnum then params:set("v" .. vnum .. "_gate", (params:get("v" .. vnum .. "_gate") == 1) and 0 or 1) end
    elseif n == 2 and z == 0 then
      if k2_eaten then k2_eaten = false
      else C.set_transport(not C.transport()) end
    end
    return
  end

  -- grid views (MOD MATRIX / CV SEQ / MACRO): K2+K3 chord = clear/reset the focused thing; K2 alone
  -- (release) = transport. Columns moved off K2/K3 (matrix: E1; CV seq + macro: E2 walks linearly).
  if (v.kind == "matrix" or v.kind == "modseq" or v.kind == "macro") and (n == 2 or n == 3) then
    if z == 1 then
      if k2held and k3held then
        if v.kind == "matrix" then C.mtx.set_cell(mvis[util.clamp(mrow, 1, #mvis)].di, mcol(), 0)
        elseif v.kind == "modseq" then seq_reset_cell(cursor[cur] or 1, seqcol)
        else macro_reset() end
        touched()
        k2_eaten, k3_eaten = true, true
      end
    elseif n == 2 then
      if k2_eaten then k2_eaten = false
      else C.set_transport(not C.transport()) end
    else
      if k3_eaten then k3_eaten = false end   -- K3 alone: nothing on these views
    end
    return
  end

  -- LOOPER: K3 release = record / overdub / early punch-out (on the ERASE row it opens the
  -- confirm instead); K2 release = transport; K2+K3 = reset the focused setting, as usual.
  if v.kind == "looper" and (n == 2 or n == 3) then
    if z == 1 then
      if k2held and k3held then
        local id = (looper_sel == 0) and "lp_xfade" or LP_IDS[looper_sel]
        if id then reset_param(id) end   -- erase row: chord does nothing (erase = row + confirm)
        k2_eaten, k3_eaten = true, true
      end
    elseif n == 2 then
      if k2_eaten then k2_eaten = false
      else C.set_transport(not C.transport()) end
    else
      if k3_eaten then k3_eaten = false
      elseif k3_used then k3_used = false            -- K3 hold was spent as the E3 modifier
      elseif looper_sel == #LP_ROWS then confirm_erase()
      else C.looper.record() end
    end
    return
  end

  -- scenes + project: K2/K3 act on RELEASE so the K2+K3 chord (init/delete) can pre-empt them.
  if (v.kind == "scenes" or v.kind == "project") and (n == 2 or n == 3) then
    if z == 1 then
      if k2held and k3held then
        if v.kind == "project" then confirm_project_delete()   -- ask first
        else confirm_scene_init() end                          -- ask first
        k2_eaten, k3_eaten = true, true
      end
    elseif n == 2 then
      if k2_eaten then k2_eaten = false
      elseif v.kind == "project" then project_save()
      else scene_recall() end
    else
      if k3_eaten then k3_eaten = false
      elseif v.kind == "project" then project_activate(util.clamp(cursor[cur] or 1, 1, #project_items()))
      else scene_store() end
    end
    return
  end

  -- remaining views (home): K2 = play/stop on RELEASE (so a K2+E1 undo turn doesn't also
  -- toggle transport - the eaten flag swallows it, same pattern as every other view);
  -- K3 = gate toggle on press.
  if v.kind == "home" then
    if n == 2 and z == 0 then
      if k2_eaten then k2_eaten = false
      else C.set_transport(not C.transport()) end
    elseif n == 3 and z == 1 then
      local i = util.clamp(cursor[cur] or 1, 1, C.eng.NUM_VOICES)
      params:set("v" .. i .. "_gate", (params:get("v" .. i .. "_gate") == 1) and 0 or 1)
    end
  end
end

-- ---------- grid semantic API (lib/dronage_norns_grid) ----------
-- The grid is a MIRROR of this UI: every function below routes into the exact code paths the
-- encoders/keys use (per-param feel, undo touch, confirms, toasts). Rules: never touch
-- k1held/k2held/k3held or the eaten flags (those belong to physical keys), no-op while the
-- physical minimap is up (k1held) so grid input can't fight it, and while a confirm dialog is
-- open only grid_yes/grid_no act.

-- 2D cursor move: dy = down(+)/up(-) like E2, dx = right(+)/left(-) horizontal where a view
-- has one. Per-kind edge handling (target cell missing = no-op, never a wrapped surprise).
-- coarse (grid SHIFT+arrow): on the MATRIX, dy jumps a whole voice (same param), wrapping.
function S.grid_nav(dx, dy, coarse)
  if k1held or map_held then   -- steer the minimap highlight instead
    if dy ~= 0 then minimap_row_move(dy) end
    if dx ~= 0 then minimap_col_move(dx) end
    return
  end
  if confirm then return end
  local v = VIEWS[cur]
  local k = v.kind
  if k == "home" then
    if dx ~= 0 then cursor[cur] = util.clamp((cursor[cur] or 1) + dx, 1, C.eng.NUM_VOICES) end
  elseif k == "matrix" then
    if dy ~= 0 then
      if coarse then mrow = (util.clamp(mrow, 1, #mvis) - 1 + dy * #MATRIX_DESTS) % #mvis + 1
      else mrow = util.clamp(mrow + dy, 1, #mvis) end
    end
    if dx ~= 0 then step_in_row(dx) end   -- columns ARE the sibling views
  elseif k == "modseq" then   -- true 2D over the same cells as the linear E2 walk
    if dy ~= 0 then cursor[cur] = util.clamp((cursor[cur] or 1) + dy, 1, C.seq.NUM_TRACKS) end
    if dx ~= 0 then seqcol = util.clamp(seqcol + dx, 1, SEQ_NCOL) end
  elseif k == "macro" then    -- up = AMOUNT, down = the slot cells, left/right walks them
    if dy < 0 then macro_sel = 0
    elseif dy > 0 and macro_sel == 0 then macro_sel = 1 end
    if dx ~= 0 and macro_sel > 0 then macro_sel = util.clamp(macro_sel + dx, 1, C.mac.NUM_SLOTS * 3) end
  elseif k == "scenes" then   -- 2x4 slot grid
    local r, c2 = math.floor((scur - 1) / 4), (scur - 1) % 4
    if dy ~= 0 then r = util.clamp(r + (dy > 0 and 1 or -1), 0, 1) end
    if dx ~= 0 then c2 = util.clamp(c2 + (dx > 0 and 1 or -1), 0, 3) end
    scur = r * 4 + c2 + 1
  elseif k == "project" then
    if dy ~= 0 then cursor[cur] = util.clamp((cursor[cur] or 1) + dy, 1, #project_items()) end
  elseif k == "looper" then
    if dy ~= 0 then looper_sel = util.clamp(looper_sel + dy, 0, #LP_ROWS) end
  else  -- panel / lfo / euclid lists
    if dy ~= 0 then
      local ids = view_ids(v)
      cursor[cur] = util.clamp((cursor[cur] or 1) + dy, 1, #ids)
    end
  end
end

-- prev/next sibling view in the row, WRAPPING (E1 clamps; the grid wraps by design).
-- HOME mirrors E1's viz cycle; on the MATRIX the siblings are the LFO columns, so << >>
-- walk columns (wrapping) - the voice jump lives on SHIFT+up/down (grid_nav coarse).
function S.grid_page(dir)
  if k1held or map_held or confirm then return end
  local v = VIEWS[cur]
  if v.kind == "home" then
    home_viz = (home_viz - 1 + dir) % #VIZ_NAMES + 1
    return
  end
  local rv = ROWVIEWS[v.row]
  if #rv < 2 then return end
  local i = 1
  for k2, l in ipairs(rv) do if l == cur then i = k2 break end end
  cur = rv[(i - 1 + dir) % #rv + 1]
  if C.rand then C.rand.nav() end
end

function S.grid_tweak(d)
  if k1held or map_held or confirm then return end
  tweak_view(VIEWS[cur], d)
end

-- the K2+K3 reset semantics for the current view (incl. the dialog-guarded destructive ones)
function S.grid_reset()
  if k1held or map_held or confirm then return end
  local v = VIEWS[cur]
  local k = v.kind
  if k == "panel" or k == "lfo" or k == "euclid" then
    local ids = view_ids(v)
    reset_param(ids[util.clamp(cursor[cur] or 1, 1, #ids)])
  elseif k == "matrix" then
    C.mtx.set_cell(mvis[util.clamp(mrow, 1, #mvis)].di, mcol(), 0); touched()
  elseif k == "modseq" then seq_reset_cell(cursor[cur] or 1, seqcol); touched()
  elseif k == "macro" then macro_reset(); touched()
  elseif k == "looper" then
    local id = (looper_sel == 0) and "lp_xfade" or LP_IDS[looper_sel]
    if id then reset_param(id) end
  elseif k == "scenes" then confirm_scene_init()
  elseif k == "project" then confirm_project_delete() end
  -- home: no-op (the pad renders dark there)
end

function S.grid_random()
  if k1held or map_held or confirm then return end
  do_randomize()
end

-- YES: answer an open dialog; else the view's primary verb on SCENES (recall) / PROJECT
-- (load/new); else transport PLAY. NO: answer dialog; else transport STOP. Deliberately NOT
-- K2/K3 emulation, and never touches the eaten flags (those swallow PHYSICAL releases only).
function S.grid_yes()
  local v = VIEWS[cur]
  if confirm and confirm.kind == v.kind then
    local a = confirm.action; confirm = nil; a()
    return
  end
  if v.kind == "scenes" then scene_recall()
  elseif v.kind == "project" then project_activate(util.clamp(cursor[cur] or 1, 1, #project_items()))
  else C.set_transport(true) end
end

function S.grid_no()
  local v = VIEWS[cur]
  if confirm and confirm.kind == v.kind then confirm = nil; return end
  C.set_transport(false)
end

-- single deliberate steps (no E1 latch; undo_dir belongs to the physical K2 hold)
function S.grid_undo()
  local l = C.undo.undo()
  toast(l and ("UNDO " .. l) or "NOTHING TO UNDO")
end
function S.grid_redo()
  local l = C.undo.redo()
  toast(l and ("REDO " .. l) or "NOTHING TO REDO")
end

-- the view's K3-style execute (grid SHIFT-tap): gate toggle on HOME/VOICE/EUCLID, store on
-- SCENES (overwrite confirm included), load on PROJECT; nothing elsewhere.
function S.grid_execute()
  if k1held or map_held or confirm then return end
  local v = VIEWS[cur]
  local k = v.kind
  local vnum = (k == "panel" and v.ids and v.ids[1] and v.ids[1]:match("^v(%d+)_"))
            or (k == "euclid" and v.v)
  if k == "home" then
    local i = util.clamp(cursor[cur] or 1, 1, C.eng.NUM_VOICES)
    params:set("v" .. i .. "_gate", (params:get("v" .. i .. "_gate") == 1) and 0 or 1)
  elseif vnum then
    params:set("v" .. vnum .. "_gate", (params:get("v" .. vnum .. "_gate") == 1) and 0 or 1)
  elseif k == "scenes" then scene_store()
  elseif k == "project" then project_activate(util.clamp(cursor[cur] or 1, 1, #project_items()))
  elseif k == "looper" then
    if looper_sel == #LP_ROWS then confirm_erase() else C.looper.record() end
  end
end

-- direct scene-launch pads: recall slot i from ANY view (same undo-wrapped path as the
-- scenes-view recall; an empty slot clones the current state into it, existing semantics)
function S.grid_scene(i)
  if confirm then return end
  scur = i   -- the SCENES screen highlight follows the launch
  if i ~= C.scenes.current then
    C.undo.around("SCENE", function() C.scenes.switch(i) end)
  end
  toast("RECALLED " .. i)
end

-- MAP pad: hold = minimap overlay (arrows steer `jump` via grid_nav), release = go there.
-- Shares `jump` with a concurrent physical K1 hold (both steer the same highlight) - accepted.
function S.grid_map(z)
  if z == 1 then
    if confirm then return end   -- no minimap over a dialog
    map_held = true; jump = cur
  elseif map_held then
    map_held = false
    if cur ~= jump then
      cur = jump
      if C.rand then C.rand.nav() end
    end
  end
end

-- the grid's left side mirrors the minimap 1:1, so jumps address views by (row, col) -
-- exactly the registry geometry. Returns false when no view lives there (pad = no-op).
function S.grid_jump_rc(row, col)
  for lin, vw in ipairs(VIEWS) do
    if vw.row == row and vw.col == col then
      if cur ~= lin then
        cur = lin
        if C.rand then C.rand.nav() end
      end
      return true
    end
  end
  return false
end

-- grid scene-clipboard verbs (SHIFT+scene-pad: hold = copy that slot, tap = paste to it)
function S.grid_scene_copy(i) if not confirm then scene_copy(i) end end
function S.grid_scene_paste(i) if not confirm then scene_paste(i) end end

-- snapshot for the grid's LED logic (which pads are live, what blinks)
function S.grid_state()
  local v = VIEWS[cur]
  local k = v.kind
  return {
    kind = k, name = v.name, lin = cur,
    confirm_up = (confirm ~= nil and confirm.kind == k),
    map_held = map_held,
    playing = C.transport(),
    armed = (C.transport_armed and C.transport_armed()) or false,   -- quantized PLAY pending
    rnd_ok = (k ~= "home" and k ~= "project" and k ~= "looper"),
    tweak_ok = (k ~= "home" and k ~= "scenes" and k ~= "project")
      and not (k == "looper" and looper_sel >= #LP_ROWS),   -- erase row: nothing to tweak
    rst_ok = (k ~= "home") and not (k == "project" and (cursor[cur] or 1) <= 1)   -- no project_items(): that scandirs, and this runs at 30 fps
      and not (k == "looper" and looper_sel >= #LP_ROWS),   -- erase row: chord resets nothing
    nav_x = (k == "matrix" or k == "modseq" or k == "macro" or k == "scenes" or k == "home"),
    nav_y = (k ~= "home"),
  }
end

S.toast = toast   -- host modules (looper) surface their transient messages through the house toast
S.VIEWS = VIEWS
return S
