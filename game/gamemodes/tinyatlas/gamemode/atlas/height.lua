-- Ground height from Terrarium elevation tiles (zoom 14, 256 px), seamless across tile edges. Shared by every game.
--
-- Positions are "global units": the cell grid's integer coordinates over the whole world, i.e. zoom-17 tile
-- numbers * 8192 + the position inside the cell (see cell.lua). One zoom-14 elevation pixel = 256 global units.
--
--   local H = height.new()
--   height.need(gx0, gy0, gx1, gy1) -> list of { x, y } zoom-14 tiles an area needs (with a margin)
--   H:add(x, y, png_bytes)                   decode and keep one elevation tile
--   H:has(x, y) -> bool
--   H:at(gx, gy) -> metres                   bilinear between pixel centres; nil if a needed tile is missing
--   H:min_around(gx, gy, r) -> metres        lowest height within r global units (9 samples)
local png = ATLAS_REQUIRE("png")
local floor = math.floor

local M = {}
local PX = 256                       -- global units per elevation pixel
M.PX = PX

function M.new()
  return setmetatable({ tiles = {} }, { __index = M })
end

local function key(x, y) return x * 65536 + y end

function M:has(x, y) return self.tiles[key(x, y)] ~= nil end

function M:add(x, y, bytes)
  local img = png.decode(bytes)
  if img.w ~= 256 or img.h ~= 256 then error("height: elevation tile is not 256 x 256") end
  local h, px, ch = {}, img.px, img.ch
  for i = 0, 256 * 256 - 1 do
    local o = i * ch
    h[i] = px[o + 1] * 256 + px[o + 2] + px[o + 3] / 256 - 32768
  end
  self.tiles[key(x, y)] = h
end

-- height of one global pixel (integer pixel coordinates)
local function pixel(self, ix, iy)
  local tx, ty = floor(ix / 256), floor(iy / 256)
  local t = self.tiles[tx * 65536 + ty]
  if not t then return nil end
  return t[(iy - ty * 256) * 256 + (ix - tx * 256)]
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

local OFF = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } }
function M:min_around(gx, gy, r)
  local m
  for i = 1, #OFF do
    local h = self:at(gx + OFF[i][1] * r, gy + OFF[i][2] * r)
    if h and (not m or h < m) then m = h end
  end
  return m
end

-- zoom-14 tiles covering an area of global units, plus a margin of two pixels for the bilinear filter
function M.need(gx0, gy0, gx1, gy1, margin)
  margin = margin or 2 * PX
  local out = {}
  local T = 256 * PX                                  -- global units per zoom-14 tile (65536)
  for x = floor((gx0 - margin) / T), floor((gx1 + margin) / T) do
    for y = floor((gy0 - margin) / T), floor((gy1 + margin) / T) do out[#out + 1] = { x, y } end
  end
  return out
end

return M
