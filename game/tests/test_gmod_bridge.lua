-- GMod path, end to end, in a fake GMod: the real gamemode files + the real OmniPlay bridge (data-folder
-- fallback, no module) + a fake OmniPlay app writing live.txt and reading cmd.txt the way the app does.
local DATA = os.tmpname() .. "_gmdata"; os.execute('mkdir -p "' .. DATA .. '/omniplay"')
local GMDIR = "../gamemodes/tinyatlas/gamemode"
local F = dofile("fakegmod.lua")(DATA, GMDIR)
dofile("fakegmod_render.lua")(F, { lua_roots = { "../gamemodes" } })   -- cl_init also loads the world builder
GM.FolderName = "tinyatlas"
http = http or { Fetch = function(url, ok, fail) fail("no network in test") end }
local fails = 0
local function check(name, ok, extra) if not ok then fails = fails + 1 end; print(string.format("%-58s %s %s", name, ok and "ok" or "FAIL", extra or "")) end

include("cl_init.lua")
check("gamemode loads; OmniPlay API present", OmniPlay ~= nil and OmniPlay.Get ~= nil and Trainer ~= nil)
check("bridge uses the data folder (no module installed)", OmniPlay.Native == false)
hook.Run("InitPostEntity")
check("trainer created", TinyAtlas.Ride.trainer ~= nil)
-- the game owns the screen from the start (its title screen); no ride is running yet
F.render_frame(1 / 60)
check("the game's screens draw from the start", TinyAtlas.Screens ~= nil and TinyAtlas.Screens.screen == "title" and #F.texts > 0)
check("no ride running: the rider stands still", TinyAtlas.Ride.mode ~= "ride")
check("ride commands registered", F.commands.ta_ride ~= nil and F.commands.ta_roam ~= nil and F.commands.ta_stop ~= nil)
check("new builder bench command registered", F.commands.ta_buildbench ~= nil)

-- a test route: flat, then a 6 % climb from 100 m (ridden: the rider's mode as when a ride is going)
TinyAtlas.Route = { grade_at = function(s) return s >= 100 and 6 or 0 end, tag_at = function() return "asphalt" end, wind_along = 0 }
TinyAtlas.Ride.start("ride")

-- 1) no OmniPlay: keyboard riding
F.keys[KEY_W] = true
for _ = 1, 100 do F.tick(0.05) end
local st = TinyAtlas.Ride.state
check("no app: keyboard source", st and st.source == "keyboard", st and st.source)
check("no app: W makes you ride", TinyAtlas.Ride.speed > 3, string.format("%.1f km/h", TinyAtlas.Ride.speed * 3.6))
F.keys[KEY_W] = nil

-- 2) the app starts: the fake OmniPlay writes live.txt 10x a second (like OmniPlay does)
local seq, cmd = 0, nil
local function app_write(fields)
  seq = seq + 1
  local t = { type = "state", v = 1, seq = seq, app = "OmniPlay", connected = true,
              device = { name = "TestBike", kind = fields.kind or "bike", hills = true, belt_speed = false },
              speed_kmh = fields.speed or 25, cadence = 85, power = fields.power, hr = 120, moving = fields.moving ~= false,
              gait = "run", grade = 0, distance_m = 0, elapsed_s = 0 }
  file.Write("omniplay/live.txt", F.enc(t))
end
local function run(secs, fields)
  local n = math.floor(secs / 0.05)
  for i = 1, n do
    if i % 2 == 0 then app_write(fields) end
    F.tick(0.05)
    local raw = file.Read("omniplay/cmd.txt"); if raw then cmd = F.dec(raw) end
  end
end
TinyAtlas.Ride.s = 0
run(4, { power = 220 })
st = TinyAtlas.Ride.state
check("app running: OmniPlay source", st.source == "omniplay", st.source)
check("power from the bike reaches the physics", st.power == 220, tostring(st.power))
check("game names itself in OmniPlay", cmd and cmd.game == "Tiny Atlas", cmd and tostring(cmd.game))
check("take_input sent (OmniPlay stops pressing keys)", cmd and cmd.take_input == true)
local beat1 = cmd and cmd.beat
run(1, { power = 220 })
check("heartbeat keeps counting", cmd and beat1 and cmd.beat > beat1, string.format("%s -> %s", tostring(beat1), tostring(cmd and cmd.beat)))
check("game acks OmniPlay's state seq", cmd and cmd.ack and cmd.ack >= seq - 2, string.format("ack %s seq %d", tostring(cmd and cmd.ack), seq))
local flat_speed = TinyAtlas.Ride.speed
-- ride onto the climb
while TinyAtlas.Ride.s < 140 do run(0.5, { power = 220 }) end
run(3, { power = 220 })
check("hill sent to the trainer on the climb (6 % x 0.5 = 3 %)", cmd and type(cmd.grade) == "number" and math.abs(cmd.grade - 3) < 0.3, tostring(cmd and cmd.grade))
check("the climb slows the rider at the same power", TinyAtlas.Ride.speed < flat_speed, string.format("%.1f -> %.1f km/h", flat_speed * 3.6, TinyAtlas.Ride.speed * 3.6))
-- a bike that reports speed but no power still rides
run(3, { power = nil, speed = 20 })
st = TinyAtlas.Ride.state
check("speed-only bike: power worked out from its speed", st.power and st.power > 50, string.format("%s W", tostring(st.power and math.floor(st.power))))
-- walking pad: its speed is the runner's speed
run(3, { kind = "treadmill", speed = 6 })
st = TinyAtlas.Ride.state
check("walking pad: rider moves at the belt's speed", math.abs(TinyAtlas.Ride.speed * 3.6 - 6) < 0.5, string.format("%.1f km/h", TinyAtlas.Ride.speed * 3.6))

-- 3) the app closes: back to the keyboard
file.Write("omniplay/live.txt", F.enc({ closed = true, seq = seq + 1 }))
for _ = 1, 60 do F.tick(0.05) end
st = TinyAtlas.Ride.state
check("app closed: back to the keyboard", st.source == "keyboard", st.source)

hook.Run("ShutDown")
os.execute('rm -rf "' .. DATA .. '"')
print(fails == 0 and "ALL GMOD BRIDGE CHECKS PASSED" or (fails .. " FAILED"))
return fails
