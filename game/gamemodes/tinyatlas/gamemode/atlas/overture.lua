-- Overture Maps (overturemaps.org) map data: roads, buildings, water, land use for a box, read straight from its
-- GeoParquet files on S3 (only the parts that cover the box: the footer, then the bbox columns of the row groups
-- whose statistics touch it, then the wanted columns of the row groups that hold a match), as BeamNG.Earth does
-- (server/overture.py). Shared by every game. Data licences: ODbL (OpenStreetMap), CDLA / CC BY (see CREDIT).
--
--   local O = overture.new(fetch)
--   O:query(layer, lon0, lat0, lon1, lat1, columns, tick) -> rows      inside a coroutine (it yields while downloading)
--   layer: "buildings/building", "buildings/building_part", "transportation/segment", "base/water", "base/land_use"
--   columns: leaf paths ("height", "names.primary", "sources.list.element.record_id"); "geometry" comes decoded
--   rows[i] = { [column] = value, geometry = wkb.decode(...), bbox = { x0, y0, x1, y1 } }
local parquet = ATLAS_REQUIRE("parquet")
local wkb = ATLAS_REQUIRE("wkb")
local index = ATLAS_REQUIRE("overture_index")
local floor, min, max = math.floor, math.min, math.max

local M = {}
M.__index = M
M.RELEASE = index.RELEASE
M.CREDIT = "Overture Maps Foundation, © OpenStreetMap contributors (ODbL), Microsoft, Google, Esri (see CREDITS)"
M.TAIL = 1048576            -- bytes read from a file's end for its footer at first (most footers are 0.5-2 MB)
M.MERGE_GAP = 65536         -- column chunks closer than this are fetched in one request
M.META_KEPT = 24            -- parsed footers kept in memory

function M.new(fetch)
  return setmetatable({ F = fetch, meta = {}, meta_order = {} }, M)
end

