-- Decides what to have built around the rider and builds it a little at a time. Engine-agnostic.
--
-- Levels (finest first):
--   1 m blocks   32 m squares of near chunks, only along the route from `behind` metres back to `ahead`
--                metres forward (by distance along the route, so hairpins and loops are handled), within
--                `near_radius` of the track. Textured ground, water, buildings with facades, trees, bridges.
--   4 m cells    256 m cells (near or mid) within `lod4_radius` of the rider, minus what is behind him.
--                Plain colours, box buildings, trees. A cell with 1 m blocks in it is built as 64 m pieces
--                with holes where the blocks are.
--   16 m pages   every 1024 m page of the route, with holes for the 4 m cells. Always drawn.
--   far grid     the whole far grid (32 m data, drawn at 64 m). Lower than everything above where they overlap.
--
-- The engine supplies E = { upload(buffer, material_name) -> handle, free(handle), clock() -> seconds }.
local Stream = {}
Stream.__index = Stream
local floor, max, min, sqrt, huge = math.floor, math.max, math.min, math.sqrt, math.huge

Stream.defaults = {
  block = 32, ahead = 450, behind = 60, near_radius = 110,
  lod4_radius = 1200, lod4_fine = 450, lod4_behind = 250, budget_ms = 4, far_step = 2, far_tile = 64, tree_dist = 900,
  building_dist = 450,  -- buildings with facades (not plain boxes) this far from the rider
  slice_quads = 4000,   -- quads per mesh: one mesh is uploaded at a time, so this bounds the work in one go
}

