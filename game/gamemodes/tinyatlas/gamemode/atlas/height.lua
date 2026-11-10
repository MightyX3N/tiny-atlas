-- Ground height from Terrarium-encoded elevation tiles at zoom 14, seamless across tile edges. Shared by every game.
-- Takes Mapterhorn tiles (lossless WebP, 512 px) or AWS Terrarium tiles (PNG, 256 px, resampled to 512).
--
-- Positions are "global units": the cell grid's integer coordinates over the whole world, i.e. zoom-17 tile
-- numbers * 8192 + the position inside the cell (see cell.lua). One elevation pixel = 128 global units.
--
--   local H = height.new()
--   height.need(gx0, gy0, gx1, gy1) -> list of { x, y } zoom-14 tiles an area needs (with a margin)
--   H:add(x, y, png_bytes)                   decode and keep one elevation tile
--   H:has(x, y) -> bool
--   H:at(gx, gy) -> metres                   bilinear between pixel centres; nil if a needed tile is missing
--   H:min_around(gx, gy, r) -> metres        lowest height within r global units (25 samples)
local png = ATLAS_REQUIRE("png")
local webp = ATLAS_REQUIRE("webp")
local floor = math.floor

local M = {}
local N = 512                        -- pixels per tile side
local PX = 65536 / N                 -- global units per elevation pixel
M.PX = PX

function M.new()
  return setmetatable({ tiles = {} }, { __index = M })
end

local function key(x, y) return x * 65536 + y end

function M:has(x, y) return self.tiles[key(x, y)] ~= nil end