-- wait for start(ok, err) to call back: yields (the game's job runner resumes) until then
local function await(start)
  local done, res, er = false, nil, nil
  start(function(r) done, res = true, r end, function(e) done, er = true, e end)
  while not done do coroutine.yield() end
  if er then error(er, 0) end
  return res
end
-- several at once
local function await_all(starts, tick)
  local left, res, er = #starts, {}, nil
  for i, st in ipairs(starts) do
    st(function(r) res[i] = r; left = left - 1 end, function(e) er = er or e; left = left - 1 end)
    if tick then tick() end
  end
  while left > 0 do coroutine.yield() end
  if er then error(er, 0) end
  return res
end
M.await, M.await_all = await, await_all

function M.url(layer, name)
  local theme, typ = layer:match("^(.-)/(.*)$")
  return index.BASE .. index.RELEASE .. "/theme=" .. theme .. "/type=" .. typ .. "/" .. name
end
local function cache_dir(layer, name)
  return "overture/" .. index.RELEASE .. "/" .. layer .. "/" .. name:sub(1, 10)
end

-- Overture publishes a new release about monthly and removes old ones after some months: once a day the newest is
-- looked up (stac.overturemaps.org) and, when it is not the shipped one, its file list is made from its STAC
-- collections (each file's box) and the bucket's listing (the file names, in the same order); kept on disk.
M.STAC = "https://stac.overturemaps.org"
local function http(self, url)
  return await(function(ok, err) self.F.P.http_get(url, ok, err) end)
end
function M:update_index(tick)
  if self.index_checked then return end
  self.index_checked = true
  local P = self.F.P
  local root = self.F.root
  local day = os.date("!%Y-%m-%d")
  local note = P.read(root .. "/overture/latest.txt")
  local latest = note and note:match("^" .. day .. " (%S+)")
  if not latest then
    local ok, body = pcall(http, self, M.STAC .. "/catalog.json")
    latest = ok and body:match('"latest"%s*:%s*"([%w%.%-]+)"')
    if not latest then return end
    P.write(root .. "/overture/latest.txt", day .. " " .. latest)
  end
  if latest == index.RELEASE then return end
  local path = root .. "/overture/index_" .. latest .. ".lua"
  local saved = P.read(path)
  if saved then
    local f = (loadstring or load or function(c) local r = CompileString(c, "tinyatlas", false); return type(r) == "function" and r or nil end)(saved)
    if f then
      if setfenv then setfenv(f, {}) end
      local ok, t = pcall(f)
      if ok and type(t) == "table" and t.layers then index.RELEASE = latest; index.layers = t.layers; return end
    end
  end
  local layers = {}
  for layer in pairs(index.layers) do
    local theme, typ = layer:match("^(.-)/(.*)$")
    local ok, err = pcall(function()
      local coll = http(self, M.STAC .. "/" .. latest .. "/" .. theme .. "/" .. typ .. "/collection.json")
      local bbs = {}
      local spatial = coll:match('"spatial"%s*:%s*{%s*"bbox"%s*:%s*(%b[])')
      for box in spatial:sub(2, -2):gmatch("%b[]") do
        local v = {}
        for n in box:gmatch("[-%d%.eE+]+") do v[#v + 1] = tonumber(n) end
        bbs[#bbs + 1] = v
      end
      local names = {}
      local token
      repeat
        local url = index.BASE:gsub("/release/$", "/") .. "?list-type=2&prefix=release/" .. latest .. "/theme=" .. theme ..
          "/type=" .. typ .. "/" .. (token and ("&continuation-token=" .. token:gsub("[^%w]", function(c) return string.format("%%%02X", c:byte()) end)) or "")
        local xml = http(self, url)
        for key in xml:gmatch("<Key>([^<]+)</Key>") do
          local name = key:match("([^/]+%.parquet)$")
          if name then names[#names + 1] = name end
        end
        token = xml:find("<IsTruncated>true</IsTruncated>") and xml:match("<NextContinuationToken>([^<]+)</NextContinuationToken>")
      until not token
      table.sort(names)
      -- the collection's first box is the whole layer's, then one per file (one file: only the whole one)
      local first = #bbs == #names + 1 and 2 or 1
      if #bbs - first + 1 ~= #names then error(#names .. " files but " .. #bbs .. " boxes") end
      local list = {}
      for i, name in ipairs(names) do
        local b = bbs[first + i - 1]
        list[i] = { name, b[1], b[2], b[3], b[4], 0 }
      end
      layers[layer] = list
    end)
    if not ok then return end         -- (the shipped index stays)
    if tick then tick() end
  end
  local out = { "return { layers = {" }
  for layer, list in pairs(layers) do
    out[#out + 1] = string.format("[%q] = {", layer)
    for _, f in ipairs(list) do out[#out + 1] = string.format("{%q,%.6f,%.6f,%.6f,%.6f,0},", f[1], f[2], f[3], f[4], f[5]) end
    out[#out + 1] = "},"
  end
  out[#out + 1] = "} }"
  P.write(path, table.concat(out, "\n"))
  index.RELEASE = latest
  index.layers = layers
  M.RELEASE = latest
end

-- the files of a layer whose box touches lon0..lon1, lat0..lat1
function M.files(layer, lon0, lat0, lon1, lat1)
  local out = {}
  for _, f in ipairs(index.layers[layer] or {}) do
    if f[2] <= lon1 and f[4] >= lon0 and f[3] <= lat1 and f[5] >= lat0 then out[#out + 1] = f end
  end
  return out
end

-- a file's parsed footer (src = { url, dir })
function M:footer(src, tick)
  local key = src.url
  local m = self.meta[key]
  if m then return m end
  local url, dir = src.url, src.dir
  local n = src.tail or M.TAIL
  local tail = await(function(ok, err) self.F:get_tail(url, dir, n, ok, err) end)
  local meta, need = parquet.footer(tail, tick)
  if not meta then
    n = need + 4096
    tail = await(function(ok, err) self.F:get_tail(url, dir, n, ok, err) end)
    meta = parquet.footer(tail, tick)
  end
  self.meta[key] = meta
  local order = self.meta_order
  order[#order + 1] = key
  if #order > M.META_KEPT then self.meta[table.remove(order, 1)] = nil end
  return meta
end

-- download the column chunks { { rg, leaf }, ... } of one file: their bytes, in the same order
local function fetch_chunks(self, src, list, tick)
  local url, dir = src.url, src.dir
  local ranges = {}
  for i, c in ipairs(list) do
    local a, len = parquet.chunk_range(c[1], c[2])
    ranges[i] = { a, a + len, i }
  end
  table.sort(ranges, function(p, q) return p[1] < q[1] end)
  local merged = {}
  for _, r in ipairs(ranges) do
    local m = merged[#merged]
    if m and r[1] - m[2] <= M.MERGE_GAP then
      if r[2] > m[2] then m[2] = r[2] end
      m.items[#m.items + 1] = r
    else
      merged[#merged + 1] = { r[1], r[2], items = { r } }
    end
  end
  local starts = {}
  for k, m in ipairs(merged) do
    starts[k] = function(ok, err) self.F:get_range(url, dir, m[1], m[2] - m[1], ok, err, tick) end
  end
  local bodies = await_all(starts, tick)
  local out = {}
  for k, m in ipairs(merged) do
    for _, r in ipairs(m.items) do out[r[3]] = bodies[k]:sub(r[1] - m[1] + 1, r[2] - m[1]) end
  end
  return out
end

local BOX = { "bbox.xmin", "bbox.ymin", "bbox.xmax", "bbox.ymax" }

function M:query(layer, lon0, lat0, lon1, lat1, columns, tick)
  self:update_index(tick)
  local rows = {}
  for _, f in ipairs(M.files(layer, lon0, lat0, lon1, lat1)) do
    self:query_file({ url = M.url(layer, f[1]), dir = cache_dir(layer, f[1]) }, lon0, lat0, lon1, lat1, columns, tick, rows)
  end
  return rows
end

-- the rows of one GeoParquet file (src = { url, dir [, tail] }) with a bbox struct column, appended to rows
function M:query_file(src, lon0, lat0, lon1, lat1, columns, tick, rows)
  tick = tick or function() end
  rows = rows or {}
  do
    local meta = self:footer(src, tick)
    local layer = src.url
    tick()
    local L = meta.leaves
    for _, c in ipairs(BOX) do if not L[c] then error("overture: " .. layer .. " has no " .. c) end end
    -- row groups whose bbox statistics touch the box
    local cand = {}
    for _, rg in ipairs(meta.row_groups) do
      local x0 = parquet.stats(rg, L["bbox.xmin"])
      local _, x1 = parquet.stats(rg, L["bbox.xmax"])
      local y0 = parquet.stats(rg, L["bbox.ymin"])
      local _, y1 = parquet.stats(rg, L["bbox.ymax"])
      if not (x0 and x1 and y0 and y1) or (x0 <= lon1 and x1 >= lon0 and y0 <= lat1 and y1 >= lat0) then
        cand[#cand + 1] = rg
      end
    end
    -- their bbox columns: which rows are in the box
    local list = {}
    for _, rg in ipairs(cand) do for _, c in ipairs(BOX) do list[#list + 1] = { rg, L[c] } end end
    local got = #list > 0 and fetch_chunks(self, src, list, tick) or {}
    local hits = {}
    for i, rg in ipairs(cand) do
      local b = {}
      for k = 1, 4 do b[k] = parquet.read_column(got[(i - 1) * 4 + k], rg, L[BOX[k]], { tick = tick }) ; tick() end
      local h = {}
      for r = 1, b[1].n do
        local x0, y0, x1, y1 = b[1][r], b[2][r], b[3][r], b[4][r]
        if x0 and x0 <= lon1 and x1 >= lon0 and y0 <= lat1 and y1 >= lat0 then h[#h + 1] = { r, x0, y0, x1, y1 } end
      end
      if #h > 0 then hits[#hits + 1] = { rg = rg, rows = h } end
    end
    -- the wanted columns of the row groups with hits
    if #hits > 0 then
      local want = {}
      for _, c in ipairs(columns) do if L[c] then want[#want + 1] = c end end
      list = {}
      for _, hg in ipairs(hits) do for _, c in ipairs(want) do list[#list + 1] = { hg.rg, L[c] } end end
      got = fetch_chunks(self, src, list, tick)
      local k = 0
      for _, hg in ipairs(hits) do
        local cols = {}
        for _, c in ipairs(want) do
          k = k + 1
          cols[c] = parquet.read_column(got[k], hg.rg, L[c], { raw = (c == "geometry"), tick = tick })
          tick()
        end
        for hi, h in ipairs(hg.rows) do
          if hi % 32 == 0 then tick() end
          local r = h[1]
          local row = { bbox = { h[2], h[3], h[4], h[5] } }
          for _, c in ipairs(want) do
            local v = cols[c][r]
            if c == "geometry" then
              if v then row.geometry = wkb.decode(v) end
            else row[c] = v end
          end
          rows[#rows + 1] = row
        end
        tick()
      end
    end
  end
  return rows
end

return M
