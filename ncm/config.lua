-- Fixed protocol constants. Nothing here is account specific: credentials live
-- in ncm/store.lua and only leave the plugin as a Cookie request header.
local M = {}

M.api = "https://music.163.com"
M.eapi_host = "https://interfacepc.music.163.com"
-- The listen-together routes are served from the mobile gateway. It validates
-- the envelope and the `os`/`appver` cookie attributes together, so a mobile
-- identity has to reach the host that expects it: interfacepc answers those
-- calls with a rejection instead of a room.
M.mobile_eapi_host = "https://interface.music.163.com"
M.client_log_host = "https://clientlog.music.163.com"

M.weapi_key = "0CoJUm6Qyw8W8jud"
M.eapi_key = "e82ckenh8dichen8"
M.weapi_iv = "0102030405060708"
M.weapi_user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " ..
  "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0"
M.rsa_modulus = "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b72515" ..
  "2b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ec" ..
  "bda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d8" ..
  "13cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"

-- Client identities. `desktop` is the macOS player: the client-log deposit only
-- counts plays from that surface. `mobile` is what listen-together expects.
M.clients = {
  pc = {
    os = "pc",
    appver = "3.1.17.204416",
    osver = "Microsoft-Windows-10-Professional-build-19045-64bit",
    channel = "netease",
    userAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) " ..
      "Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117",
  },
  desktop = {
    os = "osx",
    appver = "3.1.10.5100",
    osver = "15.5",
    channel = "netease",
    userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " ..
      "(KHTML, like Gecko) Version/15.5 Safari/605.1.15 NeteaseMusic/3.1.10.5100",
  },
  mobile = {
    os = "android",
    appver = "9.5.95",
    osver = "14",
    channel = "xiaomi",
    versioncode = "9005095",
    userAgent = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) " ..
      "Chrome/91.0.4472.164 Mobile Safari/537.36 NeteaseMusic/9.5.95",
  },
}

-- Bitrate per client quality tier. 999000 asks for lossless; the service
-- answers with the best rendition the account may play and reports its real
-- bitrate, which the client maps back onto a tier.
M.quality = {
  original = 999000,
  high = 320000,
  medium = 192000,
  low = 128000,
}

-- Paging guards. The host never asks for more than 500 rows; NetEase caps its
-- own list endpoints well below that.
M.max_page = 500
M.detail_chunk = 400

-- NetEase's main editorial account publishes the curated playlists the home
-- shelf shows; the personalized route never returns them.
M.editorial_uid = 1463586082

-- The client fetches 100 tracks for every chart it renders, and the runtime
-- serializes calls, so an unlimited toplist would stall the shelf.
M.max_charts = 8

M.favorites_ttl = 300000
M.album_ttl = 300000
M.playlist_ttl = 120000

return M
