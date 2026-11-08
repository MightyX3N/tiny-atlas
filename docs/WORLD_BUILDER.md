# The world builder (restart)

The new world builder is plain Lua shared by every game (`game/gamemodes/tinyatlas/gamemode/atlas/`). It builds the
world on demand from live map data, for any GPX route or free roam. The design and the milestones are in the
*Tiny Atlas — world restart design* doc. This file describes what exists so far.

## Milestone 1: foundation (done)

| Module | What it does | Checked against |
|---|---|---|
| `inflate.lua` | DEFLATE / zlib / gzip decoder | Python `zlib` on 30 streams (all levels, stored blocks, random data) |
| `png.lua` | PNG decoder (8-bit, all colour types) + Terrarium elevation | PIL on all 128 cached elevation tiles, byte for byte |
| `mvt.lua` | Mapbox vector tile decoder | `mapbox_vector_tile` on 815 cached tiles, all 221,772 features |
| `cdt.lua` | Constrained Delaunay triangulation on integer coordinates | randomised tests; structural self-check after every build |
| `cell.lua` | Ground of one cell: every point gets exactly one surface | all 17,856 cells of 279 cached tiles (below) |
| `fetch.lua` | Map sources with an on-disk cache | fake GMod bench test (download, then cache) |

**Cells.** A cell is one zoom-17 tile: an 8 × 8 part of a zoom-14 vector tile, about 300 m wide at the equator and
175 m at 55° north. Coordinates inside a cell are integers 0..8192 (about 2–4 cm), so every orientation test is exact.

**How a cell is built.**

1. Shapes from the vector tile: polygons as they are; roads, paths, rail and streams as a quad per segment plus a
   bevel triangle at each joint, with widths from the road class. Bridges and tunnels are left out (bridges are
   their own models, milestone 3).
2. Every edge is clipped to the cell and snapped to the grid, then cut against all others with snap rounding:
   crossings become grid points (rounded exactly, in integers), every point owns the half-open unit square around
   it, and every edge is routed through each square it passes. After this no two edges cross.
3. Constrained Delaunay triangulation of all points, with every edge forced in.
4. Each region between constraint edges gets the highest-priority shape covering it
   (building > road > path > rail > pier > water > paved > land cover / land use > ground).
5. Edges between equal surfaces are dropped and the triangulation made Delaunay again.

**Self-checks after every cell:** every triangle counter-clockwise, neighbours consistent, the triangle areas add
up exactly to the cell's area (no gaps, no overlaps), every edge forced in, every triangle has a surface.

**Results on 279 cached tiles (17,856 cells):** no cell with a problem; 16 ms mean, 68 ms p95, 178 ms worst per
cell in LuaJIT on the build machine. LuaJIT with the JIT switched off is about as fast (the code is short and
branchy). Pictures of every tile were checked by eye (`tools/atlascheck/sheets.py`).

**Note on the test data:** the 279 cached tiles came from the old build cache, where an earlier tool had stripped
them down (buildings were optional and often missing). The full tiles GMod downloads have the buildings: central
Amsterdam has 116 building features instead of 66 and builds at about 100 ms per cell.

## Running in Garry's Mod

`cl_atlas.lua` holds the platform layer (`http.Fetch`, binary cache files under `data/tinyatlas/cache/`) and a
job runner that resumes build coroutines from `Think`, spending at most `ta_atlas_budget_ms` (4) per frame.

`ta_buildbench [lat] [lon] [cells]` downloads the zoom-14 tile at a place (default: Amsterdam, Dam square), builds
its 64 cells the way the game will, and writes a report to `data/tinyatlas/perf/buildbench_*.txt`: CPU time per
cell, wall time, triangles, problems, and the riding speed the builder keeps up with at the current frame rate.
The gate for milestone 1: every cell under 1000 ms CPU, keeps up with 40 km/h, no problems.

**Measured in the real game (2026-11-08), central Amsterdam, full tile:** 61 ms CPU per cell on average, 84 ms
worst, no problems in 64 cells, 163k triangles; at 4 ms per frame it keeps up with about 470 km/h. **PASS.**

## Milestone 2: ground (built, being checked)

| Module | What it does |
|---|---|
| `webp.lua` | Lossless WebP decoder (Mapterhorn elevation tiles); checked against PIL on 27 images |
| `height.lua` | Elevation tiles (Mapterhorn WebP, AWS Terrarium PNG as fallback), bilinear heights in global units |
| `ground.lua` | Heights for a built cell: terrain, roads, water levels, quay walls; checks |
| `mesh.lua` | Triangle lists per pack texture (repeating every `tile_metres`), quay walls, distant ground |
| `route.lua` | GPX reader; a route resampled every 2 m with heights and grades from the built ground |
| `world.lua` | Streaming: which cells to build around the rider and along the route, downloads, decoding, dropping |

