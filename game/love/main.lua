-- Tiny Atlas, standalone (LÖVE 11.5 or 12): the Garry's Mod gamemode itself, run on a small layer that gives it the
-- GMod functions it uses (gmod.lua, gmod_render.lua). Everything the game does is in the gamemode's files; this only
-- starts it and hands it LÖVE's frames, keys and mouse.
--
-- Test runs (no window needed): TA_AUTOTEST=<script.lua> runs a Lua script against the game after it starts
-- (it can press keys, wait, and save screenshots) - see tools/love_test/.
love.filesystem.setRequirePath("?.lua;?/init.lua")
local L = require("gmod")
local R = require("gmod_render")

function love.load(args)
  love.graphics.setDefaultFilter("nearest", "nearest")
  R.init()
  L.game_files = R.game_files
  L.start()
  include("shared.lua")
  include("cl_init.lua")
  GAMEMODE = GM
  hook.Run("Initialize")
  hook.Run("InitPostEntity")
  local test = os.getenv("TA_AUTOTEST")
  if test then
    local chunk = assert(loadfile(test))
    TINYATLAS_LOVE.test = coroutine.create(chunk)
  end
end

function love.update(dt)
  L.update(dt)
  local T = TINYATLAS_LOVE.test
  if T and coroutine.status(T) ~= "dead" then
    local ok, err = coroutine.resume(T, L, R)
    if not ok then print("TEST FAILED: " .. tostring(err)); love.event.quit(1) end
  end
end

function love.draw() R.frame() end
function love.keypressed(key) L.keypressed(key) end
function love.wheelmoved(x, y) L.wheel(y) end
function love.quit() hook.Run("ShutDown") end
