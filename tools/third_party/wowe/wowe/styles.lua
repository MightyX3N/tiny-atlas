-- Settings, the looks (from the reference pictures) and their colours.
--
-- Six colours, dark to light, for all the water (surfaces and falls):
--   shadow     slits in the curtains, bank shade, the deepest water
--   deep       dark streaks, deep water
--   base       the water
--   light      light streaks, the shade of the foam, rings
--   highlight  lines, the mouth's cyan streaks, outlines, the foam's underside
--   foam       foam, the brightest glints

local G = ... or _WOWE

local Guide = G.require("guide")

local Styles = {}

Styles.COLOR_KEYS = { "shadow", "deep", "base", "light", "highlight", "foam" }

Styles.ORDER = { "forest", "cave", "emerald", "ruins", "lava", "pool", "river", "pond", "beach",
                 "brook", "rocky", "shallow", "clear", "glassy", "lagoon", "stream" }

Styles.LOOKS = {
  -- Forest: deep blue water, dark slits under the edge, light strands
  -- woven like a ladder, round pale foam carried off down the river.
  forest = {
    colors = { "1c3558", "2b5480", "3f6c9a", "5291bd", "7cc4d4", "d6f3f2" },
    lap = 3, waves = 0, shade = 5, depth = 4, sparkle = 3, net = 4, cell = 14, patches = 2,
    ripples = 3, reach = 7, reflect = 5, trail = 6, rpatches = 2,
    flow = 4, streaks = 2, rush = 6, banks = 3, rapids = 4, rdepth = 3, rnet = 7, rcell = 13,
    mouthFoam = 8, mouthFringe = 12, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 5, speed = 5, lines = 4, weave = 6, gaps = 7, top = 5, edges = 2, shading = 5, light = "right",
    foam = 7, spread = 4, bubble = 6, mist = 3, rise = 4, spray = 3,
  },
  -- Cave: bright turquoise, long light strands, a white edge on the lit
  -- side, a thick cloud of mist, foam streaming away.
  cave = {
    colors = { "1b3a5c", "2b93ad", "44b0c7", "5ccde0", "8be7fb", "effbfc" },
    lap = 4, waves = 0, shade = 3, depth = 3, sparkle = 2, net = 3, cell = 16, patches = 2,
    ripples = 2, reach = 7, reflect = 6, trail = 7, rpatches = 2,
    flow = 5, streaks = 3, rush = 7, banks = 4, rapids = 6, rdepth = 2, rnet = 7, rcell = 12,
    mouthFoam = 8, mouthFringe = 14, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 3, speed = 6, lines = 8, weave = 3, gaps = 1, top = 6, edges = 7, shading = 4, light = "left",
    foam = 6, spread = 5, bubble = 5, mist = 8, rise = 6, spray = 4,
  },
  -- Emerald: green-teal jungle water, bright strands, mint foam, a lively
  -- pool full of rings and sparkles.
  emerald = {
    colors = { "053737", "0a6a5e", "07907a", "14ae93", "55d0b6", "d2f7e6" },
    lap = 5, waves = 0, shade = 4, depth = 5, sparkle = 4, net = 6, cell = 14, patches = 3,
    ripples = 3, reach = 7, reflect = 5, trail = 6, rpatches = 3,
    flow = 4, streaks = 2, rush = 6, banks = 4, rapids = 5, rdepth = 4, rnet = 8, rcell = 12,
    mouthFoam = 7, mouthFringe = 11, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "scales",
    arcs = 4, speed = 5, lines = 6, weave = 4, gaps = 3, top = 6, edges = 3, shading = 5, light = "left",
    foam = 6, spread = 4, bubble = 4, mist = 4, rise = 4, spray = 5,
  },
  -- Ruins: pale grey-teal water spilling over old stone, quiet.
  ruins = {
    colors = { "22414e", "3b5e66", "527983", "6f9b9b", "9cc4bc", "e2f2ea" },
    lap = 3, waves = 0, shade = 6, depth = 3, sparkle = 2, net = 3, cell = 12, patches = 2,
    ripples = 2, reach = 6, reflect = 6, trail = 4, rpatches = 2,
    flow = 3, streaks = 1, rush = 5, banks = 3, rapids = 3, rdepth = 3, rnet = 7, rcell = 11,
    mouthFoam = 5, mouthFringe = 14, mouthTeeth = 4, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 6, speed = 4, lines = 6, weave = 2, gaps = 2, top = 4, edges = 3, shading = 4, light = "left",
    foam = 5, spread = 3, bubble = 4, mist = 5, rise = 5, spray = 3,
  },
  -- Lava: a slow glowing river of molten rock pouring over the edge,
  -- embers flung up, smoke, a crust drifting off.
  lava = {
    colors = { "2a0710", "7a1410", "c8381a", "f07a1e", "ffc244", "fff4b8" },
    lap = 6, waves = 0, shade = 5, depth = 6, sparkle = 5, net = 5, cell = 12, patches = 4,
    ripples = 2, reach = 5, reflect = 4, trail = 7, rpatches = 3,
    flow = 2, streaks = 2, rush = 4, banks = 5, rapids = 3, rdepth = 5, rnet = 7, rcell = 10,
    mouthFoam = 7, mouthFringe = 11, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "fringe",
    arcs = 4, speed = 2, lines = 5, weave = 5, gaps = 4, top = 5, edges = 4, shading = 6, light = "left",
    foam = 4, spread = 3, bubble = 5, mist = 3, rise = 7, spray = 6,
  },
  -- Four still water looks. Pool: blue water, a bright line where it meets
  -- the rocks and a dark band under them, dark pebbles of shade drifting
  -- over the floor.
  pool = {
    colors = { "0a3b62", "17707f", "31968f", "3cb2a8", "52ddd2", "c2fff4" },
    lap = 1, waves = 0, shade = 6, depth = 0, sparkle = 3, net = 0, cell = 14, patches = 5,
    ripples = 2, reach = 6, reflect = 5, trail = 5,
    flow = 3, streaks = 1, rush = 5, banks = 1, rapids = 2, rdepth = 0, rnet = 0, rcell = 14, rpatches = 5,
    mouthFoam = 8, mouthFringe = 14, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 4, speed = 4, lines = 5, weave = 4, gaps = 4, top = 5, edges = 3, shading = 5, light = "left",
    foam = 6, spread = 4, bubble = 5, mist = 3, rise = 4, spray = 3,
  },
  -- River: pale turquoise, a white foam net sliding downstream, foam on
  -- the stones.
  river = {
    colors = { "34505e", "5a8f96", "7fc0b1", "9dd6c0", "c8eedb", "f2fbf0" },
    lap = 3, waves = 0, shade = 3, depth = 0, sparkle = 2, net = 8, cell = 12, patches = 4,
    ripples = 2, reach = 6, reflect = 4, trail = 6,
    flow = 5, streaks = 2, rush = 6, banks = 3, rapids = 4, rdepth = 0, rnet = 8, rcell = 12, rpatches = 4,
    mouthFoam = 8, mouthFringe = 15, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 4, speed = 5, lines = 6, weave = 3, gaps = 3, top = 5, edges = 3, shading = 4, light = "left",
    foam = 6, spread = 4, bubble = 5, mist = 4, rise = 5, spray = 4,
  },
  -- Pond: green-teal, a wobbling net of light lines, dark blotches.
  pond = {
    colors = { "1f563d", "3a775e", "4f9e88", "66b69f", "a2d6bf", "e2f7ea" },
    lap = 2, waves = 0, shade = 0, depth = 0, sparkle = 2, net = 7, cell = 14, patches = 3,
    ripples = 3, reach = 6, reflect = 5, trail = 4,
    flow = 3, streaks = 1, rush = 5, banks = 2, rapids = 3, rdepth = 0, rnet = 7, rcell = 14, rpatches = 3,
    mouthFoam = 6, mouthFringe = 11, mouthTeeth = 4, mouthWave = 2, mouthRagged = 6, fallStyle = "scales",
    arcs = 5, speed = 4, lines = 5, weave = 4, gaps = 3, top = 4, edges = 2, shading = 4, light = "left",
    foam = 5, spread = 3, bubble = 4, mist = 3, rise = 4, spray = 3,
  },
  -- Beach: turquoise sea, wide white surf lapping at the sand, wave lines
  -- rolling in, sparkles.
  beach = {
    colors = { "174c5e", "0b8584", "0c9e8f", "3dbba8", "92dccb", "f2f9f3" },
    lap = 7, waves = 2, shade = 0, depth = 5, sparkle = 5, net = 0, cell = 16, patches = 2,
    ripples = 2, reach = 6, reflect = 4, trail = 6,
    flow = 4, streaks = 2, rush = 6, banks = 5, rapids = 5, rdepth = 4, rnet = 0, rcell = 16, rpatches = 2,
    mouthFoam = 9, mouthFringe = 15, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "fringe",
    arcs = 4, speed = 5, lines = 6, weave = 3, gaps = 2, top = 6, edges = 3, shading = 4, light = "left",
    foam = 7, spread = 5, bubble = 5, mist = 4, rise = 5, spray = 5,
  },
  -- The clean looks (Clean: flat zones, whole pixel edges), one for each
  -- of the river pictures. Brook: blue, light shallows, deep blotches, a
  -- few glints.
  brook = {
    colors = { "3d6a90", "4a7da3", "5998b8", "78b1c9", "a8daec", "eaf8fb" },
    clean = true, cleanSize = 0, shallows = 5, stones = 0, dither = 0,
    lap = 2, waves = 0, shade = 0, depth = 3, sparkle = 3, net = 0, cell = 16, patches = 0,
    ripples = 2, reach = 6, reflect = 4, trail = 5, rpatches = 0,
    flow = 4, streaks = 2, rush = 5, banks = 2, rapids = 3, rdepth = 4, rnet = 0, rcell = 14,
    mouthFoam = 8, mouthFringe = 12, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 4, speed = 5, lines = 5, weave = 3, gaps = 3, top = 5, edges = 3, shading = 4, light = "left",
    foam = 6, spread = 4, bubble = 5, mist = 3, rise = 4, spray = 3,
  },
  -- Rocky: teal, a darker channel, pale stony shallows full of stones.
  rocky = {
    colors = { "3a636c", "3e8095", "4c94a1", "7fa99f", "aceef0", "e8fbfa" },
    clean = true, cleanSize = 0, shallows = 7, stones = 6, dither = 0,
    lap = 3, waves = 0, shade = 0, depth = 5, sparkle = 2, net = 0, cell = 16, patches = 0,
    ripples = 2, reach = 6, reflect = 3, trail = 6, rpatches = 0,
    flow = 5, streaks = 3, rush = 6, banks = 3, rapids = 5, rdepth = 5, rnet = 0, rcell = 14,
    mouthFoam = 8, mouthFringe = 12, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 4, speed = 6, lines = 6, weave = 3, gaps = 3, top = 6, edges = 3, shading = 4, light = "left",
    foam = 6, spread = 4, bubble = 5, mist = 3, rise = 4, spray = 4,
  },
  -- Shallow: pale mint water over sand, checkered patches.
  shallow = {
    colors = { "6e8a7e", "8ea699", "a9c9ba", "b9d9c8", "cff6ef", "f4fffb" },
    clean = true, cleanSize = 0, shallows = 6, stones = 0, dither = 2,
    lap = 2, waves = 0, shade = 0, depth = 4, sparkle = 2, net = 0, cell = 16, patches = 0,
    ripples = 2, reach = 5, reflect = 2, trail = 4, rpatches = 0,
    flow = 3, streaks = 2, rush = 4, banks = 2, rapids = 2, rdepth = 4, rnet = 0, rcell = 14,
    mouthFoam = 7, mouthFringe = 11, mouthTeeth = 4, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 3, speed = 4, lines = 5, weave = 3, gaps = 2, top = 5, edges = 3, shading = 3, light = "left",
    foam = 5, spread = 4, bubble = 4, mist = 2, rise = 4, spray = 3,
  },
  -- Clear: see-through water, a net of light over a stony bed.
  clear = {
    colors = { "5c7c7e", "759796", "80aeb5", "8fc4cb", "c2e6ea", "f0fafa" },
    clean = true, cleanSize = 0, shallows = 5, stones = 5, dither = 0,
    lap = 2, waves = 0, shade = 0, depth = 3, sparkle = 2, net = 6, cell = 18, patches = 2,
    ripples = 2, reach = 5, reflect = 3, trail = 4, rpatches = 2,
    flow = 3, streaks = 2, rush = 4, banks = 2, rapids = 2, rdepth = 3, rnet = 6, rcell = 18,
    mouthFoam = 7, mouthFringe = 11, mouthTeeth = 4, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 3, speed = 4, lines = 5, weave = 3, gaps = 2, top = 5, edges = 3, shading = 4, light = "left",
    foam = 5, spread = 4, bubble = 4, mist = 3, rise = 4, spray = 3,
  },
  -- Glassy: pale green-grey, a fine net of light.
  glassy = {
    colors = { "577878", "6b8a88", "85a69e", "98b8ab", "b9e0db", "eef8f2" },
    clean = true, cleanSize = 0, shallows = 4, stones = 3, dither = 0,
    lap = 2, waves = 0, shade = 0, depth = 3, sparkle = 2, net = 5, cell = 14, patches = 0,
    ripples = 2, reach = 5, reflect = 3, trail = 4, rpatches = 0,
    flow = 4, streaks = 2, rush = 5, banks = 2, rapids = 3, rdepth = 3, rnet = 5, rcell = 14,
    mouthFoam = 7, mouthFringe = 11, mouthTeeth = 4, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 3, speed = 5, lines = 5, weave = 3, gaps = 2, top = 5, edges = 3, shading = 4, light = "left",
    foam = 5, spread = 4, bubble = 4, mist = 3, rise = 4, spray = 3,
  },
  -- Lagoon: turquoise, stones near the shore, short white ripples.
  lagoon = {
    colors = { "47756c", "57958f", "6fb6ad", "90c6ae", "b6e9e9", "f0fcfa" },
    clean = true, cleanSize = 0, shallows = 5, stones = 4, dither = 0,
    lap = 3, waves = 1, shade = 0, depth = 4, sparkle = 3, net = 0, cell = 16, patches = 0,
    ripples = 3, reach = 6, reflect = 4, trail = 5, rpatches = 0,
    flow = 4, streaks = 2, rush = 5, banks = 3, rapids = 3, rdepth = 4, rnet = 0, rcell = 14,
    mouthFoam = 8, mouthFringe = 12, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "scales",
    arcs = 4, speed = 5, lines = 5, weave = 3, gaps = 2, top = 5, edges = 3, shading = 4, light = "left",
    foam = 6, spread = 4, bubble = 5, mist = 3, rise = 4, spray = 4,
  },
  -- Stream: a blue channel between wide pale beds.
  stream = {
    colors = { "5b8086", "6f9fac", "87b7c1", "a3b8a8", "cdf3f4", "f6fdfd" },
    clean = true, cleanSize = 0, shallows = 8, stones = 2, dither = 0,
    lap = 2, waves = 0, shade = 0, depth = 5, sparkle = 2, net = 0, cell = 16, patches = 0,
    ripples = 2, reach = 6, reflect = 3, trail = 5, rpatches = 0,
    flow = 5, streaks = 3, rush = 6, banks = 2, rapids = 4, rdepth = 5, rnet = 0, rcell = 14,
    mouthFoam = 8, mouthFringe = 12, mouthTeeth = 5, mouthWave = 2, mouthRagged = 6, fallStyle = "streaks",
    arcs = 4, speed = 6, lines = 6, weave = 3, gaps = 3, top = 6, edges = 3, shading = 4, light = "left",
    foam = 6, spread = 4, bubble = 5, mist = 3, rise = 4, spray = 4,
  },
}

