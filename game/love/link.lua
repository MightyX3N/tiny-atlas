-- Riding live with other players in the standalone: direct connections between games over ENet (UDP, built into
-- LÖVE). Your game listens on a port (playit.lua can make that port reachable from the internet) and connects to the
-- other riders' addresses. The game's own code (cl_live.lua) only sees this small interface:
--   link.start(port) -> true / nil, error      listen (the next free port if that one is taken)
--   link.connect("host:port")                   connect to another rider's game
--   link.send(text [, peer])                    to one peer, or to every connected peer (unreliable, sequenced)
--   link.poll() -> { { type = "connect" | "receive" | "disconnect", peer = id, data = text }, ... }
--   link.peers() -> { id = true, ... }          link.port   the port listened on
local ok_enet, enet = pcall(require, "enet")
local M = { peers = {}, ids = {}, by_id = {}, next_id = 0, pending = {} }

function M.available() return ok_enet end

function M.start(port)
  if M.host then return true end
  if not ok_enet then return nil, "no ENet in this LÖVE" end
  port = port or 27630
  for p = port, port + 20 do
    local h = enet.host_create("*:" .. p, 64, 2)
    if h then M.host, M.port = h, p; return true end
  end
  return nil, "no free port"
end

local function id_of(peer)
  local k = tostring(peer)
  local id = M.ids[k]
  if not id then
    M.next_id = M.next_id + 1
    id = "p" .. M.next_id
    M.ids[k], M.by_id[id] = id, peer
  end
  return id
end

function M.connect(addr)
  if not M.host then return nil end
  if M.pending[addr] then return M.pending[addr] end
  local ok, peer = pcall(M.host.connect, M.host, addr, 2)
  if not ok or not peer then return nil end
  local id = id_of(peer)
  M.pending[addr] = id
  return id
end
function M.forget(addr) M.pending[addr] = nil end

function M.send(text, id)
  if not M.host then return end
  if id then
    local p = M.by_id[id]
    if p and M.peers[id] then p:send(text, 0, "unsequenced") end
  else
    for pid in pairs(M.peers) do M.by_id[pid]:send(text, 0, "unsequenced") end
  end
end
function M.send_reliable(text, id)
  local p = M.by_id[id]
  if p and M.peers[id] then p:send(text, 1, "reliable") end
end

function M.poll()
  local out = {}
  if not M.host then return out end
  for _ = 1, 200 do
    local ok, ev = pcall(M.host.service, M.host, 0)
    if not ok or not ev then break end
    local id = id_of(ev.peer)
    if ev.type == "connect" then M.peers[id] = true
    elseif ev.type == "disconnect" then
      M.peers[id] = nil
      for a, pid in pairs(M.pending) do if pid == id then M.pending[a] = nil end end
    end
    out[#out + 1] = { type = ev.type, peer = id, data = ev.data }
  end
  return out
end
function M.peers_list() return M.peers end

function M.stop()
  if not M.host then return end
  for id in pairs(M.peers) do pcall(function() M.by_id[id]:disconnect_now() end) end
  pcall(function() M.host:flush() end)
  pcall(function() M.host:destroy() end)
  M.host, M.peers, M.pending = nil, {}, {}
end

return M
