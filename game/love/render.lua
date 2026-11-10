-- Drawing the world in LÖVE: meshes from mesh.lua / OSM2World2Lua groups, the asset pack's textures, a 3D shader
-- with fog and cut-out windows, the sky, the distant ground under the built cells, and the pixel-art filter.
local ffi = require("ffi")
local mesh_lib = ATLAS_REQUIRE("mesh")
local lg = love.graphics
local M = {}
M.SKY_TOP, M.SKY_HORIZON = { 96 / 255, 150 / 255, 206 / 255 }, { 196 / 255, 216 / 255, 232 / 255 }
M.FOG_NEAR, M.FOG_FAR = 300, 2000
M.VIEW = 700                     -- metres: built cells farther away are not drawn
M.FOV = 62                       -- vertical field of view, degrees

ffi.cdef [[ typedef struct { float x, y, z, u, v; uint8_t r, g, b, a; } ta_vertex; ]]
-- LÖVE 12 vertex format (LÖVE 11's older layout as a fallback)
local FORMAT = (love.getVersion() >= 12) and {
  { name = "VertexPosition", format = "floatvec3" },
  { name = "VertexTexCoord", format = "floatvec2" },
  { name = "VertexColor", format = "unorm8vec4" },
} or { { "VertexPosition", "float", 3 }, { "VertexTexCoord", "float", 2 }, { "VertexColor", "byte", 4 } }

local SHADER = [[
uniform mat4 u_vp;          // view-projection, camera at the origin
uniform vec3 u_off;         // this mesh's origin relative to the camera
uniform vec2 u_screen;
uniform vec3 u_fog_col;
uniform vec2 u_fog;         // near, far
uniform float u_cut;        // alpha below this is cut out (windows)
varying float v_dist;
#ifdef VERTEX
vec4 position(mat4 tp, vec4 vp) {
  vec3 w = vp.xyz + u_off;
  v_dist = length(w);
  vec4 c = u_vp * vec4(w, 1.0);
  // through LÖVE's own projection, so the picture is the right way up on screen and in canvases alike
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
  float f = clamp((v_dist - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);
  return vec4(mix(c.rgb, u_fog_col, f), 1.0);
}
#endif
]]

function M.init()
  M.shader = lg.newShader(SHADER)
  M.white = lg.newImage(love.image.newImageData(1, 1, "rgba8", "\255\255\255\255"))
  M.tex = {}
  -- sky: a vertical gradient
  M.sky = lg.newMesh({ { 0, 0, 0, 0, M.SKY_TOP[1], M.SKY_TOP[2], M.SKY_TOP[3], 1 }, { 1, 0, 0, 0, M.SKY_TOP[1], M.SKY_TOP[2], M.SKY_TOP[3], 1 },
    { 1, 1, 0, 0, M.SKY_HORIZON[1], M.SKY_HORIZON[2], M.SKY_HORIZON[3], 1 }, { 0, 1, 0, 0, M.SKY_HORIZON[1], M.SKY_HORIZON[2], M.SKY_HORIZON[3], 1 } }, "fan", "static")
  M.rider = M.box(1.8, 0.5, 1.7, 200, 57, 47)
  M.rider_verts = M.box_verts
end

-- the pack's texture for a ground / building texture name (cached); the white texture when there is none
function M.texture(pack, tex)
  local key = pack.id .. "/" .. tex
  local t = M.tex[key]
  if t ~= nil then return t or M.white end
  local files = pack.ground and (pack.ground[tex] or pack.ground.rural)
  t = false
  if tex ~= "flat" and files then
    local path = pack.root .. "/materials/tinyatlas/packs/" .. pack.id .. "/" .. files[1]
    local ok, img = pcall(lg.newImage, path, { mipmaps = true })
    if ok then
      img:setWrap("repeat", "repeat")
      img:setFilter("linear", "linear", 8)
      img:setMipmapFilter("linear")
      t = img
    else
      M.log("texture missing: " .. path)
    end
  end
  M.tex[key] = t
  return t or M.white
end

-- world.lua's make / free: one LÖVE mesh per group
function M.make(groups)
  local h = { list = {}, tris = 0 }
  for _, G in ipairs(groups) do
    if G.n >= 3 then
      local data = love.data.newByteData(G.n * ffi.sizeof("ta_vertex"))
      local v = ffi.cast("ta_vertex*", data:getFFIPointer())
      local d = G.d
      for i = 0, G.n - 1 do
        local o = i * 8
        local p = v[i]
        p.x, p.y, p.z, p.u, p.v = d[o + 1], d[o + 2], d[o + 3], d[o + 4], d[o + 5]
        local r, g, b = d[o + 6], d[o + 7], d[o + 8]
        p.r = r > 255 and 255 or (r < 0 and 0 or r)
        p.g = g > 255 and 255 or (g < 0 and 0 or g)
        p.b = b > 255 and 255 or (b < 0 and 0 or b)
        p.a = 255
      end
      local m = lg.newMesh(FORMAT, G.n, "triangles", "static")
      m:setVertices(data)
      h.list[#h.list + 1] = { tex = G.tex, mesh = m, image = G.photo and M.photo_image(G.photo) or nil, photo = G.photo }
      h.tris = h.tris + G.n / 3
    end
  end
  return h
end
-- aerial photos: one texture per photo tile (a Sentinel-2 tile serves 64 cells), freed when no mesh uses it
M.photos = {}
function M.photo_image(p)
  local key = p.source .. "/" .. p.z .. "/" .. p.x .. "/" .. p.y
  local e = M.photos[key]
  if e then e.n = e.n + 1; return e.img end
  local ok, img = pcall(function()
    local data = love.image.newImageData(love.filesystem.newFileData(p.bytes, "photo.jpg"))
    local im = lg.newImage(data, { mipmaps = true })
    im:setFilter("linear", "linear", 8)
    im:setMipmapFilter("linear")
    im:setWrap("clamp", "clamp")
    return im
  end)
  if not ok then M.log("[Tiny Atlas] FAILED: aerial photo " .. key .. ": " .. tostring(img)); return nil end
  M.photos[key] = { img = img, n = 1 }
  return img
end
local function photo_release(p)
  local key = p.source .. "/" .. p.z .. "/" .. p.x .. "/" .. p.y
  local e = M.photos[key]
  if not e then return end
  e.n = e.n - 1
  if e.n <= 0 then e.img:release(); M.photos[key] = nil end
end

function M.free(h)
  for _, e in ipairs(h.list) do e.mesh:release(); if e.photo and e.image then photo_release(e.photo) end end
  h.list = {}
end

-- a box (the rider until the bike model is in): w along x, d along y, h up, standing on z = 0
function M.box(w, d, h, r, g, b)
  local x0, x1, y0, y1 = -w / 2, w / 2, -d / 2, d / 2
  local faces = {
    { { x0, y0, 0 }, { x1, y0, 0 }, { x1, y0, h }, { x0, y0, h }, 0.75 }, { { x1, y1, 0 }, { x0, y1, 0 }, { x0, y1, h }, { x1, y1, h }, 0.85 },
    { { x1, y0, 0 }, { x1, y1, 0 }, { x1, y1, h }, { x1, y0, h }, 0.95 }, { { x0, y1, 0 }, { x0, y0, 0 }, { x0, y0, h }, { x0, y1, h }, 0.7 },
    { { x0, y0, h }, { x1, y0, h }, { x1, y1, h }, { x0, y1, h }, 1.0 },
  }
  local verts = {}
  M.box_verts = verts
  for _, f in ipairs(faces) do
    local s = f[5]
    for _, k in ipairs({ 1, 2, 3, 1, 3, 4 }) do
      local p = f[k]
      verts[#verts + 1] = { p[1], p[2], p[3], 0, 0, r / 255 * s, g / 255 * s, b / 255 * s, 1 }
    end
  end
  return lg.newMesh(FORMAT, verts, "triangles", "static")
end

-- ---- matrices (column-major for LÖVE's send) ----
local function perspective(fovy, aspect, near, far)
  local f = 1 / math.tan(math.rad(fovy) / 2)
  return { f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) / (near - far), -1, 0, 0, 2 * far * near / (near - far), 0 }
end
local function look_at(ex, ey, ez, tx, ty, tz)
  -- z up; camera at the origin of the drawing (positions are sent relative to the camera)
  local fx, fy, fz = tx - ex, ty - ey, tz - ez
  local l = math.sqrt(fx * fx + fy * fy + fz * fz); fx, fy, fz = fx / l, fy / l, fz / l
  local sx, sy, sz = fy * 1 - fz * 0, fz * 0 - fx * 1, fx * 0 - fy * 0          -- f x up(0,0,1)
  l = math.sqrt(sx * sx + sy * sy + sz * sz); sx, sy, sz = sx / l, sy / l, sz / l
  local ux, uy, uz = sy * fz - sz * fy, sz * fx - sx * fz, sx * fy - sy * fx
  return { sx, ux, -fx, 0, sy, uy, -fy, 0, sz, uz, -fz, 0, 0, 0, 0, 1 }
end
local function mul(a, b)          -- column-major 4x4: a * b
  local r = {}
  for c = 0, 3 do for rr = 0, 3 do
    local s = 0
    for k = 0, 3 do s = s + a[k * 4 + rr + 1] * b[c * 4 + k + 1] end
    r[c * 4 + rr + 1] = s
  end end
  return r
end

-- canvases: the world is drawn into one (with depth), at full size or small for the pixel filter
local function canvas_for(w, h, px)
  local key = w .. "x" .. h
  if M.canvas and M.canvas.key == key then return M.canvas end
  if M.canvas then M.canvas.c:release(); M.canvas.d:release() end
  local c = lg.newCanvas(w, h, { msaa = px > 1 and 0 or 4 })
  local d = lg.newCanvas(w, h, { format = "depth24", readable = false, msaa = px > 1 and 0 or 4 })
  c:setFilter("nearest", "nearest")
  M.canvas = { c = c, d = d, key = key }
  return M.canvas
end

local function draw_list(pack, list, ox, oy, oz, sh)
  for _, e in ipairs(list) do
    sh:send("u_off", { ox, oy, oz })
    sh:send("u_cut", pack.alphatest and pack.alphatest[e.tex] and 0.5 or 0.0)
    local t = e.image or M.texture(pack, e.tex)
    e.mesh:setTexture(t)
    lg.draw(e.mesh)
  end
end

-- one frame: W = the world, cam = { x, y, z, lx, ly, lz }, rider = { x, y, z, fx, fy }, px = pixel size (1 = off)
function M.draw(W, pack, cam, rider, px)
  local sw, sh_ = lg.getDimensions()
  px = math.max(1, math.floor(px or 1))
  local w, h = math.ceil(sw / px), math.ceil(sh_ / px)
  local C = canvas_for(w, h, px)
  lg.push("all")
  lg.setCanvas({ C.c, depthstencil = C.d })
  lg.clear(M.SKY_HORIZON[1], M.SKY_HORIZON[2], M.SKY_HORIZON[3], 1, 0, 1)
  lg.setColor(1, 1, 1, 1)
  lg.draw(M.sky, 0, 0, 0, w, h * 0.55)
  local vp = mul(perspective(M.FOV, w / h, 0.3, M.FOG_FAR + 400), look_at(0, 0, 0, cam.lx - cam.x, cam.ly - cam.y, cam.lz - cam.z))
  local sh = M.shader
  lg.setShader(sh)
  -- as four columns (LÖVE 11 and 12 both take that)
  sh:send("u_vp", "column", { { vp[1], vp[2], vp[3], vp[4] }, { vp[5], vp[6], vp[7], vp[8] }, { vp[9], vp[10], vp[11], vp[12] }, { vp[13], vp[14], vp[15], vp[16] } })
  sh:send("u_screen", { w, h })
  sh:send("u_fog_col", M.SKY_HORIZON)
  sh:send("u_fog", { M.FOG_NEAR, M.FOG_FAR })
  lg.setDepthMode("lequal", true)
  lg.setMeshCullMode("none")
  -- the distant ground, then the built cells over it (depth cleared in between)
  for _, f in pairs(W.far) do
    if f.handle then draw_list(pack, f.handle.list, f.ox - cam.x, f.oy - cam.y, -cam.z, sh) end
  end
  lg.clear(false, false, 1)
  local vis = {}
  for _, c in pairs(W.cells) do
    if c.handle and c.ox then
      local half = 4096 * W.k                -- half a cell, metres
      local cx, cy = c.ox + half - cam.x, c.oy - half - cam.y
      if cx * cx + cy * cy < (M.VIEW + 200) ^ 2 then vis[#vis + 1] = c end
    end
  end
  -- by texture, so each texture is set once; see-through ones (windows) last, as mesh.TEXTURES orders them
  local order = {}
  for i, t in ipairs(mesh_lib.TEXTURES) do order[t] = i end
  local all = {}
  for _, c in ipairs(vis) do
    for _, e in ipairs(c.handle.list) do all[#all + 1] = { e = e, c = c, k = order[e.tex] or 0 } end
  end
  table.sort(all, function(a, b) return a.k < b.k end)
  for _, it in ipairs(all) do
    local e, c = it.e, it.c
    sh:send("u_off", { c.ox - cam.x, c.oy - cam.y, -cam.z })
    sh:send("u_cut", pack.alphatest and pack.alphatest[e.tex] and 0.5 or 0.0)
    e.mesh:setTexture(e.image or M.texture(pack, e.tex))
    lg.draw(e.mesh)
  end
  M.draws = #all
  -- the rider
  if rider then
    sh:send("u_off", { rider.x - cam.x, rider.y - cam.y, rider.z - cam.z })
    sh:send("u_cut", 0.0)
    -- turn the box to the heading: positions are rotated on the CPU once per frame (one small mesh)
    local a = math.atan2(rider.fy, rider.fx)
    if M.rider_a ~= a then
      M.rider_a = a
      local ca, sa = math.cos(a), math.sin(a)
      for i, B in ipairs(M.rider_verts) do
        M.rider:setVertex(i, B[1] * ca - B[2] * sa, B[1] * sa + B[2] * ca, B[3], B[4], B[5], B[6], B[7], B[8], B[9])
      end
    end
    M.rider:setTexture(M.white)
    lg.draw(M.rider)
  end
  lg.pop()
  lg.setColor(1, 1, 1, 1)
  lg.draw(C.c, 0, 0, 0, sw / w, sh_ / h)
end

return M
