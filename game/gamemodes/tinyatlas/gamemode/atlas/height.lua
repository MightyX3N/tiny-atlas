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

-- keep one tile; bytes are a WebP (Mapterhorn) or PNG (AWS Terrarium) file. Returns the source name.
function M:add(x, y, bytes)
  local h = {}
  local src
  if bytes:sub(1, 4) == "RIFF" then
    local img = webp.decode(bytes)
    if img.w ~= N or img.h ~= N then error("height: WebP elevation tile is not 512 x 512") end
    local R, G, B = img.R, img.G, img.B
    for i = 0, N * N - 1 do h[i] = R[i] * 256 + G[i] + B[i] / 256 - 32768 end
    src = "mapterhorn"
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
