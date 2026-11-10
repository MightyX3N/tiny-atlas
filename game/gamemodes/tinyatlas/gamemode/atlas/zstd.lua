-- Zstandard decompression (RFC 8878) in plain Lua: Overture's map data (Parquet pages) is compressed with it. No
-- dictionaries; checksums are not checked.
--   zstd.decompress(src [, tick]) -> byte table (1-based), length      src: string or byte table
local floor = math.floor

local M = {}

local function bytes_of(s, tick)
  if type(s) == "table" then return s, #s end
  local t, n = {}, #s
  local byte = string.byte
  for i = 1, n, 4096 do
    if tick and i % 262144 == 1 then tick() end
    local j = i + 4095
    if j > n then j = n end
    local c = { byte(s, i, j) }
    for k = 1, #c do t[i + k - 1] = c[k] end
  end
  return t, n
end
M.bytes_of = bytes_of

local P2 = {}
for i = 0, 53 do P2[i] = 2 ^ i end

local function highbit(v)            -- index of the highest set bit (v >= 1)
  local n = -1
  while v >= 1 do v = floor(v / 2); n = n + 1 end
  return n
end

-- ---- bit readers ----
-- forward (little endian, low bits first): used for FSE table descriptions
local function fwd(src, pos, last)
  return { src = src, byte = pos, bit = 0, last = last }
end
local function fread(r, n)
  local v, got = 0, 0
  while got < n do
    local b = r.src[r.byte] or 0
    local avail = 8 - r.bit
    local take = n - got
    if take > avail then take = avail end
    local part = floor(b / P2[r.bit]) % P2[take]
    v = v + part * P2[got]
    got = got + take
    r.bit = r.bit + take
    if r.bit == 8 then r.bit = 0; r.byte = r.byte + 1 end
  end
  return v
end
local function frewind(r, n)
  local p = (r.byte * 8 + r.bit) - n
  r.byte, r.bit = floor(p / 8), p % 8
end

-- backward bit stream over src[a..b] (a byte range): reads the highest remaining bits first; the last byte's highest
-- set bit is the start marker. r.pos = bits left (may go below 0: reads past the start give zeros)
local function bwd(src, a, b)
  local last = src[b]
  if not last or last == 0 then error("zstd: bad bit stream end") end
  local r = { src = src, a = a, pos = (b - a) * 8 + highbit(last) }
  return r
end
-- the n bits at bit position p (0 = lowest bit of src[a]) .. p+n-1, as a number; n <= 24
local function bits_at(r, p, n)
  if n == 0 then return 0 end
  local neg = 0
  if p < 0 then
    neg = -p
    if neg >= n then return 0 end
    p, n = 0, n - neg
  end
  local s, a = r.src, r.a
  local i = a + floor(p / 8)
  local off = p % 8
  local v = (s[i] or 0) + (s[i + 1] or 0) * 256 + (s[i + 2] or 0) * 65536 + (s[i + 3] or 0) * 16777216
  v = floor(v / P2[off]) % P2[n]
  return v * P2[neg]
end
local function bread(r, n)
  if n == 0 then return 0 end
  if n > 24 then
    local hi = bread(r, n - 24)
    return hi * P2[24] + bread(r, 24)
  end
  r.pos = r.pos - n
  return bits_at(r, r.pos, n)
end

-- ---- FSE ----
local function fse_table(norm, nsym, al)
  local size = P2[al]
  local sym, nb, base = {}, {}, {}
  local high = size - 1
  local desc = {}
  for s = 0, nsym - 1 do
    if norm[s] == -1 then sym[high] = s; high = high - 1; desc[s] = 1
    else desc[s] = norm[s] end
  end
  local step = floor(size / 2) + floor(size / 8) + 3
  local mask = size - 1
  local pos = 0
  for s = 0, nsym - 1 do
    local c = norm[s]
    if c > 0 then
      for _ = 1, c do
        sym[pos] = s
        repeat pos = (pos + step) % size until pos <= high
      end
    end
  end
  for i = 0, size - 1 do
    local s = sym[i]
    local d = desc[s]
    desc[s] = d + 1
    local b = al - highbit(d)
    nb[i] = b
    base[i] = d * P2[b] - size
  end
  return { sym = sym, nb = nb, base = base, al = al }
end
M.fse_table = fse_table

