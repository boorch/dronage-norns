-- dronage-norns keyed option params.
--
-- Every option-type param's choices carry THREE independent facets:
--   key   = PERMANENT save id. Scenes/projects store this. NEVER change a key (that's the whole point).
--   label = display string (the norns option). Reorder + rename freely.
--   value = the value the param's action/logic consumes (Plaits engine #, waveform id, div index, ...).
-- Reordering a list = moving entries; renaming = editing a label. key + value travel WITH the entry,
-- so saved selections and audio behaviour stay correct no matter how the UI list is shuffled.
--
-- ALL option-set definitions + param-id bindings live here, self-contained, so every `include` of this
-- module sees the same registry regardless of whether norns `include` caches (each copy rebuilds it
-- identically from these static tables).
--
-- To REORDER a list: move its entry lines. To RENAME: edit a label. To ADD: append an entry with a
-- fresh key + the new behaviour value. All three are save-safe. (Param defaults in
-- dronage_norns_defaults.lua are still index-based - update them if you reorder; they're the
-- NEW-project baseline, not a save.)

local M = {}
M.sets, M.id2set = {}, {}

local function define(name, entries)
  local labels, key2idx = {}, {}
  for i, e in ipairs(entries) do labels[i] = e.label; key2idx[e.key] = i end
  M.sets[name] = { entries = entries, labels = labels, key2idx = key2idx }
end

-- ---- option sets (list order = display order) ----
define("model", {                                     -- value = Plaits engine number; display order = banks then customs
  -- green bank (Plaits 1.0, engines 0-7)
  { key = "virtual_analog", label = "Virtual Analog", value = 0 },
  { key = "waveshaping",    label = "Waveshaping",    value = 1 },
  { key = "fm",             label = "FM",             value = 2 },
  { key = "grain",          label = "Grain",          value = 3 },
  { key = "additive",       label = "Additive",       value = 4 },
  { key = "wavetable",      label = "Wavetable",      value = 5 },
  { key = "chord",          label = "Chord",          value = 6 },
  { key = "speech",         label = "Speech",         value = 7 },
  -- red bank (Plaits 1.0, engines 8-15)
  { key = "swarm",          label = "Swarm",          value = 8 },
  { key = "noise",          label = "Noise",          value = 9 },
  { key = "particle",       label = "Particle",       value = 10 },
  { key = "string",         label = "String",         value = 11 },
  { key = "modal",          label = "Modal",          value = 12 },
  { key = "bass_drum",      label = "Bass Drum",      value = 13 },
  { key = "snare_drum",     label = "Snare Drum",     value = 14 },
  { key = "hi_hat",         label = "Hi Hat",         value = 15 },
  -- orange bank (Plaits 1.2, engines 16-23)
  { key = "va_vcf",         label = "VA VCF",         value = 16 },
  { key = "phase_dist",     label = "Phase Dist",     value = 17 },
  { key = "fm6_a",          label = "6op FM A",       value = 18 },
  { key = "fm6_b",          label = "6op FM B",       value = 19 },
  { key = "fm6_c",          label = "6op FM C",       value = 20 },
  { key = "wave_terrain",   label = "Wave Terr",      value = 21 },
  { key = "string_machine", label = "Str Machine",    value = 22 },
  { key = "chiptune",       label = "Chiptune",       value = 23 },
  -- dronage custom engines; display order Hyper, VCous, VCtar, Combust (values stay put = save-safe)
  { key = "hyper",          label = "Hyper",          value = 24 },
  { key = "vcous",          label = "VCous",          value = 26 },
  { key = "vctar",          label = "VCtar",          value = 27 },
  { key = "combust",        label = "Combust",        value = 25 },
})
define("out_mode", {                                 -- value = OUT routing (mono): 0 mix, 1 out, 2 aux
  { key = "mix", label = "MIX", value = 0 },
  { key = "out", label = "MAIN", value = 1 },   -- the model's main output (label was OUT; key stays save-stable)
  { key = "aux", label = "AUX", value = 2 },
  { key = "stereo",     label = "STEREO",     value = 3 },   -- out->L, aux->R
  { key = "inv_stereo", label = "INV STEREO", value = 4 },   -- aux->L, out->R
})
define("shape", {                                     -- value = LFO waveform id (src_compute switch)
  { key = "sine",    label = "sine",    value = 1 },
  { key = "tri",     label = "tri",     value = 2 },
  { key = "saw_up",  label = "saw+",    value = 3 },
  { key = "saw_dn",  label = "saw-",    value = 4 },
  { key = "square",  label = "square",  value = 5 },
  { key = "sh_rnd",  label = "sh rnd",  value = 6 },
  { key = "sh_seed", label = "sh seed", value = 7 },
})
define("scale", {                                     -- value = list index; cents = quantizer data (musicutil + dronage-tui scala.rs)
  -- Off (passthrough)
  { key="off", label="Off", value=1, cents={  } },
  { key="chromatic", label="Chromatic", value=2, cents={ 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200 } },
  -- 12-TET (norns musicutil)
  { key="major", label="Major", value=3, cents={ 200, 400, 500, 700, 900, 1100, 1200 } },
  { key="minor", label="Minor", value=4, cents={ 200, 300, 500, 700, 800, 1000, 1200 } },
  { key="harm_minor", label="Harm Minor", value=5, cents={ 200, 300, 500, 700, 800, 1100, 1200 } },
  { key="melodic_minor", label="Melodic Min", value=6, cents={ 200, 300, 500, 700, 900, 1100, 1200 } },
  { key="dorian", label="Dorian", value=7, cents={ 200, 300, 500, 700, 900, 1000, 1200 } },
  { key="phrygian", label="Phrygian", value=8, cents={ 100, 300, 500, 700, 800, 1000, 1200 } },
  { key="lydian", label="Lydian", value=9, cents={ 200, 400, 600, 700, 900, 1100, 1200 } },
  { key="mixolydian", label="Mixolydian", value=10, cents={ 200, 400, 500, 700, 900, 1000, 1200 } },
  { key="locrian", label="Locrian", value=11, cents={ 100, 300, 500, 600, 800, 1000, 1200 } },
  { key="pentatonic", label="Maj Pent", value=12, cents={ 200, 400, 700, 900, 1200 } },
  { key="minor_pentatonic", label="Min Pent", value=13, cents={ 300, 500, 700, 1000, 1200 } },
  { key="whole_tone", label="Whole Tone", value=14, cents={ 200, 400, 600, 800, 1000, 1200 } },
  { key="blues", label="Blues", value=15, cents={ 300, 500, 600, 700, 1000, 1200 } },
  { key="major_bebop", label="Maj Bebop", value=16, cents={ 200, 400, 500, 700, 800, 900, 1100, 1200 } },
  { key="dorian_bebop", label="Dor Bebop", value=17, cents={ 200, 300, 400, 500, 700, 900, 1000, 1200 } },
  { key="mixo_bebop", label="Mixo Bebop", value=18, cents={ 200, 400, 500, 700, 900, 1000, 1100, 1200 } },
  { key="altered", label="Altered", value=19, cents={ 100, 300, 400, 600, 800, 1000, 1200 } },
  { key="dim_whole_half", label="Dim W-H", value=20, cents={ 200, 300, 500, 600, 800, 900, 1100, 1200 } },
  { key="dim_half_whole", label="Dim H-W", value=21, cents={ 100, 300, 400, 600, 700, 900, 1000, 1200 } },
  { key="harmonic_major", label="Harm Major", value=22, cents={ 200, 400, 500, 700, 800, 1100, 1200 } },
  { key="hungarian_major", label="Hung Major", value=23, cents={ 300, 400, 600, 700, 900, 1000, 1200 } },
  { key="hungarian_minor", label="Hung Minor", value=24, cents={ 200, 300, 600, 700, 800, 1100, 1200 } },
  { key="neapolitan_major", label="Neap Major", value=25, cents={ 100, 300, 500, 700, 900, 1100, 1200 } },
  { key="neapolitan_minor", label="Neap Minor", value=26, cents={ 100, 300, 500, 700, 800, 1100, 1200 } },
  { key="lydian_minor", label="Lydian Min", value=27, cents={ 200, 400, 600, 700, 800, 1000, 1200 } },
  { key="major_locrian", label="Maj Locrian", value=28, cents={ 200, 400, 500, 600, 800, 1000, 1200 } },
  { key="leading_whole", label="Lead Whole", value=29, cents={ 200, 400, 600, 800, 1000, 1100, 1200 } },
  { key="six_tone_sym", label="6-Tone Sym", value=30, cents={ 100, 400, 500, 800, 900, 1100, 1200 } },
  { key="double_harmonic", label="Dbl Harmonic", value=31, cents={ 100, 400, 500, 700, 800, 1100, 1200 } },
  { key="enigmatic", label="Enigmatic", value=32, cents={ 100, 400, 600, 800, 1000, 1100, 1200 } },
  { key="overtone", label="Overtone", value=33, cents={ 200, 400, 600, 700, 900, 1000, 1200 } },
  { key="prometheus", label="Prometheus", value=34, cents={ 200, 400, 600, 900, 1000, 1200 } },
  -- world / exotic
  { key="persian", label="Persian", value=35, cents={ 100, 400, 500, 600, 800, 1100, 1200 } },
  { key="oriental", label="Oriental", value=36, cents={ 100, 400, 500, 600, 900, 1000, 1200 } },
  { key="balinese", label="Balinese", value=37, cents={ 100, 300, 700, 800, 1200 } },
  { key="purvi", label="Purvi", value=38, cents={ 100, 400, 600, 700, 800, 1100, 1200 } },
  { key="spanish_8", label="Spanish 8", value=39, cents={ 100, 300, 400, 500, 600, 800, 1000, 1200 } },
  { key="gagaku", label="Gagaku", value=40, cents={ 200, 500, 700, 900, 1000, 1200 } },
  { key="in_sen", label="In Sen", value=41, cents={ 100, 200, 500, 800, 1200 } },
  { key="okinawa", label="Okinawa", value=42, cents={ 400, 500, 700, 1100, 1200 } },
  { key="hirajoshi", label="Hirajoshi", value=43, cents={ 200, 300, 700, 800, 1200 } },
  { key="iwato", label="Iwato", value=44, cents={ 100, 500, 600, 1000, 1200 } },
  { key="fifths", label="Fifths", value=45, cents={ 700, 1200 } },
  -- microtonal (baked from dronage-tui Scala files, cents)
  { key="edo_19", label="19-EDO", value=46, cents={ 63.1579, 126.3158, 189.4737, 252.6316, 315.7895, 378.9474, 442.1053, 505.2632, 568.4211, 631.5789, 694.7368, 757.8947, 821.0526, 884.2105, 947.3684, 1010.5263, 1073.6842, 1136.8421, 1200 } },
  { key="edo_22", label="22-EDO", value=47, cents={ 54.5455, 109.0909, 163.6364, 218.1818, 272.7273, 327.2727, 381.8182, 436.3636, 490.9091, 545.4546, 600, 654.5454, 709.0909, 763.6364, 818.1818, 872.7273, 927.2727, 981.8182, 1036.3636, 1090.9091, 1145.4545, 1200 } },
  { key="edo_31", label="31-EDO", value=48, cents={ 38.7097, 77.4193, 116.129, 154.8387, 193.5484, 232.2581, 270.9677, 309.6774, 348.3871, 387.0968, 425.8064, 464.5161, 503.2258, 541.9355, 580.6452, 619.3548, 658.0645, 696.7742, 735.4839, 774.1935, 812.9032, 851.6129, 890.3226, 929.0323, 967.7419, 1006.4516, 1045.1613, 1083.871, 1122.5807, 1161.2903, 1200 } },
  { key="pythagorean", label="Pythagorean", value=49, cents={ 113.685, 203.91, 294.135, 407.82, 498.045, 611.73, 701.955, 815.64, 905.865, 996.09, 1109.775, 1200 } },
  { key="ji_7limit", label="7-lim JI", value=50, cents={ 111.7313, 203.91, 266.8709, 386.3137, 498.045, 582.5122, 701.955, 813.6863, 884.3587, 968.8259, 1088.2687, 1200 } },
  { key="meantone_qc", label="QC Meantone", value=51, cents={ 76.049, 193.1569, 310.2647, 386.3137, 503.4216, 579.4706, 696.5784, 773, 889.7353, 1006.8431, 1082.8921, 1200 } },
  { key="kirnberger_iii", label="Kirnberger", value=52, cents={ 90.225, 193.1569, 294.135, 386.3137, 498.045, 590.224, 696.5784, 792.18, 889.7353, 996.09, 1088.2687, 1200 } },
  { key="vallotti", label="Vallotti", value=53, cents={ 94.135, 196.09, 298.045, 392.18, 501.955, 592.18, 698.045, 796.09, 894.135, 1000, 1090.225, 1200 } },
  { key="werckmeister_iii", label="Werckmeister", value=54, cents={ 90.225, 192.18, 294.135, 390.225, 498.045, 588.27, 696.09, 792.18, 888.27, 996.09, 1092.18, 1200 } },
  { key="makam_rast", label="Makam Rast", value=55, cents={ 203.7736, 339.6226, 498.1132, 701.8868, 905.6604, 1041.5094, 1200 } },
  { key="maqam_rast", label="Maqam Rast", value=56, cents={ 203.91, 354.5471, 498.045, 701.955, 905.865, 1049.3629, 1200 } },
  { key="dastgah_17", label="Dastgah 17", value=57, cents={ 90, 133.238, 203.91, 294.135, 337.365, 407.82, 498.045, 568.717, 631.283, 701.955, 792.18, 835.193, 905.865, 996.09, 1039.103, 1109.775, 1200 } },
  { key="thai_7tet", label="Thai 7-TET", value=58, cents={ 171.4286, 342.8571, 514.2857, 685.7143, 857.1429, 1028.5714, 1200 } },
  { key="drone_fifths", label="Drone 5ths", value=59, cents={ 203.91, 407.82, 498.045, 701.955, 905.865, 1109.775, 1200 } },
  { key="harmonic_series", label="Harm Series", value=60, cents={ 203.91, 386.3137, 551.3179, 701.955, 840.5277, 968.8259, 1088.2687, 1200 } },
  { key="subharmonic", label="Sub Series", value=61, cents={ 111.7313, 231.1741, 359.4723, 498.045, 648.6821, 813.6863, 996.09, 1200 } },
  { key="lmy_wtp", label="LMY WTP", value=62, cents={ 176.6459, 203.91, 239.6068, 443.5168, 470.7809, 674.6909, 701.955, 737.6518, 941.5618, 968.8259, 1172.7359, 1200 } },
  { key="eikosany", label="Eikosany", value=63, cents={ 53.2729, 84.4672, 165.0042, 203.91, 266.8709, 368.9142, 431.8751, 470.7809, 551.3179, 582.5122, 635.7851, 701.955, 786.4222, 818.1888, 866.9592, 968.8259, 1017.5963, 1049.3629, 1133.8301, 1200 } },
  { key="hexany_1357", label="Hexany 1357", value=64, cents={ 266.8709, 386.3137, 653.1846, 884.3587, 968.8259, 1200 } },
  { key="hexany_1379", label="Hexany 1379", value=65, cents={ 203.91, 266.8709, 470.7809, 701.955, 968.8259, 1200 } },
})
define("root", {                                      -- value = root semitone 0..11
  { key = "c",  label = "C",  value = 0 },  { key = "cs", label = "C#", value = 1 },
  { key = "d",  label = "D",  value = 2 },  { key = "ds", label = "D#", value = 3 },
  { key = "e",  label = "E",  value = 4 },  { key = "f",  label = "F",  value = 5 },
  { key = "fs", label = "F#", value = 6 },  { key = "g",  label = "G",  value = 7 },
  { key = "gs", label = "G#", value = 8 },  { key = "a",  label = "A",  value = 9 },
  { key = "as", label = "A#", value = 10 }, { key = "b",  label = "B",  value = 11 },
})
define("div", {                                       -- value = index into matrix DIV_BEATS
  { key = "8bar",      label = "8 bar", value = 1 },  { key = "4bar",      label = "4 bar", value = 2 },
  { key = "2bar",      label = "2 bar", value = 3 },  { key = "1bar",      label = "1 bar", value = 4 },
  { key = "2nd_dot",   label = "1/2.",  value = 5 },  { key = "2nd",       label = "1/2",   value = 6 },
  { key = "4th_dot",   label = "1/4.",  value = 7 },  { key = "2nd_trip",  label = "1/2T",  value = 8 },
  { key = "4th",       label = "1/4",   value = 9 },  { key = "8th_dot",   label = "1/8.",  value = 10 },
  { key = "4th_trip",  label = "1/4T",  value = 11 }, { key = "8th",       label = "1/8",   value = 12 },
  { key = "16th_dot",  label = "1/16.", value = 13 }, { key = "8th_trip",  label = "1/8T",  value = 14 },
  { key = "16th",      label = "1/16",  value = 15 }, { key = "32nd_dot",  label = "1/32.", value = 16 },
  { key = "16th_trip", label = "1/16T", value = 17 }, { key = "32nd",      label = "1/32",  value = 18 },
  { key = "32nd_trip", label = "1/32T", value = 19 },
})
local esteps = { { key = "drone", label = "drone", value = 1 } }   -- value 1 = drone; 2..16 = step count
for n = 2, 16 do esteps[#esteps + 1] = { key = "s" .. n, label = tostring(n), value = n } end
define("esteps", esteps)
define("erate", {                                     -- value = euclid rate index
  { key = "r_0_25", label = "1/4x", value = 1 }, { key = "r_0_5", label = "1/2x", value = 2 },
  { key = "r_0_75", label = "3/4x", value = 3 }, { key = "r_1",   label = "1x",   value = 4 },
  { key = "r_1_5",  label = "1.5x", value = 5 }, { key = "r_2",   label = "2x",   value = 6 },
})
define("sh_anchor", { { key = "off", label = "off", value = false }, { key = "on", label = "on", value = true } })
define("sync",      { { key = "free", label = "free", value = false }, { key = "synced", label = "synced", value = true } })
define("polarity",  { { key = "bi", label = "bi", value = false }, { key = "uni", label = "uni", value = true } })

-- ---- param id -> set bindings (all option params) ----
for i = 1, 4 do M.id2set["v" .. i .. "_model"] = "model" end
for i = 1, 4 do M.id2set["v" .. i .. "_out_mode"] = "out_mode" end
for s = 1, 8 do
  M.id2set["lfo" .. s .. "_shape"] = "shape";  M.id2set["lfo" .. s .. "_sync"] = "sync"
  M.id2set["lfo" .. s .. "_div"] = "div";      M.id2set["lfo" .. s .. "_polarity"] = "polarity"
end
for v = 1, 4 do M.id2set["v" .. v .. "_esteps"] = "esteps"; M.id2set["v" .. v .. "_erate"] = "erate" end
M.id2set["dronage_scale"] = "scale";            M.id2set["dronage_root"] = "root"
M.id2set["dronage_delay_div"] = "div";          M.id2set["dronage_revdelay_div"] = "div"
M.id2set["dronage_sh_anchor"] = "sh_anchor"

-- ---- API ----
function M.labels(set) return M.sets[set].labels end          -- pass to params:add{ options = ... }
function M.keyed(id) return M.id2set[id] ~= nil end
local function setof(id) return M.sets[M.id2set[id]] end
function M.value(id, idx) local s = setof(id); local e = s and s.entries[idx]; if e then return e.value end end  -- action: display idx -> behaviour value
function M.key(id, idx)   local s = setof(id); local e = s and s.entries[idx]; if e then return e.key end end    -- save: display idx -> stable key
function M.index(id, key) local s = setof(id); return s and s.key2idx[key] end                                   -- load: stable key -> display idx (nil if removed)

return M
