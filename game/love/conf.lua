-- Tiny Atlas standalone (LÖVE 11.5; LÖVE 12 works too)
function love.conf(t)
  t.identity = "tinyatlas"
  t.version = "11.5"
  t.console = false
  t.window.title = "Tiny Atlas"
  t.window.width = 1280
  t.window.height = 720
  t.window.resizable = true
  t.window.vsync = 1
  t.window.minwidth, t.window.minheight = 640, 360
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
end
