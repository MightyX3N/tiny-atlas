-- A fake Garry's Mod client: just enough of GMod's API to run the gamemode's real Lua files outside
-- the game. Files under "DATA" go to a temp folder, timers and hooks are ticked by the test, keys are
-- set by the test. Usage: local gm = dofile("fakegmod.lua")(data_dir, gamemode_dir)
return function(DATA, GMDIR)
  local F = { t = 0, keys = {}, timers = {}, hooks = {}, nets = {}, printed = {}, DATA = DATA, GMDIR = GMDIR }
  CLIENT, SERVER = true, false
  KEY_W, KEY_S, KEY_LSHIFT = 33, 29, 79

  -- ---- JSON (GMod's util.TableToJSON / JSONToTable) ----
  local function enc(v)
    local t = type(v)
    if t == "nil" then return "null" elseif t == "boolean" then return tostring(v)
    elseif t == "number" then return (v == math.floor(v) and string.format("%d", v)) or string.format("%.6g", v)
    elseif t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    else
      local n = 0; for _ in pairs(v) do n = n + 1 end
      if n == #v and n > 0 then local o = {}; for i = 1, n do o[i] = enc(v[i]) end; return "[" .. table.concat(o, ",") .. "]" end
      local o = {}; for k, x in pairs(v) do o[#o + 1] = enc(tostring(k)) .. ":" .. enc(x) end
      return "{" .. table.concat(o, ",") .. "}"
    end
  end
  local function dec(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local val
    local function str()
      local o = {}; i = i + 1
      while true do
        local c = s:sub(i, i)
        if c == '"' then i = i + 1; return table.concat(o) end
        if c == "\\" then
          local e = s:sub(i + 1, i + 1)
          if e == "u" then o[#o + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16) % 256); i = i + 6
          else o[#o + 1] = ({ n = "\n", t = "\t", r = "\r" })[e] or e; i = i + 2 end
        else o[#o + 1] = c; i = i + 1 end
      end
    end
    function val()
      ws(); local c = s:sub(i, i)
      if c == "{" then
        local o = {}; i = i + 1; ws()
        if s:sub(i, i) == "}" then i = i + 1; return o end
        while true do ws(); local k = str(); ws(); i = i + 1; o[k] = val(); ws()
          local d = s:sub(i, i); i = i + 1; if d == "}" then return o end end
      elseif c == "[" then
        local o = {}; i = i + 1; ws()
        if s:sub(i, i) == "]" then i = i + 1; return o end
        while true do o[#o + 1] = val(); ws(); local d = s:sub(i, i); i = i + 1; if d == "]" then return o end end
      elseif c == '"' then return str()
      elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
      elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
      elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
      else local j = s:find("[,%]} \t\r\n]", i) or #s + 1; local n = tonumber(s:sub(i, j - 1)); i = j; return n end
    end
    local ok, r = pcall(val); return ok and r or nil
  end
  F.enc, F.dec = enc, dec

  util = {
    TableToJSON = enc, JSONToTable = function(s) return type(s) == "string" and dec(s) or nil end,
    IsBinaryModuleInstalled = function() return false end,    -- no gmcl_omniplay: the data-folder fallback
    AddNetworkString = function() end,
  }
  file = {
    CreateDir = function(p) os.execute('mkdir -p "' .. DATA .. "/" .. p .. '"') end,
    Read = function(p, where) local f = io.open(DATA .. "/" .. p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end,
    Write = function(p, s) local f = assert(io.open(DATA .. "/" .. p, "wb")); f:write(s); f:close() end,
  }
  timer = { Create = function(name, delay, reps, fn) F.timers[name] = { delay = delay, fn = fn, next = F.t + delay } end, Remove = function(n) F.timers[n] = nil end }
  hook = {
    Add = function(ev, id, fn) F.hooks[ev] = F.hooks[ev] or {}; F.hooks[ev][id] = fn end,
    Run = function(ev, ...) for _, fn in pairs(F.hooks[ev] or {}) do local r = fn(...); if r ~= nil then return r end end end,
  }
  net = {
    Start = function(n) F.net_msg = { name = n } end, WriteBool = function() end, WriteFloat = function() end,
    WriteUInt = function() end, WriteString = function(t) F.net_msg.text = t end,
    SendToServer = function() F.nets[#F.nets + 1] = F.net_msg end,
    Receive = function(name, fn) F.net_recv = F.net_recv or {}; F.net_recv[name] = fn end,
    ReadString = function() return table.remove(F.net_in or {}, 1) or "" end,
  }
  concommand = { Add = function() end }
  input = { IsKeyDown = function(k) return F.keys[k] == true end,
    IsMouseDown = function(b) return F.mouse_down == true end,
    GetCursorPos = function() return F.mouse_x or 0, F.mouse_y or 0 end }
  MOUSE_LEFT, MOUSE_RIGHT = 107, 108
  -- every key the game reads (numbers as GMod's)
  local KN = { "UP", "DOWN", "LEFT", "RIGHT", "ENTER", "PAD_ENTER", "SPACE", "BACKSPACE", "TAB", "ESCAPE", "W", "A", "S",
    "D", "B", "LSHIFT", "RSHIFT", "PERIOD", "COMMA", "MINUS", "PAD_DECIMAL", "PAD_MINUS", "APOSTROPHE" }
  for i = 0, 9 do KN[#KN + 1] = tostring(i); KN[#KN + 1] = "PAD_" .. i end
  for c = string.byte("A"), string.byte("Z") do KN[#KN + 1] = string.char(c) end
  local nk = 200
  for _, k in ipairs(KN) do if _G["KEY_" .. k] == nil then nk = nk + 1; _G["KEY_" .. k] = nk end end
  function RealTime() return F.t end
  function CurTime() return F.t end
  function FrameTime() return F.dt or 0.05 end
  function LocalPlayer() return {} end
  function IsValid(x) return x ~= nil end
  function AddCSLuaFile() end
  function FindMetaTable() return {} end
  math.Clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
  string.sub = string.sub
  function include(p) local f = assert(loadfile(GMDIR .. "/" .. p)); return f() end
  GM = {}

  -- GMod's HTTP{}: done with curl on the next tick (answers come back a frame later, like in the game)
  F.http = {}
  F.http_log = {}
  function HTTP(t)
    F.http[#F.http + 1] = t
    return true
  end
  local function run_http(t)
    local tmp = os.tmpname()
    local hdr = t.type and (" -H 'Content-Type: " .. t.type .. "'") or ""
    if t.body then local f = io.open(tmp, "wb"); f:write(t.body); f:close(); hdr = hdr .. " --data-binary @" .. tmp end
    local p = io.popen("curl -s -m 20 -X " .. (t.method or "GET") .. hdr .. " -w '\n%{http_code}' '" .. t.url .. "'")
    local all = p:read("*a"); p:close(); os.remove(tmp)
    local body, code = all:match("^(.*)\n(%d+)$")
    F.http_log[#F.http_log + 1] = { url = t.url, code = tonumber(code) }
    if code and tonumber(code) > 0 then if t.success then t.success(tonumber(code), body, {}) end
    elseif t.failed then t.failed("unsuccessful") end
  end
  function F.tick(dt)
    F.dt = dt; F.t = F.t + dt
    local q = F.http; F.http = {}
    for _, t in ipairs(q) do run_http(t) end
    for _, tm in pairs(F.timers) do
      while F.t >= tm.next do tm.next = tm.next + tm.delay; tm.fn() end
    end
    hook.Run("Think")
  end
  return F
end
