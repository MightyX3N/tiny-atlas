-- The other riders on the road with you: ghosts (rides recorded by others, and your own best, played back from
-- the start with you), riders riding live with you right now (cl_live.lua), and the game's own computer riders
-- when a route has no ghosts yet. Also records your ride (once a second) as your ghost.
--   Others.start(route_id, source)   a ride begins: fetch its ghosts (or make computer riders)
--   Others.update(dt)                moves them along (with your ride's clock)
--   Others.draw(ctx)                 draws the near ones (cl_view.lua, inside the 3D camera)
--   Others.finish() -> result        your ride is over: your ghost kept, the ride sent to the leaderboard
--   Others.list                      { name, kind = "ghost" | "live" | "bot", s (metres along) or x, y, speed, ... }
TinyAtlas.Others = TinyAtlas.Others or {}
local OT = TinyAtlas.Others
local Ghost = include("core/ghost.lua")
local Bots = include("core/bots.lua")
OT.Ghost, OT.Bots = Ghost, Bots
OT.list = OT.list or {}
OT.MAX_DRAWN = 12              -- the nearest ones drawn
OT.DRAW_M = 160                -- and only this near
OT.BOTS = 4
OT.SIDES = { 1.1, -1.1, 2.1, -2.1, 0.6, -0.6, 1.6, -1.6 }

local V = TinyAtlas.View
local Ride = TinyAtlas.Ride
local O = TinyAtlas.Online
local RD = TinyAtlas.Rider

-- ---- your own ghosts, kept on your computer (data/tinyatlas/ghosts/<route>_<source>.txt): your best ride ----
local function own_path(rid, source) return "tinyatlas/ghosts/" .. rid .. "_" .. source .. ".txt" end
function OT.own_best(rid, source)
  local t = file.Read(own_path(rid, source), "DATA")
  if not t then return nil end
  local head, g = t:match("^(.-)\n(.*)$")
  local time = tonumber(head and head:match("time=([%d%.]+)"))
  return time and { time = time, ghost = g }
end
local function save_own(rid, source, time, text)
  file.CreateDir("tinyatlas/ghosts")
  file.Write(own_path(rid, source), string.format("time=%.1f\n", time) .. text)
end

local function add(e)
  e.anim = RD.new_anim()
  e.s, e.speed, e.cadence = e.s or 0, e.speed or 0, e.cadence or 0
  OT.list[#OT.list + 1] = e
  return e
end
local function add_ghost(name, kit, text, why, id)
  local g = Ghost.load(text)
  if not g then return end
  for _, e in ipairs(OT.list) do if e.kind == "ghost" and e.id == id then return end end
  return add({ kind = "ghost", name = name, kit = RD.kit_from_string(kit), g = g, why = why, id = id, time = g.time })
end
local function add_bots(rid)
  local base = tonumber(rid:sub(1, 7), 16) or 1
  for i = 1, OT.BOTS do
    local b = Bots.make(base + i * 7919)
    b.kit = RD.kit_from_string(tostring(b.kit_seed) .. "||" .. (1 + (base + i) % 6) .. "|" .. (1 + (base * i) % 7))
    b.s = -2 - i * 1.5                     -- lined up just behind the start
    b.id = "bot" .. i
    add(b)
  end
end

-- a ride on a route begins
function OT.start(rid, source)
  OT.list, OT.route, OT.source = {}, rid, source or "keys"
  OT.rec = Ghost.recorder()
  OT.state, OT.result = "fetching", nil
  OT.token = {}                          -- a later start makes this one's answers stale
  local token = OT.token
  -- your own best on this route, from your computer: always there, online or not
  local mine = rid and OT.own_best(rid, OT.source)
  if mine then add_ghost("Your best", RD.kit_string(), mine.ghost, "you", "own") end
  if not rid or not O or not O.enabled() then
    if not mine then add_bots(rid or "1") end
    OT.state = "offline"
    return
  end
  O.route(rid, OT.source, function(res)
    if OT.token ~= token then return end
    OT.info = res
    local want = 0
    for _, gm in ipairs(res and res.ghosts or {}) do
      if gm.player ~= O.id then
        want = want + 1
        O.ghost(gm.ride, function(g)
          if OT.token ~= token or not g then return end
          add_ghost(g.name, g.kit, g.ghost, gm.why, "ride" .. gm.ride)
        end)
      end
    end
    if want == 0 and not mine then add_bots(rid) end
    OT.state = res and "online" or "offline"
  end, true)
end
function OT.stop() OT.list, OT.route, OT.rec, OT.token = {}, nil, nil, {} end

-- ---- every frame ----
function OT.update(dt)
  local riding = Ride.mode == "ride"
  local t = Ride.stats and Ride.stats.time or 0
  if V.mode == "ride" and riding and OT.rec then
    OT.rec:add(t, Ride.s or 0, Ride.speed or 0, Ride.state and Ride.state.cadence or 0)
  end
  local R = V.mode == "ride" and V.R
  for _, e in ipairs(OT.list) do
    if e.kind == "ghost" then
      e.s, e.speed, e.cadence = e.g:at(t)
      e.finished = e.g:done(t)
    elseif e.kind == "bot" and R then
      if riding then
        local s = math.max(0, math.min(R.length, e.s))
        Bots.step(e, dt, R:grade(s), R:tag(s))
        if e.s >= R.length then e.s, e.v, e.cadence, e.finished = R.length, 0, 0, true end
      end
      e.speed = riding and (e.v or 0) or 0
    end
    RD.update(dt, { speed = e.speed or 0, cadence = (e.speed or 0) > 0.3 and e.cadence or 0 }, e.anim)
  end
  if TinyAtlas.Live then TinyAtlas.Live.update(dt) end
end

-- where a rider is in the world: x, y, z, fx, fy (nil if nowhere to draw)
function OT.where(e)
  local R = V.mode == "ride" and V.R
  local on_route = R and e.s and (e.kind ~= "live" or (e.route ~= nil and e.route == V.route_id))
  if on_route then
    local s = math.max(0, math.min(R.length, e.s or 0))
    local x, y, z = R:pos(s)
    local fx, fy = R:dir(s, 8)
    -- side by side, not inside each other: each keeps a little to one side
    local side = e.side or 0
    return x - fy * side, y + fx * side, z, fx, fy
  end
  if e.gx and V.W then
    local x, y = V.W:metres_of(e.gx, e.gy)
    local z = V.W:height_at(x, y)
    if not z then return nil end
    return x, y, z, e.fx or 1, e.fy or 0
  end
end

-- the near ones, nearest first (for drawing and the name tags)
function OT.near()
  local out = {}
  local live = TinyAtlas.Live and TinyAtlas.Live.riders or {}
  local all = {}
  for _, e in ipairs(OT.list) do all[#all + 1] = e end
  for _, e in pairs(live) do all[#all + 1] = e end
  local cam = V.cam
  for i, e in ipairs(all) do
    -- side by side: you ride in the middle of the road, the others to your left and right
    if e.side == nil then e.side = OT.SIDES[(i - 1) % #OT.SIDES + 1] end
    local x, y, z, fx, fy = OT.where(e)
    if x then
      local d = math.sqrt((x - V.x) ^ 2 + (y - V.y) ^ 2)
      -- not one right in front of the camera's lens (it would fill the screen)
      local near_cam = cam and ((x - cam.x) ^ 2 + (y - cam.y) ^ 2) < 2.5 * 2.5
      if d < OT.DRAW_M and not near_cam then out[#out + 1] = { e = e, d = d, x = x, y = y, z = z, fx = fx, fy = fy } end
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  while #out > OT.MAX_DRAWN do table.remove(out) end
  OT.shown = out
  return out
end

-- inside the 3D camera: ctx = { pack, O, U, mat = fn(kind, e) }
function OT.draw(ctx)
  local draws = 0
  for _, n in ipairs(OT.near()) do
    local e = n.e
    local grade = 0
    if V.mode == "ride" and V.R and e.s then grade = V.R:grade(math.max(0, math.min(V.R.length, e.s))) end
    draws = draws + RD.draw({ pack = ctx.pack, x = n.x, y = n.y, z = n.z, fx = n.fx, fy = n.fy, O = ctx.O, U = ctx.U,
      grade = grade, running = e.running, anim = e.anim, mat = function(kind) return ctx.mat(kind, e) end })
  end
  return draws
end

-- ---- your ride is over ----
function OT.finish()
  local st = Ride.stats or {}
  local rid, source = OT.route, OT.source
  local res = { route = rid, source = source }
  OT.result = res
  if not rid or not OT.rec or not V.R or (V.s or 0) < V.R.length - 1 then return res end
  OT.rec:add(st.time + 1, V.R.length, 0, 0)
  local text = OT.rec:text()
  local time = st.time
  local best = OT.own_best(rid, source)
  res.time, res.own_best = time, best and best.time
  if not best or time < best.time then save_own(rid, source, time, text); res.new_own_best = true end
  if O and O.enabled() then
    res.state = "sending"
    O.submit({ route = rid, source = source, time = math.floor(time + 0.5), length = V.R.length,
      avg_power = time > 0 and (st.energy or 0) / time or 0, kg = Ride.cv.weight:GetFloat(), ghost = text },
      function(r, err)
        if r then res.state, res.rank, res.riders, res.best = "sent", r.rank, r.riders, r.best
        else res.state, res.err = "failed", err end
      end)
  end
  return res
end
