-- TinyAtlas asset pack validator. Plain Lua 5.1 / LuaJIT, so the same file runs in GMod, LÖVE and tools.
-- usage (tools):  validate(pack_table, io_adapter, base_pack_or_nil) -> report
-- io_adapter = { exists = function(relpath) -> bool, read = function(relpath) -> string|nil }

local M = {}

M.GROUND_TAGS = { "urban", "grass", "scrub", "water", "asphalt", "paving", "cobble", "gravel", "sand", "cycleway",
  "dirt", "rail", "pitch", "farmland", "forest_floor", "meadow", "rock", "snow", "wetland", "orchard",
  "rural", "parking", "dry_grass" }
M.TREE_KINDS = { "broadleaf", "conifer", "palm", "shrub", "orchard" }
M.SEASONS = { spring = true, summer = true, autumn = true, winter = true }
local KNOWN = { id = 1, name = 1, author = 1, version = 1, license = 1, credits = 1, local_only = 1, extends = 1,
  tile_metres = 1, edge_darken = 1, ground = 1, ground_priority = 1, seasons = 1, water = 1, wall = 1, sky = 1, sun = 1,
  trees = 1, props = 1, buildings = 1, bridge = 1, filter = 1, rider = 1, bikes = 1, description = 1, preview = 1 }

local function png_size(data)
  if not data or #data < 24 or data:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
  local function u32(i) local a, b, c, d = data:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
  return u32(17), u32(21)
end
M.png_size = png_size

local function is_colour(s) return type(s) == "string" and s:match("^#%x%x%x%x%x%x$") ~= nil end

