-- Riding live with other players. Each game sends where its rider is a few times a second to the others it is
-- connected to, and draws the riders it hears from (cl_others.lua). How the messages travel:
--   standalone: straight between games (TINYATLAS_LOVE.link, ENet); a game that hosts is reachable through
--               playit.gg (TINYATLAS_LOVE.playit); the online service tells games who is riding near them
--   GMod:       through the GMod server you are on (init.lua passes each player's messages to the others)
--   Live.riders   id -> { kind = "live", name, kit, route, s, speed, cadence, gx, gy, ... }
--   Live.addr()   your address for others (when hosting), Live.join(addr) connect to a rider's game
TinyAtlas.Live = TinyAtlas.Live or {}
local Live = TinyAtlas.Live
local V = TinyAtlas.View
local Ride = TinyAtlas.Ride
local O = TinyAtlas.Online
local RD = TinyAtlas.Rider
local json = O.json
Live.riders = Live.riders or {}
Live.SEND_EVERY = 0.25
Live.STALE = 6
Live.MAX_PEERS = 16
Live.PORT = 27630
local cv_host = CreateClientConVar("ta_host", "0", true, false, "Host: other riders can connect to you through playit.gg")
Live.cv_host = cv_host

-- ---- how messages travel ----
local T
if TINYATLAS_LOVE then
  T = TINYATLAS_LOVE.link
else
  -- GMod: through the server
  local inbox = {}
  T = {
    available = function() return true end,
    start = function() return true end,
    connect = function() end,
    send = function(text)
      net.Start("tinyatlas_live")
      net.WriteString(text)
      net.SendToServer()
    end,
    poll = function() local out = inbox; inbox = {}; return out end,
  }
  if net and net.Receive then
    net.Receive("tinyatlas_live", function()
      local from, text = net.ReadString(), net.ReadString()
      inbox[#inbox + 1] = { type = "receive", peer = "g" .. from, data = text }
    end)
  end
end
Live.T = T

function Live.start()
  if Live.started or not T or not T.available() then return end
  local ok, err = T.start(Live.PORT)
  Live.started = ok
  if not ok then print("[Tiny Atlas] riding live is off: " .. tostring(err)) end
end
function Live.playit() return TINYATLAS_LOVE and TINYATLAS_LOVE.playit end
function Live.addr()
  local P = Live.playit()
  return P and P.state == "ready" and P.addr or nil
end
-- hosting on / off (the setting): playit.gg makes our port reachable
function Live.host(on)
  local P = Live.playit()
  if not P then return end
  Live.start()
  if on and Live.started then P.enable(T.port or Live.PORT) elseif not on then P.disable() end
end
function Live.join(addr)
  Live.start()
  if Live.started and addr and addr ~= Live.addr() then return T.connect(addr) end
end

-- where you are, for the others
local function my_state()
  local st = Ride.state or {}
  local m = { i = O.id or O.key():sub(1, 8), n = O.my_name(), k = RD.kit_string(), v = math.floor((Ride.speed or 0) * 10) / 10,
    c = math.floor(st.cadence or 0), run = (st.kind == "treadmill" or st.kind == "footpod") or nil }
  if V.mode == "ride" and V.route_id then m.r, m.s = V.route_id, math.floor((V.s or 0) * 10) / 10 end
  if V.W and V.x then
    m.gx, m.gy = V.W:global_of_metres(V.x, V.y)
    m.fx, m.fy = math.floor((V.fx or 1) * 100) / 100, math.floor((V.fy or 0) * 100) / 100
  end
  return m
end

local send_t, look_t = 0, 0
function Live.riding() return V.on and V.phase == "riding" and not V.preview and (Ride.mode == "ride" or Ride.mode == "paused") end

function Live.update(dt)
  if not T or not O.enabled() then return end
  local now = RealTime()
  -- messages in
  for _, ev in ipairs(T.poll and T.poll() or {}) do
    if ev.type == "receive" and ev.data then
      local ok, m = pcall(json.decode, ev.data)
      if ok and type(m) == "table" and m.i and m.i ~= (O.id or "") then
        local e = Live.riders[ev.peer]
        if not e then
          e = { kind = "live", anim = RD.new_anim(), peer = ev.peer }
          Live.riders[ev.peer] = e
        end
        e.id, e.name = tostring(m.i), tostring(m.n or "Rider"):sub(1, 24)
        if e.kit_str ~= m.k then e.kit_str, e.kit = m.k, RD.kit_from_string(m.k) end
        e.route, e.s0, e.speed, e.cadence, e.running = m.r, tonumber(m.s), tonumber(m.v) or 0, tonumber(m.c) or 0, m.run
        e.gx, e.gy, e.fx, e.fy = tonumber(m.gx), tonumber(m.gy), tonumber(m.fx), tonumber(m.fy)
        e.heard = now
      end
    elseif ev.type == "disconnect" then
      Live.riders[ev.peer] = nil
    end
  end
  for id, e in pairs(Live.riders) do
    if now - (e.heard or 0) > Live.STALE then Live.riders[id] = nil
    else
      -- between messages: carried on at their speed
      if e.s0 then e.s = e.s0 + (e.speed or 0) * (now - e.heard) end
      RD.update(dt, { speed = e.speed or 0, cadence = (e.speed or 0) > 0.3 and e.cadence or 0 }, e.anim)
    end
  end
  if not Live.riding() then return end
  -- messages out
  send_t = send_t - dt
  if send_t <= 0 then
    send_t = Live.SEND_EVERY
    local ok, text = pcall(json.encode, my_state())
    if ok then T.send(text) end
  end
  -- the riders the online service found near you: connect to the ones you can reach
  look_t = look_t - dt
  if look_t <= 0 and TINYATLAS_LOVE then
    look_t = 2
    local n = 0
    for _ in pairs(T.peers_list and T.peers_list() or {}) do n = n + 1 end
    for _, r in ipairs(O.riders or {}) do
      if n >= Live.MAX_PEERS then break end
      if r.addr and r.addr ~= Live.addr() then
        local connected = false
        for _, e in pairs(Live.riders) do if e.id == r.id then connected = true end end
        if not connected then Live.join(r.addr); n = n + 1 end
      end
    end
  end
end

-- ---- telling the online service where you ride (once a minute), so others can find you ----
local was_riding = false
hook.Add("Think", "TinyAtlas_Presence", function()
  if not O.enabled() then return end
  local riding = Live.riding()
  if riding and (not was_riding or RealTime() >= O.next_presence) then
    local body = { riding = true, addr = Live.addr() }
    if V.mode == "ride" then
      body.route, body.route_name = V.route_id, V.route_title
    elseif V.W and V.x then
      -- roam: the rough area only, and not until you are a kilometre from where you started (your home, maybe)
      local d = math.sqrt((V.x or 0) ^ 2 + (V.y or 0) ^ 2)
      body.roam = true
      if d > 1000 then
        local lat, lon = V.W:latlon_of_global(V.W:global_of_metres(V.x, V.y))
        body.lat, body.lon = math.floor(lat * 100) / 100, math.floor(lon * 100) / 100
      end
    end
    O.presence(body)
  elseif not riding and was_riding then
    O.presence({ riding = false })
  end
  was_riding = riding
end)

hook.Add("InitPostEntity", "TinyAtlas_Live", function()
  if not O.enabled() then return end
  Live.start()
  if cv_host:GetBool() then Live.host(true) end
end)