-- Ranges of the numbers, for clamping and for the sliders.
Styles.RANGE = {
  lap = { 0, 10 }, shade = { 0, 10 }, depth = { 0, 10 }, sparkle = { 0, 10 },
  ripples = { 0, 5 }, reach = { 0, 10 }, reflect = { 0, 10 }, trail = { 0, 10 },
  flow = { 1, 10 }, streaks = { 0, 10 }, rush = { 0, 10 }, drift = { 0, 10 }, angle = { 0, 359 },
  banks = { 0, 10 }, rapids = { 0, 10 }, rdepth = { 0, 10 }, rangle = { 0, 359 },
  rnet = { 0, 10 }, rcell = { 6, 32 }, rpatches = { 0, 10 },
  waves = { 0, 3 }, patches = { 0, 10 },
  tideAmp = { 1, 8 }, tideCycles = { 1, 4 }, tideUneven = { 0, 10 }, tideWet = { 0, 10 },
  mouthFoam = { 0, 20 }, mouthFringe = { 0, 30 }, mouthTeeth = { 0, 12 }, mouthWave = { 0, 4 }, mouthRagged = { 0, 10 },
  net = { 0, 10 }, cell = { 6, 32 },
  speed = { 1, 10 }, lines = { 0, 10 }, weave = { 0, 10 }, gaps = { 0, 10 }, top = { 0, 10 },
  edges = { 0, 10 }, shading = { 0, 10 }, arcs = { 0, 10 },
  foam = { 0, 10 }, spread = { 0, 10 }, bubble = { 0, 10 }, mist = { 0, 10 }, rise = { 0, 10 },
  spray = { 0, 10 },
  frames = { 4, 48 }, ms = { 20, 1000 },
  palHue = { 0, 60 }, palSat = { 0, 60 }, palRange = { 20, 180 },
  guideStrength = { 0, 10 }, guideReach = { 2, 32 }, guideFoam = { 0, 10 },
  cleanSize = { 0, 5 }, shallows = { 0, 10 }, stones = { 0, 10 }, dither = { 0, 3 },
}

