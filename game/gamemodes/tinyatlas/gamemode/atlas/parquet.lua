-- Parquet files in plain Lua (Overture's map data, OpenStreetMap's Layercake): the footer (Thrift compact), and the
-- columns of a row group decoded to Lua values. Pages: data page v1 / v2 and dictionary pages; encodings PLAIN,
-- RLE_DICTIONARY / PLAIN_DICTIONARY, RLE (levels, booleans); compression none or ZSTD. Nested columns come back
-- assembled: a repeated column's row is a list (of lists, one per repeated level).
--
--   local meta = parquet.footer(bytes)              bytes: the file's end (string), with the footer
--   meta.schema, meta.leaves[path] = leaf ("names.primary", "sources.list.element.dataset", ...), meta.row_groups
--   parquet.chunk_range(rg, leaf) -> first byte (0-based), length      what to download for one column of a row group
--   parquet.read_column(chunk_bytes, rg, leaf, opts) -> values[1..rows]  opts.raw: BYTE_ARRAY as { buf, offset, len }
--   parquet.stats(rg, leaf) -> min, max (numbers for INT32 / INT64 / DOUBLE / FLOAT, strings for BYTE_ARRAY)
local zstd = ATLAS_REQUIRE("zstd")
local floor = math.floor

local M = {}

local P2 = {}
for i = 0, 63 do P2[i] = 2 ^ i end

local bytes_of = zstd.bytes_of

-- ---- Thrift compact protocol: structs as { [field id] = value } ----
local function varint(b, p)
  local v, m = 0, 1
  while true do
    local c = b[p]; p = p + 1
    v = v + (c % 128) * m
    if c < 128 then return v, p end
    m = m * 128
  end
end
local function zigzag(v) if v % 2 == 0 then return v / 2 end return -(v + 1) / 2 end

local read_value
local function read_struct(b, p)
  local t, fid = {}, 0
  while true do
    local h = b[p]; p = p + 1
    if h == 0 then return t, p end
    local ty = h % 16
    local d = floor(h / 16)
    if d == 0 then local v; v, p = varint(b, p); fid = zigzag(v) else fid = fid + d end
    if ty == 1 then t[fid] = true
    elseif ty == 2 then t[fid] = false
    else t[fid], p = read_value(b, p, ty) end
  end
