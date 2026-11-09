-- Session state that outlives one operation.
--
-- The cookie is the only thing written to plugin storage. Everything else
-- (the verified account, the QR candidate, the response caches) is rebuilt at
-- most once per VM start, which keeps storage writes off the hot path: the
-- previous implementation wrote the storage file for every response that
-- carried a Set-Cookie header.
local M = {}

local COOKIE_KEY = "session_cookie"
local cookie = host.storage_get(COOKIE_KEY)
if type(cookie) ~= "string" then cookie = "" end
local qr_cookie = ""
local resets = {}

M.user = nil

function M.cookie()
  return cookie
end

-- Stores a compact Cookie header, or clears the session when `value` is empty.
-- Identical values are not rewritten.
function M.set_cookie(value)
  local next_value = value
  if type(next_value) ~= "string" then next_value = "" end
  if next_value == cookie then return end
  cookie = next_value
  if next_value == "" then
    host.storage_set(COOKIE_KEY, nil)
  else
    host.storage_set(COOKIE_KEY, next_value)
  end
end

function M.qr_cookie()
  return qr_cookie
end

function M.set_qr_cookie(value)
  qr_cookie = type(value) == "string" and value or ""
end

function M.field(name)
  if cookie == "" then return nil end
  local value = host.cookie_field(cookie, name)
  if value == nil or value == "" then return nil end
  return value
end

function M.csrf()
  return M.field("__csrf") or M.field("__csrf_token") or ""
end

-- Modules register their caches so a login, logout or account switch starts
-- from a clean slate instead of showing the previous listener's library.
function M.on_reset(callback)
  resets[#resets + 1] = callback
end

function M.reset()
  M.user = nil
  for index = 1, #resets do
    pcall(resets[index])
  end
end

return M
