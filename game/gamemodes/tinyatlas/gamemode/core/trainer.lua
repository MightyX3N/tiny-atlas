-- The rider's legs: a smart trainer / walking pad through OmniPlay when it's running, the keyboard
-- (or a controller) otherwise. Shared by GMod and LOVE: both give it the same `OmniPlay` API (the
-- omniplay_bridge addon in GMod, game/love/omniplay_api.lua in LOVE).
--
--   local T = Trainer.new(OmniPlay, { bike = "mtb", rider_kg = 75, difficulty = 0.5 })
--   every frame: local st = T:update(dt, input, route)
--     input = { forward = bool, sprint = bool, brake = bool }      (keyboard / controller)
--     route = { s = metres along the route, grade_at = f(s) -> %, tag_at = f(s) -> ground tag,
--               wind_along = m/s (+ headwind), boat = bool (on a ferry / water crossing) }
--     st = { speed = m/s, power, cadence, hr, source = "omniplay" | "keyboard", kind, hill_sent }
--
-- Bikes: speed comes from the rider's power through the riding physics (grade, surface, wind), so
-- climbs feel like climbs. A bike that reports speed but no power gets the power that speed would
-- take on the flat. Walking pads and footpods: the device's own speed (the legs set it).
-- Hills go back to the trainer: the grade a few metres ahead x difficulty, clamped to what OmniPlay
-- accepts. OmniPlay smooths it; it only applies it if the player allowed "Games may set hills".
local Trainer = {}
Trainer.__index = Trainer

local function find_physics()
  if RidePhysics then return RidePhysics end          -- GMod: loaded as a global by the gamemode
  return require("ride_physics")                      -- LOVE / tests
end

function Trainer.new(api, opts)
  opts = opts or {}
  local Phys = find_physics()
  local self = setmetatable({
    api = api,
    phys = Phys.new({ bike = opts.bike or "mtb", rider_kg = opts.rider_kg or 75 }),
    difficulty = opts.difficulty or 0.5,             -- share of the real grade sent to the trainer
    lookahead = opts.lookahead or 12,                -- metres: the trainer needs a moment to change
    grade_min = -10, grade_max = 20,                 -- what OmniPlay accepts
    keyboard_wkg = opts.keyboard_wkg or 2.6,         -- keyboard riding: a steady club rider
    game = opts.game or "Tiny Atlas",
    taken = false, named = false,
    hill_t = 0, hill_sent = nil,
    cadence = 0, power = 0,
  }, Trainer)
  return self
end

-- the grade the trainer should feel now: averaged over the stretch just ahead
function Trainer:hill_target(route)
  if route.boat then return nil end
  local s, n, sum = route.s or 0, 4, 0
  for i = 1, n do sum = sum + (route.grade_at(s + self.lookahead * i / n) or 0) end
  local g = sum / n * self.difficulty
  return math.max(self.grade_min, math.min(self.grade_max, g))
end

function Trainer:device()
  local api = self.api
  if not api or not api.IsConnected or not api.IsConnected() then return nil end
  local d = api.Get()
  if not d or d.connected == false then return nil end    -- OmniPlay runs but no machine is paired
  return d
end

function Trainer:update(dt, input, route)
  input = input or {}
  local api = self.api
  local d = self:device()
  if api and api.SetGame and not self.named and api.IsConnected and api.IsConnected() then
    api.SetGame(self.game); self.named = true
  end
  local grade = route.grade_at(route.s or 0) or 0
  local tag = route.tag_at and route.tag_at(route.s or 0) or "asphalt"
  local wind = route.wind_along or 0
  local st = { hill_sent = self.hill_sent }

  if d then
    -- we read the machine ourselves: OmniPlay stops pressing keys (asked once, while connected)
    if not self.taken then api.TakeInput(true); self.taken = true end
    local kind = d.device and d.device.kind or d.kind or "bike"
    st.source, st.kind, st.hr, st.cadence = "omniplay", kind, d.hr, d.cadence or 0
    if kind == "bike" then
      local power = d.power
      if power == nil then        -- speed-only bike: the power that speed takes on the flat
        power = self.phys:power_for((d.speed_kmh or 0) / 3.6, 0, "asphalt")
      end
      if d.moving == false then power = 0 end
      st.power = power
      st.speed = route.boat and self.phys.v or self.phys:step(dt, power, grade, tag, wind)
    else                          -- walking pad / footpod: their speed is the runner's speed
      local target = (d.moving == false) and 0 or (d.speed_kmh or 0) / 3.6
      self.phys.v = self.phys.v + (target - self.phys.v) * math.min(1, dt * 4)
      st.speed = self.phys.v
    end
    -- hills back to the machine, a few times a second, only when they change
    self.hill_t = self.hill_t + dt
    if self.hill_t >= 0.25 then
      self.hill_t = 0
      local want = self:hill_target(route)
      local changed = (want == nil) ~= (self.hill_sent == nil) or (want and self.hill_sent and math.abs(want - self.hill_sent) >= 0.25)
      if changed then api.SetGrade(want); self.hill_sent = want end
      st.hill_sent = self.hill_sent
    end
  else
    -- keyboard / controller: a steady effort, more when sprinting, nothing when coasting
    if self.taken then self.taken = false end   -- OmniPlay takes the keys back by itself
    local base = self.keyboard_wkg * self.phys.rider_kg
    local power = input.forward and (input.sprint and base * 2.2 or base) or 0
    st.source, st.kind, st.power = "keyboard", "bike", power
    st.cadence = power > 0 and (input.sprint and 105 or 88) or 0
    local v = self.phys:step(dt, power, grade, tag, wind)
    if input.brake then v = math.max(0, v - 4 * dt); self.phys.v = v end
    st.speed = v
  end
  self.power = st.power or 0
  return st
end

-- leave cleanly: flat hill and keys back to OmniPlay (also happens by itself 3 s after we stop reading)
function Trainer:release()
  if self.api and self.taken then
    if self.api.SetGrade then self.api.SetGrade(nil) end
    if self.api.TakeInput then self.api.TakeInput(false) end
  end
  self.taken = false
  if self.api and self.api.Release then self.api.Release() end
end

return Trainer