end
local function str_of(b, a, n)
  local parts = {}
  for i = a, a + n - 1, 4096 do
    local j = i + 4095
    if j > a + n - 1 then j = a + n - 1 end
    parts[#parts + 1] = string.char(unpack(b, i, j))
  end
  return table.concat(parts)
end
M.str_of = str_of
function read_value(b, p, ty)
  if ty == 3 then local v = b[p]; return v >= 128 and v - 256 or v, p + 1 end
  if ty == 4 or ty == 5 or ty == 6 then local v; v, p = varint(b, p); return zigzag(v), p end
  if ty == 7 then return M.double(b, p), p + 8 end
  if ty == 8 then local n; n, p = varint(b, p); return str_of(b, p, n), p + n end
  if ty == 9 or ty == 10 then
    local h = b[p]; p = p + 1
    local n, et = floor(h / 16), h % 16
    if n == 15 then n, p = varint(b, p) end
    local l = {}
    local tick = M.parse_tick
    for i = 1, n do
      if et == 1 or et == 2 then l[i] = b[p] == 1; p = p + 1
      else l[i], p = read_value(b, p, et) end
      if tick and i % 64 == 0 then tick() end
    end
    return l, p
  end
  if ty == 11 then
    local n; n, p = varint(b, p)
    local m = {}
    if n > 0 then
      local kv = b[p]; p = p + 1
      local kt, vt = floor(kv / 16), kv % 16
      for _ = 1, n do
        local k, v
        k, p = read_value(b, p, kt)
        v, p = read_value(b, p, vt)
        m[k] = v
      end
    end
    return m, p
  end
  if ty == 12 then return read_struct(b, p) end
  error("parquet: unknown thrift type " .. tostring(ty))
end
M.read_struct = read_struct

-- ---- numbers ----
function M.double(b, p)
  local b7, b6 = b[p + 7], b[p + 6]
  local sign = b7 >= 128 and -1 or 1
  local e = (b7 % 128) * 16 + floor(b6 / 16)
  local m = ((((((b6 % 16) * 256 + b[p + 5]) * 256 + b[p + 4]) * 256 + b[p + 3]) * 256 + b[p + 2]) * 256 + b[p + 1]) * 256 + b[p]
  if e == 0 then
    if m == 0 then return 0 * sign end
    return sign * m * 2 ^ -1074
  elseif e == 2047 then
    return m == 0 and sign * math.huge or 0 / 0
  end
  return sign * (1 + m / P2[52]) * 2 ^ (e - 1023)
end
local function float32(b, p)
  local b3, b2 = b[p + 3], b[p + 2]
  local sign = b3 >= 128 and -1 or 1
  local e = (b3 % 128) * 2 + floor(b2 / 128)
  local m = ((b2 % 128) * 256 + b[p + 1]) * 256 + b[p]
  if e == 0 then return sign * m * 2 ^ -149 end
  if e == 255 then return m == 0 and sign * math.huge or 0 / 0 end
  return sign * (1 + m / P2[23]) * 2 ^ (e - 127)
end
local function int32(b, p)
  local v = b[p] + b[p + 1] * 256 + b[p + 2] * 65536 + b[p + 3] * 16777216
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end
local function int64(b, p)
  local lo = b[p] + b[p + 1] * 256 + b[p + 2] * 65536 + b[p + 3] * 16777216
  local hi = b[p + 4] + b[p + 5] * 256 + b[p + 6] * 65536 + b[p + 7] * 16777216
  if hi >= 2147483648 then return (hi - 4294967296) * 4294967296 + lo end
  return hi * 4294967296 + lo
end

-- ---- footer ----
local REP = { [0] = "required", "optional", "repeated" }
function M.footer(s, tick)
  M.parse_tick = tick
  local b, n = bytes_of(s, tick)
  if str_of(b, n - 3, 4) ~= "PAR1" then error("parquet: not a parquet file end") end
  local len = b[n - 7] + b[n - 6] * 256 + b[n - 5] * 65536 + b[n - 4] * 16777216
  local start = n - 8 - len + 1
  if start < 1 then M.parse_tick = nil; return nil, len + 8 end           -- more of the file's end is needed
  local fm = read_struct(b, start)
  M.parse_tick = nil
  local meta = { num_rows = fm[3], created_by = fm[6], row_groups = {}, leaves = {}, footer_len = len }
  -- the schema tree (depth first), with each leaf's levels
  local els = fm[2]
  local idx = 1
  local leaf_i = 0
  local function walk(path, maxdef, maxrep, reps)
    local e = els[idx]; idx = idx + 1
    local rep = REP[e[3] or 0]
    local d, r = maxdef, maxrep
    local reps2 = reps
    if path then
      if rep ~= "required" then d = d + 1 end
      if rep == "repeated" then
        r = r + 1
        reps2 = {}
        for i, v in ipairs(reps) do reps2[i] = v end
        reps2[#reps2 + 1] = d          -- this repeated node has an element at def level >= d
      end
    end
    local name = e[4]
    local p = path and (path == "" and name or path .. "." .. name) or ""
    local nc = e[5] or 0
    if nc == 0 and path then
      leaf_i = leaf_i + 1
      meta.leaves[p] = { path = p, index = leaf_i, type = e[1], type_length = e[2], max_def = d, max_rep = r,
        rep_defs = reps2, converted = e[6] }
    end
    for _ = 1, nc do walk(p, d, r, reps2) end
  end
  walk(nil, 0, 0, {})
  -- each column chunk kept compact: codec, values, bytes, data page offset, dictionary page offset, statistics
  -- (min, max raw) - a big file's footer (Layercake: 2,477 row groups) would take hundreds of MB as parsed
  for i, rg in ipairs(fm[4] or {}) do
    local cols = {}
    for j, cc in ipairs(rg[1]) do
      local c = cc[3]
      local st = c[12]
      cols[j] = { c[4], c[5], c[7], c[9], c[11], st and (st[6] or st[2]), st and (st[5] or st[1]) }
    end
    meta.row_groups[i] = { columns = cols, num_rows = rg[3], index = i }
    fm[4][i] = nil
  end
  return meta
end

local function cmeta(rg, leaf) return rg.columns[leaf.index] end

function M.chunk_range(rg, leaf)
  local c = cmeta(rg, leaf)
  local first = c[4]
  if c[5] and c[5] > 0 and c[5] < first then first = c[5] end
  return first, c[3]
end

-- a statistics value (PLAIN, no length prefix) as a Lua value
local function stat_value(leaf, s)
  if not s then return nil end
  local ty = leaf.type
  local b = bytes_of(s)
  if ty == 1 and #s == 4 then return int32(b, 1) end
  if ty == 2 and #s == 8 then return int64(b, 1) end
  if ty == 4 and #s == 4 then return float32(b, 1) end
  if ty == 5 and #s == 8 then return M.double(b, 1) end
  if ty == 6 then return s end
  return nil
end
function M.stats(rg, leaf)
  local c = cmeta(rg, leaf)
  return stat_value(leaf, c[6]), stat_value(leaf, c[7])
end

-- ---- RLE / bit-packed hybrid ----
-- n values of bit width bw from b[p..pend] into out[o..]
local function rle_hybrid(b, p, pend, bw, n, out, o)
  local got = 0
  local bytes_w = floor((bw + 7) / 8)
  while got < n and p <= pend do
    local h
    h, p = varint(b, p)
    if h % 2 == 0 then
      local count = h / 2
      local v = 0
      for k = bytes_w - 1, 0, -1 do v = v * 256 + b[p + k] end
      p = p + bytes_w
      if count > n - got then count = n - got end
      for i = 0, count - 1 do out[o + got + i] = v end
      got = got + count
    else
      local groups = (h - 1) / 2
      local total = groups * 8
      -- values LSB first across the bytes
      local bitpos = 0
      local limit = P2[bw]
      for i = 0, total - 1 do
        if got >= n then break end
        local v, have = 0, 0
        while have < bw do
          local byte = b[p + floor(bitpos / 8)] or 0
          local off = bitpos % 8
          local take = 8 - off
          if take > bw - have then take = bw - have end
          v = v + (floor(byte / P2[off]) % P2[take]) * P2[have]
          have = have + take
          bitpos = bitpos + take
        end
        out[o + got] = v % limit
        got = got + 1
      end
      p = p + groups * bw
    end
  end
  return p
end

local function bit_width(maxv)
  local w = 0
  while maxv >= 1 do maxv = floor(maxv / 2); w = w + 1 end
  return w
end

-- ---- values ----
-- n PLAIN values of a leaf from b[p..]; returns the position after them
local function plain(leaf, b, p, n, out, o, raw, tick)
  local ty = leaf.type
  if ty == 6 then
    for i = 0, n - 1 do
      if tick and i % 2048 == 0 then tick() end
      local len = b[p] + b[p + 1] * 256 + b[p + 2] * 65536 + b[p + 3] * 16777216
      p = p + 4
      if raw then out[o + i] = { b, p, len } else out[o + i] = str_of(b, p, len) end
      p = p + len
    end
  elseif ty == 5 then
    for i = 0, n - 1 do out[o + i] = M.double(b, p); p = p + 8 end
  elseif ty == 1 then
    for i = 0, n - 1 do out[o + i] = int32(b, p); p = p + 4 end
  elseif ty == 2 then
    for i = 0, n - 1 do out[o + i] = int64(b, p); p = p + 8 end
  elseif ty == 4 then
    for i = 0, n - 1 do out[o + i] = float32(b, p); p = p + 4 end
  elseif ty == 0 then
    for i = 0, n - 1 do
      local bit = floor(b[p + floor(i / 8)] / P2[i % 8]) % 2
      out[o + i] = bit == 1
    end
    p = p + floor((n + 7) / 8)
  elseif ty == 7 then
    local w = leaf.type_length
    for i = 0, n - 1 do
      if raw then out[o + i] = { b, p, w } else out[o + i] = str_of(b, p, w) end
      p = p + w
    end
  else
    error("parquet: unsupported type " .. tostring(ty))
  end
  return p
end

local function decompress(codec, b, p, clen, ulen, tick)
  if codec == 0 then
    if p == 1 and clen == #b then return b end
    local t = {}
    for i = 0, clen - 1 do
      t[i + 1] = b[p + i]
      if tick and i % 131072 == 0 then tick() end
    end
    return t
  end
  if codec ~= 6 then error("parquet: unsupported compression " .. tostring(codec)) end
  local src = {}
  for i = 0, clen - 1 do
    src[i + 1] = b[p + i]
    if tick and i % 131072 == 0 then tick() end
  end
  local out = zstd.decompress(src, tick)
  return out
end

-- one column chunk (its bytes, downloaded from chunk_range) -> per-row values
function M.read_column(s, rg, leaf, opts)
  opts = opts or {}
  local tick = opts.tick
  local b = bytes_of(s, tick)
  local c = cmeta(rg, leaf)
  local codec = c[1]
  local total = c[2]                   -- values (levels) in the chunk
  local maxdef, maxrep = leaf.max_def, leaf.max_rep
  local dbw, rbw = bit_width(maxdef), bit_width(maxrep)
  local dict
  local defs, reps, vals = {}, {}, {}
  local nlev, nval = 0, 0
  local p = 1
  while nlev < total and p <= #b do
    local ph
    ph, p = read_struct(b, p)
    local ptype, ulen, clen = ph[1], ph[2], ph[3]
    if ptype == 2 then
      local dh = ph[7]
      local pg = decompress(codec, b, p, clen, ulen, tick)
      dict = {}
      plain(leaf, pg, 1, dh[1], dict, 0, opts.raw, tick)
    elseif ptype == 0 or ptype == 3 then
      local nv, enc, pg, q, pend
      if ptype == 0 then
        local dh = ph[5]
        nv, enc = dh[1], dh[2]
        pg = decompress(codec, b, p, clen, ulen, tick)
        q, pend = 1, #pg
        if maxrep > 0 then
          local len = pg[q] + pg[q + 1] * 256 + pg[q + 2] * 65536 + pg[q + 3] * 16777216
          rle_hybrid(pg, q + 4, q + 3 + len, rbw, nv, reps, nlev + 1)
          q = q + 4 + len
        end
        if maxdef > 0 then
          local len = pg[q] + pg[q + 1] * 256 + pg[q + 2] * 65536 + pg[q + 3] * 16777216
          rle_hybrid(pg, q + 4, q + 3 + len, dbw, nv, defs, nlev + 1)
          q = q + 4 + len
        end
      else
        local dh = ph[8]
        nv, enc = dh[1], dh[4]
        local dlen, rlen = dh[5], dh[6]
        local compressed = dh[7] ~= false
        if maxrep > 0 then rle_hybrid(b, p, p + rlen - 1, rbw, nv, reps, nlev + 1) end
        if maxdef > 0 then rle_hybrid(b, p + rlen, p + rlen + dlen - 1, dbw, nv, defs, nlev + 1) end
        local vstart = p + rlen + dlen
        local vlen = clen - rlen - dlen
        if compressed and codec ~= 0 then pg = decompress(codec, b, vstart, vlen, ulen - rlen - dlen, tick)
        else pg = decompress(0, b, vstart, vlen, vlen) end
        q, pend = 1, #pg
      end
      -- how many of this page's levels carry a value
      local present = nv
      if maxdef > 0 then
        present = 0
        for i = nlev + 1, nlev + nv do if defs[i] == maxdef then present = present + 1 end end
      end
      if enc == 0 then
        plain(leaf, pg, q, present, vals, nval + 1, opts.raw, tick)
      elseif enc == 8 or enc == 2 then
        local bw = pg[q]
        local idx = {}
        rle_hybrid(pg, q + 1, pend, bw, present, idx, 1)
        for i = 1, present do vals[nval + i] = dict[idx[i]] end
      elseif enc == 3 and leaf.type == 0 then
        local len = pg[q] + pg[q + 1] * 256 + pg[q + 2] * 65536 + pg[q + 3] * 16777216
        local tmp = {}
        rle_hybrid(pg, q + 4, q + 3 + len, 1, present, tmp, 1)
        for i = 1, present do vals[nval + i] = tmp[i] == 1 end
      else
        error("parquet: unsupported encoding " .. tostring(enc) .. " in " .. leaf.path)
      end
      nlev, nval = nlev + nv, nval + present
      if tick then tick() end
    end
    p = p + clen
  end
  -- assemble rows
  local rows = {}
  if maxrep == 0 then
    local vi = 0
    for i = 1, nlev do
      if maxdef == 0 or defs[i] == maxdef then vi = vi + 1; rows[i] = vals[vi] end
    end
    rows.n = nlev
    return rows
  end
  local rd = leaf.rep_defs           -- the def level at which each repeated level has an element
  local L = {}
  local nrow = 0
  local vi = 0
  for i = 1, nlev do
    local r, d = reps[i], defs[i] or maxdef
    if r == 0 then nrow = nrow + 1; L[1] = {}; rows[nrow] = L[1] end
    for k = (r == 0 and 1 or r), maxrep do
      if d < rd[k] then break end
      local list = L[k]
      if k < maxrep then
        local nl = {}
        list[#list + 1] = nl
        L[k + 1] = nl
      else
        if d == maxdef then vi = vi + 1; list[#list + 1] = vals[vi] else list[#list + 1] = false end
      end
    end
  end
  rows.n = nrow
  return rows
end

return M
