-- The streamed world: which cells to build around the rider, getting their map and height data, building them
-- and handing triangle lists to the game. Shared by every game; the game supplies:
--
--   opts.fetch        fetch.lua instance (downloads + cache)
--   opts.lat, lon     the world's origin (route start): positions are metres east / north of it
--   opts.tile_metres  metres per ground texture (pack)
--   opts.unit         game units per metre
--   opts.make(groups, cell) -> handle    turn mesh.lua groups into the game's meshes
--   opts.free(handle)                   release them
--   opts.log(msg)                       status lines
--   opts.tex_metres   metres per ground texture, per texture (pack.tex_metres; others use tile_metres)
--   opts.buildings    true: buildings from the map (bne_buildings.lua, BeamNG.Earth's rules)
--   opts.style        "flat" (low-poly colours, the default look) or "textured" (the pack's ground textures)
--   opts.trees        the pack's 3D tree models (trees.lua places them by the ground's surfaces); nil: no trees
--
--   W:work(tick)        one piece of work (call from a build job coroutine; tick yields when time is up).
--                       Returns false when there is nothing to do.
--   W:focus(x, y, fx, fy)   where the rider is and which way they look; picks the cells to build / drop
--   W:height_at(x, y) -> z, surface   on the built ground (nil if that cell is not built)
--   W:set_route(R)      the route being ridden: its points get their heights as the cells under them are built
--   W:route_ready_ahead(s) -> metres of route from s that have heights
--   (the route is put onto the map's roads and paths as the world is built ahead: match.lua)
local fetch = ATLAS_REQUIRE("fetch")
local overture = ATLAS_REQUIRE("overture")
local ov_layers = ATLAS_REQUIRE("ov_layers")
local mvt = ATLAS_REQUIRE("mvt")
local cell = ATLAS_REQUIRE("cell")
local height = ATLAS_REQUIRE("height")
local ground = ATLAS_REQUIRE("ground")
local mesh = ATLAS_REQUIRE("mesh")
local buildings = ATLAS_REQUIRE("buildings")
local match = ATLAS_REQUIRE("match")
local trees = ATLAS_REQUIRE("trees")
local floor, sqrt, max, min, cos, rad, abs = math.floor, math.sqrt, math.max, math.min, math.cos, math.rad, math.abs

local M = {}
M.FAR_TILES = 1               -- distant ground: zoom-14 tiles this many around the rider's tile
M.BUILD_RADIUS = 650          -- metres: cells closer than this get built
M.DROP_RADIUS = 900           -- metres: cells farther than this are dropped
M.AHEAD = 1200                -- metres of route ahead that are built early
M.KEEP_TILES = 8              -- decoded vector tiles kept
M.KEEP_HEIGHTS = 25           -- decoded elevation tiles kept
local fill_route                                 -- defined below, used by work
local CELL = 8192             -- global units per cell (zoom 17)
local TILE = 65536            -- global units per zoom-14 tile
local WORLD = 2 ^ 14 * TILE

function M.new(o)
  local W = setmetatable({ o = o, F = o.fetch, cells = {}, tiles = {}, htiles = {}, H = height.new(), clock = 0, pins = {}, pinsY = {},
    queue = {}, far = {}, extra = {}, stats = { built = 0, failed = 0, ms = 0, dropped = 0 } }, { __index = M })
  W.GX0, W.GY0 = W:global_of(o.lat, o.lon)
  W.k = 40075016.686 * cos(rad(o.lat)) / WORLD      -- metres per global unit at the origin
  W.log = o.log or print
  if o.trees then mesh.add_textures(trees.textures(o.trees)) end
  return W
end

function M:global_of(lat, lon)
  local fx = (lon + 180) / 360
  local lr = rad(lat)
  local fy = (1 - math.log(math.tan(lr) + 1 / cos(lr)) / math.pi) / 2
  return fx * WORLD, fy * WORLD
end
function M:metres_of(gx, gy) return (gx - self.GX0) * self.k, -(gy - self.GY0) * self.k end
function M:global_of_metres(x, y) return self.GX0 + x / self.k, self.GY0 - y / self.k end
function M:tag_of(surf) return mesh.TEXTURE[surf or "road"] or "asphalt" end
local function ckey(cx, cy) return cx * 1048576 + cy end
local function tkey(x, y) return x * 65536 + y end

-- ---- data: vector tiles and elevation tiles, downloaded (or read from the cache) and decoded on demand ----
local function request_omt(self, x, y)
  local key = tkey(x, y)
  local t = self.tiles[key]
  if t then return t end
  t = { x = x, y = y, state = "loading" }
  self.tiles[key] = t
  self.F:get("omt", 14, x, y, function(bytes) t.bytes = bytes; t.state = "bytes" end,
    function(e) t.state = "failed"; t.err = e; self.log("FAILED: map tile 14/" .. x .. "/" .. y .. ": " .. tostring(e)) end)
  return t
end
local function request_height(self, x, y)
  local key = tkey(x, y)
  local t = self.htiles[key]
  if t then return t end
  t = { x = x, y = y, state = "loading" }
  self.htiles[key] = t
  -- Mapterhorn has high-resolution heights in many countries; elsewhere it has no zoom-14 tile: use Terrarium
  self.F:get("mapterhorn", 14, x, y, function(bytes) t.bytes = bytes; t.state = "bytes" end, function()
    self.F:get("terrarium", 14, x, y, function(bytes) t.bytes = bytes; t.state = "bytes" end,
      function(e) t.state = "failed"; self.log("FAILED: elevation tile 14/" .. x .. "/" .. y .. ": " .. tostring(e)) end)
  end)
  return t
end

-- make sure the tile and the elevation around it are decoded; yields while downloads are running.
-- Returns the decoded layers, or nil if the map tile could not be had.
local function ensure(self, tx, ty, tick)
  local t = request_omt(self, tx, ty)
  local hs = {}
  for dx = -1, 1 do for dy = -1, 1 do hs[#hs + 1] = request_height(self, tx + dx, ty + dy) end end
  while true do
    local waiting = t.state == "loading"
    for _, h in ipairs(hs) do if h.state == "loading" then waiting = true end end
    if not waiting then break end
    coroutine.yield()
  end
  self.clock = self.clock + 1
  for _, h in ipairs(hs) do
    if h.state == "bytes" then
      local ok, err = pcall(function() h.src = self.H:add(h.x, h.y, h.bytes, tick) end)
      h.bytes = nil
      if ok then h.state = "ready" else h.state = "failed"; self.log("FAILED: elevation tile " .. h.x .. "/" .. h.y .. ": " .. tostring(err)) end
    end
    h.used = self.clock
  end
  if t.state == "bytes" then
    local ok, layers = pcall(mvt.decode, t.bytes, tick)
    if ok then t.layers = layers; t.state = "ready" else t.state = "failed"; self.log("FAILED: map tile " .. tx .. "/" .. ty .. ": " .. tostring(layers)) end
    t.bytes = nil
  end
  -- roads, buildings, water and land use from Overture Maps (with OpenStreetMap's road tags), as BeamNG.Earth reads
  -- them; the vector tile keeps the land cover, parks and airports
  if self.o.overture ~= false and not t.ov then
    t.ov = "loading"
    local path = ov_layers.cache_path(tx, ty)
    local cached = self.F.P.read(self.F.root .. "/" .. path)
    local L = cached and ov_layers.deserialize(cached)
    if not L then
      self.OV = self.OV or overture.new(self.F)
      local ok, res = pcall(ov_layers.tile, self.OV, tx, ty, { tick = tick, log = function(m) self.log(m) end })
      if ok then
        L = res
        self.F.P.write(self.F.root .. "/" .. path, ov_layers.serialize(L, tick))
        local st = L.stats or {}
        self.log(string.format("map data (Overture) for tile %d/%d: %d buildings, %d roads and paths (%d street widths measured, %d with OpenStreetMap tags)",
          tx, ty, st.buildings or 0, st.roads or 0, st.measured or 0, st.osm_ways or 0))
        if not self.ov_credit then self.ov_credit = true; self.log("map data: " .. overture.CREDIT) end
      else
        self.log("FAILED: Overture map data for tile " .. tx .. "/" .. ty .. " (" .. tostring(res) .. "): using the vector tile's")
      end
    end
    if L then
      local merged = {}
      for k, v in pairs(t.layers or {}) do merged[k] = v end
      for _, k in ipairs({ "building", "building_part", "transportation", "water", "waterway", "ov_surface", "ov_tree", "ov_wood" }) do merged[k] = L[k] end
      merged.landuse = nil
      t.layers = merged
      t.state = "ready"
    end
    t.ov = L and "ready" or "failed"
  end
  -- paths added under the route where it leaves the mapped roads (match.lua)
  local ex = self.extra[tkey(tx, ty)]
  if ex and t.layers and (t.extra_n or 0) < #ex then
    local L = t.layers.transportation
    if not L then L = { extent = 4096, features = {} }; t.layers.transportation = L end
    for i = (t.extra_n or 0) + 1, #ex do L.features[#L.features + 1] = ex[i] end
    t.extra_n = #ex
  end
  t.used = self.clock
  -- forget the least recently used decoded data
  local function trim(list, keep, drop)
    local ready = {}
    for _, x in pairs(list) do if x.state == "ready" then ready[#ready + 1] = x end end
    if #ready <= keep then return end
    table.sort(ready, function(a, b) return a.used < b.used end)
    for i = 1, #ready - keep do drop(ready[i]) end
  end
  trim(self.tiles, M.KEEP_TILES, function(x) self.tiles[tkey(x.x, x.y)] = nil end)
  trim(self.htiles, M.KEEP_HEIGHTS, function(x) self.H:drop(x.x, x.y); self.htiles[tkey(x.x, x.y)] = nil end)
  return t.layers
end

-- a map tile's decoded layers (downloads it if needed; inside a build job)
function M:tile_layers(tx, ty, tick) return ensure(self, tx, ty, tick) end

-- The map around a point for a minimap: the roads, paths and water of the tiles already loaded, as lines in metres
-- from the world's origin. { { kind = "road" | "path" | "water" | "rail", pts = { x, y, x, y, ... } }, ... }
-- Made once per tile (kept with the tile); tiles not loaded yet give nothing.
local MAP_KIND = { motorway = "road", trunk = "road", primary = "road", secondary = "road", tertiary = "road",
  minor = "road", service = "road", track = "path", path = "path", rail = "rail", transit = "rail" }
function M:map_lines(x, y, radius)
  local gx, gy = self:global_of_metres(x, y)
  local r = radius / self.k
  local out = {}
  for tx = floor((gx - r) / TILE), floor((gx + r) / TILE) do
    for ty = floor((gy - r) / TILE), floor((gy + r) / TILE) do
      local t = self.tiles[tkey(tx, ty)]
      if t and t.layers then
        if not t.map then
          local lines = {}
          local scale = TILE / 4096
          local function add(L, kind_of)
            if not L then return end
            for _, f in ipairs(L.features) do
              local kind = kind_of(f)
              if kind and (f.type == 2 or kind == "water") then
                for _, part in ipairs(f.parts) do
                  local pts = {}
                  for i = 1, #part - 1, 2 do
                    local mx, my = self:metres_of(tx * TILE + part[i] * scale, ty * TILE + part[i + 1] * scale)
                    pts[#pts + 1] = mx; pts[#pts + 1] = my
                  end
                  if f.type == 3 and #pts >= 4 then pts[#pts + 1] = pts[1]; pts[#pts + 1] = pts[2] end
                  if #pts >= 4 then lines[#lines + 1] = { kind = kind, pts = pts } end
                end
              end
            end
          end
          add(t.layers.transportation, function(f)
            local p = f.props or {}
            if p.brunnel == "tunnel" then return nil end
            return MAP_KIND[p.class] or (p.class and "road")
          end)
          add(t.layers.waterway, function() return "water" end)
          add(t.layers.water, function() return "water" end)
          t.map = lines
        end
        for _, l in ipairs(t.map) do out[#out + 1] = l end
      end
    end
  end
  return out
end

-- a feature added to a map tile (tile units): kept for when the tile is decoded again; cells of that tile already
-- built where it lies are dropped so they get built again with it
function M:add_feature(tx, ty, f)
  local key = tkey(tx, ty)
  local ex = self.extra[key]
  if not ex then ex = {}; self.extra[key] = ex end
  ex[#ex + 1] = f
  local t = self.tiles[key]
  if t and t.layers then
    local L = t.layers.transportation
    if not L then L = { extent = 4096, features = {} }; t.layers.transportation = L end
    L.features[#L.features + 1] = f
    t.extra_n = #ex
  end
  local a0, b0, a1, b1 = 1e18, 1e18, -1e18, -1e18
  for _, part in ipairs(f.parts) do
    for k = 1, #part, 2 do
      a0, a1 = min(a0, part[k]), max(a1, part[k]); b0, b1 = min(b0, part[k + 1]), max(b1, part[k + 1])
    end
  end
  for ccx = floor((a0 - 8) / 512), floor((a1 + 8) / 512) do
    for ccy = floor((b0 - 8) / 512), floor((b1 + 8) / 512) do
      if ccx >= 0 and ccx < 8 and ccy >= 0 and ccy < 8 then
        local ck = ckey(tx * 8 + ccx, ty * 8 + ccy)
        local c = self.cells[ck]
        if c and c.state == "ready" then
          if c.handle then self.o.free(c.handle) end
          self:unpin(c)
          self.cells[ck] = nil
          self.stats.rebuilt = (self.stats.rebuilt or 0) + 1
        end
      end
    end
  end
end

-- build one cell's ground: r (cell.lua) and g (ground.lua); nil if the map tile is missing
function M:build_cell(cx, cy, tick)
  local tx, ty = floor(cx / 8), floor(cy / 8)
  local layers = ensure(self, tx, ty, tick)
  if not layers then return nil end
  local lat = fetch.lat_of(ty + 0.5, 14)
  local r = cell.build(layers, cx - tx * 8, cy - ty * 8, lat, { tick = tick, tx = tx, ty = ty })
  local g = ground.heights(r, self.H, cx * CELL, cy * CELL, { tick = tick, pin = function(gx, gy) return self:pin_at(gx, gy) end })
  return r, g, layers
end

-- a built cell's border height at a point: the point itself, or between the two nearest points of that cell's
-- border line (the two cells' borders do not always have their points in exactly the same places)
local PIN_GAP = 600            -- global units: farther apart than this, the points are not one border line
local function between(line, pos)
  local lo, hi
  for q, p in pairs(line) do
    if q < pos then if pos - q < PIN_GAP and (not lo or q > lo) then lo = q end
    elseif q > pos then if q - pos < PIN_GAP and (not hi or q < hi) then hi = q end end
  end
  if not lo or not hi then return nil end
  local a, b = line[lo], line[hi]
  local t = (pos - lo) / (hi - lo)
  return { land = a.land + (b.land - a.land) * t, water = a.water and b.water and a.water + (b.water - a.water) * t or nil }
end
function M:pin_at(gx, gy)
  local col = self.pins[gx]
  local p = col and col[gy]
  if p then return p end
  if col and gx % CELL == 0 then p = between(col, gy); if p then return p end end
  local row = self.pinsY[gy]
  if row and gy % CELL == 0 then return between(row, gx) end
end

-- the heights of a built cell's border points, for the neighbours built after it (ground.lua makes them match).
-- owner remembers the points so unpin can let them go when the cell is dropped.
function M:pin_cell(owner, cx, cy, r, g)
  local pins, X, Y, S = self.pins, r.X, r.Y, r.S
  local gx0, gy0 = cx * CELL, cy * CELL
  local list = {}
  for v = 1, #X do
    local x, y = X[v], Y[v]
    if (x == 0 or y == 0 or x == S or y == S) and g.land[v] then
      local gx, gy = gx0 + x, gy0 + y
      local col = pins[gx]
      if not col then col = {}; pins[gx] = col end
      local p = col[gy]
      if p then p.n = p.n + 1
      else
        p = { land = g.land[v], water = g.water[v], n = 1 }
        col[gy] = p
        local row = self.pinsY[gy]
        if not row then row = {}; self.pinsY[gy] = row end
        row[gx] = p
      end
      list[#list + 1] = gx; list[#list + 1] = gy
    end
  end
  owner.pins = list
end
function M:unpin(owner)
  local list, pins = owner.pins, self.pins
  if not list then return end
  for i = 1, #list, 2 do
    local col = pins[list[i]]
    local p = col and col[list[i + 1]]
    if p then
      p.n = p.n - 1
      if p.n <= 0 then
        local gx, gy = list[i], list[i + 1]
        col[gy] = nil; if next(col) == nil then pins[gx] = nil end
        local row = self.pinsY[gy]
        if row then row[gx] = nil; if next(row) == nil then self.pinsY[gy] = nil end end
      end
    end
  end
  owner.pins = nil
end


-- ---- which cells: around the rider, and along the route ahead ----
function M:focus(x, y, fx, fy)
  self.x, self.y, self.fx, self.fy = x, y, fx or 1, fy or 0
  local gx, gy = self:global_of_metres(x, y)
  local cm = CELL * self.k                          -- cell size in metres
  local want = {}
  local function add(cx, cy, pr)
    local key = ckey(cx, cy)
    if not want[key] or pr < want[key][3] then want[key] = { cx, cy, pr } end
  end
  local rc = math.ceil(M.BUILD_RADIUS / cm) + 1
  local ccx, ccy = floor(gx / CELL), floor(gy / CELL)
  for cy = ccy - rc, ccy + rc do
    for cx = ccx - rc, ccx + rc do
      local mx, my = self:metres_of((cx + 0.5) * CELL, (cy + 0.5) * CELL)
      local dx, dy = mx - x, my - y
      local d = sqrt(dx * dx + dy * dy)
      if d - cm * 0.71 < M.BUILD_RADIUS then
        local ahead = d > 0 and (dx * self.fx + dy * self.fy) / d or 1
        add(cx, cy, d * (1 - 0.4 * ahead))
      end
    end
  end
  local R = self.route
  if R and self.s then
    local k0 = max(1, floor(self.s / 2) + 1)
    local k1 = min(R.n, floor((self.s + M.AHEAD) / 2) + 1)
    for k = k0, k1, 10 do
      local cx, cy = floor(R.GX[k] / CELL), floor(R.GY[k] / CELL)
      local along = R.S[k] - self.s
      for dy = -1, 1 do for dx = -1, 1 do add(cx + dx, cy + dy, along * 0.5 + ((dx ~= 0 or dy ~= 0) and 60 or 0)) end end
    end
  end
  -- drop far cells that are not wanted
  for key, c in pairs(self.cells) do
    if not want[key] then
      local mx, my = self:metres_of((c.cx + 0.5) * CELL, (c.cy + 0.5) * CELL)
      if sqrt((mx - x) ^ 2 + (my - y) ^ 2) > M.DROP_RADIUS then
        if c.handle then self.o.free(c.handle) end
        self:unpin(c)
        self.cells[key] = nil
        self.stats.dropped = self.stats.dropped + 1
      end
    end
  end
  -- distant ground around the rider's tile
  local ttx, tty = floor(gx / TILE), floor(gy / TILE)
  local far_want = {}
  for dy = -M.FAR_TILES, M.FAR_TILES do
    for dx = -M.FAR_TILES, M.FAR_TILES do far_want[tkey(ttx + dx, tty + dy)] = { ttx + dx, tty + dy, abs(dx) + abs(dy) } end
  end
  for key, f in pairs(self.far) do
    if not far_want[key] then
      if f.handle then self.o.free(f.handle) end
      self.far[key] = nil
    end
  end
  local fq = {}
  for key, w in pairs(far_want) do if not self.far[key] then fq[#fq + 1] = w end end
  table.sort(fq, function(a, b) return a[3] < b[3] end)
  self.far_queue = fq
  local q = {}
  for key, w in pairs(want) do
    local c = self.cells[key]
    if not c then q[#q + 1] = w end
  end
  table.sort(q, function(a, b) return a[3] < b[3] end)
  self.queue = q
  self.wanted = want
end

-- cells near the rider that are not built yet (for the loading screen)
function M:missing_near(radius)
  local n, total = 0, 0
  for key, w in pairs(self.wanted or {}) do
    local mx, my = self:metres_of((w[1] + 0.5) * CELL, (w[2] + 0.5) * CELL)
    if sqrt((mx - self.x) ^ 2 + (my - self.y) ^ 2) < radius then
      total = total + 1
      local c = self.cells[key]
      if not c or c.state ~= "ready" and c.state ~= "failed" then n = n + 1 end
    end
  end
  return n, total
end

-- one tile of distant ground: its elevation only, as a coarse grid
local function build_far(self, tx, ty, tick)
  local key = tkey(tx, ty)
  local f = { tx = tx, ty = ty, state = "building" }
  self.far[key] = f
  local h = request_height(self, tx, ty)
  while h.state == "loading" do coroutine.yield() end
  if h.state == "bytes" then
    local ok, err = pcall(function() h.src = self.H:add(tx, ty, h.bytes, tick) end)
    h.bytes = nil
    h.state = ok and "ready" or "failed"
  end
  self.clock = self.clock + 1
  h.used = self.clock
  if self.far[key] ~= f then return end
  if h.state ~= "ready" then f.state = "failed"; return end
  f.ox, f.oy = self:metres_of(tx * TILE, ty * TILE)
  local groups = (self.o.style == "flat" and mesh.far_flat or mesh.far)(self.H, tx, ty, { k = self.k, ox = f.ox, oy = f.oy, tile_metres = self.o.far_metres or self.o.tile_metres,
    unit = self.o.unit, tick = tick })
  f.handle = self.o.make(groups, f)
  f.state = "ready"
end

function M:work(tick, clock)
  -- distant ground when nothing near is waiting (or only cells farther than 300 m)
  local fq = self.far_queue
  if fq and #fq > 0 and (not self.queue[1] or self.queue[1][3] > 300) then
    local w = table.remove(fq, 1)
    if not self.far[tkey(w[1], w[2])] then build_far(self, w[1], w[2], tick); return true end
  end
  local w = table.remove(self.queue, 1)
  while w and self.cells[ckey(w[1], w[2])] do w = table.remove(self.queue, 1) end
  if not w then
    if fq and #fq > 0 then return self:work(tick, clock) end
    return false
  end
  -- the route ahead goes onto the map's roads first (its paths off the map are part of the cells built next)
  if self.match then self.match:advance((self.s or 0) + M.AHEAD + 200, tick) end
  local cx, cy = w[1], w[2]
  local key = ckey(cx, cy)
  if self.cells[key] then return true end
  local c = { cx = cx, cy = cy, state = "building" }
  self.cells[key] = c
  local t0 = clock and clock()
  local ok, r, g, layers = pcall(self.build_cell, self, cx, cy, tick)
  if self.cells[key] ~= c then return true end     -- dropped while building
  if not ok or not r then
    c.state = "failed"
    self.stats.failed = self.stats.failed + 1
    if not ok then self.log(string.format("FAILED: cell %d/%d: %s", cx, cy, tostring(r))) end
    local list = self.route and self.route_idx[key]
    if list then
      for k in pairs(list) do self.route.known[k] = true end
      self.route:finish_heights()
    end
    return true
  end
  self:pin_cell(c, cx, cy, r, g)
  c.ox, c.oy = self:metres_of(cx * CELL, cy * CELL)
  local groups = (self.o.style == "flat" and mesh.build_flat or mesh.build)(r, g, { k = self.k, ox = c.ox, oy = c.oy, tile_metres = self.o.tile_metres,
    tex_metres = self.o.tex_metres, unit = self.o.unit, tick = tick })
  if self.o.buildings and layers then
    local tx, ty = floor(cx / 8), floor(cy / 8)
    -- the drawn ground under a building (metres from the cell origin); outside the cell, the elevation data
    local k, H, gx0, gy0 = self.k, self.H, cx * CELL, cy * CELL
    local function ground(x, y)
      local lx, ly = x / k, -y / k
      if lx >= 0 and lx < CELL and ly >= 0 and ly < CELL then
        local z = mesh.height_at(r, g, lx, ly)
        if z then return z end
      end
      return H:at(gx0 + lx, gy0 + ly) or 0
    end
    local n17 = 2 ^ 17
    local okb, bg = pcall(buildings.build, layers, cx - tx * 8, cy - ty * 8, ground,
      { k = self.k, unit = self.o.unit, tick = tick, lat = fetch.lat_of(cy + 0.5, 17), lon = (cx + 0.5) / n17 * 360 - 180 })
    if okb then for _, G in ipairs(bg) do groups[#groups + 1] = G end
    else self.log(string.format("FAILED: buildings of cell %d/%d: %s", cx, cy, tostring(bg))) end
  end
  if self.o.trees then
    local okt, tg, nt = pcall(trees.build, r, g, cx, cy, { models = self.o.trees, k = self.k, unit = self.o.unit, tick = tick,
      layers = layers, sub = layers and { cx - floor(cx / 8) * 8, cy - floor(cy / 8) * 8 },
      lat = fetch.lat_of(cy + 0.5, 17), elev = self.H:at((cx + 0.5) * CELL, (cy + 0.5) * CELL) })
    if okt then for _, G in ipairs(tg) do groups[#groups + 1] = G end; c.trees = nt
    else self.log(string.format("FAILED: trees of cell %d/%d: %s", cx, cy, tostring(tg))) end
  end
  c.r, c.g = r, g
  c.problems = #r.problems + #g.problems
  if c.problems > 0 then
    local p = {}
    for _, x in ipairs(r.problems) do p[#p + 1] = x end
    for _, x in ipairs(g.problems) do p[#p + 1] = x end
    self.log(string.format("cell %d/%d: %s", cx, cy, table.concat(p, "; ")))
  end
  c.handle = self.o.make(groups, c)
  c.state = "ready"
  fill_route(self, cx, cy, r, g)
  self.stats.built = self.stats.built + 1
  if t0 then self.stats.ms = self.stats.ms + (clock() - t0) * 1000 end
  return true
end

function M:height_at(x, y)
  local gx, gy = self:global_of_metres(x, y)
  local cx, cy = floor(gx / CELL), floor(gy / CELL)
  local c = self.cells[ckey(cx, cy)]
  if not c or not c.r then return nil end
  return mesh.height_at(c.r, c.g, gx - cx * CELL, gy - cy * CELL)
end

-- the route being ridden: its points get the height of the drawn ground as the cells they lie in are built
function M:set_route(R)
  self.route = R
  local idx = {}
  for k = 1, R.n do
    local key = ckey(floor(R.GX[k] / CELL), floor(R.GY[k] / CELL))
    local L = idx[key]; if not L then L = {}; idx[key] = L end
    L[k] = true
  end
  self.route_idx = idx
  self.match = match.new(R, self)
end

-- a route point moved onto the road it is on (match.lua): its cell, and its height if that cell is built
local fill_point
function M:move_route_point(k, gx, gy)
  local R = self.route
  local old = ckey(floor(R.GX[k] / CELL), floor(R.GY[k] / CELL))
  R.GX[k], R.GY[k] = gx, gy
  R.X[k], R.Y[k] = self:metres_of(gx, gy)
  local cx, cy = floor(gx / CELL), floor(gy / CELL)
  local new = ckey(cx, cy)
  if new ~= old then
    if self.route_idx[old] then self.route_idx[old][k] = nil end
    local L = self.route_idx[new]; if not L then L = {}; self.route_idx[new] = L end
    L[k] = true
  end
  local c = self.cells[new]
  if c and c.r then fill_point(self, k, cx, cy, c.r, c.g)
  elseif R.known[k] then R.known[k] = nil; R.ZR[k] = nil end
end

function fill_route(self, cx, cy, r, g)
  local R = self.route
  local list = R and self.route_idx[ckey(cx, cy)]
  if not list then return false end
  for k in pairs(list) do fill_point(self, k, cx, cy, r, g) end
  R:finish_heights()
  return true
end

function fill_point(self, k, cx, cy, r, g)
  local R = self.route
  do
    local x, y = R.GX[k] - cx * CELL, R.GY[k] - cy * CELL
    local z, s = mesh.height_at(r, g, x, y)
    local on_brunnel = false
    for _, b in ipairs(r.brunnels) do
      for j = 1, b.n - 1 do
        local ax, ay, bx, by = b.xs[j], b.ys[j], b.xs[j + 1], b.ys[j + 1]
        local dx, dy = bx - ax, by - ay
        local l2 = dx * dx + dy * dy
        local t = l2 > 0 and ((x - ax) * dx + (y - ay) * dy) / l2 or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        -- on it means close to it and going the same way (a route crossing under a bridge keeps the ground)
        if sqrt((x - ax - dx * t) ^ 2 + (y - ay - dy * t) ^ 2) <= b.half + 2 / r.mpu and l2 > 0 then
          local fx, fy = R:dir(R.S[k])
          local c = (fx * dx - fy * dy) / sqrt(l2)          -- cell y runs south, route y north
          if c > 0.9 or c < -0.9 then on_brunnel = b.kind; break end
        end
      end
      if on_brunnel then break end
    end
    -- on a bridge or in a tunnel (built with the bridge models later), or over water: no ground height here
    if z and not on_brunnel and not cell.WATER[s] then R.ZR[k] = z; R.surf[k] = s
    else R.ZR[k] = nil; R.surf[k] = on_brunnel or (s and "bridge") or nil end
    R.known[k] = true
  end
end

-- route metres from s that already have their heights (the world is built that far ahead along the route)
function M:route_ready_ahead(s)
  local R = self.route
  if not R then return 0 end
  local k = max(1, floor(s / 2) + 1)
  local k0 = k
  while k <= R.n and R.known[k] do k = k + 1 end
  return (k - k0) * 2, k > R.n
end

-- all the cells a route passes, built one after the other without meshes (used by the route tests)
function M:prepare_route(R, tick, progress)
  self:set_route(R)
  self.match:finish(tick)
  local list = R:cells()
  local failed = 0
  for i, c in ipairs(list) do
    if progress then progress(i - 1, #list) end
    local cx, cy = c[1], c[2]
    local ok, r, g = pcall(self.build_cell, self, cx, cy, tick)
    if ok and r then self:pin_cell({}, cx, cy, r, g); fill_route(self, cx, cy, r, g)
    else
      failed = failed + 1
      self.log(string.format("FAILED: route cell %d/%d: %s", cx, cy, tostring(ok and "no map data" or r)))
    end
  end
  if progress then progress(#list, #list) end
  local sum = R:finish_heights()
  sum.cells, sum.failed = #list, failed
  return sum
end

function M:shutdown()
  for _, c in pairs(self.cells) do if c.handle then self.o.free(c.handle) end end
  for _, f in pairs(self.far) do if f.handle then self.o.free(f.handle) end end
  self.far = {}
  self.cells = {}
  self.queue = {}
end

return M
