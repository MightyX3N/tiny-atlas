-- Downloads for the standalone: worker threads (requests block, so they run there) using LÖVE 12's https module,
-- Windows' WinHTTP or curl,
-- and binary cache files in the save folder (love.filesystem). Gives fetch.lua the platform it needs.
local M = { workers = {}, waiting = {}, next_id = 0, ok = true }
local WORKER = [==[
-- one download thread: LÖVE 12's https module if there is one, else Windows' WinHTTP (through LuaJIT's FFI, so no
-- extra DLL), else curl (Linux, macOS)
local req, res = love.thread.getChannel("ta_http_req"), love.thread.getChannel("ta_http_res")
local AGENT = "TinyAtlas/0.1 (+https://github.com/MightyX3N/tiny-atlas)"
local get
local has_https, https = pcall(require, "https")
local ffi = require("ffi")
if has_https then
  get = function(url, range, method, body, headers)
    local h = { ["User-Agent"] = AGENT }
    if range then h["Range"] = range end
    for k, v in pairs(headers or {}) do h[k] = v end
    local code, res = https.request(url, { headers = h, method = method, data = body })
    return code, res
  end
elseif ffi.os == "Windows" then
  ffi.cdef [[
    typedef void *HINTERNET;
    HINTERNET WinHttpOpen(const uint16_t *agent, uint32_t access, const uint16_t *proxy, const uint16_t *bypass, uint32_t flags);
    HINTERNET WinHttpConnect(HINTERNET s, const uint16_t *server, uint16_t port, uint32_t reserved);
    HINTERNET WinHttpOpenRequest(HINTERNET c, const uint16_t *verb, const uint16_t *path, const uint16_t *version,
      const uint16_t *referrer, const uint16_t **types, uint32_t flags);
    int WinHttpSendRequest(HINTERNET r, const uint16_t *headers, uint32_t hlen, void *opt, uint32_t optlen, uint32_t total, uintptr_t ctx);
    int WinHttpReceiveResponse(HINTERNET r, void *reserved);
    int WinHttpQueryHeaders(HINTERNET r, uint32_t info, const uint16_t *name, void *buf, uint32_t *len, uint32_t *index);
    int WinHttpQueryDataAvailable(HINTERNET r, uint32_t *n);
    int WinHttpReadData(HINTERNET r, void *buf, uint32_t n, uint32_t *read);
    int WinHttpCloseHandle(HINTERNET h);
    uint32_t GetLastError(void);
  ]]
  local W = ffi.load("winhttp")
  local function wide(s)
    local b = ffi.new("uint16_t[?]", #s + 1)
    for i = 1, #s do b[i - 1] = s:byte(i) end
    return b
  end
  -- automatic proxy (Windows 8.1+), else the system default
  local session = W.WinHttpOpen(wide(AGENT), 4, nil, nil, 0)
  if session == nil then session = W.WinHttpOpen(wide(AGENT), 0, nil, nil, 0) end
  get = function(url, range, method, body, headers)
    local scheme, host, port, path = url:match("^(https?)://([^/:]+):?(%d*)(.*)$")
    if not host then error("bad URL " .. url) end
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    if path == "" then path = "/" end
    local conn = W.WinHttpConnect(session, wide(host), port, 0)
    if conn == nil then error("WinHttpConnect failed (" .. W.GetLastError() .. ")") end
    local r = W.WinHttpOpenRequest(conn, wide(method or "GET"), wide(path), nil, nil, nil, scheme == "https" and 0x00800000 or 0)
    if r == nil then W.WinHttpCloseHandle(conn); error("WinHttpOpenRequest failed (" .. W.GetLastError() .. ")") end
    local hs = range and ("Range: " .. range .. "\r\n") or ""
    for k, v in pairs(headers or {}) do hs = hs .. k .. ": " .. v .. "\r\n" end
    local hdr = hs ~= "" and wide(hs) or nil
    local data = body and ffi.new("char[?]", #body + 1, body) or nil
    local ok = W.WinHttpSendRequest(r, hdr, hdr and 0xFFFFFFFF or 0, data, body and #body or 0, body and #body or 0, 0) ~= 0
      and W.WinHttpReceiveResponse(r, nil) ~= 0
    if not ok then
      local e = W.GetLastError()
      W.WinHttpCloseHandle(r); W.WinHttpCloseHandle(conn)
      error("no answer from " .. host .. " (WinHTTP error " .. e .. ")")
    end
    local code = ffi.new("uint32_t[1]")
    local len = ffi.new("uint32_t[1]", 4)
    W.WinHttpQueryHeaders(r, 19 + 0x20000000, nil, code, len, nil)     -- status code, as a number
    local parts = {}
    local n, got = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
    local buf, cap = nil, 0
    while W.WinHttpQueryDataAvailable(r, n) ~= 0 and n[0] > 0 do
      if n[0] > cap then cap = n[0]; buf = ffi.new("uint8_t[?]", cap) end
      if W.WinHttpReadData(r, buf, n[0], got) == 0 then break end
      parts[#parts + 1] = ffi.string(buf, got[0])
    end
    W.WinHttpCloseHandle(r); W.WinHttpCloseHandle(conn)
    return tonumber(code[0]), table.concat(parts)
  end
else
  get = function(url, range, method, body, headers)
    local rh = range and (" -H 'Range: " .. range:gsub("'", "") .. "'") or ""
    for k, v in pairs(headers or {}) do rh = rh .. " -H '" .. (k .. ": " .. v):gsub("'", "") .. "'" end
    local tmp
    if method then rh = rh .. " -X " .. method:gsub("%W", "") end
    if body then
      tmp = os.tmpname()
      local f = io.open(tmp, "wb"); f:write(body); f:close()
      rh = rh .. " --data-binary @'" .. tmp .. "'"
    end
    local f = io.popen("curl -sSL -A '" .. AGENT .. "'" .. rh .. " -w '\n%{http_code}' '" .. url:gsub("'", "") .. "'", "r")
    local all = f:read("*a"); f:close()
    if tmp then os.remove(tmp) end
    local body, code = all:match("^(.*)\n(%d+)$")
    return tonumber(code), body
  end
end
while true do
  local r = req:demand()
  if r == "quit" then return end
  local fine, code, body = pcall(get, r.url, r.range, r.method, r.body, r.headers)
  if not fine then res:push({ id = r.id, err = tostring(code) })
  elseif r.method then res:push({ id = r.id, body = body or "", code = code or 0 })     -- HTTP(): every answer, with its code
  elseif not code or code >= 400 or code == 0 then res:push({ id = r.id, err = "HTTP " .. tostring(code) })
  else res:push({ id = r.id, body = body or "" }) end
end
]==]
M.THREADS = 4

function M.start()
  M.has_https = pcall(require, "https") or require("ffi").os == "Windows" or os.execute("curl --version > /dev/null 2>&1") == 0
  M.req = love.thread.getChannel("ta_http_req")
  M.res = love.thread.getChannel("ta_http_res")
  for i = 1, M.THREADS do
    local t = love.thread.newThread(WORKER)
    t:start()
    M.workers[i] = t
  end
end

function M.stop()
  for _ = 1, #M.workers do M.req:push("quit") end
end

-- call every frame: hands finished downloads to their callbacks
function M.update(log)
  while true do
    local r = M.res:pop()
    if not r then break end
    local w = M.waiting[r.id]
    M.waiting[r.id] = nil
    if w then
      if r.err then w.err(r.err) else w.ok(r.body, r.code) end
    end
  end
  for _, t in ipairs(M.workers) do
    local e = t:getError()
    if e and not t.reported then t.reported = true; log("[Tiny Atlas] FAILED: download thread: " .. e) end
  end
end

-- the platform for fetch.lua
M.platform = {
  -- range: an HTTP Range value ("bytes=0-99", "bytes=-65536") or nil
  http_get = function(url, ok, err, range)
    M.next_id = M.next_id + 1
    M.waiting[M.next_id] = { ok = ok, err = err }
    M.req:push({ id = M.next_id, url = url, range = range })
  end,
  -- any request (GMod's HTTP()): method, body, headers; ok(body, code) gets every answer the server gives
  request = function(t, ok, err)
    M.next_id = M.next_id + 1
    M.waiting[M.next_id] = { ok = ok, err = err }
    M.req:push({ id = M.next_id, url = t.url, method = t.method or "GET", body = t.body, headers = t.headers })
  end,
  read = function(path)
    if not love.filesystem.getInfo(path, "file") then return nil end
    return (love.filesystem.read(path))
  end,
  write = function(path, data)
    local dir = path:match("^(.*)/[^/]*$")
    if dir then love.filesystem.createDirectory(dir) end
    return love.filesystem.write(path, data) and true or false
  end,
  time = os.time,
}

return M
