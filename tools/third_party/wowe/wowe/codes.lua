-- What a pixel of a frame is: one byte that says which element made it,
-- its colour (1 .. 6, Styles' six colours) and what lies under it (0
-- nothing, 1 the fall, 2 a water surface). 0 is no pixel.
--
-- Only the combinations that can happen get a byte, from a table (the
-- elements of both the falls and the surfaces would not fit a fixed
-- layout). C[el][under * 7 + lv] is the byte as a one-char string; LV, EL
-- and UN read a byte back.

local Codes = {}

Codes.ELEMENTS = {
  "water", "deep", "fall", "gaps",           -- of their own
  "lines", "lip", "edges",                    -- on a fall (the lip on a surface too)
  "streaks", "shore", "shade", "rings", "trail", -- on a surface
  "foam", "spray", "mist", "sparkle",         -- on anything
  "net", "patches", "waves",                  -- on a surface
  "wet",                                      -- the ground the tide just left
}

local E = {}
for i, name in ipairs(Codes.ELEMENTS) do E[name:upper()] = i - 1 end
E.GAP, E.LINE, E.EDGE, E.STREAK, E.RING, E.SPARK = E.GAPS, E.LINES, E.EDGES, E.STREAKS, E.RINGS, E.SPARKLE
E.PATCH, E.WAVE = E.PATCHES, E.WAVES
Codes.E = E

Codes.NONE, Codes.ON_FALL, Codes.ON_WATER = 0, 1, 2

-- Under what each element may lie. Mist lies over the ground only: 0 thick,
-- 1 thin (half its opacity); over water it lightens the water instead.
local UNDERS = {
  [E.WATER] = { 0 }, [E.DEEP] = { 0 }, [E.FALL] = { 0 }, [E.GAP] = { 0 },
  [E.LINE] = { 1 }, [E.LIP] = { 1, 2 }, [E.EDGE] = { 1 },
  [E.STREAK] = { 2 }, [E.SHORE] = { 2 }, [E.SHADE] = { 2 }, [E.RING] = { 2 }, [E.TRAIL] = { 2 },
  [E.FOAM] = { 0, 1, 2 }, [E.SPRAY] = { 0, 1, 2 }, [E.MIST] = { 0, 1 }, [E.SPARK] = { 1, 2 },
  [E.NET] = { 2 }, [E.PATCH] = { 2 }, [E.WAVE] = { 2 }, [E.WET] = { 0 },
}

-- Elements that are water themselves (see-through to the layers below),
-- and the wet ground (a darkening of what is under it).
Codes.ALONE = { [E.WATER] = true, [E.DEEP] = true, [E.FALL] = true, [E.GAP] = true, [E.WET] = true }

-- The opacity sliders: every element belongs to one group.
Codes.GROUPS = { "water", "deep", "fall", "slits", "lines", "net", "patches", "waves", "foam", "shade",
                 "sparkle", "mist", "wet" }
Codes.GROUP = {
  [E.WATER] = "water", [E.DEEP] = "deep", [E.FALL] = "fall", [E.GAP] = "slits",
  [E.LINE] = "lines", [E.LIP] = "lines", [E.EDGE] = "lines", [E.STREAK] = "lines",
  [E.SHORE] = "foam", [E.SHADE] = "shade", [E.RING] = "lines", [E.TRAIL] = "foam",
  [E.FOAM] = "foam", [E.SPRAY] = "foam", [E.MIST] = "mist", [E.SPARK] = "sparkle",
  [E.NET] = "net", [E.PATCH] = "patches", [E.WAVE] = "waves", [E.WET] = "wet",
}

local C, LV, EL, UN = {}, { [0] = 0 }, { [0] = -1 }, { [0] = 0 }
local next = 1
for el = 0, #Codes.ELEMENTS - 1 do
  C[el] = {}
  for _, u in ipairs(UNDERS[el]) do
    for lv = 1, 6 do
      assert(next <= 255, "too many pixel codes")
      C[el][u * 7 + lv] = string.char(next)
      LV[next], EL[next], UN[next] = lv, el, u
      next = next + 1
    end
  end
end
Codes.C, Codes.LV, Codes.EL, Codes.UN = C, LV, EL, UN
Codes.COUNT = next - 1
Codes.CH0 = "\0"

-- The byte (a number) for an element, colour and what is under it.
function Codes.code(el, lv, under)
  local c = C[el][(under or 0) * 7 + lv]
  return c and c:byte() or nil
end

-- colour, element, under of a byte (0: 0, -1, 0).
function Codes.decode(b)
  return LV[b] or 0, EL[b] or -1, UN[b] or 0
end

return Codes
