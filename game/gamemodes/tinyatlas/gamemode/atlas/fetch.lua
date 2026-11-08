-- Map data sources with an on-disk cache. Shared by every game; the game supplies a platform table:
--
--   P.http_get(url, on_ok(body), on_err(message))     asynchronous download
--   P.read(path) -> string or nil                     cache read (binary)
--   P.write(path, data)                               cache write (binary, creates folders)
--   P.time() -> seconds                               wall clock (for cache age)
--
--   local F = fetch.new(P)
--   F:get("omt", z, x, y, on_ok(bytes), on_err(msg))  vector tile (raw protobuf, un-gzipped)
--   F:get("terrarium", z, x, y, ...)                  elevation PNG
local inflate = ATLAS_REQUIRE("inflate")

local M = {}

M.SOURCES = {
  -- OpenMapTiles-schema vector tiles from OpenFreeMap; the planet version comes from its TileJSON
  omt = { tilejson = "https://tiles.openfreemap.org/planet", maxzoom = 14, ext = "dat" },
  -- Terrarium elevation PNGs (Mapzen / AWS open data); 256 px, up to zoom 15
  terrarium = { url = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png", maxzoom = 15, ext = "dat" },
}

local TILEJSON_MAX_AGE = 7 * 24 * 3600

function M.new(P, root)
  local F = { P = P, root = root or "tinyatlas/cache", waiting = {}, templates = {}, stats = { hits = 0, downloads = 0, bytes = 0 } }
  return setmetatable(F, { __index = M })
end

function M:path(kind, z, x, y)
  return string.format("%s/%s/%d/%d_%d.%s", self.root, kind, z, x, y, M.SOURCES[kind].ext)
end

-- resolve a source's URL template (OpenFreeMap needs its current planet version from the TileJSON)
function M:template(kind, cb, err)
  local src = M.SOURCES[kind]
  if src.url then return cb(src.url) end
  if self.templates[kind] then return cb(self.templates[kind]) end
  local cpath = string.format("%s/%s/tilejson.txt", self.root, kind)
  local cached = self.P.read(cpath)
  if cached then
    local t, url = cached:match("^(%d+)\n(.+)$")
    if t and self.P.time() - tonumber(t) < TILEJSON_MAX_AGE then
      self.templates[kind] = url
      return cb(url)
    end
  end
  self.P.http_get(src.tilejson, function(body)
    body = inflate.auto(body)
    local url = body:match('"tiles"%s*:%s*%[%s*"([^"]+)"')
    if not url then return err("no tile URL in " .. src.tilejson) end
    self.templates[kind] = url
    self.P.write(cpath, string.format("%d\n%s", math.floor(self.P.time()), url))
    cb(url)
  end, function(e)
    if cached then                                -- offline: an old template still names valid tiles
      local url = cached:match("^%d+\n(.+)$")
      if url then self.templates[kind] = url; return cb(url) end
    end
    err(e)
  end)
end

function M:get(kind, z, x, y, ok, err)
  local path = self:path(kind, z, x, y)
  local data = self.P.read(path)
  if data then
    self.stats.hits = self.stats.hits + 1
    return ok(data)
  end
  local key = path
  if self.waiting[key] then                       -- already downloading: just add the callbacks
    table.insert(self.waiting[key], { ok, err })
    return
  end
  self.waiting[key] = { { ok, err } }
  local function finish(body, e)
    local list = self.waiting[key]
    self.waiting[key] = nil
    for _, cb in ipairs(list) do
      if body then cb[1](body) else cb[2](e) end
    end
  end
  self:template(kind, function(tmpl)
    local url = tmpl:gsub("{z}", z):gsub("{x}", x):gsub("{y}", y)
    self.P.http_get(url, function(body)
      local okk, plain = pcall(inflate.auto, body)
      if not okk then return finish(nil, "bad gzip from " .. url .. ": " .. tostring(plain)) end
      self.stats.downloads = self.stats.downloads + 1
      self.stats.bytes = self.stats.bytes + #plain
      self.P.write(path, plain)
      finish(plain)
    end, function(e) finish(nil, url .. ": " .. tostring(e)) end)
  end, function(e) finish(nil, e) end)
end

-- tile numbers of a latitude / longitude at zoom z, plus the position inside the tile (0..1)
function M.tile_of(lat, lon, z)
  local n = 2 ^ z
  local fx = (lon + 180) / 360 * n
  local lr = math.rad(lat)
  local fy = (1 - math.log(math.tan(lr) + 1 / math.cos(lr)) / math.pi) / 2 * n
  return math.floor(fx), math.floor(fy), fx % 1, fy % 1
end

function M.lat_of(y, z)
  return math.deg(math.atan(math.sinh(math.pi * (1 - 2 * y / 2 ^ z))))
end

return M
