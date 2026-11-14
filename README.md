# VoxTrainer

Ride real routes on your bike trainer, through the real place, rebuilt from
[OpenStreetMap](https://www.openstreetmap.org/) in 10 cm voxels and lit by the sun. Walking pads and
treadmills work too (you run instead).

VoxTrainer is the first game on **[VoxBox](https://github.com/MightyX3N/VoxBox)**, the voxel world engine.
Devices are handled by [OmniPlay](https://github.com/MightyX3N/omniplay)'s device code: smart trainers
(FTMS), cadence and speed sensors, power meters, heart-rate straps, walking pads and treadmills over
Bluetooth on Windows.

> The Tiny Atlas project that used to live here is kept on the
> [`tinyatlas` branch](https://github.com/MightyX3N/VoxTrainer/tree/tinyatlas).

## Playing

- **Start riding** follows the route; your speed comes from the trainer (or cadence × gear).
- **Connect devices** finds Bluetooth devices nearby. Connected devices are remembered.
- **Kit & bike**: jerseys, helmets and bike paints. Most unlock by riding: 5 km for the first kit, up to
  250 km for the rainbow one. Progress is saved on the computer.
- No devices? Use the keyboard: hold **W** / **↑** to pedal, **Shift** to sprint, **S** / **↓** to brake,
  **A** / **D** to jump 100 m back or forward, **C** for the camera, **H** to hide the keys, **Esc** to pause.

## Getting it running

1. Get the code with VoxBox:

       git clone --recursive https://github.com/MightyX3N/VoxTrainer
       cd VoxTrainer
       tools/setup.sh        # VoxBox submodule, Lua GDExtension, and the Bluetooth helper (needs mingw-w64)

2. Godot 4.6.3 built with the voxel module: see
   [voxbox/docs/BUILDING_GODOT.md](https://github.com/MightyX3N/VoxBox/blob/main/docs/BUILDING_GODOT.md).

3. Build a world to ride. You need `luajit`, `python3` with `pip install osmium`, and an OpenStreetMap
   extract (`.osm.pbf`, from [Geofabrik](https://download.geofabrik.de/) or
   [BBBike](https://extract.bbbike.org/)). Give a name and the points the route goes through:

       tools/build_world.sh helsinki.osm.pbf "Helsinki centre" 60.16774 24.95236 60.17801 24.93820

   This plans a bike route over the streets, cuts the map around it, builds `world/` (with a description of what
   everything is, for mods: see VoxBox's [world format](https://github.com/MightyX3N/VoxBox/blob/main/docs/FORMAT.md))
   and works out what can be seen from each stretch of the route (about 20 minutes for 2 km). It builds full detail 300 m either side of the
   route and a lighter version out to 1 km (`CORRIDOR=` and `FAR=` change that), so the map extract has to cover
   the route plus about 1.2 km; a city extract from BBBike does.

4. Open the project in the Godot editor and run it, or export it (the *Windows* preset). Put `world/` next to
   the exported `.exe`, with `omniplay_ble.dll` from `build/` for Bluetooth.

## Testing

Run with these after `--` on Godot's command line:

| option | what it does |
|---|---|
| `--autotest` | a bot rides the whole route at 40 km/h in real time (`--botkmh=N` for another speed) and fails if anything that can be seen from where it is isn't on screen yet, or is still a coarser version where it should be full detail |
| `--loadtest` | moves along the route 25 m at a time and reports how much building a kilometre takes, and the speed this computer keeps up with |
| `--keytest` | presses the keys: pedal, sprint, jump, brake |
| `--devtest --fake` | connects OmniPlay's pretend bike, pedals and checks the rider moves |
| `--kittest` | rides past 5 km and checks the Classic Red kit unlocks and is saved |
| `--tour=DIR` | takes pictures along the route (`--frames=N`, `--spots=a,b,…`, `--cam=0..3`) |
| `--world=DIR` | rides another built world |

And VoxBox's check of a built world, through the same API mods use (lanes, objects, traffic lights, doors, junctions,
footways): `godot --headless --path . -s res://voxbox/tests/semantics_test.gd -- --world=$PWD/world`

## Licence

MIT for VoxTrainer's own code (see [LICENSE](LICENSE)); the OmniPlay device code in `lua/` and `native/` is
GPL-3.0. Map data © OpenStreetMap contributors (ODbL). Everything else is in [CREDITS.md](CREDITS.md).
