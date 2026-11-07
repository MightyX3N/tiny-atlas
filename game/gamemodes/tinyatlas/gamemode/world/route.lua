-- A loaded route's track: position, heading, grade and ground at any distance along it.
local Route = {}
Route.__index = Route
local floor, sqrt = math.floor, math.sqrt

function Route.new(rt)
  local T = rt.track
  local self = setmetatable({ meta = rt, n = T.n, step = T.step, S = T.s, X = T.x, Y = T.y, Z = T.z, G = T.grade,
    GR = T.ground, BR = T.bridge, length = T.s[T.n], loop = rt.loop, tags = rt.tags, s = 0, wind_along = 0 }, Route)
  self.grade_at = function(s) return self:grade(s) end
  self.tag_at = function(s) return self:tag(s) end
  return self
end

-- index k and fraction f between point k and k+1 (1-based)
function Route:at(s)
  local L = self.length
  if self.loop then s = s % L elseif s < 0 then s = 0 elseif s > L then s = L end
  local k = floor(s / self.step) + 1
  if k >= self.n then return self.n - 1, 1 end
  if k < 1 then k = 1 end
  local S = self.S
  -- the track is resampled at a fixed step, but stay correct if it is not
  while k < self.n - 1 and S[k + 1] < s do k = k + 1 end
  while k > 1 and S[k] > s do k = k - 1 end
  local d = S[k + 1] - S[k]
  return k, d > 0 and (s - S[k]) / d or 0
end

function Route:pos(s)
  local k, f = self:at(s)
  local X, Y, Z = self.X, self.Y, self.Z
  return X[k] + (X[k + 1] - X[k]) * f, Y[k] + (Y[k + 1] - Y[k]) * f, Z[k] + (Z[k + 1] - Z[k]) * f
end

-- unit heading (x, y) averaged over +-span metres
function Route:dir(s, span)
  span = span or 6
  local x1, y1 = self:pos(s - span)
  local x2, y2 = self:pos(s + span)
  local dx, dy = x2 - x1, y2 - y1
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-6 then return 1, 0 end
  return dx / l, dy / l
end

function Route:grade(s)
  local k, f = self:at(s)
  return self.G[k] + (self.G[k + 1] - self.G[k]) * f
end

function Route:tag(s)
  local k, f = self:at(s)
  local g = self.GR[f < 0.5 and k or k + 1]
  return self.tags[g + 1] or "asphalt"
end

return Route
