# Art, data and third-party licences

The code is MIT (see `LICENSE`). Everything below keeps its own licence. The built default pack in
`packs/tinyatlas_pack_default/` is made from these sources by `tools/packs/make_default_pack.py`.

| What | Creator | Where it's used | Licence / terms |
|---|---|---|---|
| Isometric terrain tiles and nature set | Antahonist ([antahonist.itch.io](https://antahonist.itch.io)) | ground textures, flowers, logs, stumps | free asset pack, no resale of the assets themselves (see the creator's page) |
| Pixel Art Isometric Tree pack | same creator as the bush, rock and grass packs | trees (broadleaf, autumn, bare) | see the creator's itch.io page (no licence file came with the download) |
| Pixel Art Isometric Bush Asset Pack | same creator | bushes and shrubs, seasonal | see the creator's itch.io page (no licence file came with the download) |
| Rock Rock Rock (isometric rocks) | same creator | rocks and boulders | see the creator's itch.io page (no licence file came with the download) |
| Grass Pack | same creator | grass tufts, seasonal | see the creator's itch.io page (no licence file came with the download) |
| Free Low Poly Bike Models (MTB, BMX, unicycle) | VOiD1 Gaming | the bike, its texture | see the licence in the original download |
| Water animations | baked with **WOWe Generator** by Yavuz | `water/still.png`, `water/river.png` | MIT (engine in `tools/third_party/wowe/LICENSE`) |
| Pine trees, building facades, roof tiles, asphalt and cycleway textures | drawn by the pack generator (original) | default pack | MIT, with the code |
| Tiny Atlas logo | original, drawn pixel by pixel by `tools/logo/make_logo.py` | `brand/logo/` | MIT, with the code |
| OmniPlay SDK (bridge addon, LOVE binding, simulator) | MightyX3N and the OmniPlay contributors | trainers and walking pads | OmniPlay SDK License: MIT + OmniPlay support may not be sold separately (`third_party/omniplay-sdk/LICENSE`) |

## Data used when building routes (not stored in this repo)

| What | Licence | Attribution shown in the game |
|---|---|---|
| Map data: © OpenStreetMap contributors | ODbL | "Map data © OpenStreetMap contributors" |
| Vector tiles: OpenFreeMap / OpenMapTiles schema | free service; OpenMapTiles schema | "tiles by OpenFreeMap / OpenMapTiles" |
| Elevation: Terrain Tiles (Mapzen, AWS Open Data; SRTM, ETOPO1 and others) | open data, attribution | listed in every route's `route.json` |
| Climate: Open-Meteo (ERA5 reanalysis) | CC BY 4.0 | "Weather data by Open-Meteo.com" |
| Sample GPX files in `samples/`: gpxviewer.app samples, generated with BRouter over OpenStreetMap | geometry © OpenStreetMap contributors (ODbL) | test data only; not shipped as game routes |

## Before a public release

Check each "see the creator's page" row once: whether the terms allow the processed sprites to be
redistributed inside a game's source repository. If one doesn't, keep that pack's sprites out of the
repo (the generator builds them from a local copy) and ship them only inside releases.