**Heights.** Terrain from Mapterhorn (high resolution in Denmark, the Netherlands, France and more; 30 m elsewhere),
AWS Terrarium where Mapterhorn has nothing. Every road gets the height of its centre line, sampled every 6 m, with
dips shorter than 40 m filled (the data is bare earth: under an unmapped bridge it shows the gap below) and then
smoothed with a straight-line fit over +-25 m. A point on a road takes the nearest centre line; lines that meet it
(they cross, or one ends on the other) are blended in, lines that are only close (the other leg of a hairpin) are
not. Road points are then smoothed a little more, at most 25 cm, and never on the cell border, so cells join up.

**Water.** Lakes, ponds and canals get one level per OpenStreetMap water area (a low percentile of the elevation
inside it), shared by all pieces of a water body that touch; areas whose elevation spreads more than 2.5 m run
downhill and get local levels, like streams. The sea is at 0 m. Banks stay 30 cm above the water, and quay walls go
from the bank down to under the water.

**Routes.** Nothing is prepared in advance: the ride starts as soon as the ground around the start is built (about
2 s), and every route point gets the height of the drawn ground when the cell it lies in is built. Cells along the
route are built first, up to 1.2 km ahead, so the trainer always knows the gradient in time. On a bridge or in a
tunnel (not built until milestone 3) the route goes straight across.

**Checks after every cell:** standing water level within 1.5 m in each water area, and no more than 5 % (and 60 m2)
of the road area steeper than 30 %.

**In Garry's Mod** (`cl_view.lua`): `ta_ride <route>` (test routes in `gamemodes/tinyatlas/routes/`, or your own
GPX in `garrysmod/data/tinyatlas/gpx/`), `ta_roam [lat lon]`, `ta_stop`. It builds the world around the start with a
progress bar, then streams cells as you ride; beyond 700 m a coarse distant ground (elevation only) is drawn. The
console says by itself how riding goes every 30 s (frame rate, worst frame, how far ahead the world is built, cells
built and waiting), warns straight away when the world falls behind the rider, and prints FAILED lines.

**Live ride test:** `game/tests/test_live_ride.lua` rides a route in the fake GMod at 60 frames a second with the
normal 4 ms build budget, the way a player would, and reports start time, how far ahead the world stays, and Lua time
per frame. Every long piece of work yields to the next frame (map tile and image decoding included).

**Test routes** (`tools/routes/make_routes.lua` routes them along OSM roads from the cached tiles): Amsterdam city
run (10 km), Amsterdam canal ring (11.3 km), Copenhagen lakes and harbour (14.2 km), Alpe d'Huez to the village
(12.2 km, 909 m up), Rold Skov countryside loop (20.3 km); free roam in central Copenhagen.

**Picture checks:** `game/tests/capture_ride.lua` rides a route in the fake GMod with the real gamemode files and
records every mesh the renderer draws every 25 m; `tools/gmodcheck/ride.js` draws each frame (rider view and view from
above) and `ride_sheets.py` makes contact sheets and flags holes and missing textures.

## Tests

```
cd game/tests/atlas
python3 ../../../tools/luajit.py test_decode.lua png <png files>      # or zlib / gzip
python3 ../../../tools/luajit.py test_mvt.lua <vector tiles>          # compare with tools output
python3 ../../../tools/luajit.py test_cdt.lua <seed> <rounds>
python3 ../../../tools/luajit.py test_snap.lua <seed> <rounds>        # adversarial cutting cases
RASTER_PX=128 RASTER_DIR=out python3 ../../../tools/luajit.py test_cells.lua tiles.txt   # "path x y" per line
python3 ../../../tools/atlascheck/sheets.py out sheets               # contact sheets of every tile
cd ..
python3 ../../tools/luajit.py test_atlas_bench.lua <data dir> <tile file> <tilejson file> [lat lon]
cd atlas
python3 ../../../tools/luajit.py test_ground.lua <cache dir> "x y" ...              # heights + checks per cell
python3 ../../../tools/luajit.py test_routes.lua <cache dir> ../../gamemodes/tinyatlas/routes
cd ..
python3 ../../tools/luajit.py capture_ride.lua <cache dir> <out> <route | roam:lat,lon>
(cd / && python3 -m http.server 8125 --bind 127.0.0.1 &)
node ../../tools/gmodcheck/ride.js <out> <pics dir> && python3 ../../tools/gmodcheck/ride_sheets.py <out> <pics dir> <sheets dir>
```