-- an FSE table description at src[pos..]: the table and the position after it
local function fse_header(src, pos, last, max_al)
  local r = fwd(src, pos, last)
  local al = fread(r, 4) + 5
  if al > max_al then error("zstd: FSE accuracy too high") end
  local remaining = P2[al]
  local norm, s = {}, 0
  while remaining > 0 and s < 256 do
    local bits = highbit(remaining + 1) + 1
    local val = fread(r, bits)
    local lower = P2[bits - 1] - 1
    local thr = P2[bits] - 1 - (remaining + 1)
    if (val % (lower + 1)) < thr then
      frewind(r, 1)
      val = val % (lower + 1)
    elseif val > lower then
      val = val - thr
    end
    local p = val - 1
    remaining = remaining - (p < 0 and -p or p)
    norm[s] = p
    s = s + 1
    if p == 0 then
      local rep = fread(r, 2)
      while true do
        for _ = 1, rep do norm[s] = 0; s = s + 1 end
        if rep == 3 then rep = fread(r, 2) else break end
      end
    end
  end
  if remaining ~= 0 then error("zstd: bad FSE table") end
  local after = r.byte + (r.bit > 0 and 1 or 0)
  return fse_table(norm, s, al), after
end

local function rle_table(s) return { sym = { [0] = s }, nb = { [0] = 0 }, base = { [0] = 0 }, al = 0 } end

-- ---- Huffman (literals) ----
local function huf_table(weights, n)
  -- weights[0..n-1]; the last symbol's weight is implied
  local sum = 0
  for i = 0, n - 1 do local w = weights[i]; if w > 0 then sum = sum + P2[w - 1] end end
  if sum == 0 then error("zstd: empty Huffman weights") end
  local maxb = highbit(sum) + 1
  local left = P2[maxb] - sum
  local lw = highbit(left) + 1
  if P2[lw - 1] ~= left then error("zstd: bad Huffman weights") end
  local bits = {}
  for i = 0, n - 1 do bits[i] = weights[i] > 0 and (maxb + 1 - weights[i]) or 0 end
  bits[n] = maxb + 1 - lw
  local ns = n + 1
  local cnt = {}
  for i = 0, maxb do cnt[i] = 0 end
  for i = 0, ns - 1 do cnt[bits[i]] = cnt[bits[i]] + 1 end
  local rank = { [maxb] = 0 }
  local syms, nbits = {}, {}
  for i = maxb, 1, -1 do
    rank[i - 1] = rank[i] + cnt[i] * P2[maxb - i]
    for k = rank[i], rank[i - 1] - 1 do nbits[k] = i end
  end
  for i = 0, ns - 1 do
    local b = bits[i]
    if b ~= 0 then
      local code = rank[b]
      local len = P2[maxb - b]
      for k = code, code + len - 1 do syms[k] = i end
      rank[b] = code + len
    end
  end
  return { sym = syms, nb = nbits, max = maxb }
end

-- the Huffman tree description at src[pos..]: the table and the position after it
local function huf_header(src, pos)
  local hb = src[pos]
  local weights, n = {}, 0
  if hb < 128 then
    -- FSE-compressed weights in the next hb bytes
    local t, after = fse_header(src, pos + 1, pos + hb, 6)
    local r = bwd(src, after, pos + hb)
    local s1 = bread(r, t.al)
    local s2 = bread(r, t.al)
    local sym, nb, base = t.sym, t.nb, t.base
    while true do
      weights[n] = sym[s1]; n = n + 1
      s1 = base[s1] + bread(r, nb[s1])
      if r.pos < 0 then weights[n] = sym[s2]; n = n + 1; break end
      weights[n] = sym[s2]; n = n + 1
      s2 = base[s2] + bread(r, nb[s2])
      if r.pos < 0 then weights[n] = sym[s1]; n = n + 1; break end
      if n > 255 then error("zstd: too many Huffman weights") end
    end
    return huf_table(weights, n), pos + 1 + hb
  end
  n = hb - 127
  for i = 0, n - 1 do
    local b = src[pos + 1 + floor(i / 2)]
    weights[i] = (i % 2 == 0) and floor(b / 16) or (b % 16)
  end
  return huf_table(weights, n), pos + 1 + floor((n + 1) / 2)
end

