-- The new world builder (shared Lua in atlas/) running in Garry's Mod.
-- Milestone 1: the platform layer (downloads, cache files) and `ta_buildbench`, which downloads a real map tile
-- and builds its ground the way the game will: in slices of a few milliseconds per frame.
local BASE = (GM or GAMEMODE).FolderName .. "/gamemode/atlas/"
local loaded = {}
function ATLAS_REQUIRE(name)
  if loaded[name] == nil then loaded[name] = include(BASE .. name .. ".lua") end
  return loaded[name]
end

local fetch = ATLAS_REQUIRE("fetch")
local mvt = ATLAS_REQUIRE("mvt")
local cell = ATLAS_REQUIRE("cell")

-- ---- platform: downloads and binary cache files under garrysmod/data ----
local P = {}
function P.http_get(url, ok, err)
  http.Fetch(url, function(body, size, headers, code)
    if code and code >= 400 then return err("HTTP " .. code) end
    ok(body or "")
  end, function(e) err(tostring(e)) end)
end
function P.read(path)
  local f = file.Open(path, "rb", "DATA")
  if not f then return nil end
  local n = f:Size()
  local s = n > 0 and f:Read(n) or ""
  f:Close()
  return s
end
function P.write(path, data)
  local dir = path:match("^(.*)/[^/]*$")
  if dir then file.CreateDir(dir) end
  local f = file.Open(path, "wb", "DATA")
  if not f then return false end
  f:Write(data)
  f:Close()
  return true
end
function P.time() return os.time() end

local F = fetch.new(P, "tinyatlas/cache")
TinyAtlasFetch = F

-- ---- build jobs: coroutines resumed from Think, each frame spending at most ta_atlas_budget_ms ----
local budget = CreateClientConVar("ta_atlas_budget_ms", "4", true, false, "Milliseconds per frame the new world builder may use")
local jobs = {}

local last_frame = -1
local function run_jobs()
  if #jobs == 0 then return end
  -- run at most once per rendered frame, from whichever hook comes first
  local fn = FrameNumber and FrameNumber() or SysTime()
  if fn == last_frame then return end
  last_frame = fn
  -- say what is going on every few seconds, without being asked
  local job = jobs[1]
  local now = RealTime and RealTime() or SysTime()
  if not job.next_note then job.next_note = now + 3 end
  if now >= job.next_note then
    job.next_note = now + 3
    print(string.format("[Tiny Atlas] still working: %s (%.1f s CPU so far)", job.where or "starting", job.cpu))
  end
  local frame_end = SysTime() + budget:GetFloat() / 1000
  while #jobs > 0 and SysTime() < frame_end do
    local job = jobs[1]
    job.slice_end = frame_end
    local t0 = SysTime()
    job.slice_start = t0
    local ok, err = coroutine.resume(job.co)
    job.cpu = job.cpu + (SysTime() - t0)
    job.slices = job.slices + 1
    if not ok then
      print("[Tiny Atlas] FAILED while " .. (job.where or "starting") .. ": " .. tostring(err))
      ErrorNoHalt("[Tiny Atlas] build job failed: " .. tostring(err) .. "\n")
      table.remove(jobs, 1)
    elseif coroutine.status(job.co) == "dead" then
      table.remove(jobs, 1)
    end
  end
end
-- Think stops while single player is paused (console or menu open); PostRender keeps going while frames are drawn
hook.Add("Think", "TinyAtlasBuildJobs", run_jobs)
hook.Add("PostRender", "TinyAtlasBuildJobs", run_jobs)



