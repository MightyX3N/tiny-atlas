-- DEFLATE decoder (RFC 1951) with zlib (RFC 1950) and gzip (RFC 1952) wrappers, in plain Lua.
-- Needs LuaJIT's `bit` library (present in GMod and LOVE). Shared by every game.
--
--   inflate.raw(s [, pos])  -> byte table, count       raw deflate stream
--   inflate.zlib(s)         -> byte table, count       zlib stream (PNG IDAT)
--   inflate.gzip(s)         -> byte table, count       gzip member
--   inflate.auto(s)         -> string                  gzip if it starts with 1f 8b, else s unchanged
--   inflate.tostring(t, n)  -> string
local bit = bit or require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local byte, char, concat, unpack = string.byte, string.char, table.concat, unpack or table.unpack

local M = {}

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- Build a lookup table from code lengths (lens[0..n-1]). Entry = symbol * 16 + length, indexed by the next
-- `maxlen` input bits (least significant bit first, as DEFLATE stores Huffman codes bit-reversed).
local function build(lens, n)
  local maxlen, count = 0, {}
  for i = 0, 15 do count[i] = 0 end
  for i = 0, n - 1 do
    local l = lens[i] or 0
    count[l] = count[l] + 1
    if l > maxlen then maxlen = l end
  end
  local tab = {}
  if maxlen == 0 then return tab, 0 end
  count[0] = 0
  local nextc, code = {}, 0
  for l = 1, maxlen do
    code = lshift(code + count[l - 1], 1)
    nextc[l] = code
  end
  local size = lshift(1, maxlen)
  for sym = 0, n - 1 do
    local l = lens[sym] or 0
    if l > 0 then
      local c = nextc[l]; nextc[l] = c + 1
      local r = 0                                   -- reverse the l-bit code
      for _ = 1, l do r = bor(lshift(r, 1), band(c, 1)); c = rshift(c, 1) end
      local step, v = lshift(1, l), sym * 16 + l
      for i = r, size - 1, step do tab[i] = v end
    end
  end
  return tab, maxlen
end

local FIXED_LIT, FIXED_LIT_BITS, FIXED_DIST, FIXED_DIST_BITS
do
  local l = {}
  for i = 0, 143 do l[i] = 8 end
  for i = 144, 255 do l[i] = 9 end
  for i = 256, 279 do l[i] = 7 end
  for i = 280, 287 do l[i] = 8 end
  FIXED_LIT, FIXED_LIT_BITS = build(l, 288)
  local d = {}
  for i = 0, 29 do d[i] = 5 end
  FIXED_DIST, FIXED_DIST_BITS = build(d, 30)
end

