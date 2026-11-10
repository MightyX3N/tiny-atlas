-- Cycling kits from a seed: one number makes the whole kit (jersey colours and pattern, sleeves, shorts, socks, shoes),
-- the same every time and on every computer, so a kit is shared (or sent to other riders) as that number. Plain
-- Lua, shared by GMod and LÖVE.
--
--   local kit = Kit.generate(seed [, locks])      locks: { jersey = {r,g,b}, pattern = "hoops", ... } kept as given
--   Kit.paint(kit, rect)        draws the kit's 64 x 64 texture: rect(x, y, w, h, r, g, b) in its pixels
--   Kit.uv(area, pu, pv) -> u, v     where a vertex of an area (jersey, trim, shorts, socks, shoes, skin, hair,
--                                    eyes) samples that texture; pu = around the body (front 0.5), pv = up the
--                                    jersey (0 waist .. 1 neck, -1 sleeves)
-- The rider's own looks (skin, hair) are not part of the kit: Kit.SKINS, Kit.HAIRS, chosen by the player.
--
-- Colours come from a curated set, and the pattern's colour always stands out from the jersey's (enough lightness
-- difference), so a random kit looks like a team's kit, not noise. Patterns are bold (a few texture pixels wide) so
-- they still read through the game's pixel-art filter at riding distance.
local Kit = {}
Kit.SIZE = 64

-- the colours kits are made of
Kit.COLOURS = {
  { "white", 238, 238, 232 }, { "black", 28, 28, 32 }, { "charcoal", 62, 64, 70 }, { "silver", 170, 174, 178 },
  { "red", 206, 40, 44 }, { "crimson", 150, 22, 40 }, { "orange", 238, 112, 30 }, { "yellow", 246, 206, 40 },
  { "lime", 160, 210, 50 }, { "green", 38, 140, 70 }, { "forest", 26, 84, 50 }, { "teal", 20, 150, 150 },
  { "sky", 90, 170, 230 }, { "blue", 30, 90, 200 }, { "navy", 22, 36, 82 }, { "purple", 110, 50, 160 },
  { "magenta", 210, 50, 140 }, { "pink", 244, 150, 180 }, { "brown", 110, 70, 40 }, { "sand", 214, 190, 140 },
}
-- patterns, with how often they come up (rarer ones can be unlocks)
Kit.PATTERNS = {
  { "plain", 10 }, { "hoops", 8 }, { "band", 9 }, { "stripes", 6 }, { "sash", 6 }, { "chevron", 5 }, { "sides", 7 },
  { "halves", 4 }, { "yoke", 7 }, { "fade", 4 }, { "pinstripe_band", 2 }, { "checks", 1 },
}
Kit.SKINS = { { 247, 214, 186 }, { 234, 188, 150 }, { 214, 160, 118 }, { 176, 120, 82 }, { 128, 84, 56 }, { 86, 56, 38 } }
Kit.HAIRS = { { 40, 30, 24 }, { 90, 60, 30 }, { 150, 104, 54 }, { 220, 186, 110 }, { 180, 70, 30 }, { 120, 120, 124 }, { 230, 230, 230 } }

-- a small random number generator of its own (the same everywhere)
local function rng(seed)
  local s = (math.floor(math.abs(seed or 1)) % 2147483646) + 1
  return function(n)
    s = (s * 48271) % 2147483647
    local r = s / 2147483647
    if n then return 1 + math.floor(r * n) end
    return r
  end
