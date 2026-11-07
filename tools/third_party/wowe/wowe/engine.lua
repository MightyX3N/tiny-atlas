-- The work queue: prepares the scene, then bakes its frames, a slice
-- at a time (a coroutine that pauses when its time is up), so the preview
-- never holds Aseprite up. A new region or new settings start over,
-- reusing what the last run left (Scape.prepare).
--
-- Frames are baked in the order the preview wants them: `Engine.want`
-- (the frame it is about to show) first, then on round the loop, so the
-- animation plays while it bakes and every baked frame shows at once.

local G = ... or _WOWE

local Scape = G.require("scape")

local Engine = {
  F = nil,        -- the last prepared scene
  region = nil,
  p = nil,
  levels = {},    -- frame -> level string, for region and p
  ready = false,  -- prepared: frames are coming
  done = false,   -- every frame baked
  want = 1,       -- the frame to bake next, when it is not baked yet
}

local co = nil
local deadline = math.huge

local function pause()
  if os.clock() > deadline then coroutine.yield() end
end

-- Starts over for this region and these settings (a copy is kept).
function Engine.start(region, p)
  Engine.region, Engine.p = region, p
  Engine.levels = {}
  Engine.ready, Engine.done = false, false
  if not region then
    co = nil
    Engine.ready, Engine.done = true, true
    return
  end
  local levels = Engine.levels
  co = coroutine.create(function()
    local F = Scape.prepare(region, p, Engine.F, pause)
    Engine.F = F
    Engine.ready = true
    local n = p.frames
    while true do
      local i = nil
      local w = Engine.want or 1
      for k = 0, n - 1 do
        local f = (w - 1 + k) % n + 1
        if not levels[f] then
          i = f
          break
        end
      end
      if not i then break end
      levels[i] = Scape.frame(F, p, i, pause)
      if Engine.onFrame then Engine.onFrame(i, levels[i]) end
    end
  end)
end

-- Works for up to `budget` seconds. True once every frame is baked.
function Engine.run(budget)
  if not co then return Engine.done end
  deadline = os.clock() + (budget or math.huge)
  local ok, err = coroutine.resume(co)
  deadline = math.huge
  if not ok then
    co = nil
    Engine.ready, Engine.done = true, true
    error(err, 0)
  end
  if coroutine.status(co) == "dead" then
    co = nil
    Engine.ready, Engine.done = true, true
  end
  return Engine.done
end

-- Bakes whatever is left, now.
function Engine.finish()
  while not Engine.done do Engine.run(math.huge) end
  return Engine.levels
end

-- Frames baked so far.
function Engine.count()
  local n = 0
  for i = 1, (Engine.p and Engine.p.frames or 0) do
    if Engine.levels[i] then n = n + 1 end
  end
  return n
end

function Engine.reset()
  co = nil
  Engine.F, Engine.region, Engine.p = nil, nil, nil
  Engine.levels = {}
  Engine.ready, Engine.done = false, false
  Engine.want = 1
end

return Engine
