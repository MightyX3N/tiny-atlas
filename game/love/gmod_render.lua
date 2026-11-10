-- Garry's Mod's drawing functions on top of LÖVE (see gmod.lua): IMesh / mesh.*, materials, render targets,
-- render.*, cam.* (Source's camera: x forward, z up, angles pitch / yaw / roll, GMod's field of view), surface.*
-- (2D, fonts) and draw.*. Positions are Source units like in GMod.
local ffi = require("ffi")
local lg = love.graphics
local lfs = love.filesystem
local floor, rad, tan, cos, sin = math.floor, math.rad, math.tan, math.cos, math.sin
local R = {}

MATERIAL_TRIANGLES, MATERIAL_QUADS, MATERIAL_LINES = 4, 7, 2
MATERIAL_FOG_NONE, MATERIAL_FOG_LINEAR = 0, 1
RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, MATERIAL_RT_DEPTH_SHARED = 5, 1, 0
IMAGE_FORMAT_RGBA8888, IMAGE_FORMAT_RGB888, IMAGE_FORMAT_RGBA16161616F = 0, 2, 24
TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP, TEXT_ALIGN_BOTTOM = 0, 1, 2, 3, 4

-- ---- the world's shader: GMod's UnlitGeneric (texture x vertex colour, cut-outs, linear fog) and DepthWrite ----
local WORLD = [[
uniform mat4 u_vp;          // Source units -> clip, GL style
uniform vec3 u_off;         // the model matrix (a translation)
uniform vec3 u_eye;
uniform vec2 u_screen;      // the target's size
uniform vec3 u_fog_col;
uniform vec3 u_fog;         // start, end, on
uniform float u_cut;        // alpha below this is cut out
uniform float u_depth;      // 1: write the distance as a colour (DepthWrite's $color_depth)
uniform float u_debug;      // tests: 1 = texture only, 2 = vertex colour only
varying float v_dist;
varying float v_w;
#ifdef VERTEX
vec4 position(mat4 tp, vec4 vp) {
  vec3 w = vp.xyz + u_off;
  v_dist = length(w - u_eye);
  vec4 c = u_vp * vec4(w, 1.0);
  v_w = c.w;
  // through LÖVE's own projection, so it is the right way up on the screen and in canvases alike
  vec2 ndc = c.xy / c.w;
  vec2 px = vec2((ndc.x * 0.5 + 0.5) * u_screen.x, (0.5 - ndc.y * 0.5) * u_screen.y);
  vec4 q = tp * vec4(px, 0.0, 1.0);
  return vec4(q.xy * c.w, c.z, c.w);
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
  vec4 c = Texel(tex, uv) * color;
  if (c.a < u_cut) discard;
  if (u_debug > 0.5) c.rgb = u_debug < 1.5 ? Texel(tex, uv).rgb : color.rgb;
  if (u_depth > 0.5) return vec4(v_w / 4000.0, 0.0, 0.0, 1.0);
  float f = u_fog.z * clamp((v_dist - u_fog.x) / max(1.0, u_fog.y - u_fog.x), 0.0, 1.0);
  return vec4(mix(c.rgb, u_fog_col, f), 1.0);
}
#endif
]]
-- screenspace_general's pixel shaders the game has, as GLSL (the HLSL in tools/shaders/ does the same in GMod)
R.PIXSHADERS = {
  tinyatlas_edges_ps20 = [[
uniform Image u_depth;
uniform vec4 u_c0;   // one pixel (x, y); how much farther (share); how much darker
float inv_depth(vec2 uv) { float d = Texel(u_depth, uv).r; return d > 0.0 ? 1.0 / d : 0.0; }
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
  vec3 col = Texel(tex, uv).rgb;
  float w = inv_depth(uv);
  if (w > 0.0) {
    float s = u_c0.z;
    vec2 dirs[4];
    dirs[0] = vec2(u_c0.x, 0.0); dirs[1] = vec2(-u_c0.x, 0.0); dirs[2] = vec2(0.0, u_c0.y); dirs[3] = vec2(0.0, -u_c0.y);
    float edge = 0.0;
    for (int k = 0; k < 4; k++) {
      float wa = inv_depth(uv + dirs[k]);
      float wb = inv_depth(uv - dirs[k]);
      float pred = 2.0 * w - wb;
      if (wa < pred * (1.0 - s) && wa < w * (1.0 - s * 0.5)) edge = 1.0;
    }
    col *= 1.0 - edge * u_c0.w;
  }
  return vec4(col, 1.0);
}
]],
}

