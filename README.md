<p align="center"><img src="brand/logo/tiny_atlas_logo_stacked_6x.png" width="300" alt="Tiny Atlas"></p>

# Tiny Atlas

Ride, run or walk real routes anywhere in the world, in pixel art. Any GPX file becomes a world:
roads, paths, rivers, bridges, buildings and trees from OpenStreetMap, real elevation, the local
climate for weather. Ride it with the keyboard, or with your real bike trainer or walking pad through
[OmniPlay](https://github.com/MightyX3N/omniplay): your watts move you, and the hills come back to the
trainer.

Tiny Atlas runs as a **Garry's Mod gamemode** and as a **standalone LÖVE game** from one codebase.
Its look comes from **asset packs** (addons anyone can make), so the same route can be summer
pixel art, autumn, winter, or a completely different style.

> Status: early development. The route builder, asset pack format, trainer support and test viewer
> work; the in-game renderer, HUD and menus are next.

## What's here

| Folder | What |
|---|---|
| `tools/routebuilder/` | GPX → route package: chunked terrain (1 m near the route, 4 m around it, 32 m to the horizon), ground tags, graded roads, bridges, rivers and lakes with flowing water, buildings, trees, climate |
| `tools/packs/` | the default asset pack generator and the pack validator (runs the real Lua) |
| `tools/viewer/` | a stand-in renderer (three.js, headless) used to test routes and packs |
| `game/gamemodes/tinyatlas/` | the GMod gamemode (shared core: riding physics, trainer) |
| `game/love/` | LÖVE side: the same `OmniPlay.*` API over the SDK's shared memory |
| `game/tests/` | tests without the game: physics, a fake GMod running the real Lua, the OmniPlay simulator |
| `packs/tinyatlas_pack_default/` | the built default pack (a GMod addon folder) |
| `docs/` | `FORMATS.md` (route package + asset pack format), `TRAINER.md` (OmniPlay) |
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

## Tests

```
cd game/tests
python3 ../../tools/luajit.py test_physics.lua
python3 ../../tools/luajit.py test_gmod_bridge.lua
python3 ../../tools/luajit.py ../../third_party/omniplay-sdk/tools/omniplay_sim.lua bike 12 &
python3 ../../tools/luajit.py test_trainer_sim.lua
```

## Licences

Code: MIT (`LICENSE`). Art, map data and third-party parts keep their own licences:
[`assets/LICENSES.md`](assets/LICENSES.md). Map data © OpenStreetMap contributors (ODbL).
