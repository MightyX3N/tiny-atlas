-- Reads the runtime route format (tools/gmod_export.py) into flat 0-based arrays. Engine-agnostic:
-- the engine layer gives read(path) -> string|nil and json(string) -> table.
local D = {}
local byte, floor = string.byte, math.floor

function D.new(read, json, root)
  return setmetatable({ read = read, json = json, root = root, cache = {} }, { __index = D })
end

local function split(blob, json)
  local nl = blob:find("\n", 1, true)
  return json(blob:sub(1, nl - 1)), nl + 1
end

-- u16 grid -> heights (0-based, row 0 = south)
local function u16(s, pos, count, base, scale)
  local t = {}
  for i = 0, count - 1 do
    local p = pos + 2 * i
    local a, b = byte(s, p, p + 1)
    t[i] = base + scale * (a + 256 * b)
  end
  return t, pos + 2 * count
end

local function unrle(s, pos, nbytes)
  local t, k = {}, 0
  for p = pos, pos + nbytes - 1, 2 do
    local c, v = byte(s, p, p + 1)
    for _ = 1, c do t[k] = v; k = k + 1 end
  end
  return t, pos + nbytes, k
end

function D:file(name) return self.read(self.root .. "/" .. name) end

function D:route()
  if not self._route then
    local s = assert(self:file("route.txt"), "route.txt missing in " .. self.root)
    self._route = self.json(s)
  end
  return self._route
end

-- near chunk (256 m, 1 m heights, 1 m tags, 8 m water surface)
function D:chunk(cx, cy)
  local key = "c" .. cx .. "," .. cy
  local c = self.cache[key]; if c then c.used = self.tick or 0; return c end
  local blob = self:file("c_" .. cx .. "_" .. cy .. ".dat"); if not blob then return nil end
  local hd, pos = split(blob, self.json)
  local n = hd.n
  local H; H, pos = u16(blob, pos, n * n, hd.base, hd.scale)
  local T; T, pos = unrle(blob, pos, hd.tags_bytes)
  local W
  if hd.water then W = u16(blob, pos, hd.water.n * hd.water.n, hd.water.base, hd.water.scale) end
  c = { kind = "near", hd = hd, cx = cx, cy = cy, x0 = hd.x0, y0 = hd.y0, n = n, H = H, T = T, tn = n - 1, W = W,
        wn = hd.water and hd.water.n, wres = hd.water and hd.water.res, used = self.tick or 0 }
  self.cache[key] = c
  return c
end

function D:chunk_objects(cx, cy)
  local c = self:chunk(cx, cy); if not c then return nil end
  if not c.objs then
    local s = self:file("c_" .. cx .. "_" .. cy .. ".txt")
    c.objs = s and self.json(s) or { buildings = {}, trees = {} }
  end
  return c.objs
end

-- mid page (1024 m, 4 m heights, 4 m tags, 8 m water)
function D:page(px, py)
  local key = "p" .. px .. "," .. py
  local c = self.cache[key]; if c then c.used = self.tick or 0; return c end
  local blob = self:file("p_" .. px .. "_" .. py .. ".dat"); if not blob then return nil end
  local hd, pos = split(blob, self.json)
  local n = hd.n
  local H; H, pos = u16(blob, pos, n * n, hd.base, hd.scale)
  local T; T, pos = unrle(blob, pos, hd.tags_bytes)
  local W
  if hd.water then W = u16(blob, pos, hd.water.n * hd.water.n, hd.water.base, hd.water.scale) end
  local present, wat = {}, {}
  for _, p in ipairs(hd.present) do present[p[1] .. "," .. p[2]] = true end
  for _, p in ipairs(hd.water_chunks or {}) do wat[p[1] .. "," .. p[2]] = true end
  c = { kind = "mid", hd = hd, px = px, py = py, x0 = hd.x0, y0 = hd.y0, n = n, res = hd.res, H = H, T = T, tn = n - 1,
        W = W, wn = hd.water and hd.water.n, wres = hd.water and hd.water.res, present = present, water_cells = wat,
        used = self.tick or 0 }
  self.cache[key] = c
  return c
end

function D:page_objects(px, py)
  local c = self:page(px, py); if not c then return nil end
  if not c.objs then
    local s = self:file("p_" .. px .. "_" .. py .. ".txt")
    c.objs = s and self.json(s) or { boxes = {}, trees = {} }
  end
  return c.objs
end

-- 16 m level of a whole page
function D:l16(px, py)
  local blob = self:file("l_" .. px .. "_" .. py .. ".dat"); if not blob then return nil end
  local hd, pos = split(blob, self.json)
  local H; H, pos = u16(blob, pos, hd.n * hd.n, hd.base, hd.scale)
  local T = unrle(blob, pos, hd.tags_bytes)
  local cells = {}
  for _, c in ipairs(hd.cells) do cells[c[1] .. "," .. c[2]] = true end
  return { kind = "l16", px = px, py = py, x0 = hd.x0, y0 = hd.y0, n = hd.n, res = hd.res, H = H, T = T, tn = hd.n - 1, cells = cells }
end

function D:far()
  local blob = assert(self:file("far.dat"), "far.dat missing")
  local hd, pos = split(blob, self.json)
  local H; H, pos = u16(blob, pos, hd.nx * hd.ny, hd.base, hd.scale)
  local T = unrle(blob, pos, hd.tags_bytes)
  return { kind = "far", x0 = hd.x0, y0 = hd.y0, nx = hd.nx, ny = hd.ny, res = hd.res, H = H, T = T, tn = hd.tnx }
end

-- forget data not used for a while (call with the current tick)
function D:trim(older_than)
  for k, c in pairs(self.cache) do
    if c.used < older_than then self.cache[k] = nil end
  end
end

return D