function R.init()
  R.shader = lg.newShader(WORLD)
  R.white = lg.newImage(love.image.newImageData(1, 1, "rgba8", "\255\255\255\255"))
  -- gui/gradient_down: white at the top, clear at the bottom
  local gd = love.image.newImageData(1, 64)
  for y = 0, 63 do gd:setPixel(0, y, 1, 1, 1, 1 - y / 63) end
  R.gradient = lg.newImage(gd)
  R.gradient:setFilter("linear", "linear")
  R.post = {}
  for name, src in pairs(R.PIXSHADERS) do R.post[name] = lg.newShader(src) end
  -- GMod's screenspace_general looks for compiled shaders here: the GLSL ones above stand in for them
  R.game_files = {}
  for name in pairs(R.PIXSHADERS) do R.game_files["shaders/fxc/" .. name:gsub("_ps20$", "_ps20b") .. ".vcs"] = true end
  R.color_mat = CreateMaterial("color", "UnlitGeneric", { ["$basetexture"] = "color/white" })
end

-- ---- textures and materials ----
local images = {}
local function load_image(path, flags)
  local key = path .. "|" .. (flags or "")
  if images[key] ~= nil then return images[key] end
  local p = path:find("%.%a+$") and path or (path .. ".png")
  local f = "materials/" .. p
  local img = false
  if lfs.getInfo(f, "file") then
    local smooth = flags and flags:find("smooth")
    local ok, im = pcall(lg.newImage, f, { mipmaps = smooth and flags:find("mips") and true or false })
    if ok then
      img = im
      if smooth then img:setFilter("linear", "linear", 8) else img:setFilter("nearest", "nearest") end
      if img:getMipmapCount() > 1 then img:setMipmapFilter("linear") end
      if flags and flags:find("noclamp") then img:setWrap("repeat", "repeat") end
    end
  end
  images[key] = img
  return img
end
local targets = {}
local MA = {}
MA.__index = MA
function Material(path, flags)
  local m = setmetatable({ name = path, shader = "UnlitGeneric", params = {} }, MA)
  if path == "gui/gradient_down" then m.params["$basetexture"] = { image = R.gradient }
  elseif path == "color/white" then m.params["$basetexture"] = { image = R.white }
  else
    local img = load_image(path, flags)
    if img then m.params["$basetexture"] = { image = img } else m.error = true end
  end
  return m
end
function CreateMaterial(name, shader, params)
  local m = setmetatable({ name = name, shader = shader, params = {} }, MA)
  for k, v in pairs(params or {}) do m.params[k] = v end
  return m
end
function MA:IsError() return self.error == true end
function MA:GetName() return self.name end
function MA:GetTexture(k) return self.params[k] end
function MA:SetTexture(k, t) self.params[k] = t end
function MA:SetFloat(k, v) self.params[k] = v end
function MA:SetInt(k, v) self.params[k] = v end
function MA:SetVector(k, v) self.params[k] = v end
function MA:GetFloat(k) return tonumber(self.params[k]) end
-- the image behind a material's texture parameter: a texture table, a render target's name, "color/white"
local function image_of(v)
  if type(v) == "table" then return v.image or (v.canvas) end
  if type(v) == "string" then
    if targets[v] then return targets[v].canvas end
    if v == "color/white" then return R.white end
    return load_image(v) or R.white
  end
  return R.white
end

-- ---- render targets ----
local RTM = {}
RTM.__index = RTM
function GetRenderTargetEx(name, w, h, size, depth, flags, rtflags, format)
  if targets[name] then return targets[name] end
  local fmt = (format == IMAGE_FORMAT_RGBA16161616F) and "rgba16f" or "rgba8"
  local t = setmetatable({ name = name, w = w, h = h, image = nil }, RTM)
  t.canvas = lg.newCanvas(w, h, { format = fmt })
  t.canvas:setFilter("nearest", "nearest")
  t.image = t.canvas
  if depth ~= nil then t.depth = lg.newCanvas(w, h, { format = "depth24" }) end
  targets[name] = t
  return t
