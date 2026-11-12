-- NetEase Cloud Music provider for Lazer's isolated Lua plugin runtime.
--
-- Layout:
--   main.lua              operation table, error mapping, media rules
--   ncm/config.lua        fixed wire constants (hosts, keys, limits)
--   ncm/store.lua         persisted session cookie and in-memory state
--   ncm/transport.lua     weapi/eapi/plain envelopes and cookie rotation
--   ncm/models.lua        response -> client model mapping
--   ncm/account.lua       session, cookie/QR/password/SMS login, logout
--   ncm/catalog.lua       search, albums, artists, playlists, likes, streams
--   ncm/discover.lua      home feed, charts, radio
--   ncm/social.lua        comments and listen-together rooms
--
-- The embedded interpreter is a Lua 5.3 subset whose string library is backed
-- by Dart regular expressions: `string.match` returns the whole match (no
-- captures) and `%d`/`%s` classes do not exist. Everything below therefore
-- extracts text with `string.find(.., true)` plus `string.sub`, and raises
-- errors in the fixed "Gateway code N" / "HTTP N" shape the dispatcher parses.
local account = require("ncm.account")
local catalog = require("ncm.catalog")
local discover = require("ncm.discover")
local social = require("ncm.social")

local CAPABILITIES = {
  "search", "browseAlbums", "playlists", "editPlaylists", "favorites",
  "lyrics", "scrobble", "recommendations", "savedAlbums", "comments",
  "listenTogether", "radio", "charts", "homeFeed",
}

-- Artwork rules the host applies to cover URLs. The manifest must declare the
-- same hosts or the host drops a rule whose host is outside the plugin scope.
local MEDIA = {
  {
    host = "*.music.126.net",
    headers = { ["Referer"] = "https://music.163.com/" },
    artworkResize = { parameter = "param", value = "{size}y{size}" },
    fallbackHosts = { "p2.music.126.net", "p3.music.126.net", "p4.music.126.net" },
  },
  {
    host = "music.163.com",
    headers = { ["Referer"] = "https://music.163.com/" },
  },
}

local function describe()
  return {
    media = MEDIA,
    providers = {
      {
        id = "netease",
        name = "网易云音乐",
        auth = { "qr", "sms", "password", "cookie", "exportCookie" },
        loginHint = "使用网易云音乐 App 扫码，或选择手机号、密码登录。",
        cookieHint = "粘贴网易云音乐网页版 Cookie（MUSIC_U=…）",
        forgotPasswordUrl = "https://music.163.com/#/forgetpassword",
        capabilities = CAPABILITIES,
      },
    },
  }
end

local operations = {
  describe = describe,
  session = function() return account.session() end,
  loginCookie = function(args) return account.login_cookie(args.cookie) end,
  loginPassword = function(args) return account.login_password(args.account or args.phone, args.password) end,
  loginCaptcha = function(args) return account.login_captcha(args.phone, args.captcha) end,
  sendCaptcha = function(args) return account.send_captcha(args.phone) end,
  qrKey = function() return account.qr_key() end,
  qrUrl = function(args) return account.qr_url(args.key) end,
  qrCheck = function(args) return account.qr_check(args.key) end,
  logout = function() return account.logout() end,
  exportCookie = function() return account.export_cookie() end,

  search = function(args) return catalog.search(args.query, args.limit, args.offset) end,
  song = function(args) return catalog.song(args.id) end,
  album = function(args) return catalog.album(args.id) end,
  albums = function(args) return catalog.albums(args.limit, args.offset) end,
  savedAlbums = function(args) return catalog.saved_albums(args.limit, args.offset) end,
  albumSongs = function(args) return catalog.album_songs(args.id, args.limit, args.offset) end,
  artist = function(args) return catalog.artist(args.id) end,
  artistSongs = function(args) return catalog.artist_songs(args.id, args.limit, args.offset) end,
  artistAlbums = function(args) return catalog.artist_albums(args.id, args.limit, args.offset) end,
  playlists = function(args) return catalog.playlists(args.limit, args.offset) end,
  playlist = function(args) return catalog.playlist(args.id) end,
  playlistSongs = function(args) return catalog.playlist_songs(args.id, args.limit, args.offset) end,
  createPlaylist = function(args) return catalog.create_playlist(args.name, args.isPublic) end,
  addToPlaylist = function(args) return catalog.add_to_playlist(args.playlist, args.songs) end,
  removeFromPlaylist = function(args) return catalog.remove_from_playlist(args.playlist, args.indexes) end,
  favorites = function(args) return catalog.favorites(args.limit, args.offset) end,
  setFavorite = function(args) return catalog.set_favorite(args.id, args.favorite) end,
  stream = function(args) return catalog.stream(args.id, args.quality) end,
  lyrics = function(args) return catalog.lyrics(args.id) end,
  recommendations = function(args) return catalog.recommendations(args.limit) end,
  playStats = function(args) return catalog.play_stats(args.limit, args.offset) end,
  scrobble = function(args) return catalog.scrobble(args.id, args.playedMs, args.submission) end,

  homeFeed = function() return discover.home_feed() end,
  charts = function() return discover.charts() end,
  radio = function(args) return discover.radio(args.kind, args.seed, args.playlist, args.limit) end,

  comments = function(args) return social.comments(args.id, args.limit, args.offset) end,
  setCommentLiked = function(args) return social.set_comment_liked(args.id, args.commentId, args.liked) end,
  listenTogether = function(args) return social.listen_together(args.operation, args) end,
}

local function dispatch(operation, args)
  local handler = operations[operation]
  if handler == nil then
    error("unsupported operation: " .. tostring(operation), 0)
  end
  if type(args) ~= "table" then args = {} end
  return handler(args)
end

-- Reads the integer that follows `marker` in a plain-text error message. The
-- runtime cannot express capture groups, so this walks the bytes by hand.
local function number_after(message, marker)
  local start = string.find(message, marker, 1, true)
  if start == nil then return nil end
  local index = start + string.len(marker)
  local negative = false
  if string.sub(message, index, index) == "-" then
    negative = true
    index = index + 1
  end
  local digits = index
  while index <= string.len(message) do
    local byte = string.byte(message, index)
    if byte == nil or byte < 48 or byte > 57 then break end
    index = index + 1
  end
  if index == digits then return nil end
  local value = tonumber(string.sub(message, digits, index - 1))
  if value == nil then return nil end
  if negative then value = -value end
  return value
end

-- The host only ever receives a status pair: never the upstream body, a URL
-- with a signature, a cookie or a request identifier.
local function failure(message)
  local reason = tostring(message)
  local code = number_after(reason, "Gateway code ")
  local status = number_after(reason, "HTTP ")
  if code == 301 or code == 302 or code == 401 or code == 403 then
    code = 40
    status = 401
  elseif code == -460 or code == 406 or code == 429 or status == 429 then
    -- NetEase's risk-control and rate-limit answers. The host reports the HTTP
    -- status, so a 429 stays a 429 instead of a bare application code.
    if code == -460 or code == 406 then code = nil end
    status = 429
  end
  return { error = { code = code, httpStatus = status, reason = "Request failed" } }
end

return {
  call = function(operation, args)
    local ok, value = pcall(dispatch, operation, args)
    if ok then return value end
    return failure(value)
  end,
}