function Stream.new(E, D, M, route, look, cfg)
  local self = setmetatable({ E = E, D = D, M = M, route = route, look = look, cfg = {} }, Stream)
  for k, v in pairs(Stream.defaults) do self.cfg[k] = v end
  for k, v in pairs(cfg or {}) do self.cfg[k] = v end
  local rt = route.meta
  self.CS, self.PS = rt.chunk_size, rt.page_size
  self.per = floor(self.PS / self.CS)
  self.units, self.queue, self.queued = {}, {}, {}
  self.stats = { build_ms = 0, jobs = 0, max_job_ms = 0, last_job = "" }
  self.near = {}
  for _, c in ipairs(rt.chunks) do self.near[c[1] .. "," .. c[2]] = { c[1], c[2] } end
  -- every cell with data (near or mid), from the 16 m pages
  self.cells, self.l16 = {}, {}
  for _, p in ipairs(rt.l16) do
    local L = D:l16(p[1], p[2])
    if L then
      self.l16[p[1] .. "," .. p[2]] = L
      for k in pairs(L.cells) do
        local cx, cy = k:match("^(%-?%d+),(%-?%d+)$")
        self.cells[k] = { tonumber(cx), tonumber(cy) }
      end
    end
  end
  for k, c in pairs(self.near) do self.cells[k] = c end
  -- bridges: one piece each, built from the pack's parts to fit its outline (see build_bridge)
  self.bridges = {}
  local step = (look.bridge and look.bridge.tile or 1.5) / 2
  local function ring(flat)
    local xs, ys = {}, {}
    for k = 1, #flat / 2 do xs[k], ys[k] = flat[2 * k - 1], flat[2 * k] end
    return xs, ys
  end
  for i, br in ipairs(rt.bridges or {}) do
    local p, pz = br.p, br.pz
    local np = #pz
    if np >= 2 then
      -- the axis (the lane the route rides, carrying the deck height) at exactly `step` metres
      local acc = { 0 }
      for k = 2, np do
        acc[k] = acc[k - 1] + sqrt((p[2 * k - 1] - p[2 * k - 3]) ^ 2 + (p[2 * k] - p[2 * k - 2]) ^ 2)
      end
      local L = acc[np]
      if L > 1 then
        local nsteps = max(2, floor(L / step + 0.5))
        local X, Y, Z = {}, {}, {}
        local seg = 1
        for q = 0, nsteps do
          local a2 = L * q / nsteps
          while seg < np - 1 and acc[seg + 1] < a2 do seg = seg + 1 end
          local f = (a2 - acc[seg]) / max(acc[seg + 1] - acc[seg], 1e-6)
          X[q + 1] = p[2 * seg - 1] + (p[2 * seg + 1] - p[2 * seg - 1]) * f
          Y[q + 1] = p[2 * seg] + (p[2 * seg + 2] - p[2 * seg]) * f
          Z[q + 1] = pz[seg] + (pz[seg + 1] - pz[seg]) * f
        end
        local OX, OY = ring(br.outline or {})
        if #OX < 3 then     -- no outline: the lane itself
          OX, OY = {}, {}
          local hw = br.w / 2
          for q = 1, #X do
            local a1, c1 = max(1, q - 1), min(#X, q + 1)
            local dx, dy = X[c1] - X[a1], Y[c1] - Y[a1]; local l = max(sqrt(dx * dx + dy * dy), 1e-6)
            OX[q], OY[q] = X[q] + dy / l * hw, Y[q] - dx / l * hw
          end
          for q = #X, 1, -1 do
            local a1, c1 = max(1, q - 1), min(#X, q + 1)
            local dx, dy = X[c1] - X[a1], Y[c1] - Y[a1]; local l = max(sqrt(dx * dx + dy * dy), 1e-6)
            OX[#OX + 1], OY[#OY + 1] = X[q] - dy / l * hw, Y[q] + dx / l * hw
          end
        end
        local IX, IY = ring(br.inner or br.outline or {})
        if #IX < 3 then IX, IY = OX, OY end
        local x0, y0, x1, y1 = huge, huge, -huge, -huge
        for q = 1, #OX do x0, y0, x1, y1 = min(x0, OX[q]), min(y0, OY[q]), max(x1, OX[q]), max(y1, OY[q]) end
        self.bridges[i] = { X = X, Y = Y, Z = Z, w = br.w, tag = br.tag, kind = br.kind or "arch", length = L,
          OX = OX, OY = OY, IX = IX, IY = IY, x0 = x0, y0 = y0, x1 = x1, y1 = y1,
          cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, size = max(x1 - x0, y1 - y0) }
      end
    end
  end
  self:match_bridges_to_track()
  self.far = D:far()
  return self
end

local function ckey(cx, cy) return cx .. "," .. cy end

-- ------------------------------------------------------------------ what we want ----
function Stream:desired(s, px, py, fx, fy)
  local cfg, R, B, CS = self.cfg, self.route, self.cfg.block, self.CS
  local want = {}
  local bpc = floor(CS / B)
  -- 1 m blocks along the route
  local blocks, rad = {}, cfg.near_radius
  local had = self.blocks_now or {}
  local step = 5
  local s0 = floor((s - cfg.behind) / step) * step       -- fixed 5 m marks, so the samples don't slide
  for ss = s0, s + cfg.ahead + step, step do
    if R.loop or (ss >= 0 and ss <= R.length) then
      local x, y = R:pos(ss)
      local rr = rad + 24
      for by = floor((y - rr) / B), floor((y + rr) / B) do
        for bx = floor((x - rr) / B), floor((x + rr) / B) do
          local k = bx .. "," .. by
          if not blocks[k] then
            local mx, my = (bx + 0.5) * B - x, (by + 0.5) * B - y
            local lim = rad + B * 0.5 + (had[k] and 24 or 0)   -- blocks already built stay a little longer
            if mx * mx + my * my <= lim * lim then
              local cx, cy = floor(bx / bpc), floor(by / bpc)
              if self.near[ckey(cx, cy)] then blocks[k] = { bx, by, cx, cy } end
            end
          end
        end
      end
    end
  end
  self.blocks_now = blocks
  local trans = {}
  for k, b in pairs(blocks) do
    want["b:" .. k] = { kind = "b", spec = "1", bx = b[1], by = b[2], cx = b[3], cy = b[4],
                        x = (b[1] + 0.5) * B, y = (b[2] + 0.5) * B, r = B * 0.71 }
    local ck = ckey(b[3], b[4])
    trans[ck] = trans[ck] or {}
    trans[ck][(b[1] - b[3] * bpc) .. "," .. (b[2] - b[4] * bpc)] = true
  end
  -- 4 m cells
  -- (with some slack for cells that already are at this level, so they don't flip at the edge)
  local lod4, was, step_was = {}, self.lod4_now or {}, self.step_now or {}
  local R4, back, fine = cfg.lod4_radius, cfg.lod4_behind, cfg.lod4_fine
  local steps, details = {}, {}
  for k, c in pairs(self.cells) do
    local mx, my = (c[1] + 0.5) * CS - px, (c[2] + 0.5) * CS - py
    local d = sqrt(mx * mx + my * my)
    local slack = was[k] and 200 or 0
    if trans[k] or (d <= R4 + slack and mx * fx + my * fy > -back - slack - CS * 0.71) then
      lod4[k] = c
      local st = d < fine and 4 or 8
      if step_was[k] and math.abs(d - fine) < 100 then st = step_was[k] end
      steps[k] = st
      local det = d < cfg.building_dist
      local dw = (self.detail_now or {})[k]
      if dw ~= nil and math.abs(d - cfg.building_dist) < 80 then det = dw end
      details[k] = det
    end
  end
  self.lod4_now, self.step_now, self.detail_now = lod4, steps, details
  local PIECE = 64
  local ppc = floor(CS / PIECE)
  local bpp = floor(PIECE / B)
  for k, c in pairs(lod4) do
    local cov = trans[k]
    local x0, y0 = c[1] * CS, c[2] * CS
    if not cov then
      want["c:" .. k] = { kind = "c", spec = "w" .. steps[k] .. (details[k] and "d" or ""), step = steps[k], detail = details[k], cx = c[1], cy = c[2], x = x0 + CS / 2, y = y0 + CS / 2, r = CS * 0.71 }
    else
      for pj = 0, ppc - 1 do
        for pi = 0, ppc - 1 do
          local mask, full = {}, true
          for qj = 0, bpp - 1 do
            for qi = 0, bpp - 1 do
              local bi, bj = pi * bpp + qi, pj * bpp + qj
              if cov[bi .. "," .. bj] then mask[#mask + 1] = bi .. "," .. bj else full = false end
            end
          end
          if not full then
            want["q:" .. k .. "," .. pi .. "," .. pj] = { kind = "q", spec = table.concat(mask, ";"), cx = c[1], cy = c[2],
              pi = pi, pj = pj, piece = PIECE, x = x0 + (pi + 0.5) * PIECE, y = y0 + (pj + 0.5) * PIECE, r = PIECE * 0.71 }
          end
        end
      end
    end
  end
  -- bridges
  for i, br in pairs(self.bridges) do
    local mx, my = br.cx - px, br.cy - py
    local d = sqrt(mx * mx + my * my)
    if d <= R4 and mx * fx + my * fy > -back - br.size then
      want["r:" .. i] = { kind = "r", spec = "1", i = i, cx = floor(br.cx / CS), cy = floor(br.cy / CS),
                          x = br.cx, y = br.cy, r = br.size * 0.75 }
    end
  end
  -- 16 m pages, holes where the 4 m level is
  for pk, L in pairs(self.l16) do
    local holes = {}
    for ck in pairs(L.cells) do if lod4[ck] then holes[#holes + 1] = ck end end
    table.sort(holes)
    want["l:" .. pk] = { kind = "l", spec = table.concat(holes, ";"), px = L.px, py = L.py, holes = holes,
                         x = L.x0 + self.PS / 2, y = L.y0 + self.PS / 2, r = self.PS * 0.71 }
  end
  -- far tiles
  local F, T = self.far, cfg.far_tile * cfg.far_step
  for tj = 0, floor((F.ny - 2) / T) do
    for ti = 0, floor((F.nx - 2) / T) do
      want["f:" .. ti .. "," .. tj] = { kind = "f", spec = "1", ti = ti, tj = tj,
        x = F.x0 + (ti + 0.5) * T * F.res, y = F.y0 + (tj + 0.5) * T * F.res, r = T * F.res * 0.71 }
    end
  end
  return want
end

-- ------------------------------------------------------------------ building ----
local function bucket_near(self, C)
  if C.bucket then return C.bucket end
  local objs = self.D:chunk_objects(C.cx, C.cy)
  local B = self.cfg.block
  local bk = {}
  local function put(key, kind, o)
    local e = bk[key]; if not e then e = { b = {}, t = {} }; bk[key] = e end
    local l = e[kind]; l[#l + 1] = o
  end
  for _, b in ipairs(objs.buildings) do
    local sx, sy, n = 0, 0, (#b - 3) / 2
    for k = 1, n do sx = sx + b[2 + 2 * k]; sy = sy + b[3 + 2 * k] end
    put(floor((sx / n - C.x0) / B) .. "," .. floor((sy / n - C.y0) / B), "b", b)
  end
  for _, t in ipairs(objs.trees) do put(floor((t[1] - C.x0) / B) .. "," .. floor((t[2] - C.y0) / B), "t", t) end
  C.bucket = bk
  return bk
end

local function bucket_page(self, P)
  if P.bucket then return P.bucket end
  local objs = self.D:page_objects(P.px, P.py)
  local CS = self.CS
  local bk = {}
  local function put(key, kind, o)
    local e = bk[key]; if not e then e = { b = {}, t = {} }; bk[key] = e end
    local l = e[kind]; l[#l + 1] = o
  end
  for _, b in ipairs(objs.boxes) do put(floor(b[1] / CS) .. "," .. floor(b[2] / CS), "b", b) end
  for _, t in ipairs(objs.trees) do put(floor(t[1] / CS) .. "," .. floor(t[2] / CS), "t", t) end
  P.bucket = bk
  return bk
end

-- a tree on the ground that is actually drawn (z given); trees close to the track are kept small enough
-- that their crown doesn't reach over it (t[7] = distance to the track, from the exporter)
local function tree_into(self, b, t, ox, oy, scale, z)
  local L = self.look
  local info = L.trees[t[4] + 1] or L.trees.default
  local v = t[5] or 0
  local rect = info.rects[v % #info.rects + 1]
  local f = (v * 0.618034) % 1
  local h = (info.hmin + (info.hmax - info.hmin) * f) * (scale or 1)
  local d = t[7]
  if d then
    local half = h * rect[5] / rect[6] / 2
    local room = max(1.0, d - 1.3)
    if half > room then h = h * room / half end
  end
  self.M.tree(b, t[1] - ox, t[2] - oy, z or t[3], rect, h, (v * 2.39996) % 3.14159, 245)
end

local WATER_DRAFT = 0.3
-- base of a building: houseboats (a footprint on water) float at the water surface
local function building_base(self, C, bd)
  local L = self.look
  if not C.W then return nil end
  local sx, sy, n = 0, 0, (#bd - 3) / 2
  for k = 1, n do sx = sx + bd[2 + 2 * k]; sy = sy + bd[3 + 2 * k] end
  local cx, cy = sx / n - C.x0, sy / n - C.y0
  local i, j = floor(cx), floor(cy)
  if i < 0 or j < 0 or i >= C.tn or j >= C.tn then return nil end
  if C.T[j * C.tn + i] == L.water_tag then return self.M.water_z(C, cx, cy) - WATER_DRAFT end
  return nil
end

local function build_block(self, u)
  local M, L, B = self.M, self.look, self.cfg.block
  local C = self.D:chunk(u.cx, u.cy)
  if not C then return {} end
  local bpc = floor(self.CS / B)
  local bi, bj = u.bx - u.cx * bpc, u.by - u.cy * bpc
  local ox, oy = C.x0 + bi * B, C.y0 + bj * B
  self:cut_under_bridges(C)
  local g, w, o = M.buffer(), M.buffer(), M.buffer()
  M.ground_lod1(g, C, bi, bj, B, L.tagcells, L.fallback_cells, L.water_tag, L.wall_rect, L.wall_tint)
  M.water_lod1(w, C, bi, bj, B, L.water_tag, L.water_frames, L.water_sheet_px)
  local e = bucket_near(self, C)[bi .. "," .. bj]
  if e then
    for _, bd in ipairs(e.b) do
      M.building_lod1(o, bd, ox, oy, L.objects, L.buildings, L.roof_tints[bd[1] % #L.roof_tints + 1], building_base(self, C, bd))
    end
    for _, t in ipairs(e.t) do
      local tz = M.surface_at(C.H, C.n, C.n, t[1] - C.x0, t[2] - C.y0, 1)
      tree_into(self, o, t, ox, oy, t[6], tz)
      -- street trees (on pavement, cobbles...) stand in a tree pit
      local ti, tj = floor(t[1] - C.x0), floor(t[2] - C.y0)
      if ti >= 0 and tj >= 0 and ti < C.tn and tj < C.tn and L.hard[C.T[tj * C.tn + ti]] then
        M.tree_pit(g, t[1] - ox, t[2] - oy, tz, 1.4, L.pit_soil, L.pit_kerb)
      end
    end
  end
  return { { g, "ground" }, { w, "water" }, { o, "objects" } }, ox, oy
end

-- 4 m level of a near cell (whole, or one 64 m piece with holes) or a mid cell
local function build_cell(self, u)
  local M, L, CS, B = self.M, self.look, self.CS, self.cfg.block
  local key = ckey(u.cx, u.cy)
  local f, o, bo = M.buffer(), M.buffer(), M.buffer()
  local detail = u.kind == "q" or u.detail
  local x0, y0 = u.cx * CS, u.cy * CS
  local qi0, qj0, qn = 0, 0, CS        -- in metres inside the cell
  if u.kind == "q" then qi0, qj0, qn = u.pi * u.piece, u.pj * u.piece, u.piece end
  local covered = {}
  if u.spec ~= "" and u.kind == "q" then
    for k in u.spec:gmatch("[^;]+") do covered[k] = true end
  end
  local ox, oy = x0 + qi0, y0 + qj0
  if self.near[key] then
    local C = self.D:chunk(u.cx, u.cy)
    local V = { H = C.H, n = C.n, T = C.T, tn = C.tn, res = 1 }
    local emit = nil
    if next(covered) then emit = function(i, j) return not covered[floor(i / B) .. "," .. floor(j / B)] end end
    local wz = C.W and function(i, j) return M.water_z(C, i, j) end
    M.terrain_flat(f, V, qi0, qj0, qi0 + qn, qj0 + qn, u.step or 4, emit, L.colours, L.fallback_colour, L.water_tag, L.water_colour, wz)
    local bk = bucket_near(self, C)
    for bj = floor(qj0 / B), floor((qj0 + qn) / B) - 1 do
      for bi = floor(qi0 / B), floor((qi0 + qn) / B) - 1 do
        local e = bk[bi .. "," .. bj]
        if e and not covered[bi .. "," .. bj] then
          local step = u.step or 4
          for _, bd in ipairs(e.b) do
            local base = building_base(self, C, bd)
            local tint = L.roof_tints[bd[1] % #L.roof_tints + 1]
            if detail then
              M.building_lod1(bo, bd, ox, oy, L.objects, L.buildings, tint, base)
            else
              local xs, ys, n = M.ring_local(bd, 4, ox, oy)
              if n >= 3 then
                local F = L.objects.facades[bd[1] % #L.objects.facades + 1]
                local rc = L.objects.roof_colour
                local b0 = base or bd[3]
                M.building_flat(f, xs, ys, n, b0, b0 + bd[2], L.objects.white, F.colour, { rc[1] * tint[1], rc[2] * tint[2], rc[3] * tint[3] })
              end
            end
          end
          for _, t in ipairs(e.t) do
            tree_into(self, o, t, ox, oy, t[6], M.surface_at(C.H, C.n, C.n, t[1] - C.x0, t[2] - C.y0, step))
          end
        end
      end
    end
  else
    local px, py = floor(u.cx / self.per), floor(u.cy / self.per)
    local P = self.D:page(px, py)
    if not P then return {} end
    local ci, cj = (u.cx - px * self.per) * (CS / P.res), (u.cy - py * self.per) * (CS / P.res)
    local V = { H = P.H, n = P.n, T = P.T, tn = P.tn, res = P.res }
    local wz = P.W and P.water_cells[key] and function(i, j) return M.water_z(P, i * P.res, j * P.res) end
    M.terrain_flat(f, V, ci, cj, ci + CS / P.res, cj + CS / P.res, max(1, floor((u.step or 4) / P.res)), nil, L.colours, L.fallback_colour, L.water_tag, L.water_colour, wz)
    local e = bucket_page(self, P)[key]
    if e then
      local nf, rc = #L.objects.facades, L.objects.roof_colour
      local roofs = self.roof_cols
      if not roofs then
        roofs = {}
        for i, t in ipairs(L.roof_tints) do roofs[i] = { rc[1] * t[1], rc[2] * t[2], rc[3] * t[3] } end
        self.roof_cols = roofs
      end
      for _, bx in ipairs(e.b) do
        local style = floor(bx[1] * 7 + bx[2] * 13) % nf
        if detail then
          local xs, ys = M.box_ring(bx, 0, 0)
          local bd = { style, bx[6], bx[7], xs[1], ys[1], xs[2], ys[2], xs[3], ys[3], xs[4], ys[4] }
          M.building_lod1(bo, bd, ox, oy, L.objects, L.buildings, L.roof_tints[style % #L.roof_tints + 1])
        else
          M.box_flat(f, bx, ox, oy, L.objects.facades[style + 1].colour, roofs[style % #roofs + 1])
        end
      end
      local st = max(1, floor((u.step or 4) / P.res))
      for _, t in ipairs(e.t) do
        tree_into(self, o, t, ox, oy, 1, M.surface_at(P.H, P.n, P.n, (t[1] - P.x0) / P.res, (t[2] - P.y0) / P.res, st))
      end
    end
  end
  return { { f, "flat" }, { bo, "objects" }, { o, "objects_far" } }, ox, oy
end

local function build_l16(self, u)
  local M, L = self.M, self.look
  local P = self.l16[u.px .. "," .. u.py]
  local holes = {}
  for _, h in ipairs(u.holes) do holes[h] = true end
  local per = self.per
  local cq = floor(self.CS / P.res)
  local V = { H = P.H, n = P.n, T = P.T, tn = P.tn, res = P.res }
  local f = M.buffer()
  M.terrain_flat(f, V, 0, 0, P.n - 1, P.n - 1, 1, function(i, j)
    local k = (P.px * per + floor(i / cq)) .. "," .. (P.py * per + floor(j / cq))
    return P.cells[k] == true and not holes[k]
  end, L.colours, L.fallback_colour, L.water_tag, L.water_colour, nil)
  return { { f, "flat" } }, P.x0, P.y0
end

local function build_far(self, u)
  local M, L, F, cfg = self.M, self.look, self.far, self.cfg
  local T = cfg.far_tile * cfg.far_step
  local qi0, qj0 = u.ti * T, u.tj * T
  local qi1, qj1 = min(qi0 + T, F.nx - 1), min(qj0 + T, F.ny - 1)
  qi1 = qi0 + floor((qi1 - qi0) / cfg.far_step) * cfg.far_step
  qj1 = qj0 + floor((qj1 - qj0) / cfg.far_step) * cfg.far_step
  local f = M.buffer()
  if qi1 > qi0 and qj1 > qj0 then
    M.terrain_flat(f, { H = F.H, n = F.nx, nrows = F.ny, T = F.T, tn = F.tn, res = F.res }, qi0, qj0, qi1, qj1, cfg.far_step,
      nil, L.colours, L.fallback_colour, L.water_tag, L.water_colour, nil)
  end
  return { { f, "flat" } }, F.x0 + qi0 * F.res, F.y0 + qj0 * F.res
end

-- where the track runs over a bridge, the deck is at the ride height (the rider stays on the deck)
function Stream:match_bridges_to_track()
  local R = self.route
  for _, br in pairs(self.bridges) do
    local cand = {}
    for k = 1, R.n do
      local x, y = R.X[k], R.Y[k]
      if x > br.x0 - 10 and x < br.x1 + 10 and y > br.y0 - 10 and y < br.y1 + 10 then cand[#cand + 1] = k end
    end
    if #cand > 0 then
      for q = 1, #br.X do
        local px, py = br.X[q], br.Y[q]
        local best, bz = huge, nil
        for _, k in ipairs(cand) do
          if k < R.n then
            local ax, ay, bx, by = R.X[k], R.Y[k], R.X[k + 1], R.Y[k + 1]
            local dx, dy = bx - ax, by - ay
            local l2 = dx * dx + dy * dy
            local t = l2 > 0 and max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
            local qx, qy = ax + dx * t, ay + dy * t
            local d = (px - qx) ^ 2 + (py - qy) ^ 2
            if d < best then best, bz = d, R.Z[k] + (R.Z[k + 1] - R.Z[k]) * t end
          end
        end
        if bz and best < (br.w / 2) ^ 2 and math.abs(bz - br.Z[q]) < 0.8 then br.Z[q] = bz; br.on_track = true end
      end
    end
  end
end

-- the axis parameter nearest to (x, y): segment index and fraction
local function on_axis(br, x, y)
  local X, Y = br.X, br.Y
  local best, bq, bt = huge, 1, 0
  for q = 1, #X - 1 do
    local ax, ay = X[q], Y[q]
    local dx, dy = X[q + 1] - ax, Y[q + 1] - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / l2)) or 0
    local d = (x - ax - dx * t) ^ 2 + (y - ay - dy * t) ^ 2
    if d < best then best, bq, bt = d, q, t end
  end
  return bq, bt
end

local function point_in(xs, ys, x, y)
  local inside, n = false, #xs
  local j = n
  for i = 1, n do
    if ((ys[i] > y) ~= (ys[j] > y)) and (x < (xs[j] - xs[i]) * (y - ys[i]) / (ys[j] - ys[i]) + xs[i]) then inside = not inside end
    j = i
  end
  return inside
end

-- the ground under a bridge is always opened to what it crosses (the builder raises streets over canals, so
-- under a bridge the road would otherwise fill the canal): water cells inside the outline become water
function Stream:cut_under_bridges(C)
  if C.under then return C.under end
  local U, tn = {}, C.tn
  local cx0, cy0, cx1, cy1 = C.x0, C.y0, C.x0 + tn, C.y0 + tn
  for _, br in pairs(self.bridges) do
    if br.x1 > cx0 and br.x0 < cx1 and br.y1 > cy0 and br.y0 < cy1 then
      for j = max(0, floor(br.y0 - C.y0)), min(tn - 1, floor(br.y1 - C.y0)) do
        for i = max(0, floor(br.x0 - C.x0)), min(tn - 1, floor(br.x1 - C.x0)) do
          if point_in(br.IX, br.IY, C.x0 + i + 0.5, C.y0 + j + 0.5) then U[j * tn + i] = true end
        end
      end
    end
  end
  C.under = U
  return U
end

-- a bridge: arched over a short water crossing (springing at the water, crown just under the deck), a beam
-- (flat underside) with pillars otherwise
local function build_bridge(self, u)
  local br = self.bridges[u.i]
  local M, L = self.M, self.look
  local P = L.bridge
  local X, Y, Z = br.X, br.Y, br.Z
  local n = #X
  local function chunk_at(x, y)
    local cx, cy = floor(x / self.CS), floor(y / self.CS)
    return self.near[ckey(cx, cy)] and self.D:chunk(cx, cy)
  end
  local wet, zs = {}, huge
  local ground = {}
  for q = 1, n do
    local C = chunk_at(X[q], Y[q])
    if C then
      local i, j = floor(X[q] - C.x0), floor(Y[q] - C.y0)
      if i >= 0 and j >= 0 and i < C.tn and j < C.tn then
        ground[q] = C.H[j * C.n + i]
        if C.W and C.T[j * C.tn + i] == L.water_tag then
          wet[q] = true
          local wz = M.water_z(C, X[q] - C.x0, Y[q] - C.y0)
          ground[q] = min(ground[q], wz - 1.5)
          if wz < zs then zs = wz end
        end
      end
    end
  end
  -- underside along the axis
  local U = {}
  local ka, kb
  for q = 1, n do if wet[q] then ka = ka or q; kb = q end end
  local arched = false
  if br.kind == "arch" and ka then
    ka, kb = max(1, ka - 2), min(n, kb + 2)
    local zc = huge
    for q = ka, kb do zc = min(zc, Z[q] - P.thick - 0.15) end
    if zc - zs > 0.9 and kb > ka then
      arched = true
      for q = 1, n do
        if q < ka or q > kb then U[q] = zs - 0.3
        else
          local t = (q - ka) / (kb - ka)
          U[q] = zs - 0.3 + (zc - zs + 0.3) * sqrt(max(0, 1 - (2 * t - 1) ^ 2))
        end
      end
    end
  end
  if not arched then for q = 1, n do U[q] = Z[q] - P.thick end end
  local ox, oy = br.x0, br.y0
  -- position along the axis for a point: queries come in neighbouring order, so search near the last answer
  -- first (a full search only when that isn't clearly the closest)
  local last = 1
  local function along(x, y)
    local best, bq, bt = huge, last, 0
    local lo, hi = max(1, last - 4), min(n - 1, last + 4)
    for pass = 1, 2 do
      for q = lo, hi do
        local ax, ay = X[q], Y[q]
        local dx, dy = X[q + 1] - ax, Y[q + 1] - ay
        local l2 = dx * dx + dy * dy
        local t = l2 > 0 and max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / l2)) or 0
        local d = (x - ax - dx * t) ^ 2 + (y - ay - dy * t) ^ 2
        if d < best then best, bq, bt = d, q, t end
      end
      if (bq > lo and bq < hi) or (lo == 1 and hi == n - 1) then break end
      lo, hi = 1, n - 1
    end
    last = bq
    return bq, bt
  end
  local function zf(x, y)
    local q, t = along(x + ox, y + oy)
    return Z[q] + (Z[q + 1] - Z[q]) * t
  end
  local function uf(x, y)
    local q, t = along(x + ox, y + oy)
    return U[q] + (U[q + 1] - U[q]) * t
  end
  -- outline in local coordinates; an edge is a side (parapet) when it runs along the axis
  local xs, ys, side = {}, {}, {}
  local no = #br.OX
  for k = 1, no do xs[k], ys[k] = br.OX[k] - ox, br.OY[k] - oy end
  for k = 1, no do
    local k2 = k % no + 1
    local ex, ey = xs[k2] - xs[k], ys[k2] - ys[k]
    local l = sqrt(ex * ex + ey * ey)
    if l > 1e-6 then
      local q = on_axis(br, (xs[k] + xs[k2]) / 2 + ox, (ys[k] + ys[k2]) / 2 + oy)
      local ax, ay = X[q + 1] - X[q], Y[q + 1] - Y[q]
      local al = max(sqrt(ax * ax + ay * ay), 1e-6)
      side[k] = math.abs((ex * ax + ey * ay) / (l * al)) > 0.7
    end
  end
  -- pillars under a beam bridge: every ~18 m where it stands well above what is below
  local pillars = {}
  if not arched and br.length > 24 then
    local nump = floor(br.length / 18)
    for j = 1, nump do
      local q = max(1, min(n - 1, floor(n * j / (nump + 1))))
      local gz = ground[q]
      if gz and U[q] - gz > 2 then
        local dx, dy = X[q + 1] - X[q], Y[q + 1] - Y[q]
        local l = max(sqrt(dx * dx + dy * dy), 1e-6)
        pillars[#pillars + 1] = { X[q] - ox, Y[q] - oy, dx / l, dy / l, 1.2, max(1.5, br.w * 0.7), gz - 0.5, U[q] }
      end
    end
  end
  local g = M.buffer()
  local deck = L.tagcells_by_name[br.tag] or L.tagcells_by_name.asphalt or L.fallback_cells
  local function drop_at(x, y, dz)
    local wx, wy = x + ox, y + oy
    local C = chunk_at(wx, wy)
    if not C then return true end
    local i, j = floor(wx - C.x0), floor(wy - C.y0)
    if i < 0 or j < 0 or i >= C.tn or j >= C.tn then return true end
    if C.T[j * C.tn + i] == L.water_tag and (C.under[j * C.tn + i] or C.H[j * C.n + i] < dz - 1.0) then return true end
    return C.H[j * C.n + i] < dz - 1.0
  end
  M.bridge_model(g, xs, ys, side, zf, uf, deck, P, ox, oy, pillars, function(x, y, dz)
    local C = chunk_at(x + ox, y + oy)
    if C then self:cut_under_bridges(C) end
    return drop_at(x, y, dz)
  end)
  return { { g, "ground" } }, ox, oy
end

local builders = { r = build_bridge, b = build_block, c = build_cell, q = build_cell, l = build_l16, f = build_far }

-- ------------------------------------------------------------------ the frame loop ----
-- update what is wanted (cheap; call a few times a second)
function Stream:plan(s, px, py, fx, fy)
  -- 'behind' for the 4 m level is judged by where the route goes over the next 200 m, not the street
  -- the rider is on right now (in a city every corner would otherwise flip cells in and out)
  local ax, ay = self.route:pos(s + 200)
  local dx, dy = ax - px, ay - py
  local l = sqrt(dx * dx + dy * dy)
  if l > 20 then fx, fy = dx / l, dy / l end
  self.px, self.py, self.fx, self.fy = px, py, fx, fy
  local want = self:desired(s, px, py, fx, fy)
  self.want = want
  local q = {}
  for id, w in pairs(want) do
    local u = self.units[id]
    if not u or u.spec ~= w.spec then q[#q + 1] = id end
  end
  for id, u in pairs(self.units) do
    if not want[id] then u.stale = u.stale or self.E.clock() end
  end
  for id in pairs(want) do local u = self.units[id]; if u then u.stale = nil end end
  self.queue = q
  self:sort_queue()
end

local LEVEL = { r = -0.5, b = 0, q = 0.4, c = 1, l = 2, f = 3 }
function Stream:sort_queue()
  local want, px, py = self.want, self.px or 0, self.py or 0
  local pr = {}
  for _, id in ipairs(self.queue) do
    local w = want[id]
    local dx, dy = w.x - px, w.y - py
    pr[id] = LEVEL[w.kind] * 4000 + sqrt(dx * dx + dy * dy)
  end
  table.sort(self.queue, function(a, b) return pr[a] < pr[b] end)
end

-- a unit can only be built once what fills its holes exists (no flicker of the level below)
function Stream:ready(id, w)
  if w.kind == "q" and w.spec ~= "" then
    local bpc = floor(self.CS / self.cfg.block)
    for k in w.spec:gmatch("[^;]+") do
      local bi, bj = k:match("^(%-?%d+),(%-?%d+)$")
      local bid = "b:" .. (w.cx * bpc + tonumber(bi)) .. "," .. (w.cy * bpc + tonumber(bj))
      if not self.units[bid] then return false end
    end
  elseif w.kind == "l" then
    for _, ck in ipairs(w.holes) do
      if not self.units["c:" .. ck] then
        local any = false
        for id in pairs(self.units) do
          if id:sub(1, 2 + #ck) == "q:" .. ck then any = true; break end
        end
        if not any then return false end
      end
    end
  end
  return true
end

-- load the data a unit needs if it isn't loaded yet; true if something was loaded (one step)
function Stream:load_step(w)
  local D, key = self.D, w.cx and ckey(w.cx, w.cy)
  if not key then return false end
  if self.near[key] then
    local C = D.cache["c" .. key]
    if not C then D:chunk(w.cx, w.cy); return true end
    if not C.objs then D:chunk_objects(w.cx, w.cy); return true end
    if not C.bucket then
      -- (bucketing happens in the builders; do it here so it is its own step too)
      return false
    end
  else
    local px, py = floor(w.cx / self.per), floor(w.cy / self.per)
    local P = D.cache["p" .. px .. "," .. py]
    if not P then D:page(px, py); return true end
    if not P.objs then D:page_objects(px, py); return true end
  end
  return false
end

-- compute one unit's buffers; its meshes are then uploaded one per step (see work)
function Stream:compute(id)
  local w = self.want[id]
  local parts, ox, oy = builders[w.kind](self, w)
  local up = { id = id, w = w, ox = ox or 0, oy = oy or 0, parts = {}, p = 1, q0 = 0, handles = {}, quads = 0 }
  for _, p in ipairs(parts or {}) do
    if p[1].n > 0 then up.parts[#up.parts + 1] = p; up.quads = up.quads + p[1].n else self.M.release(p[1]) end
  end
  return up
end

-- upload the next mesh of the unit being built; true when the unit is complete (and swapped in)
function Stream:upload_step(up)
  local p = up.parts[up.p]
  if p then
    local b, mat = p[1], p[2]
    local cnt = min(self.cfg.slice_quads, b.n - up.q0)
    local h = up.handles[up.p]
    if not h then h = { h = {}, mat = mat, quads = b.n }; up.handles[up.p] = h end
    h.h[#h.h + 1] = self.E.upload(b, mat, up.q0, cnt)
    up.q0 = up.q0 + cnt
    if up.q0 >= b.n then up.p, up.q0 = up.p + 1, 0 end
    if up.parts[up.p] then return false end
  end
  for _, pp in ipairs(up.parts) do self.M.release(pp[1]) end
  local old = self.units[up.id]
  if old then for _, hh in ipairs(old.handles) do self.E.free(hh.h) end end
  local w = up.w
  self.units[up.id] = { id = up.id, kind = w.kind, spec = w.spec, handles = up.handles, ox = up.ox, oy = up.oy,
                        x = w.x, y = w.y, r = w.r, quads = up.quads }
  return true
end

-- build everything for one unit at once (tools and tests)
function Stream:build_one(id)
  local up = self:compute(id)
  while not self:upload_step(up) do end
  return up.quads
end

-- build for at most `budget` ms (or everything when budget is nil). Returns ms spent.
function Stream:work(budget_ms)
  local clock = self.E.clock
  local t0 = clock()
  local done = 0
  local q = self.queue
  local function over() return budget_ms and (clock() - t0) * 1000 >= budget_ms end
  while true do
    -- finish the unit being uploaded first
    local up = self.up
    if up then
      local tj = clock()
      local fin = self:upload_step(up)
      up.ms = (up.ms or 0) + (clock() - tj) * 1000
      if fin then
        self.up = nil
        done = done + 1
        local ms, kind = up.ms, up.w.kind
        self.stats.max_job_ms = max(self.stats.max_job_ms, up.slice_max or 0)
        local bk = self.stats.by_kind or {}; self.stats.by_kind = bk
        local e = bk[kind] or { n = 0, ms = 0, max = 0, quads = 0 }; bk[kind] = e
        e.n, e.ms, e.quads = e.n + 1, e.ms + ms, e.quads + up.quads
        if ms > e.max then e.max, e.max_id = ms, up.id end
      end
      up.slice_max = max(up.slice_max or 0, (clock() - tj) * 1000)
      if over() then break end
    else
      -- next wanted unit whose holes are already filled
      local picked
      local i = 1
      while i <= #q do
        local id = q[i]
        local w = self.want[id]
        local u = self.units[id]
        if not w or (u and u.spec == w.spec) then table.remove(q, i)
        elseif self:ready(id, w) then table.remove(q, i); picked = id; break
        else i = i + 1 end
      end
      if not picked then break end
      local tj = clock()
      -- loading a chunk or page from disk is a step of its own
      if self:load_step(self.want[picked]) then
        local lm = (clock() - tj) * 1000
        if lm > (self.stats.max_load_ms or 0) then self.stats.max_load_ms, self.stats.max_load_id = lm, picked end
        table.insert(q, 1, picked)
        if over() then break end
        goto next_step
      end
      tj = clock()
      self.up = self:compute(picked)
      self.up.ms = (clock() - tj) * 1000
      self.up.slice_max = self.up.ms
      self.stats.last_job = picked
      if over() then break end
    end
    ::next_step::
  end
  -- drop what is no longer wanted once everything wanted is built (or it has waited long enough)
  local now = clock()
  for id, u in pairs(self.units) do
    if u.stale and ((#q == 0 and not self.up) or now - u.stale > 3) then
      for _, h in ipairs(u.handles) do self.E.free(h.h) end
      self.units[id] = nil
    end
  end
  self.stats.build_ms = (clock() - t0) * 1000
  self.stats.jobs = done
  return self.stats.build_ms
end

function Stream:pending() return #self.queue + (self.up and 1 or 0) end

-- what to draw this frame: units in front of the camera and within range
function Stream:visible(px, py, fx, fy, max_dist)
  local out = {}
  for _, u in pairs(self.units) do
    local dx, dy = u.x - px, u.y - py
    local along = dx * fx + dy * fy
    if along > -u.r - 30 then
      local d = sqrt(dx * dx + dy * dy) - u.r
      if d < max_dist then out[#out + 1] = u end
    end
  end
  return out
end

return Stream
