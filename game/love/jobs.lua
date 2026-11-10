-- Build jobs: coroutines resumed each frame for at most budget_ms (boost_ms while the loading screen is up).
-- job.tick() yields when the frame's time is used up. Same contract as the Garry's Mod runner.
local M = { list = {}, budget_ms = 4, boost_ms = nil }
local now = love.timer.getTime

function M.add(fn)
  local job = { cpu = 0, slices = 0 }
  job.tick = function()
    local P = M.profile                    -- (tests: the longest stretch without a tick, and where it ended)
    if P then
      local t = now()
      local gap = t - (job.last_tick or t)
      if gap > P.worst then P.worst = gap; P.where = debug.traceback("", 2) end
      job.last_tick = t
    end
    if now() >= job.slice_end then coroutine.yield(); job.last_tick = now() end
  end
  job.cpu_now = function() return job.cpu + (now() - job.slice_start) end
  job.co = coroutine.create(function() fn(job) end)
  M.list[#M.list + 1] = job
  return job
end

function M.run(log)
  local jobs = M.list
  local frame_end = now() + (M.boost_ms or M.budget_ms) / 1000
  while #jobs > 0 and now() < frame_end do
    local job = jobs[1]
    job.slice_end = frame_end
    local t0 = now()
    job.slice_start = t0
    job.last_tick = t0
    job.running = true
    local ok, err = coroutine.resume(job.co)
    job.running = false
    job.cpu = job.cpu + (now() - t0)
    job.slices = job.slices + 1
    if not ok then
      log("[Tiny Atlas] FAILED while " .. (job.where or "starting") .. ": " .. tostring(err) .. "\n" .. debug.traceback(job.co))
      table.remove(jobs, 1)
    elseif coroutine.status(job.co) == "dead" then
      table.remove(jobs, 1)
    end
  end
end

return M
