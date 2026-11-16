-- Sign-in, session and account identity.
--
-- Nothing here calls the network speculatively: a failed attempt restores the
-- previous cookie and verified account, which is what the client relies on to
-- keep a working session when a pasted cookie or password is wrong.
local config = require("ncm.config")
local models = require("ncm.models")
local store = require("ncm.store")
local transport = require("ncm.transport")

local M = {}

-- A compact Cookie header from whatever the user pasted. `host.cookie_compact`
-- only strips a leading "cookie:", so a line copied from a network panel as
-- "set-cookie: MUSIC_U=…" would lose its first field; strip both first.
local function split_lines(value)
  local out = {}
  local start = 1
  local length = string.len(value)
  for index = 1, length do
    local byte = string.byte(value, index)
    if byte == 10 or byte == 13 then
      local line = string.sub(value, start, index - 1)
      if line ~= "" then out[#out + 1] = line end
      start = index + 1
    end
  end
  if start <= length then
    local line = string.sub(value, start)
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

local function strip_header_name(line)
  local trimmed = models.trim(line)
  if string.lower(string.sub(trimmed, 1, 11)) == "set-cookie:" then
    return string.sub(trimmed, 12)
  end
  if string.lower(string.sub(trimmed, 1, 7)) == "cookie:" then
    return string.sub(trimmed, 8)
  end
  return trimmed
end

local function cookie_header(value)
  local raw = models.text(value)
  if raw == "" then return "" end
  local lines = split_lines(raw)
  for index = 1, #lines do lines[index] = strip_header_name(lines[index]) end
  local compact = host.cookie_compact(table.concat(lines, "; "))
  if compact == nil then return "" end
  return compact
end

local function membership_of(profile)
  local vip = models.number(profile.vipType, 0)
  if vip >= 11 then return "黑胶VIP" end
  if vip == 10 then return "音乐包" end
  return nil
end

-- Maps the several envelopes `account/get` and the login routes use.
local function profile_of(body)
  if type(body) ~= "table" then return nil end
  local data = type(body.data) == "table" and body.data or body
  local profile = type(data.profile) == "table" and data.profile or nil
  if profile == nil and type(body.profile) == "table" then profile = body.profile end
  local account = type(data.account) == "table" and data.account or nil
  if account == nil and type(body.account) == "table" then account = body.account end

  local id = nil
  if profile ~= nil then id = models.field(profile, "userId", "id") end
  if id == nil and account ~= nil then id = account.id end
  local numeric = models.number(id, 0)
  if numeric <= 0 then return nil end

  local name = ""
  if profile ~= nil then name = models.text(profile.nickname) end
  if name == "" and account ~= nil then name = models.text(account.userName) end
  if name == "" then name = "网易云用户" end

  local user = { id = tostring(numeric), name = name }
  if profile ~= nil then
    local avatar = models.image(profile.avatarUrl)
    if avatar ~= nil then user.avatarUrl = avatar end
    local signature = models.trim(profile.signature)
    if signature ~= "" then user.signature = signature end
    local membership = membership_of(profile)
    if membership ~= nil then user.membership = membership end
  end
  return user
end

local function signed_out(message)
  local reason = tostring(message)
  if string.find(reason, "Gateway code 301", 1, true) ~= nil then return true end
  if string.find(reason, "Gateway code 302", 1, true) ~= nil then return true end
  return false
end

function M.session()
  if store.cookie() == "" then
    store.user = nil
    return nil
  end
  local ok, body = pcall(transport.request, "/api/w/nuser/account/get", {}, "weapi")
  if not ok then
    if signed_out(body) then
      store.user = nil
      return nil
    end
    -- A transport failure is not a sign-out: the client keeps the last known
    -- account and retries, instead of silently dropping the session.
    error(body, 0)
  end
  store.user = profile_of(body)
  return store.user
end

function M.require_user()
  if store.user == nil then M.session() end
  if store.user == nil then error("Gateway code 301", 0) end
  return store.user
end

local function adopt_login(body)
  local user = profile_of(body)
  if user == nil then
    -- Some routes answer only with the rotated cookie. Confirm it once.
    local ok, verified = pcall(M.session)
    if not ok or verified == nil then return nil end
    user = verified
  end
  store.reset()
  store.user = user
  return user
end

local function restore(previous_cookie, previous_user)
  store.set_cookie(previous_cookie)
  store.user = previous_user
end

-- A failed login may still rotate cookies in its HTTP response. Restore the
-- verified session before reporting the status so another account attempt
-- cannot silently sign the current listener out.
local function request_login(path, payload)
  local previous_cookie = store.cookie()
  local previous_user = store.user
  local ok, body = pcall(transport.request, path, payload, "weapi")
  if not ok then
    restore(previous_cookie, previous_user)
    error(body, 0)
  end
  local user = adopt_login(body)
  if user == nil then restore(previous_cookie, previous_user) end
  return user
end

function M.login_cookie(value)
  local candidate = cookie_header(value)
  if candidate == "" then return nil end
  local previous_cookie = store.cookie()
  local previous_user = store.user
  store.set_cookie(candidate)
  store.user = nil
  local ok, user = pcall(M.session)
  if not ok or user == nil then
    restore(previous_cookie, previous_user)
    return nil
  end
  store.reset()
  store.user = user
  return user
end

-- Returns a mobile number with separators removed, or nil when the account is
-- not numeric (an email address or a music ID).
local function phone_of(value)
  local digits = {}
  local length = string.len(value)
  for index = 1, length do
    local byte = string.byte(value, index)
    if byte >= 48 and byte <= 57 then
      digits[#digits + 1] = string.char(byte)
    elseif byte == 32 or byte == 45 or byte == 43 then
      -- Space, dash and "+" are formatting, not identifiers.
    else
      return nil
    end
  end
  local phone = table.concat(digits)
  if string.len(phone) > 11 and string.sub(phone, 1, 2) == "86" then
    phone = string.sub(phone, 3)
  end
  local size = string.len(phone)
  if size < 6 or size > 15 then return nil end
  return phone
end

local function md5(value)
  return host.crypto({ operation = "md5", text = value })
end

function M.login_password(account, password)
  local identifier = models.trim(account)
  local secret = models.text(password)
  if identifier == "" or secret == "" then return nil end
  local payload
  local path
  local phone = phone_of(identifier)
  if phone ~= nil then
    path = "/api/w/login/cellphone"
    payload = {
      type = "1", https = "true", phone = phone, countrycode = "86",
      remember = "true", password = md5(secret), secureCaptcha = "",
    }
  else
    path = "/api/w/login"
    payload = {
      type = 0, https = "true", username = identifier,
      password = md5(secret), rememberLogin = "true",
    }
  end
  return request_login(path, payload)
end

function M.login_captcha(phone, captcha, secure_captcha)
  local number = phone_of(models.trim(phone))
  local code = models.trim(captcha)
  if number == nil or code == "" then return nil end
  return request_login("/api/w/login/cellphone", {
    type = "1", https = "true", phone = number, countrycode = "86",
    remember = "true", captcha = code, secureCaptcha = models.trim(secure_captcha),
  })
end

function M.send_captcha(phone)
  local number = phone_of(models.trim(phone))
  if number == nil then error("Gateway code 400", 0) end
  -- Keep the endpoint and encryption aligned with api-enhanced's captcha_sent.
  transport.request("/api/sms/captcha/sent", {
    ctcode = "86", secrete = "music_middleuser_pclogin", cellphone = number,
  }, "weapi")
  return true
end

function M.qr_key()
  store.set_qr_cookie("")
  local body = transport.request("/api/login/qrcode/unikey", { type = 3 }, "web", { qr = true })
  local data = type(body.data) == "table" and body.data or body
  local key = models.text(data.unikey)
  if key == "" then error("Gateway code 70", 0) end
  return key
end

function M.qr_url(key)
  local value = models.text(key)
  if value == "" then return "" end
  return config.api .. "/login?codekey=" .. host.url_encode(value)
end

function M.qr_check(key)
  local value = models.text(key)
  if value == "" then return 801 end
  local body = transport.request("/api/login/qrcode/client/login", {
    key = value, type = 3, secureCaptcha = "",
  }, "web", { qr = true, allow = { 800, 801, 802, 803, 8821 } })
  local code = models.number(body.code, 801)
  if code == 803 and store.qr_cookie() ~= "" then
    store.set_cookie(store.qr_cookie())
    store.set_qr_cookie("")
    store.reset()
  elseif code == 800 then
    store.set_qr_cookie("")
  end
  return code
end

function M.logout()
  -- Best effort: a local sign-out must succeed even offline, and the token is
  -- worthless once it is no longer sent.
  pcall(transport.request, "/api/logout", {}, "eapi")
  store.set_cookie("")
  store.set_qr_cookie("")
  store.reset()
  return true
end

function M.export_cookie()
  local value = store.cookie()
  if value == "" then return nil end
  return value
end

return M