end
local function lum(c) return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] end
local function pick(list, r) return list[r(#list)] end
local function col(entry) return { entry[2], entry[3], entry[4], name = entry[1] } end

function Kit.generate(seed, locks)
  locks = locks or {}
  local r = rng(seed)
  local K = { seed = seed }
  K.jersey = locks.jersey or col(pick(Kit.COLOURS, r))
  -- the pattern's colour: clearly lighter or darker than the jersey
  local tries = 0
  repeat
    K.accent = col(pick(Kit.COLOURS, r))
    tries = tries + 1
  until math.abs(lum(K.accent) - lum(K.jersey)) > 70 or tries > 40
  K.accent = locks.accent or K.accent
  -- a third colour for thin edges, close to neither
  tries = 0
  repeat
    K.accent2 = col(pick(Kit.COLOURS, r))
    tries = tries + 1
  until (math.abs(lum(K.accent2) - lum(K.jersey)) > 50 and K.accent2.name ~= K.accent.name) or tries > 40
  K.accent2 = locks.accent2 or K.accent2
  -- the pattern, by how often each comes up
  local total = 0
  for _, p in ipairs(Kit.PATTERNS) do total = total + p[2] end
  local x, pat = r() * total, "plain"
  for _, p in ipairs(Kit.PATTERNS) do x = x - p[2]; if x <= 0 then pat = p[1]; break end end
  K.pattern = locks.pattern or pat
  K.sleeves = locks.sleeves or (r() < 0.35 and "accent" or "jersey")
  -- shorts: mostly black, sometimes navy / the jersey's colour if it is dark
  local sr = r()
  K.shorts = locks.shorts or (sr < 0.65 and col(Kit.COLOURS[2]) or sr < 0.8 and col(Kit.COLOURS[15])
    or (lum(K.jersey) < 110 and { K.jersey[1], K.jersey[2], K.jersey[3] } or col(Kit.COLOURS[3])))
  K.shorts_stripe = locks.shorts_stripe ~= nil and locks.shorts_stripe or (r() < 0.4)
  K.socks = locks.socks or (r() < 0.6 and col(Kit.COLOURS[1]) or { K.accent[1], K.accent[2], K.accent[3] })
  K.shoes = locks.shoes or (r() < 0.5 and col(Kit.COLOURS[2]) or r() < 0.6 and col(Kit.COLOURS[1]) or { K.accent[1], K.accent[2], K.accent[3] })
  -- the collar and hems: mostly the jersey's own colour, sometimes the pattern's
  local tc = r() < 0.7 and K.jersey or K.accent
  K.trim = locks.trim or { tc[1], tc[2], tc[3] }
  K.skin = locks.skin or Kit.SKINS[2]
  K.hair = locks.hair or Kit.HAIRS[2]
  return K
end

-- ---- the texture ----
-- rows 0-31: the jersey (x: around the body, the front at 32; y: 31 at the waist .. 0 at the neck)
-- rows 32-39: the sleeves; 40-47: the shorts (around); 48-63: plain colours (socks, shoes, skin, hair, eyes, trim)
local SWATCH = { socks = 0, shoes = 1, skin = 2, hair = 3, eyes = 4, trim = 5 }
function Kit.uv(area, pu, pv)
  if area == "jersey" then
    if pv < -0.5 then return 0.5, 36 / 64 end
    local v = math.max(0, math.min(1, pv))
    return pu, (31.5 - v * 31) / 64
  elseif area == "shorts" then
    return pu, 44 / 64
  end
  local s = SWATCH[area] or 2
  return (s * 8 + 4) / 64, 56 / 64
end

function Kit.paint(K, rect)
  local J, A, A2 = K.jersey, K.accent, K.accent2
  local function fill(x, y, w, h, c) rect(x, y, w, h, c[1], c[2], c[3]) end
  fill(0, 0, 64, 32, J)
  local p = K.pattern
  if p == "hoops" then
    for y = 2, 31, 10 do fill(0, y, 64, 5, A) end
  elseif p == "band" then
    fill(0, 9, 64, 8, A); fill(0, 8, 64, 1, A2); fill(0, 17, 64, 1, A2)
  elseif p == "pinstripe_band" then
    fill(0, 8, 64, 10, A)
    for x = 1, 63, 4 do fill(x, 8, 1, 10, A2) end
  elseif p == "stripes" then
    for x = 0, 63, 12 do fill(x, 0, 6, 32, A) end
  elseif p == "sash" then
    for y = 0, 31 do
      local x = 22 + math.floor(y * 0.7)            -- across the front, from one shoulder to the other hip
      fill(x, y, 7, 1, A)
      fill((x + 32) % 64, y, 7, 1, A)               -- and across the back
    end
  elseif p == "chevron" then
    for y = 0, 31 do
      local d = math.floor((31 - y) * 0.6)
      if y >= 6 and y <= 26 then
        fill(32 - 14 + d, y - 4, 3, 4, A); fill(32 + 11 - d, y - 4, 3, 4, A)
      end
    end
    fill(0, 0, 64, 5, A)
  elseif p == "sides" then
    fill(12, 0, 9, 32, A); fill(43, 0, 9, 32, A)
    fill(11, 0, 1, 32, A2); fill(52, 0, 1, 32, A2)
  elseif p == "halves" then
    fill(32, 0, 32, 32, A)
  elseif p == "yoke" then
    fill(0, 0, 64, 9, A); fill(0, 9, 64, 2, A2)
  elseif p == "fade" then
    for y = 0, 31 do
      local t = y / 31
      rect(0, y, 64, 1, math.floor(A[1] + (J[1] - A[1]) * t), math.floor(A[2] + (J[2] - A[2]) * t), math.floor(A[3] + (J[3] - A[3]) * t))
    end
  elseif p == "checks" then
    for y = 0, 31, 6 do for x = 0, 63, 6 do if (x + y) % 12 == 0 then fill(x, y, 6, 6, A) end end end
  end
  -- the sleeves, the shorts (black side panels or a stripe down each side)
  fill(0, 32, 64, 8, K.sleeves == "accent" and A or J)
  fill(0, 40, 64, 8, K.shorts)
  if K.shorts_stripe then fill(13, 40, 6, 8, A); fill(45, 40, 6, 8, A) end
  -- plain colours
  local sw = { K.socks, K.shoes, K.skin, K.hair, { 20, 20, 20 }, K.trim }
  for i, c in ipairs(sw) do fill((i - 1) * 8, 48, 8, 16, c) end
end

-- a short name for a kit, from its colours and pattern ("red and white hoops")
function Kit.describe(K)
  local n = (K.jersey.name or "custom") .. (K.pattern ~= "plain" and (" with " .. (K.accent.name or "custom") .. " " .. K.pattern:gsub("_", " ")) or "")
  return n
end

return Kit
