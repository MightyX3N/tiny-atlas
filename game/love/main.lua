-- Tiny Atlas, standalone (LÖVE 11.5 or 12). Ride a GPX route or roam anywhere: the world is built live from OpenStreetMap
-- while you ride, with a smart trainer through OmniPlay or the keyboard (W ride, Shift sprint, S brake).
-- The world code is shared with the Garry's Mod version (atlas/, core/); this file is the LÖVE layer.
--
-- Your own routes: put .gpx files in the save folder's gpx/ (the menu shows where it is).
love.filesystem.setRequirePath("?.lua;?/init.lua;core/?.lua")

local loaded = {}
function ATLAS_REQUIRE(name)
  if loaded[name] == nil then loaded[name] = assert(love.filesystem.load("atlas/" .. name .. ".lua"))() end
  return loaded[name]
end

local fetch = ATLAS_REQUIRE("fetch")
local session = ATLAS_REQUIRE("session")
local mesh_lib = ATLAS_REQUIRE("mesh")
local photos = ATLAS_REQUIRE("photos")
local net = require("net")
local jobs = require("jobs")
local render = require("render")
local Trainer = require("trainer")

local G = {
  screen = "menu", sel = 1, log = {}, settings = { look = "photo", pixel = 1 },
  LOOKS = { { id = "photo", name = "Aerial photos (realistic)" }, { id = "city", name = "Textured city (ambientCG)" }, { id = "default", name = "Default pack textures" }, { id = "flat", name = "Flat colours" } },
  ROAM = { { "Copenhagen", 55.6761, 12.5683 }, { "Amsterdam, Dam square", 52.3731, 4.8925 }, { "Berlin, Brandenburg Gate", 52.5163, 13.3777 } },
}

