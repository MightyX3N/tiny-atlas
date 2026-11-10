-- The local rider: OmniPlay or keyboard -> speed along the route, hills back to the trainer.
--   R.mode  "off"     nothing moves
--           "auto"    the menu's background: the camera rides the route by itself (no trainer)
--           "ride"    riding: the trainer (or keyboard) sets the speed; the ride's numbers are counted
--           "paused"  riding, stopped (pause menu)
--   R.stats  the ride so far: time, distance, climbed, energy (power x time), max power, heart rate sums
TinyAtlas.Ride = TinyAtlas.Ride or { s = 0, speed = 0, mode = "off" }
local R = TinyAtlas.Ride
R.AUTO_SPEED = 7                          -- m/s: the menu's fly-along

-- the trainer's settings (the trainer screen changes them)
local cv_difficulty = CreateClientConVar("ta_trainer_difficulty", "50", true, false, "Share of the real hills sent to the trainer (%)")
local cv_weight = CreateClientConVar("ta_rider_kg", "75", true, false, "Rider weight (kg) for the riding physics")
local cv_bike = CreateClientConVar("ta_bike", "mtb", true, false, "Bike: road, mtb, bmx (rolling resistance and drag)")
R.cv = { difficulty = cv_difficulty, weight = cv_weight, bike = cv_bike }

-- the route being ridden; route loading fills this in (until then: flat, so the keys still work)
TinyAtlas.Route = TinyAtlas.Route or {
  grade_at = function(s) return 0 end, tag_at = function(s) return "asphalt" end, wind_along = 0,
}

function R.make_trainer()
  if R.trainer then R.trainer:release() end
  R.trainer = Trainer.new(OmniPlay, { bike = cv_bike:GetString(), rider_kg = cv_weight:GetFloat(),
    difficulty = cv_difficulty:GetFloat() / 100, game = "Tiny Atlas" })
end
hook.Add("InitPostEntity", "TinyAtlas_Trainer", function() R.make_trainer() end)

function R.reset_stats()
  R.stats = { time = 0, dist = 0, climb = 0, energy = 0, max_power = 0, hr_sum = 0, hr_time = 0, cad_sum = 0, cad_time = 0 }
  R.last_z = nil
end
R.reset_stats()

function R.start(mode)
  R.mode = mode
  if mode == "ride" then
    R.s, R.speed = 0, 0
    R.reset_stats()
    if not R.trainer then R.make_trainer() end
    if R.trainer then R.trainer.phys.v = 0 end
  end
end

hook.Add("Think", "TinyAtlas_Ride", function()
  local dt = FrameTime()
  if dt <= 0 then return end
  local route = TinyAtlas.Route
  if R.mode == "auto" then
    R.speed = R.AUTO_SPEED
    R.s = (R.s or 0) + R.speed * dt
    if route.length and R.s > route.length - 50 then R.s = 0 end
    return
  end
  if R.mode ~= "ride" then
    R.speed = 0
    if R.trainer and R.trainer.phys then R.trainer.phys.v = 0 end
    return
  end
  local T = R.trainer
  if not T then return end
  route.s = R.s
  local st = T:update(dt, {
    forward = input.IsKeyDown(KEY_W), sprint = input.IsKeyDown(KEY_LSHIFT), brake = input.IsKeyDown(KEY_S),
  }, route)
  R.speed, R.state = st.speed, st
  R.s = R.s + st.speed * dt
  -- the ride's numbers
  local S = R.stats
  S.time = S.time + dt
  S.dist = S.dist + st.speed * dt
  local p = st.power or 0
  S.energy = S.energy + p * dt
  if p > S.max_power then S.max_power = p end
  if st.hr and st.hr > 0 then S.hr_sum = S.hr_sum + st.hr * dt; S.hr_time = S.hr_time + dt end
  if st.cadence and st.cadence > 0 then S.cad_sum = S.cad_sum + st.cadence * dt; S.cad_time = S.cad_time + dt end
  if route.pos then
    local _, _, z = route:pos(R.s)
    if z and R.last_z and z > R.last_z then S.climb = S.climb + (z - R.last_z) end
    R.last_z = z
  end
end)

hook.Add("ShutDown", "TinyAtlas_Trainer", function() if R.trainer then R.trainer:release() end end)
