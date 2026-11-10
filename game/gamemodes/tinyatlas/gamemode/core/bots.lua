-- Computer riders: when a route has no ghosts yet, a few riders of the game's own ride it with you. Each one comes
-- from a seed (name, kit, weight, strength, and whether they climb well), and rides with the same physics as you.
-- Plain Lua, shared by GMod and the standalone.
--   local b = Bots.make(seed)        b.name, b.kit_seed, b.kg, b.wkg (watts a kilo), b.climber (0..1)
--   Bots.step(b, dt, grade, tag)     moves it along: b.s (metres), b.v (m/s), b.cadence, b.power
local Bots = {}
Bots.NAMES = { "Alma", "Bjorn", "Carla", "Dario", "Edda", "Finn", "Greta", "Hugo", "Ines", "Jonas", "Kaja", "Lars", "Mira",
  "Nils", "Olga", "Pablo", "Rosa", "Sven", "Tilde", "Ugo", "Vera", "Wim", "Ylva", "Zeno", "Ada", "Bram", "Cleo", "Emil" }

local function rng(seed)
  local s = (math.floor(math.abs(seed or 1)) % 2147483646) + 1
  return function()
    s = (s * 48271) % 2147483647
    return s / 2147483647
  end
end

function Bots.make(seed, physics)
  local r = rng(seed)
  local b = { seed = seed, kind = "bot" }
  b.name = Bots.NAMES[1 + math.floor(r() * #Bots.NAMES)]
  b.kit_seed = 1 + math.floor(r() * 2000000000)
  b.kg = 58 + math.floor(r() * 30)
  b.wkg = 2.1 + r() * 1.5                -- a steady rider (2.1) to a strong one (3.6)
  b.climber = r()                        -- how much harder they push uphill
  b.cadence0 = 78 + math.floor(r() * 16)
  b.phase = r() * 100
  b.s, b.v, b.t = 0, 0, 0
  b.P = (physics or RidePhysics).new({ bike = "road", rider_kg = b.kg })
  return b
end

-- grade: % here; tag: the ground (for rolling resistance)
function Bots.step(b, dt, grade, tag)
  b.t = b.t + dt
  -- their steady power, more on climbs (good climbers more), and a slow wobble so they don't ride like clocks
  local up = math.max(0, math.min(1, (grade or 0) / 8))
  local wobble = 1 + 0.06 * math.sin(b.t * 0.13 + b.phase) + 0.04 * math.sin(b.t * 0.41 + b.phase * 2)
  local p = b.wkg * b.kg * (1 + up * (0.15 + 0.35 * b.climber)) * wobble
  -- easing off on steep descents (they coast)
  if (grade or 0) < -4 then p = p * 0.3 end
  b.power = p
  b.v = b.P:step(dt, p, grade or 0, tag or "asphalt", 0)
  b.s = b.s + b.v * dt
  b.cadence = b.v > 0.5 and b.cadence0 + 6 * math.sin(b.t * 0.2 + b.phase) or 0
end

return Bots