-- Lidar holes (ported from BeamNG.Earth's dem.fill_holes, MIT): national lidar terrain models have no ground under
-- buildings, and Mapterhorn writes those cells as exactly 0 m. In a low country (Amsterdam's ground is -1 .. +2 m)
-- every building became a pit or a bump. Zero cells take the mean of their non-zero 4-neighbours, round after round
-- (k rounds); zero areas wider than that are the open sea and stay 0, and so does the band filled into their edge.
--   fill_holes(h, n, k) changes h (0-based, n x n) in place; returns the number of cells filled
function M.fill_holes(h, n, k, tick)
  local todo, nt = {}, 0
  local is_hole = {}
  for i = 0, n * n - 1 do
    if h[i] == 0 then nt = nt + 1; todo[nt] = i; is_hole[i] = true end
  end
  if nt == 0 or nt == n * n then return 0 end
  local open = {}                       -- cells still to fill
  for k2 = 1, nt do open[todo[k2]] = true end
  local filled = 0
  for _ = 1, k do
    if nt == 0 then break end
    local got, vals, ng = {}, {}, 0
    local rest, nr = {}, 0
    for k2 = 1, nt do
      local c = todo[k2]
      local i, j = floor(c / n), c % n
      local s, w = 0, 0
      local u = (i > 0 and c - n or c)
      local d = (i < n - 1 and c + n or c)
      local l = (j > 0 and c - 1 or c)
      local r = (j < n - 1 and c + 1 or c)
      if not open[u] then s = s + h[u]; w = w + 1 end
      if not open[d] then s = s + h[d]; w = w + 1 end
      if not open[l] then s = s + h[l]; w = w + 1 end
      if not open[r] then s = s + h[r]; w = w + 1 end
      if w > 0 then ng = ng + 1; got[ng] = c; vals[ng] = s / w
      else nr = nr + 1; rest[nr] = c end
    end
    for k2 = 1, ng do h[got[k2]] = vals[k2]; open[got[k2]] = nil end
    filled = filled + ng
    todo, nt = rest, nr
    if tick then tick() end
  end
  if nt > 0 then
    -- the sea: what is left, grown back over the filled band (k rounds), is 0 again
    local wide = {}
    for k2 = 1, nt do wide[todo[k2]] = true end
    local front, nf = todo, nt
    for _ = 1, k do
      local nxt, nn = {}, 0
      for k2 = 1, nf do
        local c = front[k2]
        local i, j = floor(c / n), c % n
        local nb = { i > 0 and c - n or nil, i < n - 1 and c + n or nil, j > 0 and c - 1 or nil, j < n - 1 and c + 1 or nil }
        for q = 1, 4 do
          local v = nb[q]
          if v and is_hole[v] and not wide[v] then wide[v] = true; nn = nn + 1; nxt[nn] = v end
        end
      end
      front, nf = nxt, nn
      if nf == 0 then break end
    end
    for c in pairs(wide) do if h[c] ~= 0 then filled = filled - 1 end; h[c] = 0 end
  end
  return filled
end
M.HOLE_FILL_M, M.HOLE_FILL_MAX_PX = 600, 24

-- keep one tile; bytes are a WebP (Mapterhorn) or PNG (AWS Terrarium) file. Returns the source name.
function M:add(x, y, bytes, tick)
  local h = {}
  local src
  if bytes:sub(1, 4) == "RIFF" then
    local img = webp.decode(bytes, tick)
    if img.w ~= N or img.h ~= N then error("height: WebP elevation tile is not 512 x 512") end
    local R, G, B = img.R, img.G, img.B
    for i = 0, N * N - 1 do
      h[i] = R[i] * 256 + G[i] + B[i] / 256 - 32768
      if tick and i % 16384 == 0 then tick() end
    end
    src = "mapterhorn"
    -- (Mapterhorn's zoom-14 tiles are national lidar: no ground under buildings)
    local lat = math.deg(math.atan(math.sinh(math.pi * (1 - 2 * (y + 0.5) / 16384))))
    local px_m = 40075016.686 * math.cos(math.rad(lat)) / 16384 / N
    local k = math.min(M.HOLE_FILL_MAX_PX, math.max(2, floor(M.HOLE_FILL_M / px_m + 0.5)))
    self.holes_filled = (self.holes_filled or 0) + M.fill_holes(h, N, k, tick)
  else
    local img = png.decode(bytes)
    if img.w ~= 256 or img.h ~= 256 then error("height: PNG elevation tile is not 256 x 256") end
    local px, ch = img.px, img.ch
    local s = {}
    for i = 0, 256 * 256 - 1 do
      local o = i * ch
      s[i] = px[o + 1] * 256 + px[o + 2] + px[o + 3] / 256 - 32768
    end
    -- resample to 512: pixel centres at (i + 0.5) / 512 of the tile, bilinear on the 256 grid (clamped inside)
    for yy = 0, N - 1 do
      if tick and yy % 32 == 0 then tick() end
      local fy = (yy + 0.5) / 2 - 0.5
      if fy < 0 then fy = 0 elseif fy > 255 then fy = 255 end
      local iy = floor(fy); if iy > 254 then iy = 254 end
      local ay = fy - iy
      for xx = 0, N - 1 do
        local fx = (xx + 0.5) / 2 - 0.5
        if fx < 0 then fx = 0 elseif fx > 255 then fx = 255 end
        local ix = floor(fx); if ix > 254 then ix = 254 end
        local ax = fx - ix
        local o = iy * 256 + ix
        h[yy * N + xx] = (s[o] * (1 - ax) + s[o + 1] * ax) * (1 - ay) + (s[o + 256] * (1 - ax) + s[o + 257] * ax) * ay
      end
    end
    src = "terrarium"
  end
  self.tiles[key(x, y)] = h
  return src
end

function M:drop(x, y) self.tiles[key(x, y)] = nil end

-- height of one global pixel (integer pixel coordinates)
local function pixel(self, ix, iy)
  local tx, ty = floor(ix / N), floor(iy / N)
  local t = self.tiles[tx * 65536 + ty]
  if not t then return nil end
  return t[(iy - ty * N) * N + (ix - tx * N)]
end

function M:at(gx, gy)
  local fx, fy = gx / PX - 0.5, gy / PX - 0.5      -- pixel centres sit at half-pixel positions
  local ix, iy = floor(fx), floor(fy)
  local ax, ay = fx - ix, fy - iy
  local h00, h10 = pixel(self, ix, iy), pixel(self, ix + 1, iy)
  local h01, h11 = pixel(self, ix, iy + 1), pixel(self, ix + 1, iy + 1)
  if not (h00 and h10 and h01 and h11) then return nil end
  return (h00 * (1 - ax) + h10 * ax) * (1 - ay) + (h01 * (1 - ax) + h11 * ax) * ay
end

-- like at, but where a neighbouring tile is missing the nearest available pixel is used (for the distant ground,
-- which only loads the tiles it covers)
function M:at_soft(gx, gy)
  local fx, fy = gx / PX - 0.5, gy / PX - 0.5
  local ix, iy = floor(fx), floor(fy)
  local ax, ay = fx - ix, fy - iy
  local h00, h10 = pixel(self, ix, iy), pixel(self, ix + 1, iy)
  local h01, h11 = pixel(self, ix, iy + 1), pixel(self, ix + 1, iy + 1)
  local any = h00 or h10 or h01 or h11
  if not any then return nil end
  h00 = h00 or h10 or h01 or h11; h10 = h10 or h00; h01 = h01 or h00; h11 = h11 or h10 or h01
  return (h00 * (1 - ax) + h10 * ax) * (1 - ay) + (h01 * (1 - ax) + h11 * ax) * ay
end

local OFF = { { 0, 0 } }
for k = 0, 11 do
  local a = k * math.pi / 6
  OFF[#OFF + 1] = { math.cos(a), math.sin(a) }
  OFF[#OFF + 1] = { 0.5 * math.cos(a + 0.26), 0.5 * math.sin(a + 0.26) }
end
function M:min_around(gx, gy, r)
  local m
  for i = 1, #OFF do
    local h = self:at(gx + OFF[i][1] * r, gy + OFF[i][2] * r)
    if h and (not m or h < m) then m = h end
  end
  return m
end

-- lowest height around a point, looked up on a fixed global grid (about 8 m at 55 deg N) and remembered, so
-- every cell gets the same value at the same place and water vertices don't each sample 25 points
local WG = 256
function M:water_level(gx, gy, r)
  local ix, iy = floor(gx / WG + 0.5), floor(gy / WG + 0.5)
  local c = self.wl
  if not c then c = {}; self.wl = c end
  local k = ix * 1048576 + iy + r * 1e12
  local v = c[k]
  if v == nil then
    v = self:min_around(ix * WG, iy * WG, r) or false
    c[k] = v
  end
  return v or nil
end

-- zoom-14 tiles covering an area of global units, plus a margin of two pixels for the bilinear filter
function M.need(gx0, gy0, gx1, gy1, margin)
  margin = margin or 2 * PX
  local out = {}
  local T = 65536                                     -- global units per zoom-14 tile
  for x = floor((gx0 - margin) / T), floor((gx1 + margin) / T) do
    for y = floor((gy0 - margin) / T), floor((gy1 + margin) / T) do out[#out + 1] = { x, y } end
  end
  return out
end

return M
