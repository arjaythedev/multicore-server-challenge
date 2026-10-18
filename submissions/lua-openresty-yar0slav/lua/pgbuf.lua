-- A buffered stand-in for the nginx cosocket pgmoon talks to Postgres through. pgmoon reads every protocol
-- message with two receive() calls (5-byte header, then body), so a 10-row result (~25 messages) costs ~50
-- cosocket calls. This reads whatever has arrived with one receiveany() and serves pgmoon's receive(n) from
-- memory. pgmoon itself is unchanged: it only ever sees an object with the cosocket methods it uses.
local CHUNK = 65536

local mt = {}
mt.__index = mt

function mt:receive(n)
  local buf, pos = self.buf, self.pos
  local have = #buf - pos + 1
  while have < n do
    local chunk, err = self.sock:receiveany(CHUNK)
    if not chunk then return nil, err end
    if have > 0 then buf = buf:sub(pos) .. chunk else buf = chunk end
    pos, have = 1, #buf
  end
  local s = buf:sub(pos, pos + n - 1)
  pos = pos + n
  if pos > #buf then buf, pos = "", 1 end
  self.buf, self.pos = buf, pos
  return s
end

function mt:send(...) return self.sock:send(...) end
function mt:connect(...) return self.sock:connect(...) end
function mt:getreusedtimes() return self.sock:getreusedtimes() end
function mt:settimeout(t) return self.sock:settimeout(t) end
function mt:settimeouts(...) return self.sock:settimeouts(...) end

function mt:close()
  self.buf, self.pos = "", 1
  return self.sock:close()
end

-- Bytes left unread mean the protocol state is unknown: close rather than hand the connection to another request.
function mt:setkeepalive(...)
  if self.pos <= #self.buf then
    self:close()
    return nil, "unread data in buffer"
  end
  return self.sock:setkeepalive(...)
end

return function(sock)
  return setmetatable({ sock = sock, buf = "", pos = 1 }, mt)
end
