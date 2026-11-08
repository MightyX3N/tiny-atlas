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
```