function M.validate(pack, fs, base)
  local errors, warnings, info = {}, {}, {}
  local function err(m) errors[#errors + 1] = m end
  local function warn(m) warnings[#warnings + 1] = m end
  if type(pack) ~= "table" then return { ok = false, errors = { "the pack file must return a table" }, warnings = {}, info = {} } end

  for k in pairs(pack) do if not KNOWN[k] then warn("unknown key '" .. tostring(k) .. "' (ignored)") end end
  if type(pack.id) ~= "string" or not pack.id:match("^[%w_%-]+$") then err("id must be letters, digits, _ or -") end
  if type(pack.name) ~= "string" or pack.name == "" then err("name is missing") end
  if not pack.author then warn("author is missing") end
  if not pack.license then warn("license is missing: say where the art comes from and how it may be used") end
  if pack.extends ~= nil and type(pack.extends) ~= "string" then err("extends must be a pack id") end
  if pack.extends and not base then warn("extends '" .. pack.extends .. "' but that pack wasn't provided to check against") end

  local checked = {}
  local function image(path, where, want_square)
    if type(path) ~= "string" then err(where .. ": expected an image path"); return end
    if path:find("%.%.") or path:sub(1, 1) == "/" then err(where .. ": path must stay inside the pack (" .. path .. ")"); return end
    if not path:lower():match("%.png$") then err(where .. ": only PNG images are supported (" .. path .. ")"); return end
    if checked[path] ~= nil then return end
    if not fs.exists(path) then checked[path] = false; err(where .. ": file not found: " .. path); return end
    local w, h = png_size(fs.read(path))
    checked[path] = true
    if not w then err(where .. ": not a valid PNG: " .. path); return end
    if want_square then
      if w ~= h then err(where .. ": ground textures must be square (" .. path .. " is " .. w .. "x" .. h .. ")")
      elseif w < 8 or w > 256 then warn(where .. ": unusual size " .. w .. "px") end
    end
    if w > 2048 or h > 2048 then warn(where .. ": " .. path .. " is very large (" .. w .. "x" .. h .. ")") end
  end

  -- ground
  local ground = pack.ground or {}
  if type(ground) ~= "table" then err("ground must be a table") ground = {} end
  local missing = {}
  for _, tag in ipairs(M.GROUND_TAGS) do
    local list = ground[tag]
    if list == nil then
      if not (base and base.ground and base.ground[tag]) then missing[#missing + 1] = tag end
    elseif type(list) ~= "table" or #list == 0 then err("ground." .. tag .. " must be a list of one or more images")
    else for i, p in ipairs(list) do image(p, "ground." .. tag .. "[" .. i .. "]", true) end end
  end
  for tag in pairs(ground) do
    local known = false
    for _, t in ipairs(M.GROUND_TAGS) do if t == tag then known = true end end
    if not known then warn("ground." .. tostring(tag) .. " is not a ground tag (ignored)") end
  end
  if #missing > 0 then
    if pack.extends then err("ground tags not covered by this pack or '" .. pack.extends .. "': " .. table.concat(missing, ", "))
    else err("ground tags missing (add them or set extends = \"default\"): " .. table.concat(missing, ", ")) end
  end

  -- seasons
  for season, over in pairs(pack.seasons or {}) do
    if not M.SEASONS[season] then warn("unknown season '" .. tostring(season) .. "'") end
    for tag, list in pairs((over or {}).ground or {}) do for i, p in ipairs(list) do image(p, "seasons." .. season .. ".ground." .. tag .. "[" .. i .. "]", true) end end
    for kind, t in pairs((over or {}).trees or {}) do for i, p in ipairs(t.sprites or {}) do image(p, "seasons." .. season .. ".trees." .. kind .. "[" .. i .. "]") end end
    for tag, list in pairs((over or {}).props or {}) do
      for k, pr in ipairs(list) do for i, p in ipairs(pr.sprites or {}) do image(p, "seasons." .. season .. ".props." .. tag .. "[" .. k .. "][" .. i .. "]") end end
    end
  end

  -- trees
  local trees = pack.trees or {}
  for _, kind in ipairs(M.TREE_KINDS) do
    local t = trees[kind]
    if t then
      if type(t.sprites) ~= "table" or #t.sprites == 0 then err("trees." .. kind .. ".sprites must list one or more images")
      else for i, p in ipairs(t.sprites) do image(p, "trees." .. kind .. "[" .. i .. "]") end end
      if t.height and (type(t.height) ~= "table" or #t.height ~= 2 or t.height[1] > t.height[2]) then err("trees." .. kind .. ".height must be { min, max } in metres") end
    elseif not (base and base.trees and base.trees[kind]) then
      if kind == "palm" then info[#info + 1] = "no palm trees: broadleaf trees are used instead"
      else warn("no '" .. kind .. "' trees (broadleaf will be used)") end
    end
  end

  -- props
  for tag, list in pairs(pack.props or {}) do
    for i, pr in ipairs(list) do
      if type(pr.sprites) ~= "table" or #pr.sprites == 0 then err("props." .. tag .. "[" .. i .. "] has no sprites") end
      for j, p in ipairs(pr.sprites or {}) do image(p, "props." .. tag .. "[" .. i .. "][" .. j .. "]") end
      if type(pr.density) ~= "number" or pr.density < 0 or pr.density > 20 then err("props." .. tag .. "[" .. i .. "].density must be 0..20 per 100 m²") end
    end
  end

  -- single images and colours
  if pack.water then
    image(pack.water.texture, "water.texture", true)
    for _, kind in ipairs({ "still", "river" }) do       -- optional looping animations: frames stacked top to bottom
      local a = pack.water[kind]
      if a ~= nil then
        if type(a) ~= "table" or type(a.sheet) ~= "string" then err("water." .. kind .. " needs a sheet image")
        else
          image(a.sheet, "water." .. kind .. ".sheet")
          if type(a.frames) ~= "number" or a.frames < 1 then err("water." .. kind .. ".frames must be a number of frames") end
          local w, h = nil, nil
          if fs.exists(a.sheet) then w, h = png_size(fs.read(a.sheet)) end
          if w and h and a.frames and h ~= w * a.frames then err("water." .. kind .. ".sheet must be square frames stacked: " .. w .. "x" .. h .. " for " .. tostring(a.frames) .. " frames") end
        end
      end
    end
  end
  if pack.wall then image(pack.wall.texture, "wall.texture", true) end
  if pack.bridge then
    local br = pack.bridge
    if br.side ~= nil and not is_colour(br.side) then err("bridge.side must be a colour like #b9a88f") end
    for _, k in ipairs({ "wall", "stone", "parapet", "arch" }) do
      if br[k] ~= nil then image(br[k], "bridge." .. k, true) end
    end
    if (br.wall or br.stone or br.parapet or br.arch) and not (br.wall and br.stone and br.parapet and br.arch) then
      warn("bridge: give all four parts (wall, stone, parapet, arch) or none; missing ones fall back to plain colours")
    end
  end
  if pack.buildings then
    local b = pack.buildings
    image(b.facades, "buildings.facades")
    if checked[b.facades] then
      local w, h = png_size(fs.read(b.facades))
      if w and b.styles and w ~= 16 * b.styles then warn("buildings.facades is " .. w .. " px wide; expected 16 px per style x " .. b.styles .. " styles") end
      if h and h ~= 40 then warn("buildings.facades should be 40 px tall (upper floor 20 px + ground floor 20 px)") end
    end
    for i, p in ipairs(b.roofs or {}) do image(p, "buildings.roofs[" .. i .. "]", true) end
  end
  for _, k in ipairs({ "top", "horizon", "haze" }) do
    if pack.sky and pack.sky[k] ~= nil and not is_colour(pack.sky[k]) then err("sky." .. k .. " must be a colour like \"#88aaff\"") end
  end
  for k, v in pairs(pack.rider or {}) do if not is_colour(v) then err("rider." .. k .. " must be a colour like \"#c8392f\"") end end
  for name, b in pairs(pack.bikes or {}) do if b.texture then image(b.texture, "bikes." .. name .. ".texture") end end
  if pack.filter then
    local f = pack.filter
    if f.pixel and (type(f.pixel) ~= "number" or f.pixel < 1 or f.pixel > 16) then err("filter.pixel must be 1..16") end
    if f.colours and (type(f.colours) ~= "number" or f.colours < 2 or f.colours > 256) then err("filter.colours must be 2..256") end
  end
  if type(pack.tile_metres) == "number" and (pack.tile_metres < 0.5 or pack.tile_metres > 50) then err("tile_metres must be 0.5..50") end

  local publishable = #errors == 0 and not pack.local_only
  if pack.local_only then info[#info + 1] = "local_only pack: it stays on this computer and can't be published to the Workshop" end
  local n = 0 for _ in pairs(checked) do n = n + 1 end
  info[#info + 1] = n .. " images checked"
  return { ok = #errors == 0, publishable = publishable, errors = errors, warnings = warnings, info = info }
end

return M
