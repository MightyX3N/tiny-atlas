-- WOWe Generator
-- Paint the water's surfaces (rivers, pools) on one mask layer and where it
-- falls on another; they become one looping pixel-art scene.
--
-- Entry point. Registers the Edit > Insert command and installs a private
-- module loader: every extension shares one Lua state, so a plain
-- require("ui") could pick up another extension's module of that name.

local MODULE_DIR = "wowe"

local function moduleFile(root, name)
  return app.fs.joinPath(app.fs.joinPath(root, MODULE_DIR), name .. ".lua")
end

local function pickRoot(plugin)
  local roots = {}
  if plugin and plugin.path and #plugin.path > 0 then roots[#roots + 1] = plugin.path end
  local info = debug.getinfo(1, "S")
  if info and info.source and info.source:sub(1, 1) == "@" then
    roots[#roots + 1] = app.fs.filePath(info.source:sub(2))
  end
  for _, root in ipairs(roots) do
    if app.fs.isFile(moduleFile(root, "scape")) then return root end
  end
  return nil
end

local function installLoader(root, plugin)
  _WOWE = { root = root, cache = {}, plugin = plugin }
  function _WOWE.require(name)
    local hit = _WOWE.cache[name]
    if hit ~= nil then return hit end
    local chunk, err = loadfile(moduleFile(root, name))
    if not chunk then error("WOWe Generator: " .. name .. " could not load\n" .. tostring(err), 0) end
    local value = chunk(_WOWE)
    if value == nil then value = true end
    _WOWE.cache[name] = value
    return value
  end
end

local Ui = nil

local function launch(plugin)
  if not _WOWE then
    local root = pickRoot(plugin)
    if not root then
      app.alert("WOWe Generator: extension folder not found (wowe-generator/wowe).")
      return
    end
    installLoader(root, plugin)
  end
  local ok, err = pcall(function()
    Ui = _WOWE.require("ui")
    Ui.open(plugin.preferences)
  end)
  if not ok then app.alert{ title = "WOWe Generator", text = tostring(err) } end
end

function init(plugin)
  if app.apiVersion < 21 then
    if app.isUIAvailable then app.alert("WOWe Generator requires Aseprite 1.3 or newer.") end
    return
  end
  local root = pickRoot(plugin)
  if root then installLoader(root, plugin) end
  plugin:newCommand{
    id = "wowe_generator",
    title = "WOWe Generator",
    group = "edit_insert",
    onclick = function() launch(plugin) end,
  }
end

function exit(plugin)
  if Ui and Ui.close then pcall(Ui.close) end
  _WOWE = nil
end