-- The six colours from one (Palette): its sliders' starting values.
Styles.PAL_START = { palHue = 12, palSat = 18, palRange = 100 }

-- The drift of still ponds (off at first) and the way rivers run where no
-- fall pulls them (down the screen at first). A look leaves them as they
-- are.
Styles.DRIFT_START = { drift = 0, angle = 0, rangle = 90 }

-- Guide rods (Guide): off at first; how strongly they turn the water, how
-- far from them (px), the foam carried along them. A look leaves them as
-- they are.
Styles.GUIDE_START = { guideOn = false, guideStrength = 8, guideReach = 8, guideFoam = 4 }

-- The tide (off at first; a look leaves it as it is): how many px
-- still water climbs past its mask, how many times a loop, how unevenly
-- along the shore, how long the ground it leaves stays wet.
Styles.TIDE_START = { tide = false, tideAmp = 3, tideCycles = 1, tideUneven = 4, tideWet = 4 }

-- Clean (off at first; the clean looks turn it on): Size (Auto: by the
-- picture's size; or 1x .. 3x), how wide the shallows, stones in the
-- shallows, dither where zones meet.
Styles.CLEAN_START = { clean = false, cleanSize = 0, shallows = 4, stones = 0, dither = 0 }

Styles.FRAME_CHOICES = { "8", "12", "16", "24", "32" }

-- How the falling water is drawn (after the reference pictures): the
-- first strands and slits, long streaks, bands with ragged fringes, rows
-- of scallops.
Styles.FALL_STYLES = { "classic", "streaks", "fringe", "scales" }

-- Opacity in percent of every group (Codes.GROUPS). A look leaves them as
-- they are. Everything opaque, except the mist over the ground: a haze.
Styles.ALPHA_KEYS = { "water", "deep", "fall", "slits", "lines", "net", "patches", "waves", "foam", "shade",
                      "sparkle", "mist", "wet" }
Styles.ALPHA_START = { mist = 70, wet = 40 }

local function fullAlpha()
  local a = {}
  for _, k in ipairs(Styles.ALPHA_KEYS) do a[k] = Styles.ALPHA_START[k] or 100 end
  return a
end

local function copyAlpha(a)
  local out = fullAlpha()
  if type(a) == "table" then
    for _, k in ipairs(Styles.ALPHA_KEYS) do
      local v = tonumber(a[k])
      if v then out[k] = math.max(0, math.min(100, math.floor(v + 0.5))) end
    end
  end
  return out
end

local function copyColors(list)
  local out = {}
  for i, c in ipairs(list) do out[i] = c end
  return out
end

-- The settings of a look (frames, frame time and seed kept from `into`).
function Styles.apply(name, into)
  local look = Styles.LOOKS[name] or Styles.LOOKS.forest
  local p = into or {}
  for k, v in pairs(look) do
    if k == "colors" then p.colors = copyColors(v) else p[k] = v end
  end
  p.style = Styles.LOOKS[name] and name or "forest"
  p.frames = p.frames or 16
  p.ms = p.ms or 90
  p.seed = p.seed or 1
  p.alpha = copyAlpha(p.alpha)
  for k, v in pairs(Styles.PAL_START) do
    if p[k] == nil then p[k] = v end
  end
  for k, v in pairs(Styles.DRIFT_START) do
    if p[k] == nil then p[k] = v end
  end
  for k, v in pairs(Styles.GUIDE_START) do
    if p[k] == nil then p[k] = v end
  end
  for k, v in pairs(Styles.TIDE_START) do
    if p[k] == nil then p[k] = v end
  end
  for k, v in pairs(Styles.CLEAN_START) do
    if p[k] == nil then p[k] = v end
  end
  -- A clean look turns Clean on, any other turns it off.
  p.clean = look.clean == true
  if type(p.guides) ~= "table" then p.guides = {} end
  return p
end

function Styles.defaults()
  return Styles.apply("forest", { frames = 16, ms = 90, seed = 1 })
end

-- Settings read back from preferences: anything missing or out of range
-- comes from the defaults.
function Styles.sanitize(q)
  local p = Styles.defaults()
  if type(q) ~= "table" then return p end
  if Styles.LOOKS[q.style] then Styles.apply(q.style, p) end
  for k, r in pairs(Styles.RANGE) do
    local v = tonumber(q[k])
    if v then p[k] = math.max(r[1], math.min(r[2], math.floor(v + 0.5))) end
  end
  if tonumber(q.seed) then p.seed = math.floor(tonumber(q.seed)) end
  if q.light == "left" or q.light == "right" then p.light = q.light end
  if type(q.colors) == "table" then
    for i = 1, 6 do
      local c = q.colors[i]
      if type(c) == "string" and c:match("^%x%x%x%x%x%x$") then p.colors[i] = c:lower() end
    end
  end
  p.alpha = copyAlpha(q.alpha)
  if type(q.palBase) == "string" and q.palBase:match("^%x%x%x%x%x%x$") then p.palBase = q.palBase:lower() end
  if type(q.guideOn) == "boolean" then p.guideOn = q.guideOn end
  for _, v in ipairs(Styles.FALL_STYLES) do
    if q.fallStyle == v then p.fallStyle = v end
  end
  if type(q.tide) == "boolean" then p.tide = q.tide end
  if type(q.clean) == "boolean" then p.clean = q.clean end
  p.guides = Guide.copy(q.guides)
  return p
end

function Styles.copy(p)
  local out = {}
  for k, v in pairs(p) do
    if k == "colors" then out[k] = copyColors(v)
    elseif k == "alpha" then out[k] = copyAlpha(v)
    elseif k == "guides" then out[k] = Guide.copy(v)
    else out[k] = v end
  end
  return out
end

function Styles.rgb(hex)
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

function Styles.hex(r, g, b)
  return string.format("%02x%02x%02x", r, g, b)
end

return Styles
