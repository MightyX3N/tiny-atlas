-- The settings window's tabs, one per part of the scene:
--
--   Look     the look, the six colours (or made from one), clean pixel art
--   Water    still water: its shores, surface, tide
--   River    flowing water: its flow, surface and the mouth over a fall
--   Fall     the falling curtain, the splash, the pool where it lands, the mist
--   Rods     the guide rods drawn on the preview
--   Output   the loop's frames and time, how clear each part is
--
-- One setting a row, each with its value on it; the mouse resting on one
-- tells what it does. Parts that can be off (the tide, clean pixel art,
-- the rods) carry a switch on their section's line.
--
-- Pages.new(ctx) gives the panel's header and build; ctx is the window's
-- side of things (the settings and what a change does).

local G = ... or _WOWE

local Styles = G.require("styles")
local Style  = G.require("ui_style")
local I18n   = G.require("i18n")

local T = I18n.t

local Pages = {}

Pages.TABS = {
  { key = "look", icon = "drop" },
  { key = "water", icon = "pool" },
  { key = "river", icon = "river" },
  { key = "fall", icon = "fall" },
  { key = "rods", icon = "rod" },
  { key = "output", icon = "film" },
}

local LOOK_GROUPS = {
  { "look_falls", 1, 5 },
  { "look_still", 6, 9 },
  { "look_clean", 10, 16 },
}
Pages.LOOK_GROUPS = LOOK_GROUPS

local COLOR_NAMES = { "c_shadow", "c_deep", "c_base", "c_light", "c_highlight", "c_foam" }

local ALPHA_ROWS = { "water", "deep", "fall", "slits", "lines", "net", "patches", "waves", "foam", "shade",
                     "sparkle", "mist", "wet" }

