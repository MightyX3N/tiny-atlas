-- Helpers for test scripts run inside the LÖVE game (tools/love_test/run.sh): each script is a coroutine resumed
-- once per frame, given the layer's L and R. Start a script with:
--   local T = dofile(os.getenv("TA_TEST_LIB"))(..., os.getenv("TA_TEST_OUT"))
return function(L, R, out)
  out = out or "."
  local T = {}
  os.execute('mkdir -p "' .. out .. '"')
  function T.frames(n) for _ = 1, n do coroutine.yield() end end
  function T.seconds(s) local t = love.timer.getTime() + s; while love.timer.getTime() < t do coroutine.yield() end end
  function T.until_(fn, timeout, what)
    local t = love.timer.getTime() + (timeout or 60)
    while not fn() do
      if love.timer.getTime() > t then error("timed out waiting for " .. (what or "something"), 0) end
      coroutine.yield()
    end
  end
  -- press a key for two frames (GMod key name: "DOWN", "ENTER", "W"...)
  function T.press(name, frames)
    local code = _G["KEY_" .. name]
    assert(code, "no key " .. name)
    if name == "ESCAPE" then L.keypressed("escape") end
    L.fake.keys[code] = true
    T.frames(frames or 2)
    L.fake.keys[code] = nil
    T.frames(2)
  end
  function T.hold(name, on) L.fake.keys[_G["KEY_" .. name]] = on or nil end
  -- a click at grid position (the UI's own pixels)
  function T.click(gx, gy)
    local UI = TinyAtlas.UI
    local x, y = UI.ox + (gx + 0.5) * UI.s, UI.oy + (gy + 0.5) * UI.s
    L.fake.mouse = { x = x, y = y, down = false }
    T.frames(2)
    L.fake.mouse.down = true
    T.frames(2)
    L.fake.mouse.down = false
    T.frames(2)
  end
  function T.shot(name)
    local done = false
    love.graphics.captureScreenshot(function(img)
      local data = img:encode("png")
      local f = assert(io.open(out .. "/" .. name .. ".png", "wb")); f:write(data:getString()); f:close()
      done = true
    end)
    T.until_(function() return done end, 10, "the screenshot " .. name)
    print("shot " .. name)
  end
  function T.screen() return TinyAtlas.Screens.screen end
  -- move the focus to a widget by its id with the arrow keys (as a player would), then press Enter
  function T.choose(id)
    local UI = TinyAtlas.UI
    for _ = 1, 20 do
      if UI.focused(id) then break end
      T.press("DOWN")
    end
    assert(UI.focused(id), "could not reach '" .. id .. "' on " .. T.screen())
    T.press("ENTER")
    T.frames(4)
  end
  function T.say(...) print("[test] " .. string.format(...)) end
  return T
end
