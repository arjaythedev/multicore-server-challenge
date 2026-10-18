-- bcrypt, run in nginx's "bcrypt" thread pool through ngx.run_worker_thread, so a ~60 ms hash never blocks
-- a worker's event loop. Ubuntu's libcrypt (libxcrypt) does the work, through LuaJIT's FFI.
-- Each pool thread has its own Lua VM, so the scratch buffers below are per thread.
local ffi = require "ffi"

ffi.cdef [[
char *crypt_rn(const char *phrase, const char *setting, void *data, int size);
char *crypt_gensalt_rn(const char *prefix, unsigned long count, const char *rbytes, int nrbytes,
                       char *output, int output_size);
]]

-- nginx itself links libcrypt (for auth_basic), so the symbols are usually already in the process
local lib = pcall(function() return ffi.C.crypt_rn end) and ffi.C or ffi.load("libcrypt.so.1")

local DATA_SIZE = 65536            -- >= sizeof(struct crypt_data), which crypt_rn checks
local data = ffi.new("char[?]", DATA_SIZE)
local setting = ffi.new("char[?]", 128)
local band, bor, bxor = bit.band, bit.bor, bit.bxor

local _M = {}

-- a new $2b$10$ hash, or nil
function _M.hash(password)
  if lib.crypt_gensalt_rn("$2b$", 10, nil, 0, setting, 128) == nil then return nil end
  local out = lib.crypt_rn(password, setting, data, DATA_SIZE)
  if out == nil then return nil end
  return ffi.string(out)
end

-- true if password matches the stored hash ($2a$, $2b$ or $2y$), compared in constant time
function _M.verify(password, hash)
  local out = lib.crypt_rn(password, hash, data, DATA_SIZE)
  if out == nil then return false end
  local got = ffi.string(out)
  if #got ~= #hash then return false end
  local diff = 0
  for i = 1, #got do diff = bor(diff, bxor(got:byte(i), hash:byte(i))) end
  return band(diff, 0xff) == 0
end

return _M