local function huf_stream(t, src, a, b, out, o, count)
  local r = bwd(src, a, b)
  local maxb = t.max
  local sym, nbits = t.sym, t.nb
  local mask = P2[maxb]
  local state = bread(r, maxb)
  for i = 0, count - 1 do
    out[o + i] = sym[state]
    local n = nbits[state]
    state = (state * P2[n]) % mask + bread(r, n)
  end
  return o + count
end

-- ---- sequences ----
local LL_BASE = { [0] = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128,
  256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 }
local LL_BITS = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16 }
local ML_BASE, ML_BITS = {}, {}
for i = 0, 31 do ML_BASE[i] = i + 3; ML_BITS[i] = 0 end
do
  local b = { 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539 }
  local n = { 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
  for i = 1, #b do ML_BASE[31 + i] = b[i]; ML_BITS[31 + i] = n[i] end
end
local function norm_of(list)
  local t = {}
  for i, v in ipairs(list) do t[i - 1] = v end
  return t
end
local LL_DEF = fse_table(norm_of({ 4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1,
  1, -1, -1, -1, -1 }), 36, 6)
local ML_DEF = fse_table(norm_of({ 1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1 }), 53, 6)
local OF_DEF = fse_table(norm_of({ 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1,
  -1 }), 29, 5)

local function seq_table(mode, src, pos, last, def, max_al, prev)
  if mode == 0 then return def, pos end
  if mode == 1 then return rle_table(src[pos]), pos + 1 end
  if mode == 2 then return fse_header(src, pos, last, max_al) end
  if not prev then error("zstd: repeat table without a previous one") end
  return prev, pos
end

-- one compressed block src[a..b] onto out (from position o): the new end position
local function block(F, src, a, b, out, o)
  -- literals
  local h0 = src[a]
  local ltype = h0 % 4
  local sf = floor(h0 / 4) % 4
  local lit, nlit = {}, 0
  local p
  if ltype <= 1 then
    local regen
    if sf == 0 or sf == 2 then regen = floor(h0 / 8); p = a + 1
    elseif sf == 1 then regen = floor(h0 / 16) + src[a + 1] * 16; p = a + 2
    else regen = floor(h0 / 16) + src[a + 1] * 16 + src[a + 2] * 4096; p = a + 3 end
    if ltype == 0 then
      for i = 0, regen - 1 do lit[i] = src[p + i] end
      p = p + regen
    else
      local v = src[p]
      for i = 0, regen - 1 do lit[i] = v end
      p = p + 1
    end
    nlit = regen
  else
    local hsize, sbits, streams = 3, 10, 4
    if sf == 0 then streams = 1 elseif sf == 2 then hsize, sbits = 4, 14 elseif sf == 3 then hsize, sbits = 5, 18 end
    local hv = 0
    for i = hsize - 1, 0, -1 do hv = hv * 256 + src[a + i] end
    local regen = floor(hv / 16) % P2[sbits]
    local csize = floor(hv / P2[4 + sbits]) % P2[sbits]
    p = a + hsize
    local cend = p + csize       -- first byte after the literals
    if ltype == 2 then F.huf, p = huf_header(src, p)
    elseif not F.huf then error("zstd: treeless literals without a table") end
    local t = F.huf
    if streams == 1 then
      huf_stream(t, src, p, cend - 1, lit, 0, regen)
    else
      local s1 = src[p] + src[p + 1] * 256
      local s2 = src[p + 2] + src[p + 3] * 256
      local s3 = src[p + 4] + src[p + 5] * 256
      local q = p + 6
      local each = floor((regen + 3) / 4)
      local oo = 0
      oo = huf_stream(t, src, q, q + s1 - 1, lit, oo, each); q = q + s1
      oo = huf_stream(t, src, q, q + s2 - 1, lit, oo, each); q = q + s2
      oo = huf_stream(t, src, q, q + s3 - 1, lit, oo, each); q = q + s3
      huf_stream(t, src, q, cend - 1, lit, oo, regen - 3 * each)
    end
    nlit = regen
    p = cend
  end
  -- sequences
  local nseq
  local c0 = src[p]
  if p > b then nseq = 0
  elseif c0 == 0 then nseq = 0; p = p + 1
  elseif c0 < 128 then nseq = c0; p = p + 1
  elseif c0 < 255 then nseq = (c0 - 128) * 256 + src[p + 1]; p = p + 2
  else nseq = src[p + 1] + src[p + 2] * 256 + 0x7F00; p = p + 3 end
  local lp = 0
  if nseq > 0 then
    local modes = src[p]; p = p + 1
    local llm, ofm, mlm = floor(modes / 64) % 4, floor(modes / 16) % 4, floor(modes / 4) % 4
    F.ll, p = seq_table(llm, src, p, b, LL_DEF, 9, F.ll)
    F.of, p = seq_table(ofm, src, p, b, OF_DEF, 8, F.of)
    F.ml, p = seq_table(mlm, src, p, b, ML_DEF, 9, F.ml)
    local LL, OF, ML = F.ll, F.of, F.ml
    local r = bwd(src, p, b)
    local sll = bread(r, LL.al)
    local sof = bread(r, OF.al)
    local sml = bread(r, ML.al)
    local rep = F.rep
    for k = 1, nseq do
      local llc, ofc, mlc = LL.sym[sll], OF.sym[sof], ML.sym[sml]
      local ofv = P2[ofc] + bread(r, ofc)
      local ml = ML_BASE[mlc] + bread(r, ML_BITS[mlc])
      local ll = LL_BASE[llc] + bread(r, LL_BITS[llc])
      local off
      if ofv > 3 then
        off = ofv - 3
        rep[3], rep[2], rep[1] = rep[2], rep[1], off
      else
        local idx = ofv + (ll == 0 and 1 or 0)
        if idx == 1 then off = rep[1]
        elseif idx == 2 then off = rep[2]; rep[2], rep[1] = rep[1], off
        elseif idx == 3 then off = rep[3]; rep[3], rep[2], rep[1] = rep[2], rep[1], off
        else off = rep[1] - 1; rep[3], rep[2], rep[1] = rep[2], rep[1], off end
      end
      if k < nseq then
        sll = LL.base[sll] + bread(r, LL.nb[sll])
        sml = ML.base[sml] + bread(r, ML.nb[sml])
        sof = OF.base[sof] + bread(r, OF.nb[sof])
      end
      for i = 0, ll - 1 do out[o + i] = lit[lp + i] end
      o, lp = o + ll, lp + ll
      local from = o - off
      if from < F.start then error("zstd: match before the start of the frame") end
      for i = 0, ml - 1 do out[o + i] = out[from + i] end
      o = o + ml
    end
  end
  for i = lp, nlit - 1 do out[o] = lit[i]; o = o + 1 end
  return o
end

function M.decompress(s, tick)
  local src, n = bytes_of(s)
  local out = {}
  local o = 1
  local p = 1
  while p <= n do
    local magic = src[p] + src[p + 1] * 256 + src[p + 2] * 65536 + src[p + 3] * 16777216
    if magic >= 0x184D2A50 and magic <= 0x184D2A5F then
      -- a skippable frame
      local size = src[p + 4] + src[p + 5] * 256 + src[p + 6] * 65536 + src[p + 7] * 16777216
      p = p + 8 + size
    elseif magic ~= 0xFD2FB528 then
      error("zstd: not a zstd frame")
    else
      p = p + 4
      local d = src[p]; p = p + 1
      local fcs_flag = floor(d / 64)
      local single = floor(d / 32) % 2 == 1
      local checksum = floor(d / 4) % 2 == 1
      local did = d % 4
      if not single then p = p + 1 end
      p = p + ({ [0] = 0, 1, 2, 4 })[did]
      local fcs_size = ({ [0] = single and 1 or 0, 2, 4, 8 })[fcs_flag]
      p = p + fcs_size
      local F = { rep = { 1, 4, 8 }, start = o }
      while true do
        local bh = src[p] + src[p + 1] * 256 + src[p + 2] * 65536
        p = p + 3
        local last = bh % 2 == 1
        local btype = floor(bh / 2) % 4
        local bsize = floor(bh / 8)
        if btype == 0 then
          for i = 0, bsize - 1 do out[o + i] = src[p + i] end
          o = o + bsize; p = p + bsize
        elseif btype == 1 then
          local v = src[p]
          for i = 0, bsize - 1 do out[o + i] = v end
          o = o + bsize; p = p + 1
        elseif btype == 2 then
          o = block(F, src, p, p + bsize - 1, out, o)
          p = p + bsize
        else
          error("zstd: reserved block type")
        end
        if tick then tick() end
        if last then break end
      end
      if checksum then p = p + 4 end
    end
  end
  return out, o - 1
end

return M
