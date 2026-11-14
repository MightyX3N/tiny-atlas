-- Runs OmniPlay's own device code (the same devices.lua, bt/win.lua, bt/fake.lua and settings.lua
-- the OmniPlay app uses, unchanged) inside the game. The game talks to it only through the
-- functions at the bottom; everything it gets back is plain numbers, strings and arrays.
--
-- Those files were written for LÖVE, so this sets up the few love.* calls they make.

local B = {}
local now, os_name, exe_dir, save_dir = 0, "Linux", ".", "."

love = {
  timer = { getTime = function() return now end },
  system = { getOS = function() return os_name end },
  math = { random = math.random },
  filesystem = {
    getSourceBaseDirectory = function() return exe_dir end,
    getSource = function() return exe_dir end,
    read = function(name)
      local f = io.open(save_dir .. "/" .. name, "rb")
      if not f then return nil end
      local s = f:read("*a"); f:close(); return s
    end,
    write = function(name, s)
      local f = io.open(save_dir .. "/" .. name, "wb")
      if not f then return false end
      f:write(s); f:close(); return true
    end,
  },
}

local sdk, op, devices, settings, bt, bt_err, fake
local events = {}

-- fake: pretend devices (for testing without hardware); os: "Windows" etc.
function B.init(use_fake, os_, exe, save)
  os_name, exe_dir, save_dir, fake = os_, exe, save, use_fake
  math.randomseed(os.time())
  sdk = require("omniplay")
  settings = require("settings")
  settings.load()
  devices = require("devices")
  if fake then bt = require("bt.fake").load(sdk)
  else bt, bt_err = require("bt.win").load() end
  op = sdk.new({
    bytes_out = "table",
    send = function(id, char, bytes) devices.send(id, char, bytes) end,
    on_event = function(name, value) events[#events + 1] = name .. (value and (":" .. tostring(value)) or "") end,
  })
  settings.apply(op)
  devices.init(bt, op, sdk, settings)
  if bt then devices.reconnect_remembered() end
  return { ok = bt ~= nil, err = bt_err or "" }
end

function B.update(dt, t)
  now = t
  devices.update(dt)
end

function B.scan(on) devices.scan(on) end

-- nearby fitness devices: array of {name, addr, rssi}
function B.nearby()
  local t = {}
  for _, d in ipairs(devices.nearby(false)) do
    if not devices.conns[d.addr] then t[#t + 1] = { name = d.name, addr = d.addr, rssi = d.rssi or -100 } end
  end
  return t
end

function B.connect(addr, name) devices.connect({ addr = addr, name = name }) end

function B.forget(addr)
  devices.disconnect(addr)
  settings.forget(addr)
end

-- connections: array of {addr, name, kind, label, state, hint}
function B.connections()
  local t = {}
  for _, c in ipairs(devices.list()) do
    t[#t + 1] = { addr = c.addr, name = c.name or "", kind = c.kind or "", label = devices.label(c.kind),
      state = c.state or "", hint = c.hint or "" }
  end
  return t
end

-- the player's numbers; -1 where unknown
function B.values()
  local v = op:values()
  return {
    speed_kmh = v.speed_kmh or -1, cadence = v.cadence or -1, power = v.power or -1, hr = v.hr or -1,
    moving = v.moving and true or false, gait = v.gait or "stopped", kind = v.kind or "",
    connected = devices.any_connected(),
  }
end

function B.set_grade(pct) op:set_grade(pct) end
function B.walk_factor(pct) return sdk.walk_factor(pct) end

function B.allow_hills(on)
  settings.data.allow_hills = on and true or false
  settings.save()
  settings.apply(op)
end
function B.hills_allowed() return settings.data.allow_hills and true or false end

-- pretend devices only: 0 stopped, 1 easy, 2 steady, 3 sprint
function B.fake_effort(n) if fake and bt then bt.effort = n end end
function B.is_fake() return fake and true or false end

function B.take_events()
  local e = events
  events = {}
  return e
end

function B.shutdown()
  if not devices then return end
  for _, c in ipairs(devices.list()) do devices.disconnect(c.addr) end
  devices.scan(false)
end

return B
