-- Lossless WebP (VP8L) decoder in plain Lua, after the format specification (RFC 9649). Used for Mapterhorn
-- elevation tiles (Terrarium-encoded). Lossy WebP is not supported (and not useful for height data).
-- Shared by every game.
--
--   webp.decode(s) -> { w, h, A, R, G, B }   channel arrays, 0-based index y * w + x
local bit = bit or require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local byte, sub = string.byte, string.sub
local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local M = {}

-- ---------------------------------------------------------------------------------------------------------
-- bit reader (least significant bit first)
local function reader(s, p)
  local R = { s = s, p = p, bb = 0, bn = 0, n = #s }
  return R
end
local function need(R, k)
  while R.bn < k do
    local b = byte(R.s, R.p) or 0
    if R.p > R.n + 8 then error("webp: unexpected end of data") end
    R.p = R.p + 1
    R.bb = R.bb + b * 2 ^ R.bn                 -- doubles: up to 53 bits are exact
    R.bn = R.bn + 8
  end
end
local function bits(R, k)
  if k == 0 then return 0 end
  need(R, k)
  local m = 2 ^ k
  local v = R.bb % m
  R.bb = (R.bb - v) / m
  R.bn = R.bn - k
  return v
end

-- ---------------------------------------------------------------------------------------------------------
-- prefix (Huffman) codes: canonical, bits stored least significant first like DEFLATE
local FAST = 8
local function build(lens, n)
  local count = {}
  for l = 0, 15 do count[l] = 0 end
  local used, last = 0, 0
  for s = 0, n - 1 do
    local l = lens[s] or 0
    if l > 0 then count[l] = count[l] + 1; used = used + 1; last = s end
  end
  local code = { single = nil }
  if used <= 1 then code.single = last; return code end      -- one symbol: decoded without reading bits
  -- symbols sorted by length (puff style), for the slow path
  local offs, sym = {}, {}
  offs[1] = 0
  for l = 1, 14 do offs[l + 1] = offs[l] + count[l] end
  for s = 0, n - 1 do
    local l = lens[s] or 0
    if l > 0 then sym[offs[l]] = s; offs[l] = offs[l] + 1 end
  end
  code.count, code.sym = count, sym
  -- fast table for codes of up to FAST bits: index = next FAST input bits
  local fast = {}
  local nextc, c = {}, 0
  for l = 1, 15 do c = (c + count[l - 1]) * 2; nextc[l] = c end
  count[0] = 0
  for s = 0, n - 1 do
    local l = lens[s] or 0
    if l > 0 then
      local cv = nextc[l]; nextc[l] = cv + 1
      if l <= FAST then
        local r = 0
        for _ = 1, l do r = r * 2 + cv % 2; cv = floor(cv / 2) end
        for i = r, 2 ^ FAST - 1, 2 ^ l do fast[i] = s * 16 + l end
      end
    end
  end
  code.fast = fast
  return code
end

local function decode(R, code)
  if code.single then return code.single end
  need(R, FAST)
  local v = code.fast[R.bb % 256]
  if v then
    local l = v % 16
    local m = 2 ^ l
    R.bb = (R.bb - R.bb % m) / m
    R.bn = R.bn - l
    return (v - l) / 16
  end
  -- slow path: one bit at a time (puff)
  local count, sym = code.count, code.sym
  local c, first, index = 0, 0, 0
  for l = 1, 15 do
    c = c + bits(R, 1)
    local cnt = count[l]
    if c - cnt < first then return sym[index + (c - first)] end
    index = index + cnt
    first = (first + cnt) * 2
    c = c * 2
  end
  error("webp: bad prefix code")
end

local CL_ORDER = { 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }

local function read_code(R, size)
  local lens = {}
  if bits(R, 1) == 1 then                       -- simple code: one or two symbols
    local num = bits(R, 1) + 1
    local first8 = bits(R, 1)
    local s0 = bits(R, 1 + 7 * first8)
    lens[s0] = 1
    if num == 2 then lens[bits(R, 8)] = 1 end
    return build(lens, size)
  end
  local ncl = bits(R, 4) + 4
  local cl = {}
  for i = 1, ncl do cl[CL_ORDER[i]] = bits(R, 3) end
  local clcode = build(cl, 19)
  local maxsym = size
  if bits(R, 1) == 1 then
    local nb = 2 + 2 * bits(R, 3)
    maxsym = 2 + bits(R, nb)
  end
  local prev, s = 8, 0
  while s < size do
    if maxsym == 0 then break end
    maxsym = maxsym - 1
    local c = decode(R, clcode)
    if c < 16 then
      lens[s] = c; s = s + 1
      if c ~= 0 then prev = c end
    else
      local rep, val
      if c == 16 then rep, val = 3 + bits(R, 2), prev
      elseif c == 17 then rep, val = 3 + bits(R, 3), 0
      else rep, val = 11 + bits(R, 7), 0 end
      if s + rep > size then error("webp: code lengths run past the alphabet") end
      for _ = 1, rep do lens[s] = val; s = s + 1 end
    end
  end
  return build(lens, size)
end

-- ---------------------------------------------------------------------------------------------------------
-- LZ77 distances

local PLANE = { 0,1, 1,0, 1,1, -1,1, 0,2, 2,0, 1,2, -1,2, 2,1, -2,1, 2,2, -2,2, 0,3, 3,0, 1,3, -1,3, 3,1, -3,1,
  2,3, -2,3, 3,2, -3,2, 0,4, 4,0, 1,4, -1,4, 4,1, -4,1, 3,3, -3,3, 2,4, -2,4, 4,2, -4,2, 0,5, 3,4, -3,4, 4,3, -4,3,
  5,0, 1,5, -1,5, 5,1, -5,1, 2,5, -2,5, 5,2, -5,2, 4,4, -4,4, 3,5, -3,5, 5,3, -5,3, 0,6, 6,0, 1,6, -1,6, 6,1,
  -6,1, 2,6, -2,6, 6,2, -6,2, 4,5, -4,5, 5,4, -5,4, 3,6, -3,6, 6,3, -6,3, 0,7, 7,0, 1,7, -1,7, 5,5, -5,5, 7,1,
  -7,1, 4,6, -4,6, 6,4, -6,4, 2,7, -2,7, 7,2, -7,2, 3,7, -3,7, 7,3, -7,3, 5,6, -5,6, 6,5, -6,5, 8,0, 4,7, -4,7,
  7,4, -7,4, 8,1, 8,2, 6,6, -6,6, 8,3, 5,7, -5,7, 7,5, -7,5, 8,4, 6,7, -6,7, 7,6, -7,6, 8,5, 7,7, -7,7, 8,6, 8,7 }

local function prefix_value(R, p)
  if p < 4 then return p + 1 end
  local extra = floor((p - 2) / 2)
  local offset = (2 + p % 2) * 2 ^ extra
  return offset + bits(R, extra) + 1
end

-- 32-bit hash for the colour cache: (0x1e35a7bd * argb) >> (32 - cache_bits), exactly in doubles
local K = 0x1e35a7bd
local function cache_index(a, r, g, b, cbits)
  local lo = g * 256 + b
  local hi = a * 256 + r
  local prod = (lo * K + ((hi * K) % 65536) * 65536) % 4294967296
  return floor(prod / 2 ^ (32 - cbits))
end

-- ---------------------------------------------------------------------------------------------------------
-- entropy-coded image of w x h pixels; returns channel arrays A, R, G, B
local decode_image

local function sub_image(R, w, h)
  return decode_image(R, w, h, false)
end

function decode_image(R, w, h, main)
  local cbits = 0
  if bits(R, 1) == 1 then
    cbits = bits(R, 4)
    if cbits < 1 or cbits > 11 then error("webp: bad colour cache size") end
  end
  local csize = cbits > 0 and 2 ^ cbits or 0
  -- meta prefix codes (main image only)
  local mbits, mw, meta, ngroups = 0, 0, nil, 1
  if main and bits(R, 1) == 1 then
    mbits = bits(R, 3) + 2
    mw = floor((w + 2 ^ mbits - 1) / 2 ^ mbits)
    local mh = floor((h + 2 ^ mbits - 1) / 2 ^ mbits)
    local _, er, eg = sub_image(R, mw, mh)
    meta = {}
    for i = 0, mw * mh - 1 do
      local m = er[i] * 256 + eg[i]
      meta[i] = m
      if m + 1 > ngroups then ngroups = m + 1 end
    end
  end
  local groups = {}
  for gi = 0, ngroups - 1 do
    groups[gi] = {
      read_code(R, 256 + 24 + csize), read_code(R, 256), read_code(R, 256), read_code(R, 256), read_code(R, 40),
    }
  end
  local A, Rr, G, B = {}, {}, {}, {}
  local cA, cR, cG, cB = {}, {}, {}, {}
  local total = w * h
  local pos = 0
  local mdiv = 2 ^ mbits
  local cached = 0                                 -- pixels [0, cached) are in the colour cache
  local function flush_cache(upto)
    if csize == 0 then cached = upto; return end
    for i = cached, upto - 1 do
      local ci = cache_index(A[i], Rr[i], G[i], B[i], cbits)
      cA[ci], cR[ci], cG[ci], cB[ci] = A[i], Rr[i], G[i], B[i]
    end
    cached = upto
  end
  while pos < total do
    local x, y = pos % w, floor(pos / w)
    local grp = meta and groups[meta[floor(y / mdiv) * mw + floor(x / mdiv)]] or groups[0]
    local s = decode(R, grp[1])
    if s < 256 then
      G[pos] = s
      Rr[pos] = decode(R, grp[2])
      B[pos] = decode(R, grp[3])
      A[pos] = decode(R, grp[4])
      pos = pos + 1
    elseif s < 280 then
      local len = prefix_value(R, s - 256)
      local dsym = decode(R, grp[5])
      local dcode = prefix_value(R, dsym)
      local dist
      if dcode > 120 then dist = dcode - 120
      else
        local dx, dy = PLANE[2 * dcode - 1], PLANE[2 * dcode]
        dist = dy * w + dx
        if dist < 1 then dist = 1 end
      end
      if dist > pos then error("webp: back reference before the start") end
      if pos + len > total then error("webp: back reference past the end") end
      for k = 0, len - 1 do
        local q = pos + k - dist
        A[pos + k], Rr[pos + k], G[pos + k], B[pos + k] = A[q], Rr[q], G[q], B[q]
      end
      pos = pos + len
    else
      local ci = s - 280
      if csize == 0 or ci >= csize then error("webp: bad colour cache index") end
      flush_cache(pos)
      A[pos], Rr[pos], G[pos], B[pos] = cA[ci] or 0, cR[ci] or 0, cG[ci] or 0, cB[ci] or 0
      pos = pos + 1
    end
  end
  return A, Rr, G, B
end

-- ---------------------------------------------------------------------------------------------------------
-- inverse transforms

local function avg(a, b) return floor((a + b) / 2) end
local function clamp(v) if v < 0 then return 0 elseif v > 255 then return 255 end return v end

local function inv_predictor(img, tb, tw, sbits)
  local w, h, A, R, G, B = img.w, img.h, img.A, img.R, img.G, img.B
  local div = 2 ^ sbits
  local TG = tb[3]
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x
      local pa, pr, pg, pb
      if y == 0 then
        if x == 0 then pa, pr, pg, pb = 255, 0, 0, 0
        else local l = i - 1; pa, pr, pg, pb = A[l], R[l], G[l], B[l] end
      elseif x == 0 then
        local t = i - w; pa, pr, pg, pb = A[t], R[t], G[t], B[t]
      else
        local mode = TG[floor(y / div) * tw + floor(x / div)] % 16
        local l, t, tl = i - 1, i - w, i - w - 1
        local tr = (x == w - 1) and (i - w + 1 - w) or (i - w + 1)    -- rightmost column: leftmost pixel of the row
        if x == w - 1 then tr = y * w end
        if mode == 0 then pa, pr, pg, pb = 255, 0, 0, 0
        elseif mode == 1 then pa, pr, pg, pb = A[l], R[l], G[l], B[l]
        elseif mode == 2 then pa, pr, pg, pb = A[t], R[t], G[t], B[t]
        elseif mode == 3 then pa, pr, pg, pb = A[tr], R[tr], G[tr], B[tr]
        elseif mode == 4 then pa, pr, pg, pb = A[tl], R[tl], G[tl], B[tl]
        elseif mode == 5 then
          pa = avg(avg(A[l], A[tr]), A[t]); pr = avg(avg(R[l], R[tr]), R[t])
          pg = avg(avg(G[l], G[tr]), G[t]); pb = avg(avg(B[l], B[tr]), B[t])
        elseif mode == 6 then pa, pr, pg, pb = avg(A[l], A[tl]), avg(R[l], R[tl]), avg(G[l], G[tl]), avg(B[l], B[tl])
        elseif mode == 7 then pa, pr, pg, pb = avg(A[l], A[t]), avg(R[l], R[t]), avg(G[l], G[t]), avg(B[l], B[t])
        elseif mode == 8 then pa, pr, pg, pb = avg(A[tl], A[t]), avg(R[tl], R[t]), avg(G[tl], G[t]), avg(B[tl], B[t])
        elseif mode == 9 then pa, pr, pg, pb = avg(A[t], A[tr]), avg(R[t], R[tr]), avg(G[t], G[tr]), avg(B[t], B[tr])
        elseif mode == 10 then
          pa = avg(avg(A[l], A[tl]), avg(A[t], A[tr])); pr = avg(avg(R[l], R[tl]), avg(R[t], R[tr]))
          pg = avg(avg(G[l], G[tl]), avg(G[t], G[tr])); pb = avg(avg(B[l], B[tl]), avg(B[t], B[tr]))
        elseif mode == 11 then
          local qa, qr, qg, qb = A[l] + A[t] - A[tl], R[l] + R[t] - R[tl], G[l] + G[t] - G[tl], B[l] + B[t] - B[tl]
          local pL = abs(qa - A[l]) + abs(qr - R[l]) + abs(qg - G[l]) + abs(qb - B[l])
          local pT = abs(qa - A[t]) + abs(qr - R[t]) + abs(qg - G[t]) + abs(qb - B[t])
          if pL < pT then pa, pr, pg, pb = A[l], R[l], G[l], B[l] else pa, pr, pg, pb = A[t], R[t], G[t], B[t] end
        elseif mode == 12 then
          pa = clamp(A[l] + A[t] - A[tl]); pr = clamp(R[l] + R[t] - R[tl])
          pg = clamp(G[l] + G[t] - G[tl]); pb = clamp(B[l] + B[t] - B[tl])
        elseif mode == 13 then
          local function half(a, b) local d = a - b; d = d >= 0 and floor(d / 2) or -floor(-d / 2); return clamp(a + d) end
          pa = half(avg(A[l], A[t]), A[tl]); pr = half(avg(R[l], R[t]), R[tl])
          pg = half(avg(G[l], G[t]), G[tl]); pb = half(avg(B[l], B[t]), B[tl])
        else
          pa, pr, pg, pb = 255, 0, 0, 0                  -- modes 14 and 15 behave like 0 (libwebp)
        end
      end
      A[i] = (A[i] + pa) % 256; R[i] = (R[i] + pr) % 256; G[i] = (G[i] + pg) % 256; B[i] = (B[i] + pb) % 256
    end
  end
end

local function s8(v) return v >= 128 and v - 256 or v end
local function delta(t, c)
  local p = s8(t) * s8(c)
  return p >= 0 and floor(p / 32) or -floor((-p + 31) / 32)    -- arithmetic shift right by 5
end

local function inv_color(img, tb, tw, sbits)
  local w, h, R, G, B = img.w, img.h, img.R, img.G, img.B
  local div = 2 ^ sbits
  local TR, TG, TB = tb[2], tb[3], tb[4]
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x
      local e = floor(y / div) * tw + floor(x / div)
      local g2r, g2b, r2b = TB[e], TG[e], TR[e]
      local g = G[i]
      local r = (R[i] + delta(g2r, g)) % 256
      local b = (B[i] + delta(g2b, g) + delta(r2b, r)) % 256
      R[i], B[i] = r, b
    end
  end
end

local function inv_subtract_green(img)
  local R, G, B = img.R, img.G, img.B
  for i = 0, img.w * img.h - 1 do
    R[i] = (R[i] + G[i]) % 256; B[i] = (B[i] + G[i]) % 256
  end
end

local function inv_index(img, pal, wbits, full_w)
  local w, h = img.w, img.h                       -- w: packed width
  local A, R, G, B = img.A, img.R, img.G, img.B
  local nA, nR, nG, nB = {}, {}, {}, {}
  local bpp = 8 / 2 ^ wbits
  local per = 2 ^ wbits
  local mask = 2 ^ bpp
  local pA, pR, pG, pB, n = pal[1], pal[2], pal[3], pal[4], pal.n
  for y = 0, h - 1 do
    for x = 0, full_w - 1 do
      local packed = G[y * w + floor(x / per)]
      local idx = floor(packed / 2 ^ (bpp * (x % per))) % mask
      local o = y * full_w + x
      if idx < n then nA[o], nR[o], nG[o], nB[o] = pA[idx], pR[idx], pG[idx], pB[idx]
      else nA[o], nR[o], nG[o], nB[o] = 0, 0, 0, 0 end
    end
  end
  img.A, img.R, img.G, img.B, img.w = nA, nR, nG, nB, full_w
end

-- ---------------------------------------------------------------------------------------------------------

function M.decode(s)
  if sub(s, 1, 4) ~= "RIFF" or sub(s, 9, 12) ~= "WEBP" then error("webp: not a WebP file") end
  local p = 13
  local data
  while p + 8 <= #s + 1 do
    local tag = sub(s, p, p + 3)
    local a, b, c, d = byte(s, p + 4, p + 7)
    local len = a + b * 256 + c * 65536 + d * 16777216
    if tag == "VP8L" then data = p + 8; break end
    if tag == "VP8 " then error("webp: lossy WebP is not supported") end
    p = p + 8 + len + len % 2
  end
  if not data then error("webp: no VP8L chunk") end
  local R = reader(s, data)
  if bits(R, 8) ~= 0x2f then error("webp: bad VP8L signature") end
  local w = bits(R, 14) + 1
  local h = bits(R, 14) + 1
  bits(R, 1)                                       -- alpha hint
  if bits(R, 3) ~= 0 then error("webp: unknown VP8L version") end
  -- transforms
  local transforms = {}
  local xw = w
  while bits(R, 1) == 1 do
    local t = bits(R, 2)
    for _, tr in ipairs(transforms) do if tr.type == t then error("webp: transform used twice") end end
    local tr = { type = t, w = xw }
    if t == 0 or t == 1 then
      tr.bits = bits(R, 3) + 2
      tr.tw = floor((xw + 2 ^ tr.bits - 1) / 2 ^ tr.bits)
      local th = floor((h + 2 ^ tr.bits - 1) / 2 ^ tr.bits)
      local a, r, g, b = sub_image(R, tr.tw, th)
      tr.data = { a, r, g, b }
    elseif t == 3 then
      local n = bits(R, 8) + 1
      local a, r, g, b = sub_image(R, n, 1)
      for i = 1, n - 1 do                          -- the palette is delta coded
        a[i] = (a[i] + a[i - 1]) % 256; r[i] = (r[i] + r[i - 1]) % 256
        g[i] = (g[i] + g[i - 1]) % 256; b[i] = (b[i] + b[i - 1]) % 256
      end
      tr.pal = { a, r, g, b, n = n }
      tr.wbits = n <= 2 and 3 or (n <= 4 and 2 or (n <= 16 and 1 or 0))
      xw = floor((xw + 2 ^ tr.wbits - 1) / 2 ^ tr.wbits)
    end
    transforms[#transforms + 1] = tr
  end
  local A, Rr, G, B = decode_image(R, xw, h, true)
  local img = { w = xw, h = h, A = A, R = Rr, G = G, B = B }
  for k = #transforms, 1, -1 do
    local tr = transforms[k]
    if tr.type == 0 then inv_predictor(img, tr.data, tr.tw, tr.bits)
    elseif tr.type == 1 then inv_color(img, tr.data, tr.tw, tr.bits)
    elseif tr.type == 2 then inv_subtract_green(img)
    else inv_index(img, tr.pal, tr.wbits, tr.w) end
  end
  return { w = w, h = h, A = img.A, R = img.R, G = img.G, B = img.B }
end

return M
