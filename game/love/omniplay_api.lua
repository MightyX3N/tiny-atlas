-- The GMod `OmniPlay.*` API for the LOVE version, on top of the OmniPlay SDK's love/omniplay.lua
-- (shared memory, no DLL). Game code calls the same functions in both versions.
local sdk = require("omniplay")
local KIND = { bike = "bike", treadmill = "treadmill", footpod = "footpod" }
local API = { Native = true }
local last

function API.IsConnected()
  last = sdk.values()
  return last ~= nil
end

function API.Get()
  local v = last or sdk.values()
  if not v then return nil end
  return {
    speed_kmh = v.speed_kmh, cadence = v.cadence, power = v.power, hr = v.hr, steps = v.steps,
    moving = v.moving, gait = v.gait, grade = v.grade, connected = v.connected,
    distance_m = v.distance_m, elapsed_s = v.elapsed_s,
    device = { kind = KIND[v.kind] },
  }
end

function API.SetGame(name) sdk.set_game(name) end
function API.SetGrade(pct) sdk.set_grade(pct) end
function API.SetBeltSpeed(kmh) sdk.set_belt_speed(kmh) end
function API.TakeInput(on) sdk.take_input(on and true or false) end
function API.SetInfo(text) sdk.set_info(text) end
function API.Release() sdk.release() end

return API
