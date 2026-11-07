-- The local rider: OmniPlay or keyboard -> speed along the route, hills back to the trainer.
TinyAtlas.Ride = TinyAtlas.Ride or { s = 0, speed = 0 }
local R = TinyAtlas.Ride

-- the route being ridden; route loading fills this in (until then: flat, so the keys still work)
TinyAtlas.Route = TinyAtlas.Route or {
  grade_at = function(s) return 0 end, tag_at = function(s) return "asphalt" end, wind_along = 0,
}

hook.Add("InitPostEntity", "TinyAtlas_Trainer", function()
  R.trainer = Trainer.new(OmniPlay, { bike = "mtb", rider_kg = 75, difficulty = 0.5, game = "Tiny Atlas" })
end)

hook.Add("Think", "TinyAtlas_Ride", function()
  local T = R.trainer
  if not T then return end
  local dt = FrameTime()
  if dt <= 0 then return end
  local route = TinyAtlas.Route
  route.s = R.s
  local st = T:update(dt, {
    forward = input.IsKeyDown(KEY_W), sprint = input.IsKeyDown(KEY_LSHIFT), brake = input.IsKeyDown(KEY_S),
  }, route)
  R.speed, R.state = st.speed, st
  R.s = R.s + st.speed * dt
end)

hook.Add("ShutDown", "TinyAtlas_Trainer", function() if R.trainer then R.trainer:release() end end)