function M.raw(s, pos)
  local p = pos or 1                 -- next input byte
  local slen = #s
  local bb, bn = 0, 0                -- bit buffer and number of bits in it
  local out, n = {}, 0

  local function need(k)             -- make sure the buffer holds at least k bits (k <= 24)
    while bn < k do
      local b = byte(s, p)
      if not b then
        if p > slen + 4 then error("inflate: unexpected end of data") end
        b = 0                         -- pad: a final code may peek past the end
      end
      p = p + 1
      bb = bor(bb, lshift(b, bn)); bn = bn + 8
    end
  end
  local function bits(k)
    if k == 0 then return 0 end
    need(k)
    local v = band(bb, lshift(1, k) - 1)
    bb = rshift(bb, k); bn = bn - k
    return v
  end
  local function decode(tab, maxlen)
    need(maxlen)
    local v = tab[band(bb, lshift(1, maxlen) - 1)]
    if not v then error("inflate: bad Huffman code") end
    local l = band(v, 15)
    bb = rshift(bb, l); bn = bn - l
    return rshift(v, 4)
  end

  repeat
    local final = bits(1)
    local btype = bits(2)
    if btype == 0 then
      local drop = bn % 8                            -- stored block: skip to a byte boundary, and give
      bb = rshift(bb, drop); bn = bn - drop          -- back whole bytes already read into the buffer
      p = p - bn / 8; bb, bn = 0, 0
      local lo, hi = byte(s, p, p + 1)
      local len = lo + hi * 256
      p = p + 4
      if p + len - 1 > slen then error("inflate: stored block past end") end
      for i = p, p + len - 1 do n = n + 1; out[n] = byte(s, i) end
      p = p + len
    elseif btype == 1 or btype == 2 then
      local lit, litb, dist, distb
      if btype == 1 then
        lit, litb, dist, distb = FIXED_LIT, FIXED_LIT_BITS, FIXED_DIST, FIXED_DIST_BITS
      else
        local hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
        local cl = {}
        for i = 1, hclen do cl[CL_ORDER[i]] = bits(3) end
        local cltab, clbits = build(cl, 19)
        local lens, i = {}, 0
        while i < hlit + hdist do
          local sym = decode(cltab, clbits)
          if sym < 16 then
            lens[i] = sym; i = i + 1
          elseif sym == 16 then
            if i == 0 then error("inflate: repeat with no previous length") end
            local prev = lens[i - 1]
            for _ = 1, 3 + bits(2) do lens[i] = prev; i = i + 1 end
          elseif sym == 17 then
            for _ = 1, 3 + bits(3) do lens[i] = 0; i = i + 1 end
          else
            for _ = 1, 11 + bits(7) do lens[i] = 0; i = i + 1 end
          end
        end
        local dl = {}
        for k = 0, hdist - 1 do dl[k] = lens[hlit + k] end
        lit, litb = build(lens, hlit)
        dist, distb = build(dl, hdist)
      end
      while true do
        local sym = decode(lit, litb)
        if sym < 256 then
          n = n + 1; out[n] = sym
        elseif sym == 256 then
          break
        else
          sym = sym - 256
          local len = LEN_BASE[sym] + bits(LEN_EXTRA[sym])
          local ds = decode(dist, distb) + 1
          local d = DIST_BASE[ds] + bits(DIST_EXTRA[ds])
          if d > n then error("inflate: distance too far back") end
          local from = n - d
          for k = 1, len do out[n + k] = out[from + k] end
          n = n + len
        end
      end
    else
      error("inflate: bad block type")
    end
  until final == 1
  -- bytes still in the bit buffer were read ahead; hand back the position after the stream
  return out, n, p - rshift(bn, 3)
end

function M.zlib(s)
  local cmf, flg = byte(s, 1, 2)
  if not cmf or band(cmf, 15) ~= 8 or (cmf * 256 + flg) % 31 ~= 0 then error("inflate: not a zlib stream") end
  if band(flg, 32) ~= 0 then error("inflate: zlib preset dictionary not supported") end
  return M.raw(s, 3)
end

function M.gzip(s)
  local a, b, cm, flg = byte(s, 1, 4)
  if a ~= 0x1f or b ~= 0x8b or cm ~= 8 then error("inflate: not a gzip stream") end
  local p = 11
  if band(flg, 4) ~= 0 then local lo, hi = byte(s, p, p + 1); p = p + 2 + lo + hi * 256 end
  if band(flg, 8) ~= 0 then while byte(s, p) ~= 0 do p = p + 1 end p = p + 1 end
  if band(flg, 16) ~= 0 then while byte(s, p) ~= 0 do p = p + 1 end p = p + 1 end
  if band(flg, 2) ~= 0 then p = p + 2 end
  return M.raw(s, p)
end

function M.tostring(t, n)
  local parts, k = {}, 0
  for i = 1, n, 4096 do
    k = k + 1
    parts[k] = char(unpack(t, i, math.min(n, i + 4095)))
  end
  return concat(parts)
end

function M.auto(s)
  local a, b = byte(s, 1, 2)
  if a == 0x1f and b == 0x8b then return M.tostring(M.gzip(s)) end
  return s
end

return M
