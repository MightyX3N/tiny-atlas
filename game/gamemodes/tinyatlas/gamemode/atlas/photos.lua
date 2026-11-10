-- Aerial photos for the ground: which source covers a tile, its URL, and getting it (cached like the map data).
-- Shared by every game; the game turns the image bytes (JPEG) into a texture.
--
--   photos.get(F, z, x, y, ok(photo), fail(msg))
--     photo = { bytes = JPEG, source = id, credit = text, z, x, y, u0, v0, u1, v1 }
--     the image covers tile z/x/y from (u0, v0) to (u1, v1) of the image (0..1): a coarser source (Sentinel-2 stops
--     at zoom 14) gives its parent tile and the part of it this tile is
-- Regional sources come first where their box holds the tile; one that has nothing there (an error, or a blank or
-- tiny image) hands over to the next, down to Sentinel-2.
local S = ATLAS_REQUIRE("photo_sources")
local floor = math.floor

local M = {}
M.SIZE = 512                    -- pixels asked of WMS / export services
M.MIN_BYTES = 2000              -- a JPEG smaller than this is a blank tile (outside a service's area in its box)

local WORLD = 20037508.342789244
local function lat_of(y, z) return math.deg(math.atan(math.sinh(math.pi * (1 - 2 * y / 2 ^ z)))) end
local function lon_of(x, z) return x / 2 ^ z * 360 - 180 end

local function url_for(src, z, x, y)
  local n = 2 ^ z
  local u = src.url
  u = u:gsub("{z}", tostring(z)):gsub("{x}", tostring(x)):gsub("{y}", tostring(y)):gsub("{ty}", tostring(n - 1 - y))
  if u:find("{bbox", 1, true) or u:find("{size}", 1, true) then
    local s = 2 * WORLD / n
    local x0, y1 = -WORLD + x * s, WORLD - y * s
    local bbox = string.format("%.3f,%.3f,%.3f,%.3f", x0, y1 - s, x0 + s, y1)
    local b4326 = string.format("%.7f,%.7f,%.7f,%.7f", lat_of(y + 1, z), lon_of(x, z), lat_of(y, z), lon_of(x + 1, z))
    u = u:gsub("{bbox4326}", b4326):gsub("{bbox}", bbox):gsub("{size}", tostring(M.SIZE))
  end
  return u
end
M.url_for = url_for

-- the sources to try for tile z/x/y, best first
function M.chain(z, x, y)
  local lat, lon = lat_of(y + 0.5, z), lon_of(x + 0.5, z)
  local out = {}
  for _, s in ipairs(S.regional) do
    local b = s.box
    if lat >= b[1] and lon >= b[2] and lat <= b[3] and lon <= b[4] then out[#out + 1] = s end
  end
  for _, s in ipairs(S.global) do out[#out + 1] = s end
  return out
end

function M.get(F, z, x, y, ok, fail)
  local list = M.chain(z, x, y)
  local i = 0
  local function try()
    i = i + 1
    local s = list[i]
    if not s then return fail("no photo for " .. z .. "/" .. x .. "/" .. y) end
    -- a coarser source: its tile that holds this one
    local sz, sx, sy = z, x, y
    if s.maxzoom and z > s.maxzoom then
      local d = z - s.maxzoom
      sz, sx, sy = s.maxzoom, floor(x / 2 ^ d), floor(y / 2 ^ d)
    end
    F:get_url("photo/" .. s.id, sz, sx, sy, url_for(s, sz, sx, sy), function(bytes)
      if #bytes < M.MIN_BYTES or not (bytes:sub(1, 2) == "\255\216" or bytes:sub(1, 4) == "\137PNG") then
        return try()
      end
      local k = 2 ^ (z - sz)
      local u0, v0 = (x - sx * k) / k, (y - sy * k) / k
      ok({ bytes = bytes, source = s.id, credit = s.credit, z = sz, x = sx, y = sy, u0 = u0, v0 = v0, u1 = u0 + 1 / k, v1 = v0 + 1 / k })
    end, function() try() end)
  end
  try()
end

-- every credit line for the sources used so far (for the credits screen)
function M.credits(used)
  local out = {}
  for _, s in ipairs(S.regional) do if used[s.id] then out[#out + 1] = s.credit end end
  for _, s in ipairs(S.global) do if used[s.id] then out[#out + 1] = s.credit end end
  return out
end

return M
