-- Adds GMod's rendering API to the fake GMod (fakegmod.lua): Vector/Angle/Matrix, Mesh + mesh.*,
-- Material/CreateMaterial, render/cam/surface/draw, binary file.Open, convars and console commands.
-- It checks what breaks in the real game: vertex counts that don't match mesh.Begin, more than 65,535
-- vertices in a mesh, unbalanced PushModelMatrix, missing textures, errors reported with ErrorNoHalt.
-- With F.capture = true, meshes keep their vertices and F.draws lists what one frame drew.
return function(F, opts)
  opts = opts or {}
  F.errors, F.draws, F.texts, F.commands, F.convars, F.meshes_alive = {}, {}, {}, {}, {}, 0
  F.mesh_stats = { built = 0, verts = 0, max_verts = 0 }
  F.lua_roots = opts.lua_roots or {}
  F.material_roots = opts.material_roots or {}
  F.scr = opts.screen or { 1920, 1080 }

  MATERIAL_POINTS, MATERIAL_LINES, MATERIAL_TRIANGLES, MATERIAL_QUADS = 0, 1, 2, 7
  MATERIAL_FOG_NONE, MATERIAL_FOG_LINEAR = 0, 1
  TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP, TEXT_ALIGN_BOTTOM = 0, 1, 2, 3, 4
  KEY_B = 12

  -- ---- vectors, angles, colours, matrices ----
  local VM = {}
  VM.__index = VM
  function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VM) end
  function VM:SetUnpacked(x, y, z) self.x, self.y, self.z = x, y, z end
  function VM:Unpack() return self.x, self.y, self.z end
  VM.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
  VM.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
  VM.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return Vector(a.x * b, a.y * b, a.z * b)
  end
  function Angle(p, y, r) return { p = p or 0, y = y or 0, r = r or 0 } end
  function Color(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
  color_white, color_black = Color(255, 255, 255), Color(0, 0, 0)
  local MM = {}
  MM.__index = MM
  function Matrix() return setmetatable({ t = { 0, 0, 0 } }, MM) end
  function MM:SetTranslation(v) self.t = { v.x, v.y, v.z } end
  function MM:GetTranslation() return Vector(self.t[1], self.t[2], self.t[3]) end

  local function err(msg) F.errors[#F.errors + 1] = msg end
  function ErrorNoHalt(msg) err(tostring(msg)) end

  -- ---- meshes ----
  local IM = {}
  IM.__index = IM
  local building, model_stack, cur_mat, in3d = nil, {}, nil, false
  function Mesh() F.meshes_alive = F.meshes_alive + 1; return setmetatable({ n = 0, alive = true }, IM) end
  function IM:Destroy()
    if not self.alive then err("IMesh destroyed twice") end
    self.alive = false; F.meshes_alive = F.meshes_alive - 1
  end
  function IM:IsValid() return self.alive end
  function IM:Draw()
    if not self.alive then err("drew a destroyed IMesh") end
    if not in3d then err("IMesh:Draw outside cam.Start3D") end
    local t = model_stack[#model_stack] or { 0, 0, 0 }
    F.frame_draws = (F.frame_draws or 0) + 1
    -- the outlines' depth pass (DepthWrite) is not part of the picture: counted, not recorded
    if cur_mat and cur_mat.shader == "DepthWrite" then
      F.depth_draws = (F.depth_draws or 0) + 1
      if not (F.render_target and F.render_target.name:find("^tinyatlas_depth_")) then err("DepthWrite drawn outside the depth target") end
      return
    end
    if F.capture then F.draws[#F.draws + 1] = { mesh = self, mat = cur_mat, t = { t[1], t[2], t[3] } } end
  end
  local PER = { [MATERIAL_TRIANGLES] = 3, [MATERIAL_QUADS] = 4, [MATERIAL_LINES] = 2 }
  mesh = {}
  function mesh.Begin(m, prim, count)
    if building then err("mesh.Begin while another mesh is being built") end
    if type(m) ~= "table" then err("mesh.Begin without an IMesh") end
    building = { m = m, prim = prim, count = count, verts = 0, cur = {} }
    if F.capture or F.keep then building.data = {} end
  end
  function mesh.Position(v) building.cur.x, building.cur.y, building.cur.z = v.x, v.y, v.z end
  function mesh.TexCoord(stage, u, v) building.cur.u, building.cur.v = u, v end
  function mesh.Color(r, g, b, a) building.cur.r, building.cur.g, building.cur.b = r, g, b end
  function mesh.AdvanceVertex()
    local B, c = building, building.cur
    B.verts = B.verts + 1
    if c.x ~= c.x or c.y ~= c.y or c.z ~= c.z then err("vertex with NaN position") end
    if B.data then
      local d = B.data
      d[#d + 1] = c.x; d[#d + 1] = c.y; d[#d + 1] = c.z; d[#d + 1] = c.u or 0; d[#d + 1] = c.v or 0
      d[#d + 1] = c.r or 255; d[#d + 1] = c.g or 255; d[#d + 1] = c.b or 255
    end
  end
  function mesh.End()
    local B = building
    building = nil
    local want = (PER[B.prim] or 3) * B.count
    if B.verts ~= want then err(string.format("mesh.End: %d vertices for %d primitives (expected %d)", B.verts, B.count, want)) end
    if B.verts > 65535 then err("mesh with " .. B.verts .. " vertices (limit 65535)") end
    B.m.n, B.m.prim, B.m.data = B.verts, B.prim, B.data
    F.mesh_stats.built = F.mesh_stats.built + 1
    F.mesh_stats.verts = F.mesh_stats.verts + B.verts
    if B.verts > F.mesh_stats.max_verts then F.mesh_stats.max_verts = B.verts end
  end

  -- ---- materials ----
  local function exists(path)
    for _, root in ipairs(F.material_roots) do
      local f = io.open(root .. "/" .. path, "rb")
      if f then f:close(); return true end
    end
    return false
  end
  local MA = {}
  MA.__index = MA
  local builtin = { ["gui/gradient_down"] = true, ["color/white"] = true }
  function Material(path, flags)
    local ok = builtin[path] or exists(path)
    if not ok then err("Material: missing " .. path) end
    return setmetatable({ path = path, flags = flags, error = not ok, params = { ["$basetexture"] = { tex = path } } }, MA)
  end
  function CreateMaterial(name, shader, params)
    local p = {}
    for k, v in pairs(params) do p[k] = v end
    return setmetatable({ name = name, shader = shader, params = p }, MA)
  end
  -- menus: panels that remember what was set on them (F.panels), enough to run the gamemode's own menus
  F.panels = {}
  local PN = {}
  PN.__index = function(t, k)
    if PN[k] then return PN[k] end
    return function(self, ...) self.calls[#self.calls + 1] = { k, ... }; return self end
  end
  function PN:Remove() self.removed = true end
  function PN:IsValid() return not self.removed end
  vgui = {}
  function vgui.Create(class, parent)
    local p = setmetatable({ class = class, parent = parent, calls = {}, removed = false }, PN)
    F.panels[#F.panels + 1] = p
    return p
  end
  function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
  function MA:IsError() return self.error end
  function MA:GetTexture(k) return self.params[k] end
  function MA:SetTexture(k, t) self.params[k] = t end
  function MA:SetMatrix(k, m) self.params[k] = m end
  function MA:SetFloat(k, v) self.params[k] = v end
  function MA:GetName() return self.name or self.path end

  -- ---- render / cam / 2D ----
  render = {}
  function render.Clear() end
  function render.ClearDepth() end
  function render.SetMaterial(m) cur_mat = m end
  function render.SetColorMaterial() cur_mat = { name = "color" } end
  function render.FogMode() end
  function render.FogStart() end
  function render.FogEnd() end
  function render.FogMaxDensity() end
  function render.FogColor() end
  function render.DrawBox(pos) F.rider_box = pos end
  -- render targets (the pixel-art filter)
  RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, IMAGE_FORMAT_RGB888, IMAGE_FORMAT_RGBA16161616F = 5, 1, 2, 24
  local rt_stack = {}
  function GetRenderTargetEx(name, w, h)
    return { name = name, w = w, h = h, GetName = function(self) return self.name end }
  end
  function render.PushRenderTarget(rt, x, y, w, h)
    if not rt then err("PushRenderTarget without a target") end
    rt_stack[#rt_stack + 1] = rt
    F.render_target = rt
  end
  function render.PopRenderTarget()
    if #rt_stack == 0 then err("PopRenderTarget with nothing pushed") end
    rt_stack[#rt_stack] = nil
    F.render_target = rt_stack[#rt_stack]
  end
  function render.DrawScreenQuad()
    if #rt_stack ~= 0 then err("DrawScreenQuad while a render target is still pushed") end
    F.screen_quad = true
  end
  cam = {}
  function cam.Start3D(pos, ang, fov, x, y, w, h, zn, zf)
    if in3d then err("cam.Start3D twice") end
    in3d = true
    F.camera = { pos = pos, ang = ang, fov = fov, znear = zn, zfar = zf }
  end
  function cam.End3D()
    if #model_stack ~= 0 then err("cam.End3D with " .. #model_stack .. " model matrices still pushed") end
    in3d = false
  end
  function cam.Start2D() end
  function cam.End2D() end
  function cam.PushModelMatrix(m) model_stack[#model_stack + 1] = { m.t[1], m.t[2], m.t[3] } end
  function cam.PopModelMatrix()
    if #model_stack == 0 then err("PopModelMatrix with nothing pushed") end
    model_stack[#model_stack] = nil
  end
  surface = {}
  function surface.SetDrawColor() end
  function surface.SetMaterial() end
  function surface.DrawTexturedRect() end
  function surface.CreateFont() end
  draw = {}
  function draw.SimpleText(t) F.texts[#F.texts + 1] = t end
  function draw.SimpleTextOutlined(t) F.texts[#F.texts + 1] = t end
  function ScrW() return F.scr[1] end
  function ScrH() return F.scr[2] end
  function SysTime() return os.clock() end
  function RealFrameTime() return F.dt or 0.016 end

  -- ---- files (binary) ----
  local DATA = F.DATA
  local FO = {}
  FO.__index = FO
  local oldOpen = file.Open
  function file.Open(path, mode, where)
    local f = io.open(DATA .. "/" .. path, mode:find("w") and "wb" or "rb")
    if not f then return nil end
    return setmetatable({ f = f }, FO)
  end
  function FO:Read(n) return self.f:read(n) end
  function FO:Size() local cur = self.f:seek(); local sz = self.f:seek("end"); self.f:seek("set", cur); return sz end
  function FO:Close() self.f:close() end
  function file.Exists(path, where)
    if where == "GAME" and F.game_files then return F.game_files[path] == true end
    local f = io.open(DATA .. "/" .. path, "rb")
    if f then f:close(); return true end
    return false
  end
  function file.Find(pattern, where)
    local dir = pattern:match("^(.*)/[^/]*$") or ""
    local files, dirs = {}, {}
    local roots = where == "LUA" and F.lua_roots or { DATA }
    for _, root in ipairs(roots) do
      local p = io.popen('ls -pL "' .. root .. "/" .. dir .. '" 2>/dev/null')
      if p then
        for l in p:lines() do
          if l:sub(-1) == "/" then dirs[#dirs + 1] = l:sub(1, -2)
          elseif l:match(pattern:match("[^/]*$"):gsub("%.", "%%."):gsub("%*", ".*") .. "$") then files[#files + 1] = l end
        end
        p:close()
      end
    end
    return files, dirs
  end

  -- ---- timer.Simple, chat ----
  F.simple = {}
  timer.Simple = function(d, fn) F.simple[#F.simple + 1] = { at = F.t + d, fn = fn } end
  function F.run_simple()
    local due = F.simple; F.simple = {}
    for _, e in ipairs(due) do e.fn() end
  end
  chat = { AddText = function(...) local t = {}; for _, x in ipairs({ ... }) do if type(x) == "string" then t[#t + 1] = x end end; F.chat = table.concat(t) end }

  -- ---- convars, commands ----
  local CV = {}
  CV.__index = CV
  function CreateClientConVar(name, default)
    local c = setmetatable({ name = name, value = tostring(default) }, CV)
    F.convars[name] = c
    return c
  end
  function GetConVar(name) return F.convars[name] end
  function CV:GetString() return self.value end
  function CV:GetName() return self.name end
  function CV:GetFloat() return tonumber(self.value) or 0 end
  function CV:GetInt() return math.floor(tonumber(self.value) or 0) end
  function CV:GetBool() return (tonumber(self.value) or 0) ~= 0 end
  function F.set(name, v) F.convars[name].value = tostring(v) end
  function concommand.Add(name, fn) F.commands[name] = fn end
  function F.run(name, ...) return F.commands[name](nil, name, { ... }) end

  -- include: the gamemode folder first, then lua/ of the addons
  local GMDIR = F.GMDIR
  function include(p)
    for _, root in ipairs({ GMDIR, unpack(F.lua_roots) }) do
      local f = loadfile(root .. "/" .. p)
      if f then return f() end
    end
    error("include: not found: " .. p)
  end

  -- one rendered frame
  function F.render_frame(dt)
    F.dt = dt; F.t = F.t + dt
    F.texts, F.frame_draws = {}, 0
    F.render_target, F.screen_quad = nil, nil
    if F.capture then F.draws = {} end
    return hook.Run("RenderScene", Vector(0, 0, 0), Angle(0, 0, 0), 75)
  end
  return F
end