end
GetRenderTarget = function(name, w, h) return GetRenderTargetEx(name, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, 0, 0, IMAGE_FORMAT_RGBA8888) end
function RTM:GetName() return self.name end
function RTM:Width() return self.w end
function RTM:Height() return self.h end

-- ---- meshes ----
ffi.cdef [[ typedef struct { float x, y, z, u, v; uint8_t r, g, b, a; } gm_vertex; ]]
local FORMAT = { { "VertexPosition", "float", 3 }, { "VertexTexCoord", "float", 2 }, { "VertexColor", "byte", 4 } }
local IM = {}
IM.__index = IM
function Mesh() return setmetatable({ alive = true }, IM) end
function IM:IsValid() return self.alive end
function IM:Destroy() if self.m then self.m:release() end; self.m = nil; self.alive = false end
local building, bdata, bn, bmax
local cur = { u = 0, v = 0, r = 255, g = 255, b = 255, a = 255, x = 0, y = 0, z = 0 }
mesh = {}
function mesh.Begin(m, prim, count)
  local per = prim == MATERIAL_QUADS and 4 or prim == MATERIAL_LINES and 2 or 3
  building, bn, bmax = m, 0, count * per
  m.prim = prim
  bdata = love.data.newByteData(math.max(1, bmax) * ffi.sizeof("gm_vertex"))
  m.ptr = ffi.cast("gm_vertex*", bdata:getFFIPointer())
end
function mesh.Position(v) cur.x, cur.y, cur.z = v.x, v.y, v.z end
function mesh.TexCoord(stage, u, v) if stage == 0 then cur.u, cur.v = u, v end end
function mesh.Color(r, g, b, a) cur.r, cur.g, cur.b, cur.a = r, g, b, a end
function mesh.AdvanceVertex()
  if bn >= bmax then return end
  local p = building.ptr[bn]
  p.x, p.y, p.z, p.u, p.v = cur.x, cur.y, cur.z, cur.u, cur.v
  p.r, p.g, p.b, p.a = cur.r, cur.g, cur.b, cur.a
  bn = bn + 1
end
function mesh.End()
  local m = building
  if bn > 0 then
    m.m = lg.newMesh(FORMAT, bn, "triangles", "static")
    m.m:setVertices(bdata, 1, bn)
  end
  m.ptr, building, bdata = nil, nil, nil
end

