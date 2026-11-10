-- Hosting through playit.gg (open source, BSD 2-Clause: https://github.com/playit-cloud/playit-agent): makes the
-- port your game listens on (link.lua) reachable from the internet, so other riders can connect to you without
-- opening ports on your router. Turned on in the game's settings; the first time it asks you (in your browser) to
-- add it to a free playit account. Everything else happens here:
--   1. the playit program (playitd) is downloaded from playit's GitHub releases (once, into the save folder)
--   2. claim: a code, the page https://playit.gg/claim/<code> opened, and the key fetched once you approve it
--   3. playitd started in the background with that key; a UDP tunnel to our port made through playit's API
--   4. the tunnel's public address read back: that is what other riders connect to
--   P.enable(port), P.disable(), P.update() (every frame); P.state: off | download | claim | starting | ready |
--   failed | unsupported; P.addr (when ready), P.claim_url, P.err
local P = { state = "off" }
local net = require("net")
local lfs = love.filesystem
local json = lfs.load("gamemodes/tinyatlas/gamemode/thirdparty/json.lua")()
local ffi = require("ffi")
P.API = "https://api.playit.gg"
P.RELEASE = "https://github.com/playit-cloud/playit-agent/releases/download/v2.0.2/"
P.DIR = "playit"
local SECRET = P.DIR .. "/secret.txt"

-- which playit program for this computer
local function asset()
  if ffi.os == "Windows" then return ffi.arch == "x64" and "playitd-windows-x86_64-signed.exe" or "playitd-windows-x86-signed.exe", "playitd.exe" end
  if ffi.os == "Linux" then return ffi.arch == "arm64" and "playit-linux-aarch64" or "playit-linux-amd64", "playitd" end
  return nil
end

local function api(path, body, cb)
  local h = { ["Content-Type"] = "application/json" }
  if P.secret then h["Authorization"] = "Agent-Key " .. P.secret end
  net.platform.request({ url = P.API .. path, method = "POST", body = json.encode(body or {}), headers = h },
    function(text, code)
      local ok, t = pcall(json.decode, text or "")
      if ok and type(t) == "table" then cb(t.status == "success" and t.data, t) else cb(nil, { status = "error", data = "answer " .. tostring(code) }) end
    end,
    function(e) cb(nil, { status = "error", data = tostring(e) }) end)
end
local function fail(msg) P.state, P.err = "failed", msg; print("[Tiny Atlas] playit: " .. msg) end
local function later(sec, fn) P.timers[#P.timers + 1] = { t = love.timer.getTime() + sec, fn = fn } end

-- ---- the program: run in the background, stopped when the game closes ----
local W
if ffi.os == "Windows" then
  ffi.cdef [[
    typedef struct { uint32_t cb; void *a, *b, *c; uint32_t x, y, w, h, cx, cy, fill, flags; uint16_t show, r2; void *r3, *in, *out, *err; } TA_STARTUPINFOW;
    typedef struct { void *process, *thread; uint32_t pid, tid; } TA_PROCINFO;
    int CreateProcessW(const uint16_t *app, uint16_t *cmd, void *pa, void *ta, int inherit, uint32_t flags, void *env,
      const uint16_t *dir, TA_STARTUPINFOW *si, TA_PROCINFO *pi);
    int TerminateProcess(void *h, unsigned int code);
    int CloseHandle(void *h);
    int MultiByteToWideChar(unsigned int cp, uint32_t flags, const char *s, int n, uint16_t *out, int outn);
  ]]
  W = ffi.C
end
local function wide(s)
  local n = W.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
  local b = ffi.new("uint16_t[?]", n)
  W.MultiByteToWideChar(65001, 0, s, -1, b, n)
  return b
end
local function run(exe, args, log)
  if ffi.os == "Windows" then
    local cmd = '"' .. exe .. '" ' .. args
    local si = ffi.new("TA_STARTUPINFOW"); si.cb = ffi.sizeof(si)
    local pi = ffi.new("TA_PROCINFO")
    -- CREATE_NO_WINDOW: no console window popping up
    if W.CreateProcessW(nil, wide(cmd), nil, nil, 0, 0x08000000, nil, nil, si, pi) == 0 then return nil end
    W.CloseHandle(pi.thread)
    return { handle = pi.process }
  end
  local pidf = os.tmpname()
  os.execute(string.format("chmod +x '%s' && nohup '%s' %s > '%s' 2>&1 & echo $! > '%s'", exe, exe, args, log, pidf))
  local f = io.open(pidf); local pid = f and tonumber(f:read("*l")); if f then f:close() end
  os.remove(pidf)
  return pid and { pid = pid }
end
local function kill(p)
  if not p then return end
  if p.handle then W.TerminateProcess(p.handle, 0); W.CloseHandle(p.handle)
  elseif p.pid then os.execute("kill " .. p.pid .. " 2>/dev/null") end
end

-- ---- steps ----
local start_agent, find_tunnel
local function claim()
  local code = ""
  for _ = 1, 10 do code = code .. string.format("%x", love.math.random(0, 15)) end
  P.state, P.claim_url = "claim", "https://playit.gg/claim/" .. code
  love.system.openURL(P.claim_url)
  local function poll()
    if P.state ~= "claim" then return end
    api("/claim/setup", { code = code, agent_type = "self-managed", version = "Tiny Atlas" }, function(st, raw)
      if P.state ~= "claim" then return end
      if st == "UserAccepted" then
        api("/claim/exchange", { code = code }, function(d)
          if d and d.secret_key then
            P.secret = d.secret_key
            lfs.createDirectory(P.DIR)
            lfs.write(SECRET, P.secret)
            start_agent()
          else later(2, poll) end
        end)
      elseif st == "UserRejected" then fail("the playit page said no")
      else later(2, poll) end
    end)
  end
  poll()
end

function start_agent()
  local name, local_name = asset()
  local real = lfs.getSaveDirectory() .. "/" .. P.DIR .. "/" .. local_name
  local function go()
    P.state = "starting"
    local sock = ffi.os == "Windows" and "\\\\.\\pipe\\tinyatlas-playit" or (os.tmpname() .. "-playit.sock")
    P.proc = run(real, string.format('--secret "%s" --socket-path "%s"', P.secret, sock),
      lfs.getSaveDirectory() .. "/" .. P.DIR .. "/playit.log")
    if not P.proc then return fail("could not start playit") end
    find_tunnel()
  end
  if lfs.getInfo(P.DIR .. "/" .. local_name) then return go() end
  P.state = "download"
  net.platform.http_get(P.RELEASE .. name, function(body)
    if #body < 100000 then return fail("the playit download was not the program") end
    lfs.createDirectory(P.DIR)
    lfs.write(P.DIR .. "/" .. local_name, body)
    go()
  end, function(e) fail("could not download playit: " .. tostring(e)) end)
end

local created = false
function find_tunnel()
  if P.state ~= "starting" then return end
  api("/agents/rundata", {}, function(d, raw)
    if P.state ~= "starting" then return end
    if not d then
      local why = raw and raw.data
      if type(why) == "table" then why = json.encode(why) end
      if tostring(why):find("Auth") or tostring(why):find("Invalid") then
        lfs.remove(SECRET); P.secret = nil
        return fail("playit did not accept the saved key: turn hosting off and on to set it up again")
      end
      return later(3, find_tunnel)
    end
    for _, t in ipairs(d.tunnels or {}) do
      if t.proto == "udp" and tonumber(t.local_port) == P.port and t.assigned_domain and not t.disabled then
        P.addr = t.assigned_domain .. ":" .. tostring(t.port and t.port.from)
        P.state = "ready"
        print("[Tiny Atlas] playit: other riders can reach you at " .. P.addr)
        return
      end
    end
    if not created then
      created = true
      api("/tunnels/create", { name = "Tiny Atlas", tunnel_type = json.null or nil, port_type = "udp", port_count = 1,
        origin = { type = "agent", data = { agent_id = d.agent_id, local_ip = "127.0.0.1", local_port = P.port } },
        enabled = true }, function(ok, raw2)
          if not ok then
            local why = raw2 and raw2.data
            fail("playit could not make a tunnel: " .. (type(why) == "table" and json.encode(why) or tostring(why)))
          end
        end)
    end
    later(3, find_tunnel)
  end)
end

function P.enable(port)
  if P.state ~= "off" and P.state ~= "failed" then return end
  P.port, P.timers, P.err, created = port, {}, nil, false
  if not asset() then P.state = "unsupported"; P.err = "hosting through playit works on Windows and Linux"; return end
  P.secret = lfs.getInfo(SECRET) and (lfs.read(SECRET) or ""):match("^%s*(.-)%s*$") or nil
  if P.secret and #P.secret > 10 then start_agent() else P.secret = nil; claim() end
end
function P.disable()
  kill(P.proc)
  P.proc, P.state, P.addr, P.claim_url = nil, "off", nil, nil
end
function P.update()
  if not P.timers then return end
  local now = love.timer.getTime()
  for i = #P.timers, 1, -1 do
    local t = P.timers[i]
    if now >= t.t then table.remove(P.timers, i); t.fn() end
  end
end

return P
