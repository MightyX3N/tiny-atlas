-- A route to ride: read from GPX, placed in the world, with heights from the built ground. Shared by every game.
--
--   route.parse_gpx(text) -> { name = ..., points = { {lat, lon}, ... } } or nil, error
--   local R = route.new(points, world)     world: world.lua instance (positions, cells)
--   R.n, R.S[i] (metres along), R.X[i], R.Y[i] (metres from the world origin, y north), R.GX[i], R.GY[i] (global
--   units), R.Z[i] (metres, after heights are filled in), R.surf[i] (ground surface under the point)
--   R:pos(s) -> x, y, z   R:dir(s) -> fx, fy   R:grade(s) -> %   R:tag(s) -> ground tag for the ride physics
--   (the world moves the points onto the roads and paths they are on as it matches the route: match.lua)
local M = {}
local floor, sqrt, max, min, abs = math.floor, math.sqrt, math.max, math.min, math.abs
M.STEP = 2                                          -- metres between resampled route points

local function attr(tag, name)
  return tonumber(tag:match('%f[%w]' .. name .. '%s*=%s*"([^"]*)"') or tag:match("%f[%w]" .. name .. "%s*=%s*'([^']*)'"))
end

function M.parse_gpx(text)
  local pts = {}
  for _, kind in ipairs({ "trkpt", "rtept" }) do
    for tag in text:gmatch("<" .. kind .. "%s[^>]*>") do
      local lat, lon = attr(tag, "lat"), attr(tag, "lon")
      if lat and lon then pts[#pts + 1] = { lat, lon } end
    end
    if #pts > 0 then break end
  end
  if #pts < 2 then return nil, "no track points in the GPX file" end
  local name = text:match("<trk>%s*<name>([^<]*)</name>") or text:match("<name>([^<]*)</name>")
  return { name = name, points = pts }
end

function M.new(points, world)
  local R = setmetatable({ world = world, S = {}, X = {}, Y = {}, GX = {}, GY = {}, Z = {}, ZR = {}, known = {}, surf = {}, n = 0,
    wind_along = 0, s = 0 }, { __index = M })
  -- metres along the track, then resample every STEP metres
  local gx, gy, xs, ys, ds = {}, {}, {}, {}, {}
  local d = 0
  for i, p in ipairs(points) do
    gx[i], gy[i] = world:global_of(p[1], p[2])
    xs[i], ys[i] = world:metres_of(gx[i], gy[i])
    if i > 1 then d = d + sqrt((xs[i] - xs[i - 1]) ^ 2 + (ys[i] - ys[i - 1]) ^ 2) end
    ds[i] = d
  end
  local n = floor(d / M.STEP) + 1
  local j = 1
  for k = 1, n do
    local s = (k - 1) * M.STEP
    while j < #points - 1 and ds[j + 1] < s do j = j + 1 end
    local seg = ds[j + 1] - ds[j]
    local f = seg > 0 and (s - ds[j]) / seg or 0
    if f > 1 then f = 1 end
    R.S[k] = s
    R.GX[k] = gx[j] + (gx[j + 1] - gx[j]) * f
    R.GY[k] = gy[j] + (gy[j + 1] - gy[j]) * f
    R.X[k], R.Y[k] = world:metres_of(R.GX[k], R.GY[k])
  end
  R.n, R.length = n, R.S[n]
  R.grade_at = function(s) return R:grade(s) end
  R.tag_at = function(s) return R:tag(s) end
  return R
end

-- the zoom-17 cells the route passes through, in riding order (each once)
function M:cells()
  local seen, out = {}, {}
  for k = 1, self.n do
    local cx, cy = floor(self.GX[k] / 8192), floor(self.GY[k] / 8192)
    local key = cx * 1048576 + cy
    if not seen[key] then seen[key] = true; out[#out + 1] = { cx, cy } end
  end
  return out
end

-- after heights: points without ground (over water where the bridge is not built yet, or missing data) take a
-- straight line between the nearest points that have ground; then grades over +-6 m. Returns a summary.
-- Called again whenever more of the route gets heights (ZR = ground height, known = its cell is built).
function M:finish_heights()
  local ZR, n, known = self.ZR, self.n, self.known
  local Z = {}
  local gaps, gap_m, longest = 0, 0, 0
  local k = 1
  while k <= n do
    if ZR[k] == nil then
      local k0 = k
      local built = true
      while k <= n and ZR[k] == nil do
        if not known[k] then built = false end
        k = k + 1
      end
      local a, b = ZR[k0 - 1], ZR[k]
      local len = (k - k0) * M.STEP
      if built then
        gaps = gaps + 1; gap_m = gap_m + len
        if len > longest then longest = len end
      end
      for i = k0, k - 1 do
        if a and b then Z[i] = a + (b - a) * (i - k0 + 1) / (k - k0 + 1)
        else Z[i] = a or b or 0 end                      -- not built yet: level with the last known height
      end
    else Z[k] = ZR[k]; k = k + 1 end
  end
  self.Z = Z
  -- grade in %, from the heights 6 m behind and ahead
  local G = {}
  local w = max(1, floor(6 / M.STEP + 0.5))
  local worst, worst_s, steep_m = 0, 0, 0
  for i = 1, n do
    local a, b = max(1, i - w), min(n, i + w)
    local run = self.S[b] - self.S[a]
    G[i] = run > 0 and (Z[b] - Z[a]) / run * 100 or 0
    if abs(G[i]) > abs(worst) then worst, worst_s = G[i], self.S[i] end
    if abs(G[i]) > 25 then steep_m = steep_m + M.STEP end
  end
  self.G = G
  local up = 0
  for i = 2, n do if Z[i] > Z[i - 1] then up = up + Z[i] - Z[i - 1] end end
  self.summary = { gaps = gaps, gap_m = gap_m, longest_gap = longest, worst_grade = worst, worst_at = worst_s,
    steep_m = steep_m, climb = up, length = self.length }
  return self.summary
end

local function at(self, s)
  local n = self.n
  if s <= 0 then return 1, 0 end
  if s >= self.length then return n - 1, 1 end
  local k = floor(s / M.STEP) + 1
  if k >= n then return n - 1, 1 end
  return k, (s - self.S[k]) / M.STEP
end

function M:pos(s)
  local k, f = at(self, s)
  local Z = self.Z
  local z0, z1 = Z[k] or 0, Z[k + 1] or Z[k] or 0
  return self.X[k] + (self.X[k + 1] - self.X[k]) * f, self.Y[k] + (self.Y[k + 1] - self.Y[k]) * f, z0 + (z1 - z0) * f
end

function M:dir(s, span)
  span = span or 6
  local x1, y1 = self:pos(s - span)
  local x2, y2 = self:pos(s + span)
  local dx, dy = x2 - x1, y2 - y1
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-6 then return 1, 0 end
  return dx / l, dy / l
end

function M:grade(s)
  if not self.G then return 0 end
  local k, f = at(self, s)
  return self.G[k] + (self.G[k + 1] - self.G[k]) * f
end

function M:tag(s)
  local k, f = at(self, s)
  local surf = self.surf[f < 0.5 and k or k + 1]
  return self.world:tag_of(surf)
end

return M
