-- Online: the game's side of the online service (online/ in the repo: a Cloudflare Worker). Everything here is
-- optional - with no service (or no internet) the game plays the same, without leaderboards, ghosts of others,
-- shared routes and friends.
--   O.call(name, body, cb(res, err))     any call; res is the answer (res.ok true) or nil
--   O.id, O.name                         your player ID (also your friend code) and name
--   O.route(route_id, source, cb)        the route's leaderboard, your place and its ghosts (cached a minute)
--   O.submit(ride, cb)                   a finished ride, with its ghost
--   O.presence()                         says where you ride (every minute while riding) -> O.riders, O.friends
TinyAtlas.Online = TinyAtlas.Online or {}
local O = TinyAtlas.Online
local json = include("thirdparty/json.lua")
O.json = json

local cv_on = CreateClientConVar("ta_online", "1", true, false, "Online features: leaderboards, ghosts, shared routes, friends")
local cv_url = CreateClientConVar("ta_online_url", "", true, false, "The online service's address")
local cv_name = CreateClientConVar("ta_name", "", true, false, "Your rider name")
local cv_visible = CreateClientConVar("ta_visible", "1", true, false, "Other riders can find you and ride with you")
O.cv = { on = cv_on, url = cv_url, name = cv_name, visible = cv_visible }
O.DEFAULT_URL = "https://tinyatlas.drgamingdk.workers.dev"      -- the online service (online/, deployed by GitHub Actions)
O.PRESENCE_EVERY = 60

function O.url()
  local u = cv_url:GetString()
  if u == "" then u = O.DEFAULT_URL end
  return (u:gsub("/+$", ""))
end
function O.enabled() return cv_on:GetBool() and O.url() ~= "" end

-- your secret key: made once, kept in the data folder; the service only ever sees it to work out your ID
local KEYFILE = "tinyatlas/online_key.txt"
function O.key()
  if O._key then return O._key end
  local k = file.Read(KEYFILE, "DATA")
  if not k or #k < 32 then
    local t = {}
    for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end
    -- mixed with the clock, in case the random numbers start the same way somewhere
    k = table.concat(t) .. string.format("%x", math.floor((SysTime() % 1) * 1e9))
    file.CreateDir("tinyatlas")
    file.Write(KEYFILE, k)
  end
  O._key = k:match("^%s*(.-)%s*$")
  return O._key
end
function O.my_name()
  local n = cv_name:GetString()
  if n ~= "" then return n end
  local ply = LocalPlayer and LocalPlayer()
  if ply and IsValid and IsValid(ply) and ply.Nick then return ply:Nick() end
  return "Rider"
end

O.busy, O.last_error = 0, nil
function O.call(name, body, cb)
  if not O.enabled() then if cb then cb(nil, "offline") end return end
  body = body or {}
  body.key = O.key()
  body.name = body.name or O.my_name()
  body.kit = body.kit or (TinyAtlas.Rider and TinyAtlas.Rider.kit_string and TinyAtlas.Rider.kit_string()) or ""
  local ok, text = pcall(json.encode, body)
  if not ok then if cb then cb(nil, "could not send: " .. tostring(text)) end return end
  O.busy = O.busy + 1
  HTTP({
    url = O.url() .. "/v1/" .. name, method = "POST", body = text, type = "application/json",
    success = function(code, res)
      O.busy = O.busy - 1
      local okd, t = pcall(json.decode, res or "")
      if okd and type(t) == "table" then
        if t.ok then O.online, O.last_error = true, nil else O.last_error = t.error end
        if cb then cb(t.ok and t or nil, not t.ok and (t.error or ("error " .. tostring(code))) or nil) end
      else
        O.last_error = "the service answered " .. tostring(code)
        if cb then cb(nil, O.last_error) end
      end
    end,
    failed = function(err)
      O.busy = O.busy - 1
      O.online, O.last_error = false, "can't reach the online service"
      if cb then cb(nil, O.last_error) end
    end,
  })
end

function O.hello()
  O.call("hello", {}, function(res) if res then O.id, O.hello_t = res.id, RealTime() end end)
end

-- ---- routes: leaderboards and ghosts ----
O.routes = O.routes or {}             -- route id .. source -> { t, res, waiting }
function O.route(rid, source, cb, fresh)
  if not rid then return nil end
  local key = rid .. ":" .. (source or "keys")
  local e = O.routes[key]
  local now = RealTime()
  if e and not fresh and (e.waiting or now - e.t < 60) then
    if cb then if e.res then cb(e.res) else e.cbs[#e.cbs + 1] = cb end end
    return e.res
  end
  e = e or { cbs = {} }
  e.waiting, e.t = true, now
  if cb then e.cbs[#e.cbs + 1] = cb end
  O.routes[key] = e
  O.call("route", { route = rid, source = source }, function(res)
    e.waiting = false
    if res then e.res = res end
    local cbs = e.cbs; e.cbs = {}
    for _, f in ipairs(cbs) do f(res) end
  end)
  return e.res
end
O.ghosts = O.ghosts or {}             -- ride id -> answer (with .ghost text)
function O.ghost(ride, cb)
  local g = O.ghosts[ride]
  if g then return cb(g) end
  O.call("ghost", { ride = ride }, function(res) if res then O.ghosts[ride] = res end cb(res) end)
end

function O.submit(r, cb)
  O.call("ride", r, function(res, err)
    if res then O.routes[r.route .. ":" .. r.source] = nil end
    if cb then cb(res, err) end
  end)
end

-- ---- presence: where you ride, and who you can ride with ----
O.riders, O.friends = O.riders or {}, O.friends or {}
O.next_presence = 0
function O.presence(state)
  O.next_presence = RealTime() + O.PRESENCE_EVERY
  local body = state or { riding = false }
  body.visible = cv_visible:GetBool()
  body.game = TINYATLAS_LOVE and "love" or "gmod"
  O.call("presence", body, function(res)
    if res then O.riders, O.friends, O.online_count = res.riders or {}, res.friends or {}, res.online end
  end)
end
function O.friends_now(cb)
  O.call("friends", {}, function(res) if res then O.friends = res.friends or {} end if cb then cb(res) end end)
end

hook.Add("InitPostEntity", "TinyAtlas_Online", function() if O.enabled() then O.hello() end end)