-- ctx: { p(), set(key) -> setter (bakes again), recolor() (no baking),
--        setLook(name), color(i) / setColor(i, Color) / takeColor(i) /
--        colorsDone(), base() / setBase(Color) / takeBase() / baseDone(),
--        makeRamp(), rods, showRods(), setShowRods(v), setGuideOn(v),
--        rodAction(name), newSeed(), tab(), setTab(key) }
function Pages.new(ctx)
  local function p() return ctx.p() end

  -- A slider for setting `key` (its range from the settings').
  local function slider(ui, key, o)
    o = o or {}
    local r = Styles.RANGE[key]
    ui:slider{
      id = key, label = T(o.label or key), tip = T(o.tip or ("tip_" .. key)),
      min = o.min or r[1], max = o.max or r[2], step = o.step, suffix = o.suffix, fmt = o.fmt, dim = o.dim,
      get = o.get or function() return p()[key] end,
      set = o.set or ctx.set(key),
    }
  end

  local function dial(ui, key, dim)
    ui:dial{ id = key, label = T(key), tip = T("tip_" .. key), dim = dim,
      get = function() return p()[key] end, set = ctx.set(key) }
  end

  ------------------------------------------------------------------------
  -- Look
  ------------------------------------------------------------------------

  local function lookPage(ui)
    ui:section(T("sec_look"))
    for _, g in ipairs(LOOK_GROUPS) do
      ui:caption(T(g[1]))
      local items = {}
      for i = g[2], g[3] do
        local name = Styles.ORDER[i]
        items[#items + 1] = { value = name, text = T(name), on = (p().style == name) }
      end
      ui:chips{ id = "look", items = items, select = ctx.setLook }
    end

    ui:section(T("sec_colors"))
    ui:swatches{ id = "color", count = 6,
      get = function(i) return ctx.color(i) end,
      set = function(i, c) ctx.setColor(i, c) end,
      name = function(i) return T(COLOR_NAMES[i]) end,
      take = function(i) ctx.takeColor(i) end,
      done = ctx.colorsDone }
    ui:hint(T("colors_hint"))

    ui:section(T("sec_palgen"))
    ui:colorRow{ id = "palBase", label = T("palgen_base"), tip = T("tip_palBase"),
      get = ctx.base, set = ctx.setBase, take = ctx.takeBase, done = ctx.baseDone }
    local function ramp(key)
      return function(v)
        p()[key] = v
        ctx.makeRamp()
      end
    end
    slider(ui, "palHue", { set = ramp("palHue") })
    slider(ui, "palSat", { set = ramp("palSat") })
    slider(ui, "palRange", { step = 5, suffix = "%", set = ramp("palRange") })
    ui:buttons{
      { id = "palMake", text = T("palgen_make"), tip = T("tip_palgen_make"), click = ctx.makeRamp },
      { id = "palFg", icon = "fgTake", text = T("use_fg"), tip = T("tip_use_fg"), click = ctx.takeBase },
    }

    ui:section(T("sec_clean"), { id = "clean", tip = T("tip_clean"),
      get = function() return p().clean end, set = ctx.set("clean") })
    local off = not p().clean
    slider(ui, "cleanSize", { label = "clean_size", dim = off,
      fmt = function(v) return (v == 0) and T("auto") or string.format("%gx", 1 + (v - 1) * 0.5) end })
    slider(ui, "shallows", { dim = off })
    slider(ui, "stones", { dim = off })
    slider(ui, "dither", { dim = off, suffix = " px" })
  end

  ------------------------------------------------------------------------
  -- Water
  ------------------------------------------------------------------------

  local function waterPage(ui)
    ui:section(T("sec_shore"))
    slider(ui, "lap")
    slider(ui, "waves")
    slider(ui, "shade")
    slider(ui, "sparkle")

    ui:section(T("sec_surface"))
    slider(ui, "net")
    slider(ui, "cell", { suffix = " px" })
    slider(ui, "patches")
    slider(ui, "depth")
    slider(ui, "drift")
    dial(ui, "angle", (p().drift or 0) == 0)

    ui:section(T("sec_tide"), { id = "tide", tip = T("tip_tide"),
      get = function() return p().tide end, set = ctx.set("tide") })
    local off = not p().tide
    slider(ui, "tideAmp", { label = "tide_amp", dim = off, suffix = " px" })
    slider(ui, "tideCycles", { label = "tide_cycles", dim = off, suffix = "x" })
    slider(ui, "tideUneven", { label = "tide_uneven", dim = off })
    slider(ui, "tideWet", { label = "tide_wet", dim = off })

  end

  ------------------------------------------------------------------------
  -- River
  ------------------------------------------------------------------------

  local function riverPage(ui)
    ui:section(T("sec_flow"))
    slider(ui, "flow")
    slider(ui, "rush")
    slider(ui, "rapids")
    slider(ui, "streaks")
    dial(ui, "rangle")

    ui:section(T("sec_rsurface"))
    slider(ui, "rnet")
    slider(ui, "rcell", { suffix = " px" })
    slider(ui, "banks")
    slider(ui, "rdepth")
    slider(ui, "rpatches")

    ui:section(T("sec_mouth"))
    slider(ui, "mouthFoam", { suffix = " px" })
    slider(ui, "mouthFringe", { suffix = " px" })
    slider(ui, "mouthTeeth", { suffix = " px" })
    slider(ui, "mouthWave", { suffix = " px" })
    slider(ui, "mouthRagged")
    ui:hint(T("mouth_hint"))
  end

  ------------------------------------------------------------------------
  -- Fall
  ------------------------------------------------------------------------

  local function fallPage(ui)
    ui:section(T("sec_curtain"))
    local styles = {}
    for i, v in ipairs(Styles.FALL_STYLES) do styles[i] = { value = v, text = T("style_" .. v) } end
    ui:caption(T("style"))
    ui:choice{ id = "fallStyle", options = styles, tip = T("tip_fallStyle"),
      get = function() return p().fallStyle end, set = ctx.set("fallStyle") }
    slider(ui, "speed")
    slider(ui, "lines")
    slider(ui, "weave")
    slider(ui, "gaps")
    slider(ui, "top")
    slider(ui, "arcs")
    slider(ui, "edges")
    slider(ui, "shading")
    ui:choice{ id = "light", label = T("light"), tip = T("tip_light"),
      options = { { value = "left", text = T("left") }, { value = "right", text = T("right") } },
      get = function() return p().light end, set = ctx.set("light") }

    ui:section(T("sec_splash"))
    slider(ui, "foam")
    slider(ui, "spread")
    slider(ui, "bubble")
    slider(ui, "spray")

    ui:section(T("sec_pool"))
    slider(ui, "ripples")
    slider(ui, "reach")
    slider(ui, "reflect")
    slider(ui, "trail")

    ui:section(T("sec_mist"))
    slider(ui, "mist")
    slider(ui, "rise")
  end

  ------------------------------------------------------------------------
  -- Rods
  ------------------------------------------------------------------------

  local function rodsPage(ui)
    ui:section(T("sec_rods"), { id = "guideOn", tip = T("tip_guideOn"),
      get = function() return p().guideOn end, set = ctx.setGuideOn })
    local off = not p().guideOn
    ui:toggle{ id = "showRods", label = T("rods_show"), tip = T("tip_showRods"),
      get = ctx.showRods, set = ctx.setShowRods }
    ui:choice{ id = "rodKind", label = T("rod_kind"), dim = off,
      options = { { value = "flow", text = T("rod_flow"), tip = T("rod_flow_tip") },
                  { value = "lip", text = T("rod_lip"), tip = T("rod_lip_tip") } },
      get = function() return ctx.rods.kind end,
      set = function(v) ctx.rodAction(v) end }
    slider(ui, "guideStrength", { dim = off })
    slider(ui, "guideReach", { dim = off, suffix = " px" })
    slider(ui, "guideFoam", { dim = off })
    ui:buttons{
      { id = "guideBranch", icon = "branch", text = T("guide_branch"), tip = T("rod_branch_tip"),
        on = ctx.rods.branch and not off, click = function() ctx.rodAction("branch") end },
      { id = "guideFlip", icon = "reverse", text = T("guide_flip"), tip = T("rod_reverse_tip"),
        click = function() ctx.rodAction("reverse") end },
    }
    ui:buttons{
      { id = "guideUndo", icon = "undo", text = T("guide_undo"), tip = T("rod_undo_tip"),
        click = function() ctx.rodAction("undo") end },
      { id = "guideClear", icon = "trash", text = T("guide_clear"), tip = T("rod_clear_tip"),
        click = function() ctx.rodAction("clear") end },
    }
    ui:hint(T("rods_hint"))
  end

  ------------------------------------------------------------------------
  -- Output
  ------------------------------------------------------------------------

  local function outputPage(ui)
    ui:section(T("sec_loop"))
    local frames = {}
    for i, v in ipairs(Styles.FRAME_CHOICES) do frames[i] = { value = tonumber(v), text = v } end
    ui:choice{ id = "frames", label = T("frames"), tip = T("tip_frames"), options = frames,
      get = function() return p().frames end, set = ctx.set("frames") }
    slider(ui, "ms", { label = "frame_time", min = 20, max = 300, step = 10, suffix = " ms",
      set = function(v)
        p().ms = v
        ctx.recolor()
      end })
    ui:buttons{
      { id = "shuffle", icon = "dice", text = T("shuffle"), tip = T("tip_shuffle"), click = ctx.newSeed },
    }

    ui:section(T("sec_opacity"))
    for _, key in ipairs(ALPHA_ROWS) do
      slider(ui, "alpha_" .. key, { label = "a_" .. key, tip = "tip_alpha", min = 0, max = 100, step = 5,
        suffix = "%",
        get = function() return p().alpha[key] end,
        set = function(v)
          p().alpha[key] = v
          ctx.recolor()
        end })
    end
    ui:hint(T("opacity_hint"))
  end

  local PAGES = { look = lookPage, water = waterPage, river = riverPage, fall = fallPage, rods = rodsPage,
                  output = outputPage }

  local function header(ui)
    local items = {}
    for i, t in ipairs(Pages.TABS) do items[i] = { key = t.key, icon = t.icon, text = T("tab_" .. t.key) } end
    ui:tabs{ id = "tab", items = items, current = ctx.tab(), select = ctx.setTab }
  end

  local function build(ui)
    local page = PAGES[ctx.tab()] or lookPage
    page(ui)
  end

  return { header = header, build = build, scrollKey = function() return ctx.tab() end }
end

-- The colour of a hex code, and the hex code of a colour.
function Pages.colorOf(hex)
  return Style.colorOf(hex)
end

function Pages.hexOf(c)
  return Styles.hex(c.red, c.green, c.blue)
end

return Pages
