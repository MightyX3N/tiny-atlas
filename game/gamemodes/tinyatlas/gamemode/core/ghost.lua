-- Ghosts: a ride recorded once a second (where along the route, speed, cadence), played back later beside you.
-- Plain Lua, shared by GMod, the standalone and the online service's format (online/src/index.js checkGhost):
--   "v1;" then one sample a second from the start: "s,speed,cadence" (metres along, dm/s, rpm), ";" between
--
--   local rec = Ghost.recorder()       rec:add(time, s, speed, cadence)   (call every frame; keeps a sample a second)
--   rec:text() -> the ghost as text
--   local g = Ghost.load(text)         g:at(t) -> s, speed (m/s), cadence; g.time (s), g.length (m), g.done(t)
local Ghost = {}
local floor = math.floor

local Rec = {}
Rec.__index = Rec
function Ghost.recorder() return setmetatable({ n = 0, s = {}, v = {}, c = {} }, Rec) end
-- t: the ride's time so far (pauses not counted); one sample for every whole second passed
function Rec:add(t, s, speed, cadence)
  while self.n <= floor(t) do
    local i = self.n + 1
    self.s[i], self.v[i], self.c[i] = s, speed or 0, cadence or 0
    self.n = i
  end
end
function Rec:text()
  local out = {}
  for i = 1, self.n do
    out[i] = string.format("%.1f,%d,%d", self.s[i], floor(self.v[i] * 10 + 0.5), floor(self.c[i] + 0.5))
  end
  return "v1;" .. table.concat(out, ";")
end
function Rec:seconds() return math.max(0, self.n - 1) end

local G = {}
G.__index = G
function Ghost.load(text)
  if type(text) ~= "string" or text:sub(1, 3) ~= "v1;" then return nil end
  local g = setmetatable({ s = {}, v = {}, c = {} }, G)
  for a, b, c in text:sub(4):gmatch("([-%d%.]+),(%d+),(%d+)") do
    local i = #g.s + 1
    g.s[i], g.v[i], g.c[i] = tonumber(a), tonumber(b) / 10, tonumber(c)
  end
  if #g.s < 2 then return nil end
  g.time, g.length = #g.s - 1, g.s[#g.s]
  return g
end
-- where the ghost is t seconds after the start (it stays at the finish after it)
function G:at(t)
  if t <= 0 then return self.s[1], 0, 0 end
  local i = floor(t) + 1
  if i >= #self.s then return self.s[#self.s], 0, 0 end
  local f = t - (i - 1)
  return self.s[i] + (self.s[i + 1] - self.s[i]) * f, self.v[i] + (self.v[i + 1] - self.v[i]) * f, self.c[i]
end
function G:done(t) return t >= self.time end

return Ghost
