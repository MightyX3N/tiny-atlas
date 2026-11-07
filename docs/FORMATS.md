# Route package and asset pack formats (v1)

Both formats are plain files (JSON, PNG, raw little-endian binaries, and one Lua table), so the
GMod gamemode, the standalone LÖVE version and the tools all read the same data.

Coordinates are metres in a local frame per route: **x = east, y = north**, origin at the first
track point (`route.json → origin`). Heights are metres above sea level. Grids are stored
**north to south** (row 0 is the northern edge), columns west to east.

---

## 1. Route package (`routes/<id>/`)

Made by `tools/routebuilder` from any GPX file.

| File | What it holds |
|---|---|
| `route.json` | Name, activity, distance, climbing, surfaces, climbs, sprints, towns, a 240-point profile for menus, climate per month, chunk list, far-terrain header, attribution |
| `track.json` | The ride line every 5 m: `s` (distance), `x`, `y`, `z` (height the rider rides at), `z_gpx` (GPX's own smoothed height), `grade` (%), `ground` (tag id under the wheels), `bridge` (1 if on a bridge deck) |
| `bridges.json` | Every bridge deck: polyline `p`, per-vertex deck height `pz`, width `w`, surface `tag` |
| `map.png` | Overview map with the route drawn on it, for the route picker |
| `far_h.bin` | Far terrain for the whole area (route box + 8 km): uint16 heights every 32 m, header in `route.json → far` (`nx, ny, res, x0, y1, base, scale`) |
| `far_cls.png` | Far ground tags, one pixel = 16 m (`route.json → far.ground`) |
| `mid/p_X_Y.json` + `_h.bin` + `_cls.png` | Mid-detail pages (1024 m): 257 × 257 heights 4 m apart, 512 × 512 tags at 2 m, box buildings, tree points |
| `chunks/c_X_Y.json` | One 256 × 256 m square: header, `water_level`, `buildings[]`, `trees[]` |
| `chunks/c_X_Y_h.bin` | Heights: 257 × 257 uint16 (1 m apart, edges shared with neighbours). metres = `base + value * scale` |
| `chunks/c_X_Y_cls.png` | Ground tags: 512 × 512, 8-bit grey PNG, one pixel = 0.5 m, value = tag id |

Chunk `c_X_Y` covers x ∈ [X·256, X·256+256), y ∈ [Y·256, Y·256+256).

**Three detail levels** (nothing overlaps, nothing is missing in between):

| Level | Covers | Heights | Ground tags | Objects |
|---|---|---|---|---|
| near: `chunks/` | 256 m chunks within 300 m of the route | 1 m | 0.5 m | every building (footprints), every tree |
| mid: `mid/` | 256 m chunks within 1.5 km of the route **plus every hole the route encloses** (e.g. the inside of a loop), never a near chunk | 4 m | 2 m | box buildings `[x, y, length, width, angle_deg, height, base]`, trees `[x, y, z, kind, v]` |
| far: `far_*` | everything, route box + 8 km | 32 m | 16 m | none |

A mid page `p_X_Y` covers 4 × 4 chunks (x ∈ [X·1024, X·1024+1024)); only the chunks listed in
`present` are drawn from it. `water` maps `"cx,cy"` to that chunk's water surface corners
(NW, NE, SE, SW). Every vertex shared between levels has the same height (page edges are averaged,
near-chunk borders are copied into the pages). Far vertices inside the covered area are already
lowered by `far.covered_drop_m` (25 m) so the far grid never pokes through; its vertices on the
border of the covered area take the nearer level's height. Renderers should still hang a short skirt
under each patch's edges, because a near edge has 3 extra vertices between every two mid vertices.
Far-ring towns are painted around place points (low-zoom map tiles leave most built-up land unmapped).

**Ground tags** (`route.json → ground_tags`, ids are positions in this list):
`urban grass scrub water asphalt paving cobble gravel sand cycleway dirt rail pitch farmland
forest_floor meadow rock snow wetland orchard rural parking dry_grass`

Routes store *meaning* only. What a tag looks like is decided by the asset pack, so every route
works with every pack.

**Buildings**: `p` footprint (counter-clockwise not guaranteed), `h` height, `base` ground height,
`kind` (OSM building type), `levels`, `roof` (OSM roof shape if mapped), `roof_colour`, `colour`,
`v` (random 0–999 for picking a style deterministically).

**Trees**: `x, y, z`, `kind` (`broadleaf`, `conifer`, `palm`, `shrub`, `orchard`), `v` (random), `s` (size factor).

**Water**: a chunk with water has `water`: an 8 m height grid of the water surface (`file`, `n` = 33,
`res`, `base`, `scale`, north row first) and `flow`: `[dx, dy]` downstream for rivers and streams, or
`null` for still water (lakes, sea, canals). Draw the surface from the grid **only over ground tagged
`water`** (so a stream can run downhill and nothing floats above dry land). `water_level` is the lowest
surface height (for tinting the bed). Near the route the surface is always below the ride; where the
builder cut the ground (a path through a slope), water crossing it drops with it (a ford, ≤ 20 cm).
Mid pages: `water` (one 129 × 129 grid for the page), `water_chunks` (which present chunks have water)
and `water_flow` (`"cx,cy"` → `[dx, dy]`).

What the builder already does to the terrain, so renderers don't have to:
- smooths the coarse elevation data so towns don't turn into bumps,
- carves rivers, lakes and sea with sloped embankments and a straight waterline,
- grades roads (joined into strokes across short OSM pieces, max 12 %),
- shapes the ground along the ride to the GPX's own elevation profile (calibrated to the terrain),
- fits bridge decks bank to bank with a gentle arch, fills the abutments (3 m past each end), keeps
  underpasses open, and meets the rider's height at bridge ends the route rides on,
- treats streets drawn over mapped water (not tagged as bridges) as solid ground under the rider,
- makes spots ridden twice (loops, crossings) the same height on both passes (only where the terrain
  agrees they are one spot: on a steep slope two paths a few metres apart are not),
- on steep ground trusts the terrain over the GPX's own heights (smoothed along the path), but never makes
  the ride more than 25 % steeper than the GPX says; a leftover mismatch becomes a cut or fill whose
  sides widen with its depth,
- lets mountain streams follow the terrain (a single water level per area only for lakes, rivers, sea),
- flags routes that are not usable (e.g. a land route that heads out over water and turns back).

---

## 2. Asset pack (`<addon>/lua/tinyatlas/packs/<id>.lua` + `<addon>/materials/tinyatlas/packs/<id>/…`)

The same folder layout as a GMod addon, so a pack can be dropped into `garrysmod/addons/` or the
standalone game's `addons/` folder. Image paths in the Lua file are relative to the pack's
material folder.

```lua
return {
  id = "default", name = "Default", author = "…", version = "1.0",
  license = "…", credits = { "…" },
  local_only = false,          -- true for packs generated from personal files: never uploaded
  extends = nil,               -- another pack id; anything missing is taken from it

  tile_metres = 3.3,           -- how many metres one ground texture covers
  edge_darken = 0.28,          -- dark outline where a higher-priority surface meets a lower one

  ground = {                   -- every ground tag; each entry is one or more 32x32 seamless squares
    grass = { "ground/grass_1.png", "ground/grass_2.png" },
    asphalt = { "ground/asphalt.png" },
    -- …
  },
  ground_priority = { asphalt = 6, cycleway = 7, paving = 5, … },   -- for edge outlines
  seasons = {                  -- optional per-season replacements, picked from the route's month
    winter = { ground = { grass = { "ground/grass_winter.png" } } },
  },

  water = { texture = "water.png", opacity = 0.86, bed_tint = { 0.55, 0.6, 0.62 } },
  wall = { texture = "ground/cobble.png", tint = { 0.95, 0.9, 0.85 } },   -- steep slopes / embankments
  -- water: still = lakes/sea/canals, river = flowing water. Each is a looping animation: square frames
  -- stacked top to bottom in one sheet. The river loop flows toward the bottom of the image; renderers
  -- turn it so that points downstream (chunk water.flow). `texture` is the fallback still image.
  -- water = { texture = "water/still_0.png", opacity = 0.86,
  --           still = { sheet = "water/still.png", frames = 16, ms = 90, tile_metres = 11.2 },
  --           river = { sheet = "water/river.png", frames = 16, ms = 90, tile_metres = 11.2, flows = "down" } },
  -- seasons.<season>.props.<tag> replaces that tag's props in that season (e.g. autumn bushes, frosty grass).
  sky = { top = "#6fa6dc", horizon = "#c8dbe8", haze = "#c8dbe8", fog_near = 300, fog_far = 7000 },
  sun = { colour = "#fff1d6", strength = 2.4, ambient = "#dfeeff", ground = "#6b6050" },

  trees = {                    -- sprites standing on their bottom-centre pixel
    broadleaf = { sprites = { "trees/broadleaf_1.png", … }, height = { 10, 16 } },
    conifer   = { … }, palm = { … }, shrub = { … }, orchard = { … },
  },
  props = {                    -- scattered by the renderer per ground tag (count per 100 m²)
    grass = { { sprite = "props/flowers_1.png", density = 0.4, size = 0.8 }, … },
  },
  buildings = {
    facades = "buildings/facades.png",  -- strip of styles: each style 16 px wide, rows: upper floor (20 px) + ground floor (20 px)
    styles = 6, bay_metres = 2.9, floor_metres = 3.2, ground_floor_metres = 4.2,
    roofs = { "buildings/roof_tiles.png" }, roof_tints = { {1,1,1}, {0.6,0.66,0.78}, … },
  },
  bridge = { side = "#b9a88f" },
  filter = { pixel = 3, colours = 64 },   -- 1 = off
  rider = { jersey = "#c8392f", shorts = "#1f1f24", skin = "#e3b48f", helmet = "#f2f2f2" },
  bikes = { mtb = { texture = "bikes/bike_basecolor.png" } },
}
```

`tools/packs/validate.lua` checks a pack (runs in LuaJIT, so the same code works in GMod and LÖVE):
missing files, wrong image sizes, unknown keys, ground tags not covered (and whether `extends`
covers them), and refuses to mark a `local_only` pack as publishable.

## Runtime format (Garry's Mod / LÖVE)

`tools/gmod_export.py` turns a route package into files the game's Lua reads directly (no PNG decoding):
`route.txt` (JSON: track, chunk/page lists, bridges), `c_X_Y.dat` near chunks (header line + 1 m heights u16 +
1 m ground tags RLE + 8 m water surface), `c_X_Y.txt` their buildings and trees, `p_X_Y.dat/.txt` mid pages
(4 m), `l_X_Y.dat` every route page at 16 m, `far.dat` the far grid. Grids run south to north. The exporter's
docstring has the byte layout.

## Pack atlases for engines without shaders

`tools/packs/gmod_prep.py` adds `materials/tinyatlas/packs/<id>/gmod/ground.png` (every ground tile, padded),
`objects_<season>.png` (that season's trees, bushes and props + facade cells, roof, white) and
`lua/tinyatlas/packs/<id>_gmod.lua` (where everything is, and average colours for the distant levels).
Re-run it whenever the pack's art changes.
