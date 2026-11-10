<p align="center"><img src="brand/logo/tiny_atlas_logo_stacked_6x.png" width="300" alt="Tiny Atlas"></p>

# Tiny Atlas

Ride, run or walk real routes anywhere in the world, in pixel art. Any GPX file becomes a world:
roads, paths, rivers, bridges, buildings and trees from OpenStreetMap, real elevation, the local
climate for weather. Ride it with the keyboard, or with your real bike trainer or walking pad through
[OmniPlay](https://github.com/MightyX3N/omniplay): your watts move you, and the hills come back to the
trainer.

Tiny Atlas runs as a **Garry's Mod gamemode** and as a **standalone LÖVE game** from one codebase: the gamemode
itself, run in LÖVE on a small layer that gives it the GMod functions it uses (`game/love/gmod.lua`,
`gmod_render.lua`). Both look the same: the game's own title screen, menus and ride screen, nothing of GMod's.
Its look comes from **asset packs** (addons anyone can make), so the same route can be summer
pixel art, autumn, winter, or a completely different style.

> Status: early development. The world is built live from map data while you ride; the menus, ride screen,
> trainer support and the pixel-art look work in both versions. The rider and bike models are next.

## What's here

| Folder | What |
|---|---|
| `tools/routebuilder/` | GPX → route package: chunked terrain (1 m near the route, 4 m around it, 32 m to the horizon), ground tags, graded roads, bridges, rivers and lakes with flowing water, buildings, trees, climate |
| `tools/packs/` | the default asset pack generator and the pack validator (runs the real Lua) |
| `tools/viewer/` | a stand-in renderer (three.js, headless) used to test routes and packs |
| `game/gamemodes/tinyatlas/` | the game: the world builder (`gamemode/atlas/`), the view, the UI kit and screens (`cl_ui.lua`, `cl_menu.lua`, `cl_hud.lua`), riding physics, trainer; its pixel fonts (`content/resource/fonts`, OFL) |
| `game/love/` | the LÖVE layer: GMod's functions on LÖVE, downloads, the `OmniPlay.*` API over the SDK's shared memory |
| `game/tests/` | tests without the game: physics, a fake GMod running the real Lua (`test_screens.lua` plays every screen), the OmniPlay simulator |
| `tools/love_test/` | plays the real standalone on a virtual screen like a player (`run.sh walkthrough.lua`) |
| `packs/tinyatlas_pack_default/` | the built default pack (a GMod addon folder) |
| `docs/` | `FORMATS.md` (route package + asset pack format), `GMOD.md` (the renderer, `ta_perftest`), `TRAINER.md` (OmniPlay) |
| `brand/` | logo |

## Building a route

```
pip install -r requirements.txt
cd tools
python3 -m routebuilder.build ../samples/city-run-10km.gpx --out ../routes/city-run --cache ../cache
python3 -m routebuilder.check ../routes/city-run      # automatic checks (seams, steepness, water...)
```

It downloads OpenStreetMap vector tiles (OpenFreeMap), Terrain Tiles elevation and Open-Meteo climate
into `cache/` (with `--plan plan.json` it never downloads and lists what it needs instead).
Routes that can't be ridden (a "walk" that heads out over the sea and back) are flagged as not usable.

## Looking at a route

```
cd tools/viewer && npm install
cd ../.. && python3 -m http.server 8124 &
cd tools && python3 render_tests.py city-run     # renders a contact sheet into shots/
```

## Riding it in Garry's Mod

```
python3 tools/gmod_export.py routes/city-run-10km <garrysmod>/data/tinyatlas/routes
```

Start the gamemode: it opens on its own title screen. Your own GPX files go in `garrysmod/data/tinyatlas/gpx/` (the
standalone: its save folder's `tinyatlas/gpx/`) and show up under My routes. Developer commands in the console:
`ta_ride <route>`, `ta_roam [lat] [lon]`, `ta_stop`, `ta_buildbench`.

## The standalone

```
python3 tools/build_love.py build/love        # the LÖVE layer + the gamemode + fonts + packs, laid out like GMod
love build/love
tools/love_test/run.sh tools/love_test/walkthrough.lua <map cache> <out dir>     # plays it through, screenshots
```

## Tests

```
cd game/tests
python3 ../../tools/luajit.py test_physics.lua
python3 ../../tools/luajit.py test_gmod_bridge.lua
python3 ../../tools/luajit.py test_screens.lua <map cache>
python3 ../../tools/luajit.py ../../third_party/omniplay-sdk/tools/omniplay_sim.lua bike 12 &
python3 ../../tools/luajit.py test_trainer_sim.lua
python3 ../../tools/luajit.py test_atlas_bench.lua <data dir> <tile file> <tilejson file>
```

## Licences

Code: MIT (`LICENSE`). Art, map data and third-party parts keep their own licences:
[`assets/LICENSES.md`](assets/LICENSES.md). Map data © OpenStreetMap contributors (ODbL).
