-- Wire format for music.163.com.
--
--   weapi  double AES-CBC of a JSON body plus an RSA-wrapped per-request key
--   eapi   AES-ECB of `path-36cd479b6b5-json-36cd479b6b5-md5`, upper-case hex
--   web    the plain /api form surface the desktop client uses for QR sign-in
--
-- Only this module touches the Cookie header, and every rotation goes through
-- ncm.store so a response never writes plugin storage twice for one value.
local config = require("ncm.config")
local store = require("ncm.store")

local M = {}

local function text(value)
  if value == nil then return "" end
  local kind = type(value)
  if kind == "string" then return value end
  if kind == "number" then
    if math.floor(value) == value then return tostring(math.floor(value)) end
    return tostring(value)
  end
  return ""
end

local function field_value(value)
  local kind = type(value)
  if kind == "table" then return host.json_encode(value) end
  if kind == "boolean" then return value and "true" or "false" end
  return text(value)
end

-- Sorted form body. Sorting keeps the request stable, which makes the offline
-- fixtures and the encrypted payloads comparable between runs.
local function form_body(values)
  local keys = {}
  for key in pairs(values) do keys[#keys + 1] = key end
  table.sort(keys)
  local parts = {}
  for index = 1, #keys do
    local key = keys[index]
    parts[#parts + 1] = host.url_encode(key) .. "=" .. host.url_encode(field_value(values[key]))
  end
  return table.concat(parts, "&")
end

local function copy(values)
  local out = {}
  for key, value in pairs(values) do out[key] = value end
  return out
end

local function weapi_envelope(payload)
  local plain = host.json_encode(payload)
  local first = host.crypto({
    operation = "aes", mode = "cbc", key = config.weapi_key, iv = config.weapi_iv, text = plain,
  })
  -- The second AES key is the same secret the RSA layer protects: sixteen
  -- printable characters, reversed before the raw modular exponentiation.
  local secret = host.random_hex(8)
  local second = host.crypto({
    operation = "aes", mode = "cbc", key = secret, iv = config.weapi_iv, text = first,
  })
  local wrapped = host.crypto({
    operation = "rsa_modpow",
    input = secret,
    inputEncoding = "utf8",
    reverse = true,
    modulus = config.rsa_modulus,
    exponent = 65537,
    width = 256,
  })
  return { params = second, encSecKey = string.upper(wrapped) }
end

local function eapi_envelope(path, payload)
  local plain = host.json_encode(payload)
  local digest = host.crypto({ operation = "md5", text = "nobody" .. path .. "use" .. plain .. "md5forencrypt" })
  local envelope = path .. "-36cd479b6b5-" .. plain .. "-36cd479b6b5-" .. digest
  return string.upper(host.crypto({
    operation = "aes", mode = "ecb", key = config.eapi_key, text = envelope, encoding = "hex",
  }))
end

local function client_of(options)
  if options.mobile then return config.clients.mobile end
  if options.desktop then return config.clients.desktop end
  return config.clients.pc
end

-- eapi carries the device identity twice: a JSON header inside the encrypted
-- payload and the session fields themselves.
local function eapi_header(options)
  local client = client_of(options)
  local header = {
    os = client.os,
    appver = client.appver,
    osver = client.osver,
    channel = client.channel,
    __csrf = store.csrf(),
    requestId = tostring(host.now()) .. "_" .. host.random_hex(4),
  }
  if client.versioncode ~= nil then header.versioncode = client.versioncode end
  local fields = { "MUSIC_U", "MUSIC_A", "NMTID", "deviceId" }
  for index = 1, #fields do
    local value = store.field(fields[index])
    if value ~= nil then header[fields[index]] = value end
  end
  return header
end

local function code_allowed(code, options)
  if code == 200 or code == 201 then return true end
  local allowed = options.allow
  if type(allowed) ~= "table" then return false end
  for index = 1, #allowed do
    if allowed[index] == code then return true end
  end
  return false
end

local function absorb_cookie(decoded, options)
  if type(decoded.cookie) ~= "string" or decoded.cookie == "" then return end
  local base = options.qr and store.qr_cookie() or store.cookie()
  local merged = host.cookie_merge(base, decoded.cookie)
  if merged == nil or merged == "" then return end
  if options.qr then
    store.set_qr_cookie(merged)
  else
    store.set_cookie(merged)
  end
end

-- POSTs one operation and returns its decoded JSON object.
--
-- Throws "HTTP <status>" for a transport answer outside 2xx, "INVALID_JSON"
-- for a body that is not a JSON object, and "Gateway code <n>" for a service
-- code outside the accepted set. The dispatcher turns those into the safe
-- `{error = {code, httpStatus}}` shape; no body text ever leaves the plugin.
function M.request(path, payload, mode, options)
  options = options or {}
  payload = payload or {}
  mode = mode or "eapi"

  local outgoing = copy(payload)
  local url
  local body
  local session_cookie = store.cookie()
  if options.qr then session_cookie = store.qr_cookie() end
  local client = client_of(options)

  if mode == "weapi" then
    outgoing.e_r = false
    outgoing.csrf_token = store.csrf()
    url = config.api .. "/weapi" .. string.sub(path, 5)
    body = form_body(weapi_envelope(outgoing))
  elseif mode == "web" then
    url = config.api .. path
    body = form_body(outgoing)
  else
    outgoing.e_r = false
    outgoing.header = eapi_header(options)
    url = (options.domain or config.eapi_host) .. "/eapi" .. string.sub(path, 5)
    body = form_body({ params = eapi_envelope(path, outgoing) })
  end

  local headers = {
    Accept = "application/json",
    ["Cache-Control"] = "no-cache",
    ["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8",
    Referer = config.api .. "/",
    ["User-Agent"] = client.userAgent,
  }
  if mode == "weapi" and not options.mobile and not options.desktop then
    headers["User-Agent"] = config.weapi_user_agent
  end
  -- The room endpoints read the client identity from the Cookie as well as the
  -- envelope, and reject the desktop os/appver pair there. These attributes are
  -- request scoped: `session_cookie` stays untouched for the rotation below.
  local request_cookie = session_cookie
  if options.mobile then
    local attributes = "os=" .. client.os .. "; appver=" .. client.appver
    if client.versioncode ~= nil then
      attributes = attributes .. "; versioncode=" .. client.versioncode
    end
    request_cookie = session_cookie ~= "" and (session_cookie .. "; " .. attributes) or attributes
  end
  if request_cookie ~= "" then headers.Cookie = request_cookie end

  local response = host.http({ url = url, method = "POST", headers = headers, body = body })
  if type(response) ~= "table" then error("INVALID_JSON", 0) end

  local response_headers = type(response.headers) == "table" and response.headers or {}
  local set_cookie = response_headers["set-cookie"] or response_headers["Set-Cookie"]
  if type(set_cookie) == "string" and set_cookie ~= "" then
    local merged = host.cookie_merge(session_cookie, set_cookie)
    if merged ~= nil and merged ~= "" then
      if options.qr then
        store.set_qr_cookie(merged)
      else
        store.set_cookie(merged)
      end
    end
  end

  local status = tonumber(response.status)
  if status == nil then error("HTTP 0", 0) end
  status = math.floor(status)
  if status < 200 or status >= 300 then
    error("HTTP " .. tostring(status), 0)
  end

  local ok, decoded = pcall(host.json_decode, response.body or "")
  if not ok or type(decoded) ~= "table" then error("INVALID_JSON", 0) end

  absorb_cookie(decoded, options)
  local code = tonumber(decoded.code)
  if code ~= nil then
    code = math.floor(code)
    if not code_allowed(code, options) then
      error("Gateway code " .. tostring(code), 0)
    end
  end
  return decoded
end

return M
