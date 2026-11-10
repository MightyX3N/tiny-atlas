-- A fake LÖVE 12 for tests: the love.* functions the standalone uses, stubbed so the real game Lua runs in plain
-- LuaJIT. Meshes keep their vertices and every draw is recorded, so frames can be turned into pictures
-- (tools/gmodcheck/ride.js). Downloads fail like a dead network; the cache folder has the map data.
--   local F = dofile("fakelove.lua")(game_dir, save_dir)
--   F.keys[name] = true to hold a key;  F.step(dt) runs one frame (update + draw);  F.capture = true records draws
local ffi = require("ffi")
return function(GAME, SAVE)
  local F = { keys = {}, errors = {}, draws = {}, capture = false, mesh_stats = { max_verts = 0, count = 0 }, t = 0 }
  local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end end
  local function isdir(p) local ok = os.execute('test -d "' .. p .. '"'); return ok == 0 or ok == true end
  local function where(path)
    if exists(SAVE .. "/" .. path) or isdir(SAVE .. "/" .. path) then return SAVE .. "/" .. path end
    return GAME .. "/" .. path
  end
  love = { filesystem = {}, graphics = {}, thread = {}, timer = {}, keyboard = {}, data = {}, image = {}, event = {} }
  function love.getVersion() return 12, 0, 0, "fake" end

  -- ---- filesystem: reads from the save folder first, then the game folder; writes go to the save folder ----
  local fs = love.filesystem
  local req_path = "?.lua;?/init.lua"
  function fs.setRequirePath(p) req_path = p end
  table.insert(package.loaders, 2, function(name)
    local n = name:gsub("%.", "/")
    for pat in req_path:gmatch("[^;]+") do
      local p = GAME .. "/" .. pat:gsub("%?", n)
      if exists(p) then return assert(loadfile(p)) end
    end
  end)
  function fs.load(path) return loadfile(where(path)) end
  function fs.read(path)
    local f = io.open(where(path), "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s, #s
  end
  function fs.write(path, data)
    local dir = (SAVE .. "/" .. path):match("^(.*)/[^/]*$")
    os.execute('mkdir -p "' .. dir .. '"')
    local f = io.open(SAVE .. "/" .. path, "wb"); if not f then return false end
    f:write(data); f:close(); return true
  end
  function fs.append(path, data)
    local f = io.open(SAVE .. "/" .. path, "ab"); if not f then return false end
    f:write(data); f:close(); return true
  end
  function fs.getInfo(path, kind)
    local p = where(path)
    if exists(p) and not isdir(p) then return (not kind or kind == "file") and { type = "file" } or nil end
    if isdir(p) then return (not kind or kind == "directory") and { type = "directory" } or nil end
  end
  function fs.getDirectoryItems(path)
    local out, seen = {}, {}
    for _, base in ipairs({ SAVE, GAME }) do
      local h = io.popen('ls "' .. base .. "/" .. path .. '" 2>/dev/null')
      for l in h:lines() do if not seen[l] then seen[l] = true; out[#out + 1] = l end end
      h:close()
    end
    return out
  end
  function fs.createDirectory(path) os.execute('mkdir -p "' .. SAVE .. "/" .. path .. '"'); return true end
  function fs.getSaveDirectory() return SAVE end

  -- ---- time, keys, threads (downloads answer "offline") ----
  local clock = os.clock
  function love.timer.getTime() return clock() end
  function love.keyboard.isDown(...) for _, k in ipairs({ ... }) do if F.keys[k] then return true end end return false end
  function love.event.quit() F.quit = true end
  local channels = {}
  local function channel(name)
    local c = channels[name]
    if c then return c end
    c = { q = {} }
    function c:push(v)
      if name == "ta_http_req" and type(v) == "table" then
        -- offline, except stand-in photos: TA_FAKE_PHOTOS/<z>/<x>_<y>.jpg answers PDOK-style {z}/{x}/{y} URLs
        local dir = os.getenv("TA_FAKE_PHOTOS")
        local z, x, y = v.url:match("pdok%.nl/.-/EPSG:3857/(%d+)/(%d+)/(%d+)%.jpeg")
        if dir and z then
          local f = io.open(dir .. "/" .. z .. "/" .. x .. "_" .. y .. ".jpg", "rb")
          if f then
            local b = f:read("*a"); f:close()
            F.photo_requests = (F.photo_requests or 0) + 1
            channel("ta_http_res"):push({ id = v.id, body = b })
            return
          end
          channel("ta_http_res"):push({ id = v.id, err = "HTTP 404" })
          return
        end
        -- TA_NET=1: real downloads (curl, one at a time), for the map data services
        if os.getenv("TA_NET") then
          local tmp = os.tmpname()
          local cmd = "curl -sS -A 'TinyAtlas-test' -o " .. tmp .. " -w '%{http_code}' " ..
            (v.range and ("-H 'Range: " .. v.range .. "' ") or "") .. "'" .. v.url:gsub("'", "") .. "'"
          local h = io.popen(cmd); local code = tonumber(h:read("*a")); h:close()
          local f = io.open(tmp, "rb"); local body = f and f:read("*a") or ""; if f then f:close() end
          os.remove(tmp)
          F.net_requests = (F.net_requests or 0) + 1
          F.net_bytes = (F.net_bytes or 0) + #body
          if not code or code >= 400 or code == 0 then channel("ta_http_res"):push({ id = v.id, err = "HTTP " .. tostring(code) })
          else channel("ta_http_res"):push({ id = v.id, body = body }) end
          return
        end
        channel("ta_http_res"):push({ id = v.id, err = "offline test" })
        return
      end
      self.q[#self.q + 1] = v
    end
    function c:pop() return table.remove(self.q, 1) end
    function c:demand() return table.remove(self.q, 1) end
    channels[name] = c
    return c
  end
  function love.thread.getChannel(name) return channel(name) end
  function love.thread.newThread(code) return { start = function() end, getError = function() end } end
  package.preload.https = function() return { request = function() return 0 end } end

  -- ---- data ----
  function love.data.newByteData(size)
    local buf = ffi.new("uint8_t[?]", size)
    return { getFFIPointer = function() return buf end, getSize = function() return size end, buf = buf }
  end
  function love.image.newImageData(w, h)
    if type(w) == "table" and w.bytes then return { bytes = w.bytes } end
    return { w = w, h = h }
  end
  function love.filesystem.newFileData(bytes, name) return { bytes = bytes, name = name } end
  F.photo_files = {}

  -- ---- graphics ----
  local lg = love.graphics
  local W, H = 1280, 720
  F.screen = { W, H }
  local cur = { shader = nil, canvas = nil }
  local uni = {}
  function lg.getDimensions() return W, H end
  function lg.newShader(src)
    assert(src:find("position") and src:find("effect"), "shader without position/effect")
    return { send = function(self, name, a, b) uni[name] = b or a end }
  end
  function lg.newImage(path)
    if type(path) == "table" and path.bytes then
      -- a decoded photo: written out so the picture tool can load it
      F.photo_n = (F.photo_n or 0) + 1
      local name = "photo_" .. F.photo_n .. ".jpg"
      F.photo_files[name] = path.bytes
      path = "materials/photos/" .. name
    elseif type(path) == "string" and not exists(where(path)) then error("Could not open file " .. path) end
    return { path = path, setWrap = function() end, setFilter = function() end, setMipmapFilter = function() end,
      release = function() end }
  end
  ffi.cdef [[ typedef struct { float x, y, z, u, v; uint8_t r, g, b, a; } fake_vertex; ]]
  function lg.newMesh(format, count, mode)
    if type(format) == "table" and type(format[1]) == "table" and type(format[1][1]) == "number" then
      format, count, mode = nil, format, count            -- newMesh(vertices, mode, usage)
    end
    local m = { n = 0, mode = mode }
    if type(count) == "table" then
      m.verts = count; m.n = #count
    else m.n = count end
    function m:setVertices(data)
      local p = ffi.cast("fake_vertex*", data.buf)
      local d = {}
      for i = 0, self.n - 1 do
        local v = p[i]
        local o = i * 8
        d[o + 1], d[o + 2], d[o + 3], d[o + 4], d[o + 5] = v.x, v.y, v.z, v.u, v.v
        d[o + 6], d[o + 7], d[o + 8] = v.r, v.g, v.b
      end
      self.data = d
    end
    function m:setTexture(t) self.tex = t end
    function m:release() self.released = true end
    function m:getVertexCount() return self.n end
    function m:setVertex(i, ...) self.verts[i] = { ... } end
    F.mesh_stats.count = F.mesh_stats.count + 1
    if m.n > F.mesh_stats.max_verts then F.mesh_stats.max_verts = m.n end
    return m
  end
  function lg.newCanvas(w, h) return { w = w, h = h, setFilter = function() end, release = function() end } end
  function lg.setCanvas(c) cur.canvas = c end
  function lg.setShader(s) cur.shader = s end
  function lg.draw(obj)
    if F.capture and cur.shader and obj.data then
      local o = uni.u_off
      F.draws[#F.draws + 1] = { mesh = obj, tex = obj.tex and obj.tex.path, off = { o[1], o[2], o[3] }, cut = uni.u_cut }
    end
  end
  function lg.clear(...)
    local a = { ... }
    if a[1] == false and a[3] == 1 and F.capture then F.clear_at = #F.draws end
  end
  for _, n in ipairs({ "push", "pop", "setColor", "setDepthMode", "setMeshCullMode", "setFont", "print", "rectangle", "origin" }) do lg[n] = function() end end
  function lg.newFont(size) return { getWidth = function(_, s) return #s * size * 0.5 end, getHeight = function() return size end } end
  F.uniforms = uni

  -- one frame
  function F.step(dt)
    F.t = F.t + dt
    local ok, err = pcall(love.update, dt)
    if not ok then F.errors[#F.errors + 1] = "update: " .. tostring(err) end
    ok, err = pcall(love.draw)
    if not ok then F.errors[#F.errors + 1] = "draw: " .. tostring(err) end
  end
  return F
end
