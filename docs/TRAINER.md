# Trainers and walking pads (OmniPlay)

Tiny Atlas reads the player's bike trainer, walking pad or footpod through **OmniPlay** and sends hills
back. Without OmniPlay everything works with keyboard / controller.

## Pieces

| Where | File | What |
|---|---|---|
| shared (GMod + LOVE) | `game/gamemodes/tinyatlas/gamemode/core/ride_physics.lua` | power -> speed: gravity on the grade, rolling resistance per ground tag, air drag with wind, air density by height |
| shared | `.../core/trainer.lua` | OmniPlay or keyboard -> speed; hills back to the trainer |
| GMod | `.../thirdparty/omniplay_bridge.lua` | the OmniPlay SDK's bridge (module if installed by OmniPlay, data folder otherwise) |
| GMod | `.../cl_ride.lua` | the local rider: runs the trainer every frame |
| LOVE | `game/love/omniplay_api.lua` + `omniplay.lua` | the same `OmniPlay.*` API over the SDK's shared memory (no DLL) |
| vendored | `third_party/omniplay-sdk/` | the SDK as delivered (OmniPlay SDK License: MIT + don't sell OmniPlay support separately) |

## Behaviour

- **Bikes**: speed comes from the rider's **power** through the physics, so a climb at the same watts is
  slower, wind and surface matter. A bike that reports speed but no power gets the power that speed
  takes on the flat. `moving = false` = no power.
- **Walking pads / footpods**: the device's own speed is the runner's speed (the legs set it). The game
  never sets belt speed outside workouts.
- **Hills**: every 0.25 s the average grade over the next 12 m x **difficulty** (default 50 %), clamped
  to -10..+20 %, sent only when it changes by 0.25 % or more. Ferries / water crossings: flat. OmniPlay
  smooths it and applies it only if the player allowed hills.
- `take_input(true)` once OmniPlay is sending and a device is connected; on quit `release()` (flat,
  keys back). If OmniPlay closes, the game drops back to the keyboard by itself.
- Keyboard: W = steady 2.6 W/kg, Shift = sprint (x2.2), S = brake.

## Tests (run without the game or hardware)

```
cd game/tests
python3 ../../tools/luajit.py test_physics.lua        # physics vs real-world numbers
python3 ../../tools/luajit.py ../../third_party/omniplay-sdk/tools/omniplay_sim.lua bike 12 &
python3 ../../tools/luajit.py test_trainer_sim.lua    # LOVE path against the OmniPlay simulator
python3 ../../tools/luajit.py test_gmod_bridge.lua    # GMod path in a fake GMod (data-folder bridge)
```

## Wishes for the OmniPlay side (for the app conversation)

- Nothing blocking. Nice to have later: a "trainer difficulty" hint the player sets once in OmniPlay
  (so every game uses the same feel), and the device's `max_grade` if a trainer can't do +20 %.
