-- The ride screen: the road ahead's height profile across the top (the next few kilometres, coloured by steepness,
-- with the whole route as a thin strip under it), the grade as a road sign, the bike computer (an LCD: speed,
-- power, cadence, heart rate, time) and a round map of the roads around you, turning with you.
TinyAtlas.HUD = TinyAtlas.HUD or {}
local HUD = TinyAtlas.HUD
local UI = TinyAtlas.UI
local V = TinyAtlas.View
local Ride = TinyAtlas.Ride
local C = UI.C
local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
HUD.AHEAD = 3000                  -- metres of road ahead in the top profile
HUD.MAP_M = 300                   -- metres from the middle of the map to its edge
HUD.MARK = Color(255, 138, 122)

-- heights along the route from the profile (before the world has them) or the route itself
local function height_fn(prof)
  local j = 1
  return function(d)
    if d <= prof[1][1] then return prof[1][2] end
    if d >= prof[#prof][1] then return prof[#prof][2] end
    while j > 1 and prof[j][1] > d do j = j - 1 end
    while j < #prof - 1 and prof[j + 1][1] < d do j = j + 1 end
    local a, b = prof[j], prof[j + 1]
    return a[2] + (b[2] - a[2]) * ((d - a[1]) / max(1, b[1] - a[1]))
  end
end

-- the top of the climb you are on: how far, how much higher (nil when not climbing)
local function climb_left(at, s, last)
  if at(s + 200) - at(s) < 4 then return nil end
  local top_d, top_e, d = s, at(s), s
  while d < last do
    d = d + 50
    local h = at(d)
    if h > top_e then top_d, top_e = d, h elseif top_e - h > 8 then break end
  end
  return top_d - s, top_e - at(s)
end

local function profile_top(W)
  local info = V.route_name and TinyAtlas.Screens.routes[V.route_name]
  local prof = info and info.sum and info.sum.heights and info.sum.profile
  if HUD.at_prof ~= prof then HUD.at_prof, HUD.at = prof, prof and height_fn(prof) end
  local s, L = V.s or 0, V.R.length
  local px, py, pw, ph = 10, 8, W - 20, 40
  UI.panel(px, py, pw, ph + 8)
  if prof then
    local at = HUD.at
    -- the road ahead: from a little behind you to AHEAD in front, resampled
    local a = max(0, s - HUD.AHEAD * 0.1)
    local b = min(L, a + HUD.AHEAD)
    a = max(0, b - HUD.AHEAD)
    -- the stretch ahead, resampled a few times a second (the same table in between: UI.profile keeps its drawing)
    local near = HUD.near
    if not near or RealTime() > HUD.near_t or HUD.near_prof ~= prof then
      near = {}
      for i = 0, 120 do local d = a + (b - a) * i / 120; near[#near + 1] = { d, at(d) } end
      HUD.near, HUD.near_t, HUD.near_prof = near, RealTime() + 0.5, prof
    else
      a, b = near[1][1], near[#near][1]
    end
    local pos = UI.profile(near, px + 4, py + 4, pw - 8, ph - 8, s)
    local mx, my = pos(s)
    UI.rect(mx, py + 3, 1, ph - 6, C.text)
    UI.rect(mx - 2, my - 3, 5, 5, C.red)
    UI.rect(mx - 1, my - 2, 3, 3, HUD.MARK)
    -- kilometre marks
    local step = 1000
    for k = math.ceil(a / step) * step, b, step do
      local kx = pos(k)
      UI.rect(kx, py + ph - 4, 1, 3, C.dim)
    end
    -- the whole route: a thin strip, where you are on it
    local sx, sy, sw = px + 4, py + ph, pw - 8
    UI.rect(sx, sy, sw, 3, C.ink2)
    UI.rect(sx, sy, floor(sw * min(1, s / max(1, L))), 3, C.sign)
    local wa, wb = sx + floor(sw * a / max(1, L)), sx + floor(sw * b / max(1, L))
    UI.rect(wa, sy + 3, max(1, wb - wa), 1, C.text)
    local left, up = climb_left(at, s, L)
    if left and left > 30 then
      local lv, lu
      if left < 1000 then lv, lu = UI.height(left) else lv, lu = UI.km(left) end
      local uv, uu = UI.height(up)
      UI.stext(string.format("top of the climb in %s %s  (%s %s up)", lv, lu, uv, uu), W - 84, py + ph + 12, "M1", C.text, "right")
    end
  end
  local da, du = UI.km(s)
  local db = UI.km(L)
  UI.stext(string.format("%s / %s %s", da, db, du), px + 2, py + ph + 12, "M1", C.text)
end

-- the map's pixels: worked out a few times a second (a set per colour), drawn every frame as runs of pixels
local function plot(set, pts, rad, scale, ox, oy, cs, sn)
  local r2 = rad * rad
  local lx, ly
  for i = 1, #pts - 1, 2 do
    local dx, dy = pts[i] - ox, pts[i + 1] - oy
    local X, Y = (dx * cs - dy * sn) * scale, (dx * sn + dy * cs) * scale
    if lx then
      local n = max(abs(X - lx), abs(Y - ly))
      if n < 200 and not (abs(X) > rad and abs(lx) > rad and X * lx > 0) and not (abs(Y) > rad and abs(ly) > rad and Y * ly > 0) then
        for k = 0, floor(n) do
          local t = n > 0 and k / n or 0
          local px, py = floor(lx + (X - lx) * t + 0.5), floor(ly + (Y - ly) * t + 0.5)
          if px * px + py * py < r2 then set[py * 256 + px] = true end
        end
      end
    end
    lx, ly = X, Y
  end
end
-- a set of pixels as runs: { { x, y, length }, ... }
local function runs(set)
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  local out, i = {}, 1
  while i <= #keys do
    local k = keys[i]
    local n = 1
    while keys[i + n] == k + n do n = n + 1 end
    local py = floor((k + 128) / 256)
    out[#out + 1] = { k - py * 256, py, n }
    i = i + n
  end
  return out
end
local MAP_ORDER = { "water", "path", "rail", "road", "done", "todo" }
local MAP_COL = { road = Color(150, 160, 150), path = Color(110, 132, 96), water = Color(70, 120, 170), rail = Color(90, 96, 92),
  done = Color(200, 190, 160), todo = C.red }
local MAP_BG, ARROW_IN = Color(45, 74, 42), C.red

local function minimap(W, H)
  local cx, cy, rad = W - 46, H - 46, 36
  UI.disc(cx + 1, cy + 1, rad + 1, C.shadow)
  UI.disc(cx, cy, rad + 1, C.edge)
  UI.disc(cx, cy, rad, MAP_BG)
  local hd = math.atan2(V.fy or 0, V.fx or 1)
  local rot = math.pi / 2 - hd              -- turned so the way you ride is up
  local cs, sn = math.cos(rot), math.sin(rot)
  local now = RealTime()
  if not HUD.mp or now > HUD.mp_t then
    HUD.mp_t = now + 0.2
    local scale = rad / HUD.MAP_M
    local ox, oy = V.x or 0, V.y or 0
    local sets = {}
    for _, k in ipairs(MAP_ORDER) do sets[k] = {} end
    if V.W then
      if not HUD.map or now > HUD.map_t or HUD.map_w ~= V.W then
        HUD.map, HUD.map_t, HUD.map_w = V.W:map_lines(ox, oy, HUD.MAP_M * 1.5), now + 1, V.W
      end
      for _, l in ipairs(HUD.map) do plot(sets[l.kind] or sets.road, l.pts, rad - 1, scale, ox, oy, cs, sn) end
    end
    if V.mode == "ride" and V.R then
      local R, s = V.R, V.s or 0
      local reach = HUD.MAP_M * 1.6
      local i0, i1 = max(1, floor((s - reach) / 2)), min(R.n, floor((s + reach) / 2))
      local done, todo = {}, {}
      for i = i0, i1, 2 do
        local t = R.S[i] <= s and done or todo
        t[#t + 1] = R.X[i]; t[#t + 1] = R.Y[i]
      end
      plot(sets.done, done, rad - 1, scale, ox, oy, cs, sn)
      plot(sets.todo, todo, rad - 1, scale, ox, oy, cs, sn)
    end
    HUD.mp = {}
    for _, k in ipairs(MAP_ORDER) do HUD.mp[#HUD.mp + 1] = { MAP_COL[k], runs(sets[k]) } end
  end
  for _, layer in ipairs(HUD.mp) do
    local col = layer[1]
    for _, r in ipairs(layer[2]) do UI.rect(cx + r[1], cy - r[2], r[3], 1, col) end
  end
  -- you: an arrow pointing up
  UI.rect(cx, cy - 3, 1, 1, C.text)
  UI.rect(cx - 1, cy - 2, 3, 1, C.text)
  UI.rect(cx - 2, cy - 1, 5, 2, C.text)
  UI.rect(cx - 1, cy - 1, 3, 1, ARROW_IN)
  -- north, on the rim
  UI.text("N", cx + floor(-sn * (rad - 6)), cy - floor(cs * (rad - 6)) - 5, "M1", C.text, "center")
end

function HUD.draw()
  local W, H = UI.W, UI.H
  local st = Ride.state or {}
  local ride = V.mode == "ride" and V.R
  if ride then profile_top(W) end
  -- the grade, as a yellow road sign
  local s = V.s or 0
  local g = ride and V.R:grade(s) or (V.roam_grade or 0)
  local gt = string.format("%+.1f %%", g)
  local gw = max(60, floor(UI.textw(gt, "J1")) + 18)
  local gy = ride and 58 or 8
  UI.sign(W - 10 - gw, gy, gw, 19, C.sign, C.signDark)
  UI.text(gt, W - 10 - gw + 7, gy + 1, "J1", C.ink)
  -- bottom left: the bike computer
  local lx, ly, lw, lh = 10, H - 78, 150, 68
  UI.lcd(lx, ly, lw, lh)
  local sp, su = UI.speed(Ride.speed or 0)
  UI.text(sp, lx + 10, ly + 6, "M3", C.lcdInk)
  UI.text(su, lx + 12 + UI.textw(sp, "M3"), ly + 20, "M1", C.lcdInk)
  UI.text(UI.clock(Ride.stats and Ride.stats.time), lx + lw - 8, ly + 7, "M1", C.lcdInk, "right")
  UI.text(st.source == "omniplay" and "trainer" or "keys", lx + lw - 8, ly + 16, "M1", C.lcdInk, "right")
  UI.rect(lx + 8, ly + 36, lw - 16, 1, C.lcdGhost)
  local cells = { { floor(st.power or 0), "W" }, { floor(st.cadence or 0), "rpm" }, { st.hr and st.hr > 0 and floor(st.hr) or "--", "bpm" } }
  for i, c in ipairs(cells) do
    local cx = lx + 10 + (i - 1) * 46
    UI.text(tostring(c[1]), cx, ly + 38, "M2", C.lcdInk)
    UI.text(c[2], cx, ly + 54, "M1", C.lcdInk)
  end
  minimap(W, H)
  if V.mode == "roam" then UI.stext("A / D steer", floor(W / 2), H - 16, "M1", C.dim, "center") end
end