-- ---- the 3D camera (Source's conventions) ----
local S3 = { off = { 0, 0, 0 }, stack = {}, fog = { 0, 0, 0 }, fog_col = { 1, 1, 1 } }
local function mat_mul(a, b)            -- 4x4, row-major
  local r = {}
  for i = 0, 3 do for j = 0, 3 do
    local s = 0
    for k = 0, 3 do s = s + a[i * 4 + k + 1] * b[k * 4 + j + 1] end
    r[i * 4 + j + 1] = s
  end end
  return r
end
cam = {}
function cam.Start3D(pos, ang, fov, x, y, w, h, znear, zfar)
  pos = pos or Vector(0, 0, 0); ang = ang or Angle(0, 0, 0)
  w, h = w or lg.getWidth(), h or lg.getHeight()
  local t = R.target()
  if t then w, h = t.w, t.h end
  znear, zfar = znear or 4, zfar or 30000
  -- the view's axes: forward, right, up (pitch down is positive in Source)
  local p, yw = rad(ang.p), rad(ang.y)
  local fx, fy, fz = cos(p) * cos(yw), cos(p) * sin(yw), -sin(p)
  local rx, ry, rz = sin(yw), -cos(yw), 0
  local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
  local ex, ey, ez = pos.x, pos.y, pos.z
  -- view: x right, y up, -z forward (GL)
  local V = {
    rx, ry, rz, -(rx * ex + ry * ey + rz * ez),
    ux, uy, uz, -(ux * ex + uy * ey + uz * ez),
    -fx, -fy, -fz, (fx * ex + fy * ey + fz * ez),
    0, 0, 0, 1,
  }
  -- GMod's field of view: horizontal, for a 4:3 picture
  local t43 = tan(rad(fov or 75) / 2)
  local ty = t43 * 0.75
  local tx = ty * w / h
  local P = {
    1 / tx, 0, 0, 0,
    0, 1 / ty, 0, 0,
    0, 0, -(zfar + znear) / (zfar - znear), -2 * zfar * znear / (zfar - znear),
    0, 0, -1, 0,
  }
  local VP = mat_mul(P, V)
  S3.vp, S3.eye, S3.w, S3.h = VP, { ex, ey, ez }, w, h
  S3.in3d = true
  S3.off = { 0, 0, 0 }
  S3.stack = {}
  lg.setDepthMode("lequal", true)
  lg.setMeshCullMode("none")
  lg.setColor(1, 1, 1, 1)               -- LÖVE multiplies vertex colours by the draw colour; GMod does not
  lg.setShader(R.shader)
  R.shader:send("u_vp", "column", { { VP[1], VP[5], VP[9], VP[13] }, { VP[2], VP[6], VP[10], VP[14] }, { VP[3], VP[7], VP[11], VP[15] }, { VP[4], VP[8], VP[12], VP[16] } })
  R.shader:send("u_eye", S3.eye)
  R.shader:send("u_screen", { w, h })
  R.shader:send("u_off", S3.off)
  R.shader:send("u_depth", 0)
  R.shader:send("u_cut", 0)
  S3.send_fog()
end
function cam.End3D()
  S3.in3d = false
  lg.setShader()
  lg.setDepthMode("always", false)
end
function cam.Start2D() lg.setShader(); lg.setDepthMode("always", false); lg.setColor(1, 1, 1, 1) end
function cam.End2D() if S3.in3d then lg.setShader(R.shader); lg.setDepthMode("lequal", true); lg.setColor(1, 1, 1, 1) end end
function cam.Start(t) if t and t.type == "2D" then cam.Start2D() end end
function cam.End() cam.End2D() end
function cam.PushModelMatrix(m)
  S3.stack[#S3.stack + 1] = S3.off
  local t = m.t
  S3.off = { t[1], t[2], t[3] }
  if S3.in3d then R.shader:send("u_off", S3.off) end
end
function cam.PopModelMatrix()
  S3.off = table.remove(S3.stack) or { 0, 0, 0 }
  if S3.in3d then R.shader:send("u_off", S3.off) end
end

-- ---- render.* ----
render = {}
local cur_mat
local rt_stack = {}
function S3.send_fog()
  local f = S3.fog
  R.shader:send("u_fog", { f[1], f[2], S3.fog_mode == MATERIAL_FOG_LINEAR and 1 or 0 })
  R.shader:send("u_fog_col", S3.fog_col)
end
function render.FogMode(m) S3.fog_mode = m; if S3.in3d then S3.send_fog() end end
function render.FogStart(v) S3.fog[1] = v; if S3.in3d then S3.send_fog() end end
function render.FogEnd(v) S3.fog[2] = v; if S3.in3d then S3.send_fog() end end
function render.FogMaxDensity() end
function render.FogColor(r, g, b) S3.fog_col = { r / 255, g / 255, b / 255 }; if S3.in3d then S3.send_fog() end end
function render.SetMaterial(m) cur_mat = m end
function render.SetColorMaterial() cur_mat = R.color_mat end
function render.MaterialOverride(m) R.override = m end
function render.Clear(r, g, b, a, depth, stencil)
  lg.clear(r / 255, g / 255, b / 255, (a or 255) / 255, stencil and true or false, depth and true or false)
end
function render.ClearDepth() lg.clear(false, false, 1) end
local function set_target(t)
  if t then lg.setCanvas({ t.canvas, depthstencil = t.depth })
  else lg.setCanvas() end
  if S3.in3d then
    local w, h = (t and t.w) or lg.getWidth(), (t and t.h) or lg.getHeight()
    R.shader:send("u_screen", { w, h })
  end
end
function render.PushRenderTarget(t)
  rt_stack[#rt_stack + 1] = t
  set_target(t)
end
function render.PopRenderTarget()
  rt_stack[#rt_stack] = nil
  set_target(rt_stack[#rt_stack])
end
function render.GetRenderTarget() return rt_stack[#rt_stack] end
function R.target() return rt_stack[#rt_stack] end
-- draw one mesh with the current material
function IM:Draw()
  if not self.m then return end
  local m = R.override or cur_mat
  local p = m and m.params or {}
  local sh = R.shader
  if m and m.shader == "DepthWrite" then
    sh:send("u_depth", 1)
    sh:send("u_cut", (p["$alphatest"] == 1) and (p["$alphatestreference"] or 0.5) or 0)
    self.m:setTexture(p["$alphatest"] == 1 and image_of(p["$basetexture"]) or R.white)
    lg.draw(self.m)
    sh:send("u_depth", 0)
    return
  end
  sh:send("u_cut", (p["$alphatest"] == 1) and 0.5 or 0)
  self.m:setTexture(image_of(p["$basetexture"]))
  lg.draw(self.m)
end
-- a coloured box turned to a heading (the rider stand-in)
function render.DrawBox(pos, ang, mins, maxs, col)
  local yw = rad(ang.y)
  local c, s = cos(yw), sin(yw)
  local x0, y0, z0, x1, y1, z1 = mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z
  local function P(x, y, z) return { pos.x + x * c - y * s, pos.y + x * s + y * c, pos.z + z } end
  local k = { P(x0, y0, z0), P(x1, y0, z0), P(x1, y1, z0), P(x0, y1, z0), P(x0, y0, z1), P(x1, y0, z1), P(x1, y1, z1), P(x0, y1, z1) }
  local faces = { { 1, 2, 3, 4, 0.55 }, { 5, 6, 7, 8, 1.0 }, { 1, 2, 6, 5, 0.8 }, { 2, 3, 7, 6, 0.7 }, { 3, 4, 8, 7, 0.85 }, { 4, 1, 5, 8, 0.75 } }
  local v = {}
  for _, f in ipairs(faces) do
    local l = f[5]
    local r, g, b = col.r / 255 * l, col.g / 255 * l, col.b / 255 * l
    for _, i in ipairs({ f[1], f[2], f[3], f[1], f[3], f[4] }) do v[#v + 1] = { k[i][1], k[i][2], k[i][3], 0, 0, r, g, b, 1 } end
  end
  local m = lg.newMesh({ { "VertexPosition", "float", 3 }, { "VertexTexCoord", "float", 2 }, { "VertexColor", "float", 4 } }, v, "triangles", "stream")
  R.shader:send("u_cut", 0)
  m:setTexture(R.white)
  lg.draw(m)
  m:release()
end
-- the current material over the whole target: a picture (UnlitGeneric) or a screen shader (screenspace_general)
function render.DrawScreenQuad()
  local m = cur_mat
  if not m then return end
  local p = m.params
  lg.push("all")
  lg.setShader()
  lg.setDepthMode("always", false)
  lg.setColor(1, 1, 1, 1)
  local img = image_of(p["$basetexture"])
  local W, H = lg.getDimensions()
  local t = R.target(); if t then W, H = t.w, t.h end
  if m.shader == "screenspace_general" then
    local name = p["$pixshader"]
    local sh = R.post[name]
    if sh then
      lg.setShader(sh)
      if sh:hasUniform("u_depth") then sh:send("u_depth", image_of(p["$texture1"])) end
      if sh:hasUniform("u_c0") then sh:send("u_c0", { p["$c0_x"] or 0, p["$c0_y"] or 0, p["$c0_z"] or 0, p["$c0_w"] or 0 }) end
    end
  end
  local iw, ih = img:getDimensions()
  lg.draw(img, 0, 0, 0, W / iw, H / ih)
  lg.pop()
end

-- ---- 2D: surface.* and draw.* ----
surface = {}
local S2 = { col = { 1, 1, 1, 1 }, tcol = { 1, 1, 1, 1 }, tx = 0, ty = 0, font = nil, mat = nil }
local fonts = {}
-- font families the game ships (content/resource/fonts), by name as GMod knows them
R.FONT_FILES = { ["Jersey 10"] = "resource/fonts/jersey10.ttf", ["Micro 5"] = "resource/fonts/micro5.ttf" }
function surface.CreateFont(name, data)
  local file = R.FONT_FILES[data.font or ""]
  local size = math.max(1, floor(data.size or 13))
  local hint = data.antialias == false and "mono" or "normal"
  local ok, f
  if file then ok, f = pcall(lg.newFont, file, size, hint) end
  if not ok or not f then f = lg.newFont(size, hint) end
  f:setFilter(data.antialias == false and "nearest" or "linear", data.antialias == false and "nearest" or "linear")
  fonts[name] = f
end
function surface.SetFont(name) S2.font = fonts[name] or S2.font or lg.getFont() end
function surface.GetTextSize(s)
  local f = S2.font or lg.getFont()
  return f:getWidth(tostring(s)), f:getHeight()
end
function surface.SetDrawColor(r, g, b, a)
  if type(r) == "table" then r, g, b, a = r.r, r.g, r.b, r.a end
  S2.col = { r / 255, g / 255, b / 255, (a or 255) / 255 }
end
function surface.SetTextColor(r, g, b, a)
  if type(r) == "table" then r, g, b, a = r.r, r.g, r.b, r.a end
  S2.tcol = { r / 255, g / 255, b / 255, (a or 255) / 255 }
end
function surface.SetTextPos(x, y) S2.tx, S2.ty = x, y end
function surface.DrawText(s)
  s = tostring(s)
  local f = S2.font or lg.getFont()
  lg.setFont(f)
  lg.setColor(S2.tcol)
  lg.print(s, floor(S2.tx), floor(S2.ty))
  S2.tx = S2.tx + f:getWidth(s)
end
function surface.DrawRect(x, y, w, h) lg.setColor(S2.col); lg.rectangle("fill", x, y, w, h) end
function surface.DrawOutlinedRect(x, y, w, h, t)
  lg.setColor(S2.col)
  t = t or 1
  lg.rectangle("fill", x, y, w, t); lg.rectangle("fill", x, y + h - t, w, t)
  lg.rectangle("fill", x, y, t, h); lg.rectangle("fill", x + w - t, y, t, h)
end
function surface.DrawLine(x0, y0, x1, y1) lg.setColor(S2.col); lg.line(x0 + 0.5, y0 + 0.5, x1 + 0.5, y1 + 0.5) end
function surface.SetMaterial(m) S2.mat = m end
function surface.DrawTexturedRect(x, y, w, h)
  local img = S2.mat and image_of(S2.mat.params["$basetexture"]) or R.white
  local iw, ih = img:getDimensions()
  lg.setColor(S2.col)
  lg.draw(img, x, y, 0, w / iw, h / ih)
end
draw = {}
function draw.SimpleText(text, font, x, y, col, ax, ay)
  surface.SetFont(font)
  local w, h = surface.GetTextSize(text)
  if ax == TEXT_ALIGN_CENTER then x = x - w / 2 elseif ax == TEXT_ALIGN_RIGHT then x = x - w end
  if ay == TEXT_ALIGN_CENTER then y = y - h / 2 elseif ay == TEXT_ALIGN_BOTTOM then y = y - h end
  surface.SetTextColor(col or color_white)
  surface.SetTextPos(x, y)
  surface.DrawText(text)
  return w, h
end
function draw.SimpleTextOutlined(text, font, x, y, col, ax, ay, ow, ocol)
  for dx = -ow, ow do for dy = -ow, ow do
    if dx ~= 0 or dy ~= 0 then draw.SimpleText(text, font, x + dx, y + dy, ocol, ax, ay) end
  end end
  return draw.SimpleText(text, font, x, y, col, ax, ay)
end
function draw.RoundedBox(r, x, y, w, h, col) surface.SetDrawColor(col); surface.DrawRect(x, y, w, h) end

-- ---- the frame ----
function R.frame()
  rt_stack = {}
  lg.setCanvas()
  lg.origin()
  local handled = hook.Run("RenderScene", Vector(0, 0, 0), Angle(0, 0, 0), 75)
  lg.setCanvas()
  lg.setShader()
  lg.setDepthMode("always", false)
  hook.Run("HUDPaint")
  hook.Run("PostRender")
  lg.setColor(1, 1, 1, 1)
  return handled
end
return R