local function log(msg)
  print(msg)
  for line in tostring(msg):gmatch("[^\n]+") do
    G.log[#G.log + 1] = { text = line, t = love.timer.getTime() }
    if #G.log > 200 then table.remove(G.log, 1) end
  end
  love.filesystem.append("log.txt", os.date("%H:%M:%S ") .. tostring(msg) .. "\n")
end
render.log = log

-- ---- settings ----
local function load_settings()
  local s = love.filesystem.read("settings.txt")
  if not s then return end
  for k, v in s:gmatch("(%w+)=([^\n]+)") do G.settings[k] = tonumber(v) or v end
end
local function save_settings()
  local out = {}
  for k, v in pairs(G.settings) do out[#out + 1] = k .. "=" .. tostring(v) end
  love.filesystem.write("settings.txt", table.concat(out, "\n") .. "\n")
end

-- ---- asset packs: packs/<folder>/lua/tinyatlas/packs/<id>.lua, textures under packs/<folder>/materials ----
local packs = {}
local function load_packs()
  for _, folder in ipairs(love.filesystem.getDirectoryItems("packs")) do
    local dir = "packs/" .. folder .. "/lua/tinyatlas/packs"
    for _, f in ipairs(love.filesystem.getDirectoryItems(dir)) do
      if f:match("%.lua$") and not f:match("_gmod%.lua$") then
        local ok, p = pcall(function() return assert(love.filesystem.load(dir .. "/" .. f))() end)
        if ok and type(p) == "table" and p.id then p.root = "packs/" .. folder; packs[p.id] = p
        else log("[Tiny Atlas] FAILED: pack " .. f .. ": " .. tostring(p)) end
      end
    end
  end
end
local function look_opts()
  if G.settings.look == "o2w" then G.settings.look = "city" end      -- the old OSM2World look's setting
  local look = G.settings.look
  if look == "flat" then return packs.default or { id = "none" }, { style = "flat", tile_metres = 3.3 } end
  if look == "photo" then
    -- the photo on the ground; buildings (and the ground where no photo comes) from the city pack
    local p = packs.city or packs.default
    return p, { style = "textured", tile_metres = p.tile_metres or 3.3, tex_metres = p.tex_metres, far_metres = p.far_metres,
      buildings = p.buildings, photos = true }
  end
  local p = packs[look] or packs.default
  return p, { style = "textured", tile_metres = p.tile_metres or 3.3, tex_metres = p.tex_metres, far_metres = p.far_metres,
    buildings = p.buildings }
end

-- ---- routes: the game's routes/ and the player's gpx/ in the save folder ----
local function list_routes()
  local out = {}
  for _, f in ipairs(love.filesystem.getDirectoryItems("routes")) do
    if f:match("%.gpx$") then out[#out + 1] = { name = f:gsub("%.gpx$", ""), path = "routes/" .. f } end
  end
  love.filesystem.createDirectory("gpx")
  for _, f in ipairs(love.filesystem.getDirectoryItems("gpx")) do
    if f:match("%.gpx$") then out[#out + 1] = { name = f:gsub("%.gpx$", "") .. " (your file)", path = "gpx/" .. f } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function menu_items()
  local items = {}
  for _, r in ipairs(G.routes) do items[#items + 1] = { kind = "route", label = "Ride: " .. r.name, route = r } end
  for _, p in ipairs(G.ROAM) do items[#items + 1] = { kind = "roam", label = "Free roam: " .. p[1], lat = p[2], lon = p[3] } end
  local lookname = G.settings.look
  for _, l in ipairs(G.LOOKS) do if l.id == G.settings.look then lookname = l.name end end
  items[#items + 1] = { kind = "look", label = "Look: " .. lookname }
  items[#items + 1] = { kind = "pixel", label = "Pixel filter: " .. (G.settings.pixel <= 1 and "off" or (G.settings.pixel .. " px")) }
  items[#items + 1] = { kind = "quit", label = "Quit" }
  return items
end

-- ---- start / stop ----
local S
TinyAtlasGame = { G = G, session = function() return S end }      -- for tests and tools
local function start(item)
  G.sel_item = item
  local pack, o = look_opts()
  G.pack = pack
  G.ride = { s = 0, speed = 0 }
  local ok
  if item.kind == "route" then
    ok = S:start_route(item.route.name, love.filesystem.read(item.route.path), o)
  else
    ok = S:start_roam(item.lat, item.lon, o)
  end
  if ok then G.screen = "ride" end
end
local function stop()
  S:stop()
  G.screen = "menu"
  G.routes = list_routes()
end

function love.load()
  love.filesystem.write("log.txt", "")
  load_settings()
  net.start()
  if not net.has_https then
    log("[Tiny Atlas] FAILED: no way to download over HTTPS here (needs Windows, curl, or LÖVE 12)")
  end
  render.init()
  load_packs()
  G.routes = list_routes()
  S = session.new({
    fetch = fetch.new(net.platform, "tinyatlas/cache"), clock = love.timer.getTime, log = log,
    make = function(groups) return render.make(groups) end, free = function(h) render.free(h) end, jobs = jobs,
  })
  -- the rider's legs: OmniPlay (smart trainer, walking pad) when it is running, the keyboard otherwise
  local ok, api = pcall(require, "omniplay_api")
  local none = function() end
  G.trainer = Trainer.new(ok and api or { IsConnected = function() return false end, Get = none, SetGame = none,
    SetGrade = none, TakeInput = none, Release = none }, { bike = "mtb", rider_kg = 75, difficulty = 0.5, game = "Tiny Atlas" })
  G.fonts = { big = love.graphics.newFont(24), mid = love.graphics.newFont(17), small = love.graphics.newFont(13) }
end

function love.update(dt)
  net.update(log)
  jobs.run(log)
  if G.screen ~= "ride" or not S.on then return end
  dt = math.min(dt, 0.1)
  local kd = love.keyboard.isDown
  local route = S:route_api()
  route.s = G.ride.s
  local st = G.trainer:update(dt, { forward = kd("w") or kd("up"), sprint = kd("lshift"), brake = kd("s") or kd("down") }, route)
  -- no riding while the world around the start is still being built
  if S.phase == "riding" then
    G.ride.speed, G.ride.state = st.speed, st
    G.ride.s = G.ride.s + st.speed * dt
  end
  local ok, err = pcall(S.update, S, dt, G.ride.s, { left = kd("a") or kd("left"), right = kd("d") or kd("right"), back = kd("b") })
  if not ok then log("[Tiny Atlas] FAILED: " .. tostring(err)); stop() end
end

-- ---- drawing ----
local lg = love.graphics
local function text(s, x, y, font, a)
  lg.setFont(font)
  lg.setColor(0, 0, 0, 0.6 * (a or 1)); lg.print(s, x + 1, y + 1)
  lg.setColor(1, 1, 1, a or 1); lg.print(s, x, y)
end

local function draw_log(x, y, max_age, n)
  local now = love.timer.getTime()
  local shown = 0
  for i = #G.log, 1, -1 do
    local e = G.log[i]
    local age = now - e.t
    if age > max_age or shown >= n then break end
    shown = shown + 1
    text(e.text, x, y - shown * 17, G.fonts.small, math.min(1, (max_age - age) / 2))
  end
end

local function draw_menu()
  local w, h = lg.getDimensions()
  lg.clear(0.13, 0.16, 0.2)
  text("Tiny Atlas", 40, 34, G.fonts.big)
  text("Up / Down to choose, Enter to start or change. In a ride: W ride, Shift sprint, S brake, A / D steer (free roam), B look back, Esc menu.", 40, 70, G.fonts.small, 0.8)
  text("Your own routes: put .gpx files in " .. love.filesystem.getSaveDirectory() .. "/gpx", 40, 88, G.fonts.small, 0.8)
  local items = menu_items()
  G.sel = math.max(1, math.min(#items, G.sel))
  local y = 124
  for i, it in ipairs(items) do
    if i == G.sel then lg.setColor(1, 1, 1, 0.12); lg.rectangle("fill", 32, y - 3, w - 64, 26) end
    text(it.label, 44, y, G.fonts.mid, i == G.sel and 1 or 0.85)
    y = y + 28
  end
  draw_log(40, h - 16, 30, 6)
end

local function draw_ride()
  local W = S.W
  local w, h = lg.getDimensions()
  if S.cam then
    render.draw(W, G.pack, S.cam, S.phase == "riding" and { x = S.x, y = S.y, z = S.z, fx = S.fx, fy = S.fy } or nil, G.settings.pixel)
  else
    lg.clear(render.SKY_HORIZON[1], render.SKY_HORIZON[2], render.SKY_HORIZON[3])
  end
  if S.phase == "loading" then
    local done, total = S:loading()
    total = math.max(total, 1)
    local bw, bh = math.min(560, w - 80), 14
    local bx, by = (w - bw) / 2, h / 2 + 18
    lg.setColor(0, 0, 0, 0.6); lg.rectangle("fill", bx - 2, by - 2, bw + 4, bh + 4)
    lg.setColor(1, 1, 1, 0.9); lg.rectangle("fill", bx, by, bw * math.min(1, done / total), bh)
    local msg = string.format("Building the world around you... %d of %d", done, total)
    lg.setFont(G.fonts.big)
    text(msg, (w - G.fonts.big:getWidth(msg)) / 2, h / 2 - 22, G.fonts.big)
  else
    for i, l in ipairs(S:hud_lines(G.ride.speed)) do text(l, 16, 12 + (i - 1) * 28, i == 1 and G.fonts.big or G.fonts.mid) end
    local st = G.ride.state
    if st then text(st.source == "omniplay" and "OmniPlay" or "Keyboard", 16, 70, G.fonts.small, 0.8) end
  end
  -- credits for what is on screen: the map data, and the aerial photos in use
  do
    local lines = { "Map data (c) OpenStreetMap contributors, OpenMapTiles; elevation: Mapterhorn" }
    if W.photo_used then for _, c in ipairs(photos.credits(W.photo_used)) do lines[#lines + 1] = "Photos: " .. c end end
    for i, l in ipairs(lines) do
      local tw = G.fonts.small:getWidth(l)
      text(l, w - tw - 10, h - 4 - (#lines - i + 1) * 15, G.fonts.small, 0.75)
    end
  end
  draw_log(16, h - 12, 12, 5)
end

function love.draw()
  if G.screen == "ride" and S.on then
    local ok, err = pcall(draw_ride)
    if not ok then log("[Tiny Atlas] FAILED: drawing the world: " .. tostring(err)); stop() end
  else
    draw_menu()
  end
end

function love.keypressed(key)
  if G.screen == "ride" then
    if key == "escape" then stop() end
    return
  end
  local items = menu_items()
  if key == "up" then G.sel = (G.sel - 2) % #items + 1
  elseif key == "down" then G.sel = G.sel % #items + 1
  elseif key == "escape" then love.event.quit()
  elseif key == "return" or key == "kpenter" or key == "space" then
    local it = items[G.sel]
    if it.kind == "route" or it.kind == "roam" then start(it)
    elseif it.kind == "look" then
      local i = 1
      for k, l in ipairs(G.LOOKS) do if l.id == G.settings.look then i = k end end
      G.settings.look = G.LOOKS[i % #G.LOOKS + 1].id
      save_settings()
    elseif it.kind == "pixel" then
      G.settings.pixel = G.settings.pixel >= 6 and 1 or G.settings.pixel + 1
      save_settings()
    elseif it.kind == "quit" then love.event.quit() end
  end
end

function love.quit()
  if S then S:stop() end
  if G.trainer and G.trainer.release then pcall(G.trainer.release, G.trainer) end
  net.stop()
end
