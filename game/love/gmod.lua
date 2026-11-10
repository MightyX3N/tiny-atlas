-- The Garry's Mod functions the gamemode uses, on top of LÖVE, so the gamemode's own files run here unchanged
-- (game/gamemodes/tinyatlas/gamemode). This file: the general ones (vectors, colours, settings, hooks, timers, files,
-- downloads, input, include); gmod_render.lua: drawing. Only what the gamemode uses, done the way GMod does it.
--
-- The game's folder (made by tools/build_love.py) is laid out like GMod's: gamemodes/tinyatlas/..., lua/ (asset
-- packs' Lua), materials/, resource/fonts/, shaders/. Saved files (GMod's data/) go to LÖVE's save folder.
local lfs = love.filesystem
local net = require("net")
local L = {}
TINYATLAS_LOVE = {
  save_folder = lfs.getSaveDirectory(),
  quit = function() love.event.quit() end,
}

CLIENT, SERVER = true, false
math.Clamp = function(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
math.Round = function(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
function isfunction(v) return type(v) == "function" end
function istable(v) return type(v) == "table" end
function isstring(v) return type(v) == "string" end
function isnumber(v) return type(v) == "number" end
function table.Count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function table.HasValue(t, v) for _, x in pairs(t) do if x == v then return true end end return false end
function string.StartWith(s, p) return s:sub(1, #p) == p end
function string.EndsWith(s, p) return p == "" or s:sub(-#p) == p end
function string.Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function string.Split(s, sep)
  local out, i = {}, 1
  while true do
    local a, b = s:find(sep, i, true)
    if not a then out[#out + 1] = s:sub(i); break end
    out[#out + 1] = s:sub(i, a - 1); i = b + 1
  end
  return out
end
string.Explode = function(sep, s) return string.Split(s, sep) end

-- ---- vectors, angles, matrices, colours ----
local VM = {}
VM.__index = VM
function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VM) end
function VM:SetUnpacked(x, y, z) self.x, self.y, self.z = x, y, z end
function VM:Unpack() return self.x, self.y, self.z end
function VM.__mul(a, b)
  if type(a) == "number" then a, b = b, a end
  if type(b) == "number" then return Vector(a.x * b, a.y * b, a.z * b) end
  return Vector(a.x * b.x, a.y * b.y, a.z * b.z)
end
function VM.__add(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
function VM.__sub(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
function VM.__unm(a) return Vector(-a.x, -a.y, -a.z) end
function VM:Length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
local AM = {}
AM.__index = AM
function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, AM) end
function AM:Unpack() return self.p, self.y, self.r end
local MM = {}
MM.__index = MM
-- t: the translation; r: the 3 x 3 rotation / scale rows, nil when there is none (GMod's Matrix({ rows }) too)
function Matrix(rows)
  local m = setmetatable({ t = { 0, 0, 0 } }, MM)
  if rows then
    m.t = { rows[1][4], rows[2][4], rows[3][4] }
    m.r = { rows[1][1], rows[1][2], rows[1][3], rows[2][1], rows[2][2], rows[2][3], rows[3][1], rows[3][2], rows[3][3] }
  end
  return m
end
function MM:SetTranslation(v) self.t[1], self.t[2], self.t[3] = v.x, v.y, v.z end
function MM:GetTranslation() return Vector(self.t[1], self.t[2], self.t[3]) end
function Color(r, g, b, a) return { r = r or 255, g = g or 255, b = b or 255, a = a or 255 } end
color_white, color_black, color_transparent = Color(255, 255, 255), Color(0, 0, 0), Color(0, 0, 0, 0)

-- ---- time ----
local t0 = love.timer.getTime()
L.frame, L.dt = 0, 1 / 60
function SysTime() return love.timer.getTime() end
function RealTime() return love.timer.getTime() - t0 end
function CurTime() return love.timer.getTime() - t0 end
function FrameTime() return L.dt end
function RealFrameTime() return L.dt end
function FrameNumber() return L.frame end
function ScrW() return love.graphics.getWidth() end
function ScrH() return love.graphics.getHeight() end

function IsValid(x)
  if x == nil then return false end
  if type(x) == "table" and x.IsValid then return x:IsValid() end
  return true
end
function ErrorNoHalt(...) print("ERROR: " .. table.concat({ ... }, "")) end
function Msg(...) io.write(...) end
function MsgN(...) print(...) end

-- ---- hooks, timers ----
hook = { list = {} }
function hook.Add(ev, id, fn) hook.list[ev] = hook.list[ev] or {}; hook.list[ev][id] = fn end
function hook.Remove(ev, id) if hook.list[ev] then hook.list[ev][id] = nil end end
function hook.Run(ev, ...)
  for _, fn in pairs(hook.list[ev] or {}) do
    local a, b, c = fn(...)
    if a ~= nil then return a, b, c end
  end
  local gm = GAMEMODE or GM
  if gm and type(gm[ev]) == "function" then return gm[ev](gm, ...) end
end
hook.Call = function(ev, gm, ...) return hook.Run(ev, ...) end
timer = { list = {} }
function timer.Simple(delay, fn) timer.list[#timer.list + 1] = { at = RealTime() + delay, fn = fn, reps = 1 } end
function timer.Create(name, delay, reps, fn) timer.list[name] = { at = RealTime() + delay, delay = delay, reps = reps, fn = fn } end
function timer.Remove(name) timer.list[name] = nil end
function timer.Exists(name) return timer.list[name] ~= nil end
local function run_timers()
  local now = RealTime()
  for k, t in pairs(timer.list) do
    if now >= t.at then
      if t.reps == 1 then timer.list[k] = nil
      else t.at = now + (t.delay or 0); if t.reps and t.reps > 1 then t.reps = t.reps - 1 end end
      local ok, err = pcall(t.fn)
      if not ok then ErrorNoHalt("timer: " .. tostring(err)) end
    end
  end
end

-- GMod starts its random numbers somewhere new each time; LuaJIT on its own starts the same way every run
math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6))
for _ = 1, 4 do math.random() end

-- ---- settings (console variables), saved in the save folder ----
local CVFILE = "cfg/tinyatlas.cfg"
local convars, saved = {}, {}
local function save_convars()
  local out = {}
  for name, c in pairs(convars) do if c.archive then out[#out + 1] = name .. " \"" .. c.value .. "\"" end end
  table.sort(out)
  lfs.createDirectory("cfg")
  lfs.write(CVFILE, table.concat(out, "\n") .. "\n")
end
if lfs.getInfo(CVFILE) then
  for name, v in (lfs.read(CVFILE) or ""):gmatch('(%S+)%s+"([^"]*)"') do saved[name] = v end
end
local CV = {}
CV.__index = CV
function CreateClientConVar(name, default, archive, userinfo, help)
  if convars[name] then return convars[name] end
  local c = setmetatable({ name = name, default = tostring(default), value = saved[name] or tostring(default),
    archive = archive ~= false, help = help }, CV)
  convars[name] = c
  return c
end
CreateConVar = function(name, default, flags, help) return CreateClientConVar(name, default, true, false, help) end
function GetConVar(name) return convars[name] end
function CV:GetName() return self.name end
function CV:GetDefault() return self.default end
function CV:GetString() return self.value end
function CV:GetFloat() return tonumber(self.value) or 0 end
function CV:GetInt() return math.floor(tonumber(self.value) or 0) end
function CV:GetBool() return (tonumber(self.value) or 0) ~= 0 end
function CV:SetString(v) v = tostring(v); if self.value ~= v then self.value = v; save_convars() end end
function CV:SetFloat(v) self:SetString(tostring(v)) end
function CV:SetInt(v) self:SetString(tostring(math.floor(v))) end
function CV:SetBool(v) self:SetString(v and "1" or "0") end
concommand = { list = {} }
function concommand.Add(name, fn) concommand.list[name] = fn end
function RunConsoleCommand(name, ...)
  local args = { ... }
  if convars[name] then convars[name]:SetString(args[1] or ""); return end
  local fn = concommand.list[name]
  if fn then fn(nil, name, args, table.concat(args, " ")) end
end

-- ---- files ----
-- GMod's paths: "DATA" = the save folder; "GAME" = the game's folder; "LUA" = lua/ and gamemodes/
local function roots(where)
  if where == "DATA" or where == nil then return { "" } end
  if where == "LUA" or where == "lsv" or where == "LuaMenu" then return { "lua/", "gamemodes/" } end
  return { "" }
end
local function find_path(p, where)
  for _, r in ipairs(roots(where)) do
    if lfs.getInfo(r .. p) then return r .. p end
  end
end
file = {}
function file.Exists(p, where)
  if where == "GAME" and L.game_files and L.game_files[p] ~= nil then return L.game_files[p] end
  return find_path(p, where) ~= nil
end
function file.IsDir(p, where) local f = find_path(p, where); return f and lfs.getInfo(f).type == "directory" or false end
function file.Read(p, where) local f = find_path(p, where); if not f then return nil end; return (lfs.read(f)) end
function file.Write(p, s) local d = p:match("^(.*)/[^/]*$"); if d then lfs.createDirectory(d) end; lfs.write(p, s) end
function file.Append(p, s) lfs.append(p, s) end
function file.CreateDir(p) lfs.createDirectory(p) end
function file.Delete(p) lfs.remove(p) end
function file.Find(pattern, where)
  local dir, mask = pattern:match("^(.*)/([^/]*)$")
  if not dir then dir, mask = "", pattern end
  local lua = "^" .. mask:gsub("[%.%-%+%(%)%[%]%^%$%%]", "%%%0"):gsub("%*", ".*") .. "$"
  local files, dirs, seen = {}, {}, {}
  for _, r in ipairs(roots(where)) do
    local full = r .. dir
    if lfs.getInfo(full, "directory") then
      for _, name in ipairs(lfs.getDirectoryItems(full)) do
        if name:match(lua) and not seen[name] then
          seen[name] = true
          if lfs.getInfo(full .. "/" .. name, "directory") then dirs[#dirs + 1] = name else files[#files + 1] = name end
        end
      end
    end
  end
  table.sort(files); table.sort(dirs)
  return files, dirs
end
local FO = {}
FO.__index = FO
function file.Open(p, mode, where)
  if mode:find("w") then
    local d = p:match("^(.*)/[^/]*$"); if d then lfs.createDirectory(d) end
    return setmetatable({ path = p, out = {}, mode = mode }, FO)
  end
  local f = find_path(p, where)
  if not f then return nil end
  return setmetatable({ data = lfs.read(f) or "", pos = 1, mode = mode }, FO)
end
function FO:Size() return self.data and #self.data or 0 end
function FO:Read(n) local s = self.data:sub(self.pos, self.pos + (n or #self.data) - 1); self.pos = self.pos + #s; return s end
function FO:Write(s) self.out[#self.out + 1] = s end
function FO:Close() if self.out then lfs.write(self.path, table.concat(self.out)) end end

-- ---- downloads (worker threads: game/love/net.lua) ----
http = {}
function http.Fetch(url, ok, fail, headers)
  net.platform.http_get(url, function(body) if ok then ok(body, #body, {}, 200) end end,
    function(e) if fail then fail(e) end end, headers and headers.Range)
end

-- GMod's HTTP{ url, method, body, type, headers, success = fn(code, body, headers), failed = fn(reason) }
function HTTP(t)
  local h = {}
  for k, v in pairs(t.headers or {}) do h[k] = v end
  if t.body and t.type then h["Content-Type"] = t.type end
  net.platform.request({ url = t.url, method = t.method or "GET", body = t.body, headers = h },
    function(body, code) if t.success then t.success(code or 200, body, {}) end end,
    function(e) if t.failed then t.failed(e) end end)
  return true
end

-- ---- the gamemode's files ----
GM = GM or { FolderName = "tinyatlas", Name = "Tiny Atlas" }
local GMDIR = "gamemodes/tinyatlas/gamemode/"
local current = { GMDIR }
-- the LÖVE side of a few GMod-only files
local REPLACE = { ["thirdparty/omniplay_bridge.lua"] = function() OmniPlay = require("omniplay_api"); return OmniPlay end }
function include(p)
  for k, fn in pairs(REPLACE) do if p:sub(-#k) == k then return fn() end end
  local tries = { current[#current] .. p, GMDIR .. p, "gamemodes/" .. p, "lua/" .. p }
  for _, f in ipairs(tries) do
    if lfs.getInfo(f, "file") then
      local chunk, err = lfs.load(f)
      if not chunk then error(err, 2) end
      current[#current + 1] = f:match("^(.*/)") or ""
      local res = { pcall(chunk) }
      table.remove(current)
      if not res[1] then error(res[2], 0) end
      return unpack(res, 2)
    end
  end
  error("include: no file " .. p, 2)
end
function AddCSLuaFile() end
function FindMetaTable() return {} end
function LocalPlayer() return L.player end
L.player = setmetatable({}, { __index = function() return function() end end })
resource = { AddFile = function() end }
util = { AddNetworkString = function() end }
chat = { AddText = function(...) end }
-- the GMod net library: one player, nothing to send to
net_gmod = {}
for _, k in ipairs({ "Start", "WriteBool", "WriteFloat", "WriteUInt", "WriteString", "WriteTable", "SendToServer", "Receive", "Send" }) do
  net_gmod[k] = function() end
end

-- ---- input: GMod's key numbers, LÖVE's key names ----
local KEYMAP = {
  W = "w", A = "a", S = "s", D = "d", B = "b", LSHIFT = "lshift", RSHIFT = "rshift", UP = "up", DOWN = "down",
  LEFT = "left", RIGHT = "right", ENTER = "return", PAD_ENTER = "kpenter", SPACE = "space", BACKSPACE = "backspace",
  TAB = "tab", ESCAPE = "escape", PERIOD = ".", COMMA = ",", MINUS = "-", PAD_DECIMAL = "kp.", PAD_MINUS = "kp-",
  APOSTROPHE = "'", LCONTROL = "lctrl", RCONTROL = "rctrl",
}
for i = 0, 9 do KEYMAP[tostring(i)] = tostring(i); KEYMAP["PAD_" .. i] = "kp" .. i end
for c = string.byte("A"), string.byte("Z") do local ch = string.char(c); KEYMAP[ch] = ch:lower() end
local codes, n = {}, 1
for name, key in pairs(KEYMAP) do _G["KEY_" .. name] = n; codes[n] = key; n = n + 1 end
MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE = 107, 108, 109
input = {}
-- (test runs press keys and move the mouse through L.fake: keys = { [code] = true }, mouse = { x, y, down })
L.fake = { keys = {} }
function input.IsKeyDown(code)
  if L.fake.keys[code] then return true end
  local k = codes[code]; return k ~= nil and love.keyboard.isDown(k)
end
function input.IsMouseDown(b)
  if L.fake.mouse then return b == MOUSE_LEFT and L.fake.mouse.down == true end
  return love.mouse.isDown(b == MOUSE_LEFT and 1 or b == MOUSE_RIGHT and 2 or 3)
end
function input.GetCursorPos()
  if L.fake.mouse then return L.fake.mouse.x, L.fake.mouse.y end
  return love.mouse.getPosition()
end
gui = {}
function gui.EnableScreenClicker(on) love.mouse.setVisible(on and true or false) end
function gui.MousePos() return love.mouse.getPosition() end

-- ---- the frame: GMod's order of hooks ----
function L.update(dt)
  L.dt = dt
  L.frame = L.frame + 1
  net.update(print)
  if TINYATLAS_LOVE.playit then TINYATLAS_LOVE.playit.update() end
  run_timers()
  hook.Run("Think")
end
function L.keypressed(key)
  if key == "escape" then hook.Run("OnPauseMenuShow") end
end
function L.wheel(y)
  hook.Run("PlayerBindPress", L.player, y > 0 and "invprev" or "invnext", true)
end
function L.start()
  net.start()
  -- riding live with others: direct connections (ENet), made reachable through playit.gg when you host
  TINYATLAS_LOVE.link = require("link")
  TINYATLAS_LOVE.playit = require("playit")
end
function L.quit()
  if TINYATLAS_LOVE.playit then TINYATLAS_LOVE.playit.disable() end
  if TINYATLAS_LOVE.link then TINYATLAS_LOVE.link.stop() end
end

return L