local function add_job(fn)
  local job = { cpu = 0, slices = 0 }
  job.tick = function()
    if SysTime() >= job.slice_end then coroutine.yield() end
  end
  -- CPU time this job has used so far, including the running slice
  job.cpu_now = function() return job.cpu + (SysTime() - job.slice_start) end
  job.co = coroutine.create(function() fn(job) end)
  jobs[#jobs + 1] = job
  return job
end

-- ---- ta_buildbench [lat] [lon] [cells] ----
local function report(lines)
  file.CreateDir("tinyatlas/perf")
  local name = os.date("tinyatlas/perf/buildbench_%Y%m%d_%H%M%S.txt")
  file.Write(name, table.concat(lines, "\n") .. "\n")
  for _, l in ipairs(lines) do print(l) end
  if chat and chat.AddText then chat.AddText(Color(120, 200, 255), "[Tiny Atlas] ", color_white, lines[#lines]) end
  return name
end

concommand.Add("ta_buildbench", function(_, _, args)
  local lat = tonumber(args[1]) or 52.3731          -- default: Amsterdam, Dam square
  local lon = tonumber(args[2]) or 4.8925
  local ncell = math.Clamp(tonumber(args[3]) or 64, 1, 64)
  local tx, ty = fetch.tile_of(lat, lon, 14)
  print(string.format("[Tiny Atlas] build bench: tile 14/%d/%d (%.4f, %.4f), %d cells", tx, ty, lat, lon, ncell))
  print("[Tiny Atlas] getting the map tile...")
  local t_req = SysTime()
  local dl0 = F.stats.downloads
  F:get("omt", 14, tx, ty, function(bytes)
    local t_got = SysTime()
    print(string.format("[Tiny Atlas] tile ready (%d bytes, %s); building...", #bytes,
      F.stats.downloads > dl0 and "downloaded" or "from cache"))
    add_job(function(job)
      job.where = "decoding the tile"
      local wall0 = SysTime()
      local d0 = job.cpu_now()
      local layers = mvt.decode(bytes)
      local decode_ms = (job.cpu_now() - d0) * 1000
      coroutine.yield()
      local tlat = fetch.lat_of(ty + 0.5, 14)
      local per, problems, tris, worst = {}, 0, 0, { ms = -1 }
      local order = {}
      for cy = 0, 7 do for cx = 0, 7 do order[#order + 1] = { cx, cy } end end
      for k = 1, ncell do
        local cx, cy = order[k][1], order[k][2]
        job.where = string.format("cell %d of %d", k, ncell)
        local c0 = job.cpu_now()
        local r = cell.build(layers, cx, cy, tlat, { tick = job.tick, clock = SysTime })
        local spent = job.cpu_now() - c0
        per[#per + 1] = spent * 1000
        tris = tris + r.nt
        if #r.problems > 0 then
          problems = problems + 1
          print(string.format("[Tiny Atlas]   cell %d,%d: %s", cx, cy, table.concat(r.problems, "; ")))
        end
        if spent * 1000 > worst.ms then worst = { ms = spent * 1000, cx = cx, cy = cy, st = r.stats } end
      end
      job.where = "writing the report"
      local wall = SysTime() - wall0
      table.sort(per)
      local sum = 0 for _, v in ipairs(per) do sum = sum + v end
      local cell_m = 40075016.686 * math.cos(math.rad(tlat)) / 2 ^ 17
      -- a ride along a route needs about 3 new cells for every cell length it moves forward
      local kmh = (#per / wall) / 3 * cell_m * 3.6
      local lines = {
        string.format("Tiny Atlas build bench  %s", os.date("%Y-%m-%d %H:%M:%S")),
        string.format("tile 14/%d/%d  lat %.4f lon %.4f  cell %.0f m  JIT %s  budget %.1f ms/frame",
          tx, ty, lat, lon, cell_m, (jit and jit.status and jit.status()) and "on" or "off", budget:GetFloat()),
        string.format("download %.0f ms (%s)  decode %.1f ms  tile %d bytes", (t_got - t_req) * 1000,
          F.stats.downloads > dl0 and "network" or "cache", decode_ms, #bytes),
        string.format("cells %d  CPU per cell: mean %.1f ms  median %.1f  p95 %.1f  max %.1f (cell %d,%d)",
          #per, sum / #per, per[math.floor(#per / 2) + 1], per[math.floor(#per * 0.95) + 1], per[#per], worst.cx, worst.cy),
        string.format("wall time %.2f s over %d slices  triangles %d  cells with problems %d", wall, job.slices, tris, problems),
        string.format("keeps up with a rider at about %.0f km/h at this budget and frame rate", kmh),
        string.format("RESULT: %s (gate: every cell under 1000 ms CPU, keeps up with 40 km/h, no problems)",
          (per[#per] < 1000 and kmh >= 40 and problems == 0) and "PASS" or "FAIL"),
      }
      print("[Tiny Atlas] report written to data/" .. report(lines))
    end)
  end, function(e)
    print("[Tiny Atlas] FAILED: could not get the map tile: " .. tostring(e))
  end)
end)

-- ---- ta_fetch_testdata: download the map and height tiles of the test areas into the cache (one-time) ----
local TEST_AREAS = {
  { "Amsterdam (city run, canal ring)", 52.345, 52.385, 4.86, 4.93 },
  { "Copenhagen (lakes, harbour)", 55.655, 55.705, 12.53, 12.62 },
  { "Alpe d'Huez", 45.045, 45.100, 6.015, 6.085 },
  { "Rold Skov (countryside, forest)", 56.77, 56.84, 9.78, 9.90 },
}
concommand.Add("ta_fetch_testdata", function()
  local queue = {}
  for _, a in ipairs(TEST_AREAS) do
    local x0, y1 = fetch.tile_of(a[2], a[4], 14)
    local x1, y0 = fetch.tile_of(a[3], a[5], 14)
    for x = x0, x1 do for y = y0, y1 do
      queue[#queue + 1] = { "omt", x, y }
      queue[#queue + 1] = { "terrarium", x, y }
      queue[#queue + 1] = { "mapterhorn", x, y }
    end end
  end
  -- skip what is already in the cache, so running it again only fetches what is missing
  local todo = {}
  for _, q in ipairs(queue) do if not P.read(F:path(q[1], 14, q[2], q[3])) then todo[#todo + 1] = q end end
  print(string.format("[Tiny Atlas] %d of %d test tiles already cached", #queue - #todo, #queue))
  queue = todo
  local total, done, failed, running, nexti = #queue, 0, 0, 0, 1
  if total == 0 then print("[Tiny Atlas] test data: everything is already cached") return end
  local bytes0 = F.stats.bytes
  local t0, last_note = SysTime(), SysTime()
  print(string.format("[Tiny Atlas] fetching %d tiles for %d test areas...", total, #TEST_AREAS))
  local function pump()
    while running < 4 and nexti <= total do
      local q = queue[nexti]; nexti = nexti + 1
      running = running + 1
      F:get(q[1], 14, q[2], q[3], function()
        running = running - 1; done = done + 1
        if SysTime() - last_note > 3 then
          last_note = SysTime()
          print(string.format("[Tiny Atlas]   %d/%d tiles (%.1f MB downloaded)", done + failed, total, (F.stats.bytes - bytes0) / 1e6))
        end
        if done + failed == total then
          print(string.format("[Tiny Atlas] test data: %d tiles ready, %d failed, %.1f MB in %.0f s%s", done, failed,
            (F.stats.bytes - bytes0) / 1e6, SysTime() - t0, failed > 0 and "  FAILED for some tiles (see above)" or ""))
        else pump() end
      end, function(e)
        running = running - 1; failed = failed + 1
        print("[Tiny Atlas]   FAILED: " .. tostring(e))
        if done + failed == total then
          print(string.format("[Tiny Atlas] test data: %d tiles ready, %d failed", done, failed))
        else pump() end
      end)
    end
  end
  pump()
end)
