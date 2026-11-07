-- LOVE path, end to end: the OmniPlay simulator (a separate process) plays the app with a rider;
-- the trainer reads it through the SDK's shared memory and sends hills back.
package.path = "../gamemodes/tinyatlas/gamemode/core/?.lua;../love/?.lua;" .. package.path
local ffi = require("ffi"); pcall(ffi.cdef, "int usleep(unsigned us);")
local OmniPlay = require("omniplay_api")
local Trainer = require("trainer")
local T = Trainer.new(OmniPlay, { bike = "mtb", rider_kg = 75, difficulty = 0.5 })
local function grade_at(s) if s < 120 then return 0 elseif s < 600 then return 7 else return 0 end end
local route = { s = 0, grade_at = grade_at, tag_at = function() return "asphalt" end, wind_along = 0 }
local dt, t = 0.05, 0
local log = {}
while t < 9 do
  local st = T:update(dt, {}, route)
  route.s = route.s + st.speed * dt * 6          -- move 6x faster along the route so the test reaches the climb
  t = t + dt
  if math.floor(t * 20 + 0.5) % 10 == 0 then
    log[#log + 1] = string.format("t=%4.1f s=%5.0f grade=%2d src=%s power=%s speed=%5.1f km/h hill=%s",
      t, route.s, grade_at(route.s), st.source, tostring(st.power and math.floor(st.power)), st.speed * 3.6, tostring(st.hill_sent))
  end
  ffi.C.usleep(dt * 1e6)
end
T:release()
for _, l in ipairs(log) do print(l) end
