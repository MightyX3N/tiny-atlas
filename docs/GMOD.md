# The world in Garry's Mod

The gamemode draws the route itself (it takes over `RenderScene`), streaming the world around the rider.

## Trying it

1. Copy `game/gamemodes/tinyatlas` to `garrysmod/gamemodes/`.
2. Copy the default pack (`packs/tinyatlas_pack_default`, at least `addon.json`, `lua/` and
   `materials/tinyatlas/packs/default/gmod/` + `water/still.png`) to `garrysmod/addons/`.
3. Export a route into `garrysmod/data/tinyatlas/routes/`:
   `python3 tools/gmod_export.py routes/city-run-10km <garrysmod>/data/tinyatlas/routes`
4. Start any map with the **Tiny Atlas** gamemode and use the console:

| Command | |
|---|---|
| `ta_routes` | list the exported routes |
| `ta_perftest <route> [km/h] [seconds]` | ride it automatically, show the frame rate, write a report to `data/tinyatlas/perf/` |
| `ta_ride <route>` | ride it yourself (W, or your trainer through OmniPlay) |
| `ta_stop` | back to the normal view |

Hold **B** to look back.

Settings (console variables): `ta_ahead` (450 m), `ta_behind` (60 m), `ta_near_radius` (110 m),
`ta_lod4_radius` (1200 m), `ta_tree_dist` (900 m), `ta_build_budget_ms` (4), `ta_mesh_slice` (4000 quads),
`ta_mesh_quads` (0 = triangles, 1 = quads), `ta_season` (summer/autumn/winter), `ta_perf_overlay`.

## How it works

Four levels, finest first (`world/world_stream.lua`):

- **1 m blocks** (32 m squares): only along the route, from `ta_behind` back to `ta_ahead` forward measured
  *along the route* (so hairpins and loops are right), within `ta_near_radius` of the track. Textured ground
  (one atlas, one draw per block), water, buildings with a facade quad per bay and floor, trees, bridges.
- **4 m cells** (256 m): around the rider, minus what is behind (judged by where the route goes over the next
  200 m, not the street he is on). Plain colours; 8 m quads beyond 450 m. A cell with 1 m blocks in it is built
  as 64 m pieces with holes for them.
- **16 m pages** (1024 m): every page of the route, always drawn, with holes where the 4 m level is.
- **far grid**: 32 m data drawn at 64 m, lower than everything above where they overlap.

Levels change with some slack so nothing flips at an edge. A piece is only swapped in once whatever fills its
holes is built, so the level below never shows through. Building is spread over frames: loading a chunk from
disk, computing a piece and uploading each mesh (≤ `ta_mesh_slice` quads) are separate steps, and each frame
spends at most `ta_build_budget_ms` on them. Buffers are reused so building doesn't churn the garbage collector.

Positions use a floating origin (the camera stays near Source's 0,0,0; each piece is drawn with its own model
matrix), so routes of any size work despite Source's ±16384 unit limit.

Packs provide atlases for this renderer (`tools/packs/gmod_prep.py`): Garry's Mod can't repeat part of a
texture or blend ground types in a shader, so each 1 m ground cell and each facade bay is mapped onto an atlas
cell by the builder. The distant levels use the pack's average colours.

## Testing without the game

`game/tests/test_world.lua` runs the real gamemode files in the fake GMod (`fakegmod.lua` +
`fakegmod_render.lua`, which checks vertex counts against `mesh.Begin`, the 65,535-vertex limit, balanced
model matrices, missing textures and leaked meshes) on a real exported route and pack: loading, the window
along the route over a ride, look-back, the overlay, the report, ride mode with the keyboard, both mesh
modes and all seasons.

```
cd game/tests
python3 ../../tools/luajit.py test_world.lua <exported routes dir> city-run-10-km 60 [capture.bin]
```

With a capture file it also saves one frame's draw calls; `tools/gmodcheck/shoot.js capture.bin out.png`
draws exactly those triangles with the pack's atlases, to check geometry and texture mapping.

Lua timings in the fake GMod are only the Lua side (the fake `mesh.*` calls cost nothing); the real cost of
building meshes and drawing comes from `ta_perftest` in the game.
