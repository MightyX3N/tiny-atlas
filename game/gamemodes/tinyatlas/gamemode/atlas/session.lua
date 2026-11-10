-- One ride or free roam in the live world, without any drawing: shared by every game (the LÖVE standalone now,
-- the Garry's Mod layer later). The game supplies the platform and draws what the session says.
--
--   local S = session.new(platform)
--   platform.fetch            fetch.lua instance
--   platform.clock()          seconds (wall clock, for status lines and frame times)
--   platform.log(msg)         status lines
--   platform.make(groups, cell) -> handle,  platform.free(handle)   (as world.lua)
--   platform.jobs             { add = function(fn) -> job }, job.tick yields; jobs.boost_ms while loading
--   S:start_route(name, gpx_text, opts) / S:start_roam(lat, lon, opts)    opts: pack fields (tile_metres, tex_metres,
--       far_metres, buildings, style)
--   S:update(dt, ride_s, keys)  each frame; ride_s = metres ridden (trainer), keys = { left, right, back }
--       -> S.x, S.y, S.z (rider, metres), S.fx, S.fy (heading), S.cam = { x, y, z, lx, ly, lz } (camera, look-at)
--   S.phase "loading" | "riding";  S:loading() -> cells ready, cells wanted;  S:hud_lines()
--   S:route_api() -> what core/trainer.lua needs (grade_at, tag_at, wind_along)
local world = ATLAS_REQUIRE("world")
local route = ATLAS_REQUIRE("route")
local floor, max, min, sqrt, atan2, cos, sin, rad = math.floor, math.max, math.min, math.sqrt, math.atan2, math.cos, math.sin, math.rad

local M = {}
M.__index = M
M.CAM_BACK, M.CAM_UP = 9, 4
M.LOADING_BOOST_MS = 40

function M.new(platform)
  return setmetatable({ P = platform, on = false }, M)
end

function M:log(msg) self.P.log("[Tiny Atlas] " .. msg) end

function M:stop()
  if self.W then self.W:shutdown() end
  if self.job then self.job.cancel = true end
  self.W, self.job, self.on = nil, nil, false
  if self.P.jobs then self.P.jobs.boost_ms = nil end
end

local function begin(self, o, mode, R, lat, lon)
  self:stop()
  local P = self.P
  local W = world.new({
    fetch = P.fetch, lat = lat, lon = lon, tile_metres = o.tile_metres or 3.3, unit = 1,
    tex_metres = o.tex_metres, far_metres = o.far_metres, buildings = o.buildings, style = o.style,
    make = P.make, free = P.free, log = function(m) self:log(m) end,
  })
  self.W, self.R, self.mode, self.on = W, R, mode, true
  self.s, self.phase, self.t = 0, "loading", 0
  self.perf = { n = 0, sum = 0, worst = 0, behind = false }
  self.plan_t, self.note_t = 0, 0
  self.x, self.y, self.z, self.fx, self.fy = 0, 0, 0, 1, 0
  self.started = P.clock()
  if R then R.world = W; W:set_route(R) end
  P.jobs.boost_ms = M.LOADING_BOOST_MS
  self.job = P.jobs.add(function(job)
    job.quiet = true
    job.where = "building the world"
    while not job.cancel and self.W == W do
      if not W:work(job.tick, P.clock) then coroutine.yield() end
    end
  end)
  return true
end

function M:start_route(name, text, o)
  local g, err = route.parse_gpx(text or "")
  if not g then self:log("FAILED: " .. tostring(name) .. ": " .. tostring(err)) return false end
  local lat, lon = g.points[1][1], g.points[1][2]
  -- route.new needs a world for its positions: a throwaway one with the same origin
  local tmp = world.new({ fetch = self.P.fetch, lat = lat, lon = lon, tile_metres = 3.3, unit = 1, make = function() end, free = function() end })
  local R = route.new(g.points, tmp)
  self:log(string.format("riding %s (%.2f km): building the world around the start...", g.name or name, R.length / 1000))
  self.name = g.name or name
  return begin(self, o or {}, "ride", R, lat, lon)
end

function M:start_roam(lat, lon, o)
  self:log(string.format("free roam at %.4f, %.4f: loading...", lat, lon))
  self.name = "Free roam"
  self.heading, self.last_s = 0, nil
  return begin(self, o or {}, "roam", nil, lat, lon)
end

-- what the trainer needs from the ground under the rider
function M:route_api()
  local S = self
  if self.mode == "ride" then
    local R = self.R
    return { grade_at = function(s) return R:grade(s) end, tag_at = function(s) return R:tag(s) end, wind_along = 0 }
  end
  return { grade_at = function() return S.roam_grade or 0 end, tag_at = function() return S.roam_tag or "asphalt" end, wind_along = 0 }
end

-- ---- the rider and the camera ----
local function rider(self, dt, ride_s, keys)
  if self.mode == "ride" then
    local R = self.R
    local s = max(0, min(R.length, ride_s or 0))
    self.s = s
    local x, y, z = R:pos(s)
    local fx, fy = R:dir(s, 8)
    return x, y, z, fx, fy
  end
  local ds = (ride_s or 0) - (self.last_s or ride_s or 0)
  self.last_s = ride_s or 0
  if keys.left then self.heading = self.heading + 60 * dt end
  if keys.right then self.heading = self.heading - 60 * dt end
  local fx, fy = cos(rad(self.heading)), sin(rad(self.heading))
  local x, y = self.x + fx * ds, self.y + fy * ds
  local W = self.W
  local z, surf = W:height_at(x, y)
  if not z then x, y, z = self.x, self.y, self.z end        -- the ground there is not built yet: wait
  local z2 = W:height_at(x + fx * 5, y + fy * 5)
  self.roam_grade = z2 and z and (z2 - z) / 5 * 100 or 0
  self.roam_tag = W:tag_of(surf)
  return x, y, z, fx, fy
end

local function camera(self, x, y, z, fx, fy, back)
  local d, h = M.CAM_BACK, M.CAM_UP
  local W = self.W
  local cx, cy, gz
  if self.mode == "ride" then
    local R = self.R
    local cs = back and self.s + 5 or self.s - d
    cx, cy, gz = R:pos(cs)
    if cs < 0 or cs > R.length then cx, cy = x - fx * (back and -5 or d), y - fy * (back and -5 or d) end
    -- in a sharp corner the route point behind is right beside the rider: step back along the heading instead
    local want = back and 5 or d
    local dx, dy = x - cx, y - cy
    if sqrt(dx * dx + dy * dy) < want * 0.75 then
      local k = back and -want or want
      cx, cy = x - fx * k, y - fy * k
      gz = W:height_at(cx, cy) or gz
    end
  else
    local k = back and -5 or d
    cx, cy = x - fx * k, y - fy * k
    gz = W:height_at(cx, cy) or z
  end
  local cz = max(z, gz or z) + h
  local lfx, lfy = fx, fy
  if back then lfx, lfy = -fx, -fy end
  return { x = cx, y = cy, z = cz, lx = x + lfx * 10, ly = y + lfy * 10, lz = z + 0.6 }
end

function M:update(dt, ride_s, keys)
  local W = self.W
  if not W then return end
  keys = keys or {}
  self.t = self.t + dt
  if self.phase == "riding" then
    local P = self.perf
    P.n, P.sum = P.n + 1, P.sum + dt
    if dt > P.worst then P.worst = dt end
  end
  local x, y, z, fx, fy = rider(self, dt, ride_s, keys)
  self.x, self.y, self.z, self.fx, self.fy = x, y, z, fx, fy
  -- plan a few times a second
  self.plan_t = self.plan_t - dt
  if self.plan_t <= 0 then
    W.s = self.s
    W:focus(x, y, fx, fy)
    self.plan_t = 0.25
  end
  if self.phase == "loading" then
    local miss = W:missing_near(300)
    -- ready when the ground around the start is built (and, on a route, the start has its height)
    if miss == 0 and (self.mode ~= "ride" or self.R.known[1]) then
      self.phase = "riding"
      self.P.jobs.boost_ms = nil
      self:log(string.format("world ready in %.1f s (%d cells built, %.0f ms each on average)", self.P.clock() - self.started,
        W.stats.built, W.stats.built > 0 and W.stats.ms / W.stats.built or 0))
      self.note_t = self.P.clock() + 30
      if self.mode == "roam" then
        local gz = W:height_at(self.x, self.y)
        if not gz then self:log("FAILED: no ground under the start point") end
        self.z = gz or 0; z = self.z
      end
    end
  end
  self:status()
  self.cam = camera(self, x, y, z, fx, fy, keys.back)
end

function M:loading()
  local miss, total = self.W:missing_near(300)
  return total - miss, total
end

-- status lines by themselves: loading every 3 s, riding every 30 s, and at once when the world falls behind
function M:status()
  local W = self.W
  local now = self.P.clock()
  if self.phase == "loading" then
    if now < self.note_t then return end
    self.note_t = now + 3
    local done, total = self:loading()
    self:log(string.format("building the world around you: %d of %d cells ready", done, total))
    return
  end
  local P = self.perf
  local ahead, all = 0, true
  if self.mode == "ride" then ahead, all = W:route_ready_ahead(self.s) end
  local behind = self.mode == "ride" and not all and ahead < 150
  if behind and not P.behind then
    self:log(string.format("FALLING BEHIND: the world is built only %.0f m ahead of you (%d cells waiting)", ahead, #W.queue))
  end
  P.behind = behind
  if now < self.note_t then return end
  self.note_t = now + 30
  if P.n == 0 then return end
  self:log(string.format("riding: %.0f fps, worst frame %.0f ms | %s | %d cells built (%.0f ms each), %d waiting, %d failed",
    P.n / P.sum, P.worst * 1000,
    self.mode == "ride" and (all and "world built to the finish" or string.format("world built %.0f m ahead", ahead)) or "free roam",
    W.stats.built, W.stats.built > 0 and W.stats.ms / W.stats.built or 0, #W.queue, W.stats.failed))
  P.n, P.sum, P.worst = 0, 0, 0
end

function M:hud_lines(speed)
  local l2
  if self.mode == "ride" then
    l2 = string.format("%.2f / %.2f km   grade %.1f %%", self.s / 1000, self.R.length / 1000, self.R:grade(self.s))
  else
    l2 = string.format("free roam   grade %.1f %%", self.roam_grade or 0)
  end
  return { string.format("%.1f km/h", (speed or 0) * 3.6), l2 }
end

return M
