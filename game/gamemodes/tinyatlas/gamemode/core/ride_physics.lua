-- Riding physics, shared by GMod and LOVE (plain Lua, no engine calls).
-- Power in, speed out: the real forces on a rider (gravity on the grade, rolling resistance of the
-- surface, air drag with wind), so a climb slows you down the way it would outside. Runners and
-- walking pads use the device's own speed instead (the person sets it with their legs).
local P = {}
P.__index = P

local G = 9.81

-- rolling resistance per ground tag (MTB tyre; road tyres use about 60 % of this)
P.CRR = {
  asphalt = 0.0045, cycleway = 0.0045, parking = 0.005, paving = 0.006, cobble = 0.010, gravel = 0.010,
  dirt = 0.013, rural = 0.016, grass = 0.018, meadow = 0.018, dry_grass = 0.016, farmland = 0.02, forest_floor = 0.016,
  scrub = 0.02, sand = 0.035, rock = 0.012, snow = 0.03, wetland = 0.03, orchard = 0.018, pitch = 0.012, urban = 0.006,
  rail = 0.01, water = 0.0,
}

-- bikes: drag area (m^2), mass (kg), tyre factor on CRR
P.BIKES = {
  road = { cda = 0.35, mass = 8.5, tyre = 0.6 },     -- hoods, recreational position
  mtb = { cda = 0.50, mass = 13.0, tyre = 1.0 },      -- upright
  bmx = { cda = 0.52, mass = 11.0, tyre = 1.1 },
  unicycle = { cda = 0.55, mass = 6.0, tyre = 1.4 },
}

function P.new(opts)
  opts = opts or {}
  local bike = P.BIKES[opts.bike or "mtb"] or P.BIKES.mtb
  return setmetatable({
    v = 0,                                   -- speed along the route, m/s
    rider_kg = opts.rider_kg or 75,
    bike = bike,
    eff = 0.975,                             -- drivetrain
    rho = opts.rho or 1.2,                   -- air density
    max_v = (opts.max_kmh or 90) / 3.6,      -- a sane cap on descents
  }, P)
end

-- air density at a height (m) and temperature (C): a climb in the Alps really is a little less draggy
function P.air_density(height_m, temp_c)
  local t = (temp_c or 15) + 273.15
  local p = 101325 * (1 - 2.25577e-5 * math.max(-400, height_m or 0)) ^ 5.25588
  return p / (287.05 * t)
end

function P:mass() return self.rider_kg + self.bike.mass end

-- forces resisting motion at speed v (N); grade in % (+ uphill), wind_along m/s (+ = headwind)
function P:resist(v, grade, tag, wind_along)
  local m = self:mass()
  local a = math.atan((grade or 0) / 100)
  local crr = (P.CRR[tag or "asphalt"] or 0.008) * self.bike.tyre
  local va = v + (wind_along or 0)
  local aero = 0.5 * self.rho * self.bike.cda * va * math.abs(va)
  return m * G * math.sin(a) + crr * m * G * math.cos(a) + aero
end

-- advance dt seconds with `power` watts; returns the new speed (m/s)
function P:step(dt, power, grade, tag, wind_along)
  local m = self:mass() + 1.5                -- + spinning wheels
  local v = self.v
  -- at a standstill power can't be divided by speed: cap the push like a rider's legs would (~ 600 N)
  local drive = (power or 0) * self.eff / math.max(v, 0.15)
  drive = math.min(drive, 600)
  local f = drive - self:resist(v, grade, tag, wind_along)
  local nv = v + f / m * dt
  if nv < 0 then nv = 0 end                 -- no rolling backwards (a rider would put a foot down)
  if nv > self.max_v then nv = self.max_v end
  self.v = nv
  return nv
end

-- the steady speed for a power on a grade (for menus, ghosts and checks)
function P:steady_speed(power, grade, tag, wind_along)
  local lo, hi = 0, self.max_v
  for _ = 1, 60 do
    local mid = (lo + hi) / 2
    if power * self.eff - self:resist(mid, grade, tag, wind_along) * mid > 0 then lo = mid else hi = mid end
  end
  return lo
end

-- the power it takes to hold a speed on a grade (e.g. a trainer that reports speed but no power)
function P:power_for(v, grade, tag, wind_along)
  return math.max(0, self:resist(v, grade, tag, wind_along) * v / self.eff)
end

return P
