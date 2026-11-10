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
  -- Mapterhorn elevation: Terrarium-encoded lossless WebP, 512 px; high-resolution areas only above zoom 12
  mapterhorn = { url = "https://tiles.mapterhorn.com/{z}/{x}/{y}.webp", maxzoom = 17, ext = "dat" },
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

-- any tile by URL, cached under <root>/<kind>/<z>/<x>_<y>.dat (photos, land cover). A failure is remembered for the
-- session (and a 404 on disk, as an empty file), so a tile a service does not have is not asked for again.
function M:get_url(kind, z, x, y, url, ok, err)
  local path = string.format("%s/%s/%d/%d_%d.dat", self.root, kind, z, x, y)
  local data = self.P.read(path)
  if data then
    if #data == 0 then return err("not available (cached)") end
    self.stats.hits = self.stats.hits + 1
    return ok(data)
  end
  self.failed = self.failed or {}
  if self.failed[path] then return err(self.failed[path]) end
  if self.waiting[path] then table.insert(self.waiting[path], { ok, err }); return end
  self.waiting[path] = { { ok, err } }
  local function finish(body, e)
    local list = self.waiting[path]
    self.waiting[path] = nil
    for _, cb in ipairs(list) do if body then cb[1](body) else cb[2](e) end end
  end
  self.P.http_get(url, function(body)
    self.stats.downloads = self.stats.downloads + 1
    self.stats.bytes = self.stats.bytes + #body
    self.P.write(path, body)
    finish(body)
  end, function(e)
    self.failed[path] = tostring(e)
    if tostring(e):match("HTTP 404") or tostring(e):match("HTTP 400") then self.P.write(path, "") end
    finish(nil, url .. ": " .. tostring(e))
  end)
end

-- ---- parts of big files (HTTP range requests), cached on disk in blocks: Overture's and Layercake's Parquet ----
M.BLOCK = 262144
-- bytes first .. first + len - 1 (0-based) of the file at url; dir: its cache folder (under root)
-- (tick: called between cached blocks read from disk, inside a coroutine)
function M:get_range(url, dir, first, len, ok, err, tick)
  local B = M.BLOCK
  local b0, b1 = math.floor(first / B), math.floor((first + len - 1) / B)
  local blocks, missing = {}, {}
  for b = b0, b1 do
    if tick and (b - b0) % 4 == 3 then tick() end
    local d = self.P.read(string.format("%s/%s/%d.blk", self.root, dir, b))
    if d then blocks[b] = d else missing[#missing + 1] = b end
  end
  local function done()
    local parts = {}
    for b = b0, b1 do parts[#parts + 1] = blocks[b] end
    local all = table.concat(parts)
    local off = first - b0 * B
    ok(all:sub(off + 1, off + len))
  end
  if #missing == 0 then self.stats.hits = self.stats.hits + 1; return done() end
  -- runs of missing blocks, one request each
  local runs = {}
  for _, b in ipairs(missing) do
    local r = runs[#runs]
    if r and r[2] == b - 1 then r[2] = b else runs[#runs + 1] = { b, b } end
  end
  local left, failed = #runs, nil
  for _, r in ipairs(runs) do
    local a = r[1] * B
    local z = (r[2] + 1) * B - 1
    local key = url .. "#" .. r[1] .. "-" .. r[2]
    local function finish(body, e)
      local list = self.waiting[key]
      self.waiting[key] = nil
      for _, cb in ipairs(list) do if body then cb[1](body) else cb[2](e) end end
    end
    local function got(body)
      -- the last block may be short (the file's end)
      for b = r[1], r[2] do
        local s = body:sub((b - r[1]) * B + 1, (b - r[1] + 1) * B)
        if #s > 0 then
          blocks[b] = s
          self.P.write(string.format("%s/%s/%d.blk", self.root, dir, b), s)
        else blocks[b] = "" end
      end
      left = left - 1
      if left == 0 then if failed then err(failed) else done() end end
    end
    local function bad(e)
      failed = failed or e
      left = left - 1
      if left == 0 then err(failed) end
    end
    if self.waiting[key] then table.insert(self.waiting[key], { got, bad })
    else
      self.waiting[key] = { { got, bad } }
      self.P.http_get(url, function(body)
        self.stats.downloads = self.stats.downloads + 1
        self.stats.bytes = self.stats.bytes + #body
        finish(body)
      end, function(e) finish(nil, url .. ": " .. tostring(e)) end, string.format("bytes=%d-%d", a, z))
    end
  end
end

-- the last n bytes of the file at url (a Parquet footer), cached as <dir>/tail_<n>.blk
function M:get_tail(url, dir, n, ok, err)
  local path = string.format("%s/%s/tail_%d.blk", self.root, dir, n)
  local d = self.P.read(path)
  if d then return ok(d) end
  local key = url .. "#tail" .. n
  if self.waiting[key] then table.insert(self.waiting[key], { ok, err }); return end
  self.waiting[key] = { { ok, err } }
  self.P.http_get(url, function(body)
    self.stats.downloads = self.stats.downloads + 1
    self.stats.bytes = self.stats.bytes + #body
    self.P.write(path, body)
    local list = self.waiting[key]; self.waiting[key] = nil
    for _, cb in ipairs(list) do cb[1](body) end
  end, function(e)
    local list = self.waiting[key]; self.waiting[key] = nil
    for _, cb in ipairs(list) do cb[2](url .. ": " .. tostring(e)) end
  end, "bytes=-" .. n)
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
