-- Guide rods: bendable lines laid over the preview.
--
-- A rod is { pts = { x1, y1, x2, y2, ... }, parent = n, at = f, kind = k }:
-- its control points in sprite px (pixel centres at + 0.5). A flow rod
-- (kind nil) steers the water, running from the first point to the last;
-- near it the water turns to run along it (Flow), most on the rod itself
-- and less and less out to the reach. A branch names the rod it grows
-- from (parent) and where on it (at, 0 .. 1 of the parent's length); its
-- first point sits there and moves with the parent. A lip rod (kind
-- "lip") marks the edge a fall goes over: across a fall, the water above
-- it is the mouth and the fall starts at it (Mask.withLips).
--
-- A rod is drawn and used as a smooth curve through its points (Catmull-
-- Rom).

local Guide = {}

local floor, ceil, sqrt, min, max = math.floor, math.ceil, math.sqrt, math.min, math.max

local function catmull(a, b, c, d, t)
  local t2, t3 = t * t, t * t * t
  return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
end

-- The rod's curve, a point about every `step` px: xs, ys, and for every
-- point the span of control points it lies on (i: from point i to i + 1).
function Guide.sample(pts, step)
  step = step or 1.5
  local n = #pts // 2
  local xs, ys, span = {}, {}, {}
  if n < 2 then return xs, ys, span end
  local function P(i)
    i = max(1, min(n, i))
    return pts[i * 2 - 1], pts[i * 2]
  end
  for i = 1, n - 1 do
    local ax, ay = P(i - 1)
    local bx, by = P(i)
    local cx, cy = P(i + 1)
    local dx, dy = P(i + 2)
    local len = sqrt((cx - bx) ^ 2 + (cy - by) ^ 2)
    local k = max(1, ceil(len / step))
    for q = 0, k - 1 do
      local t = q / k
      local m = #xs + 1
      xs[m], ys[m], span[m] = catmull(ax, bx, cx, dx, t), catmull(ay, by, cy, dy, t), i
    end
  end
  local lx, ly = P(n)
  local m = #xs + 1
  xs[m], ys[m], span[m] = lx, ly, n - 1
  return xs, ys, span
end

-- Every rod as a chain: its curve (xs, ys, span), the length along it from
-- its start (ss), its way on the screen (tx, ty, unit) and its length.
function Guide.chain(r)
  local xs, ys, span = Guide.sample(r.pts, 1.5)
  local n = #xs
  local ss, tx, ty = {}, {}, {}
  local s = 0
  for k = 1, n do
    if k > 1 then s = s + sqrt((xs[k] - xs[k - 1]) ^ 2 + (ys[k] - ys[k - 1]) ^ 2) end
    ss[k] = s
    local a, b = max(1, k - 1), min(n, k + 1)
    local ux, uy = xs[b] - xs[a], ys[b] - ys[a]
    local l = sqrt(ux * ux + uy * uy)
    if l > 1e-9 then tx[k], ty[k] = ux / l, uy / l end
  end
  -- Where points coincide the way is unknown there: the nearest known one
  -- (down the screen when none is).
  for k = 2, n do
    if not tx[k] then tx[k], ty[k] = tx[k - 1], ty[k - 1] end
  end
  for k = n - 1, 1, -1 do
    if not tx[k] then tx[k], ty[k] = tx[k + 1], ty[k + 1] end
  end
  for k = 1, n do
    if not tx[k] then tx[k], ty[k] = 0, 1 end
  end
  return { xs = xs, ys = ys, span = span, ss = ss, tx = tx, ty = ty, len = s }
end

function Guide.chains(rods)
  local out = {}
  for i, r in ipairs(rods) do out[i] = Guide.chain(r) end
  return out
end

-- The point at fraction `at` (0 .. 1 of its length) along a chain, and
-- the chain's way there.
function Guide.pointAt(c, at)
  local n = #c.xs
  if n == 0 then return nil end
  if n == 1 or c.len <= 0 then return c.xs[1], c.ys[1], c.tx[1], c.ty[1] end
  local want = max(0, min(1, at)) * c.len
  for k = 2, n do
    if c.ss[k] >= want then
      local seg = c.ss[k] - c.ss[k - 1]
      local f = (seg > 0) and (want - c.ss[k - 1]) / seg or 0
      return c.xs[k - 1] + (c.xs[k] - c.xs[k - 1]) * f, c.ys[k - 1] + (c.ys[k] - c.ys[k - 1]) * f,
        c.tx[k], c.ty[k]
    end
  end
  return c.xs[n], c.ys[n], c.tx[n], c.ty[n]
end

-- The nearest point of a chain to (x, y): its distance, the fraction along
-- the chain (0 .. 1), the point, and the span of control points it is on.
function Guide.nearest(c, x, y)
  local best, bat, bx, by, bspan = math.huge, 0, nil, nil, 1
  local n = #c.xs
  for k = 1, n - 1 do
    local ax, ay = c.xs[k], c.ys[k]
    local vx, vy = c.xs[k + 1] - ax, c.ys[k + 1] - ay
    local L2 = vx * vx + vy * vy
    local t = (L2 > 0) and max(0, min(1, ((x - ax) * vx + (y - ay) * vy) / L2)) or 0
    local px, py = ax + vx * t, ay + vy * t
    local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
    if d < best then
      best = d
      local s = c.ss[k] + (c.ss[k + 1] - c.ss[k]) * t
      bat = (c.len > 0) and s / c.len or 0
      bx, by, bspan = px, py, c.span[k]
    end
  end
  return best, bat, bx, by, bspan
end

-- Puts every branch's first point back on its parent (after the parent
-- moved); branches of branches follow in turn.
function Guide.attach(rods)
  for _ = 1, 4 do
    local moved = false
    for _, r in ipairs(rods) do
      local par = r.parent and rods[r.parent]
      if par and par ~= r and #r.pts >= 2 then
        local x, y = Guide.pointAt(Guide.chain(par), r.at or 0)
        if x and (x ~= r.pts[1] or y ~= r.pts[2]) then
          r.pts[1], r.pts[2] = x, y
          moved = true
        end
      end
    end
    if not moved then break end
  end
