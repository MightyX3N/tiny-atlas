-- checks the riding physics against known real-world numbers
package.path = "../gamemodes/tinyatlas/gamemode/core/?.lua;" .. package.path
local P = require("ride_physics")
local fails = 0
local function check(name, got, lo, hi)
  local ok = got >= lo and got <= hi
  if not ok then fails = fails + 1 end
  print(string.format("%-46s %7.2f  (%s..%s) %s", name, got, lo, hi, ok and "ok" or "FAIL"))
end
local road = P.new({ bike = "road", rider_kg = 75 })
local mtb = P.new({ bike = "mtb", rider_kg = 75 })
check("road 200 W flat asphalt km/h", road:steady_speed(200, 0, "asphalt") * 3.6, 30, 36)
check("mtb 200 W flat asphalt km/h", mtb:steady_speed(200, 0, "asphalt") * 3.6, 25, 31)
check("mtb 200 W flat gravel km/h", mtb:steady_speed(200, 0, "gravel") * 3.6, 21, 28)
check("road 250 W on 8 % km/h", road:steady_speed(250, 8, "asphalt") * 3.6, 10, 14)
check("road 300 W on 10 % (Alpe d'Huez-ish) km/h", road:steady_speed(300, 10, "asphalt") * 3.6, 9.5, 13)
check("road 0 W on -6 % (coasting) km/h", road:steady_speed(0, -6, "asphalt") * 3.6, 50, 70)
check("road 200 W, 20 km/h headwind km/h", road:steady_speed(200, 0, "asphalt", 20 / 3.6) * 3.6, 18, 25)
check("power to hold 30 km/h on road flat W", road:power_for(30 / 3.6, 0, "asphalt"), 130, 190)
check("air density 2000 m, 10 C", P.air_density(2000, 10), 0.95, 1.05)
-- acceleration from standstill: 300 W should reach 30 km/h in roughly 10-20 s on a road bike
local r = P.new({ bike = "road" }); local t = 0
while r.v < 30 / 3.6 and t < 60 do r:step(0.05, 300, 0, "asphalt"); t = t + 0.05 end
check("0-30 km/h at 300 W seconds", t, 6, 20)
-- stall on a wall: 100 W on 25 % must not exceed walking pace, and never go negative
local w = P.new({ bike = "mtb" }); for _ = 1, 400 do w:step(0.05, 100, 25, "dirt") end
check("100 W on 25 % dirt km/h (crawls, no stall)", w.v * 3.6, 1.0, 3.0)
print(fails == 0 and "ALL PHYSICS CHECKS PASSED" or (fails .. " FAILED"))
return fails