end

-- Rod i and every branch growing from it gone; the others keep their
-- parents.
function Guide.remove(rods, i)
  local gone = { [i] = true }
  local again = true
  while again do
    again = false
    for k, r in ipairs(rods) do
      if not gone[k] and r.parent and gone[r.parent] then
        gone[k] = true
        again = true
      end
    end
  end
  local map, out = {}, {}
  for k, r in ipairs(rods) do
    if not gone[k] then
      out[#out + 1] = r
      map[k] = #out
    end
  end
  for _, r in ipairs(out) do
    if r.parent then r.parent = map[r.parent] end
  end
  return out
end

-- The rod the other way round: the water runs back up it. Its branches
-- stay where they are on it; a branch turned round no longer starts on its
-- parent, so it comes off it.
function Guide.reverse(rods, i)
  local r = rods[i]
  if not r then return end
  local pts, n = {}, #r.pts // 2
  for k = n, 1, -1 do
    pts[#pts + 1] = r.pts[k * 2 - 1]
    pts[#pts + 1] = r.pts[k * 2]
  end
  r.pts = pts
  r.parent, r.at = nil, nil
  for _, b in ipairs(rods) do
    if b.parent == i then b.at = 1 - (b.at or 0) end
  end
  Guide.attach(rods)
end

-- A copy of the rods (plain tables of numbers), anything malformed left
-- out.
function Guide.copy(rods)
  local out, map = {}, {}
  if type(rods) ~= "table" then return out end
  for i, r in ipairs(rods) do
    if type(r) == "table" and type(r.pts) == "table" and #r.pts >= 4 then
      local pts = {}
      for k = 1, #r.pts - (#r.pts % 2) do
        local v = tonumber(r.pts[k])
        if not v or v ~= v then pts = nil break end
        pts[k] = v
      end
      if pts then
        out[#out + 1] = { pts = pts, parent = tonumber(r.parent), at = tonumber(r.at),
                          kind = (r.kind == "lip") and "lip" or nil }
        map[i] = #out
      end
    end
  end
  for _, r in ipairs(out) do
    local par = r.parent and map[r.parent]
    if par and out[par] ~= r and not r.kind and not out[par].kind then
      r.parent, r.at = par, max(0, min(1, r.at or 0))
    else
      r.parent, r.at = nil, nil
    end
  end
  return out
end

-- A string that changes whenever the rods do (only those of one kind:
-- "flow" or "lip", when given).
function Guide.signature(rods, kind)
  local parts = {}
  for _, r in ipairs(rods or {}) do
    if not kind or (kind == "lip") == (r.kind == "lip") then
      local q = {}
      for k = 1, #r.pts do q[k] = string.format("%.2f", r.pts[k]) end
      parts[#parts + 1] = table.concat(q, ",") .. "/" .. tostring(r.parent) .. "@" .. string.format("%.4f", r.at or 0)
        .. (r.kind or "")
    end
  end
  return table.concat(parts, ";")
end

-- The rods of one kind: "flow" (the ones that steer) or "lip".
function Guide.ofKind(rods, kind)
  local out = {}
  for _, r in ipairs(rods or {}) do
    if (kind == "lip") == (r.kind == "lip") then out[#out + 1] = r end
  end
  return out
end

-- Where a lip rod crosses each column it spans: x -> y (sprite px; the
-- lowest crossing where it doubles back).
function Guide.edge(r)
  local c = Guide.chain(r)
  local xs, ys = c.xs, c.ys
  local out = {}
  local function put(X, y)
    local old = out[X]
    if not old or y > old then out[X] = y end
  end
  if #xs == 1 then put(math.floor(xs[1]), ys[1]) end
  for i = 1, #xs - 1 do
    local ax, ay, bx, by = xs[i], ys[i], xs[i + 1], ys[i + 1]
    local lo, hi = min(ax, bx), max(ax, bx)
    -- Columns whose centres lie on this piece (and the piece's own ends).
    for X = ceil(lo - 0.5), floor(hi - 0.5) do
      local cx = X + 0.5
      local f = (bx ~= ax) and (cx - ax) / (bx - ax) or 0
      put(X, ay + (by - ay) * f)
    end
    put(floor(ax), ay)
    put(floor(bx), by)
  end
  return out
end

-- How the rods steer the water: for every surface pixel within `reach` px
-- of a rod (the mouths too: the water goes over the edge the way it was
-- steered), how strongly (strength on the rod,
-- 0 at the reach) and which way the nearest rod runs there (unit, on the
-- screen).
function Guide.field(W, B, chains, strength, reach, step)
  local w, h = B.w, B.h
  local x0, y0 = B.x0, B.y0
  local jOf = W.jOf
  local r2 = reach * reach
  local bestD, gx, gy = {}, {}, {}
  for _, c in ipairs(chains) do
    local xs, ys, tx, ty = c.xs, c.ys, c.tx, c.ty
    for i = 1, #xs - 1 do
      local ax, ay = xs[i] - x0, ys[i] - y0
      local bx, by = xs[i + 1] - x0, ys[i + 1] - y0
      local vx, vy = bx - ax, by - ay
      local L2 = vx * vx + vy * vy
      local xa, xb = max(0, floor(min(ax, bx) - reach)), min(w - 1, ceil(max(ax, bx) + reach))
      local ya, yb = max(0, floor(min(ay, by) - reach)), min(h - 1, ceil(max(ay, by) + reach))
      for py = ya, yb do
        local row = py * w + 1
        local cy = py + 0.5 - ay
        for px = xa, xb do
          local j = jOf[row + px]
          if j then
            local cx = px + 0.5 - ax
            local t = (L2 > 0) and max(0, min(1, (cx * vx + cy * vy) / L2)) or 0
            local dx, dy = cx - vx * t, cy - vy * t
            local d2 = dx * dx + dy * dy
            if d2 < r2 then
              local old = bestD[j]
              if not old or d2 < old then
                bestD[j] = d2
                local ux, uy = tx[i] + (tx[i + 1] - tx[i]) * t, ty[i] + (ty[i + 1] - ty[i]) * t
                local l = sqrt(ux * ux + uy * uy)
                if l > 1e-9 then ux, uy = ux / l, uy / l else ux, uy = tx[i], ty[i] end
                gx[j], gy[j] = ux, uy
              end
            end
          end
        end
      end
      if step and i % 16 == 0 then step() end
    end
  end
  local gw = {}
  for j, d2 in pairs(bestD) do
    local f = 1 - sqrt(d2) / reach
    gw[j] = strength * f * f * (3 - 2 * f)
  end
  return { w = gw, tx = gx, ty = gy }
end

return Guide
