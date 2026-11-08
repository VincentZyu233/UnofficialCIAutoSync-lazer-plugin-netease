local json = host.json_decode
local encode = host.json_encode
local url_encode = host.url_encode
local M = {}
local COOKIE_KEY = "session_cookie"
local EAPI_KEY = "e82ckenh8dichen8"
local WEAPI_KEY = "0CoJUm6Qyw8W8jud"
local EAPI_DOMAIN = "https://interfacepc.music.163.com"
local WEB_DOMAIN = "https://music.163.com"
local DESKTOP_UA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117"
local cookie = host.storage_get(COOKIE_KEY)
local qr_cookie = nil
local account_user = nil
local favorite_ids = nil

local function compact_cookie(value)
  return value and host.cookie_compact(value) or nil
end

-- NetEase returns QR/login session cookies both as Set-Cookie headers and as
-- a raw Cookie string in the JSON `cookie` field (`NMTID=...; MUSIC_U=...;
-- __csrf=...`). host.cookie_merge keeps only the first `;` segment of each
-- line, so with NMTID first it drops MUSIC_U and the 803 confirmation can
-- never become a signed-in session. Parse both shapes and keep every field.
local function merge_cookie(previous, update)
  local values = {}
  local function trim(value)
    value = string.gsub(value, "^[ \t]+", "")
    return (string.gsub(value, "[ \t]+$", ""))
  end
  local function collect(text)
    if type(text) ~= "string" then return end
    text = string.gsub(text, "^[ \t]*[Cc]ookie:[ \t]*", "")
    text = string.gsub(text, "\r", ";")
    text = string.gsub(text, "\n", ";")
    local start = 1
    local text_length = string.len(text)
    while start <= text_length + 1 do
      local separator = string.find(text, ";", start, true)
      local part = separator and string.sub(text, start, separator - 1) or string.sub(text, start)
      local equals = string.find(part, "=", 1, true)
      if equals and equals > 1 then
        local name = trim(string.sub(part, 1, equals - 1))
        local value = trim(string.sub(part, equals + 1))
        if name ~= "" and value ~= "" then table.insert(values, name .. "=" .. value) end
      end
      if not separator then break end
      start = separator + 1
    end
  end
  collect(previous)
  collect(update)
  if #values == 0 then return nil end
  return host.cookie_compact(table.concat(values, "; "))
end

local function form(fields)
  local values = {}
  for k, v in pairs(fields) do table.insert(values, url_encode(k) .. "=" .. url_encode(tostring(v))) end
  table.sort(values)
  return table.concat(values, "&")
end

local function csrf()
  if not cookie then return "" end
  return host.cookie_field(cookie, "__csrf") or host.cookie_field(cookie, "__csrf_token") or ""
end

local function request(path, payload, mode, domain, qr)
  payload = payload or {}
  mode = mode or "eapi"
  local body = payload
  local endpoint = domain or (mode == "eapi" and EAPI_DOMAIN or WEB_DOMAIN)
  local upstream_path = string.gsub(path, "^/api", "")
  local headers = {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Referer"] = WEB_DOMAIN .. "/",
    ["Accept"] = "application/json",
    ["Cache-Control"] = "no-cache",
    ["User-Agent"] = mode == "api" and DESKTOP_UA or "Lazer Lua Gateway",
  }
  local current_cookie = cookie
  if qr then current_cookie = qr_cookie end
  if current_cookie then headers["Cookie"] = current_cookie end
  if mode == "weapi" then
    body.csrf_token = csrf()
    local plain = encode(body)
    local first = host.crypto({operation="aes", mode="cbc", key=WEAPI_KEY, iv="0102030405060708", text=plain})
    -- Eight random bytes are represented as sixteen printable hex characters,
    -- exactly the key width required by the second AES layer.
    local secret = host.random_hex(8)
    local second = host.crypto({operation="aes", mode="cbc", key=secret, iv="0102030405060708", text=first})
    local rsa = host.crypto({operation="rsa_modpow", input=secret, inputEncoding="utf8", reverse=true, modulus="e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7", exponent=65537, width=256})
    body = { params = second, encSecKey = rsa }
    endpoint = WEB_DOMAIN .. "/weapi" .. upstream_path
  elseif mode == "api" then
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    body = payload
    endpoint = WEB_DOMAIN .. path
  else
    body.e_r = false
    local mobile = string.find(path, "/listen/together/", 1, true) ~= nil
    body.header = {
      os=mobile and "android" or (domain and "osx" or "pc"), appver=domain and "3.1.10.5100" or "3.1.17.204416",
      osver="Microsoft-Windows-10-Professional-build-19045-64bit", channel="netease",
      __csrf=csrf(), requestId=tostring(host.now()) .. "_" .. host.random_hex(4),
      MUSIC_U=cookie and host.cookie_field(cookie,"MUSIC_U"),
      MUSIC_A=cookie and host.cookie_field(cookie,"MUSIC_A"),
      NMTID=cookie and host.cookie_field(cookie,"NMTID"),
      deviceId=cookie and host.cookie_field(cookie,"deviceId")
    }
    local plain = encode(body)
    local text = "nobody" .. path .. "use" .. plain .. "md5forencrypt"
    local digest = host.crypto({operation="md5", text=text})
    local encrypted = path .. "-36cd479b6b5-" .. plain .. "-36cd479b6b5-" .. digest
    body = { params = host.crypto({operation="aes", mode="ecb", key=EAPI_KEY, text=encrypted, encoding="hex"}) }
    endpoint = (domain or EAPI_DOMAIN) .. "/eapi" .. upstream_path
  end
  local response = host.http({url=endpoint, method="POST", headers=headers, body=form(body)})
  local set_cookie = response.headers and (response.headers["set-cookie"] or response.headers["Set-Cookie"])
  if set_cookie then
    local response_cookie = merge_cookie(current_cookie, set_cookie)
    if response_cookie then
      if qr then qr_cookie = response_cookie
      else cookie = response_cookie; host.storage_set(COOKIE_KEY, cookie) end
    end
  end
  if response.status < 200 or response.status >= 300 then error("HTTP " .. tostring(response.status)) end
  local value = json(response.body or "{}")
  if value.cookie then
    if qr then qr_cookie = merge_cookie(qr_cookie, value.cookie)
    else cookie = merge_cookie(cookie, value.cookie) or cookie; host.storage_set(COOKIE_KEY, cookie) end
  end
  if value.code and value.code ~= 200 and value.code ~= 803 and value.code ~= 802 and value.code ~= 801 and value.code ~= 800 and value.code ~= 8821 then error("Gateway code " .. tostring(value.code)) end
  return value
end

local function artwork(url)
  if type(url) ~= "string" then return nil end
  if string.sub(url, 1, 2) == "//" then return "https:" .. url end
  return string.gsub(url, "^http://", "https://")
end

local function song(value)
  value = value or {}
  local artists = {}
  for _, artist in ipairs(value.ar or value.artists or {}) do table.insert(artists, {id=artist.id, name=artist.name or "", coverUrl=artwork(artist.picUrl or artist.img1v1Url)}) end
  local album = value.al or value.album or {}
  return {id=value.id, title=value.name or value.title or "", artists=artists, albumId=album.id, albumName=album.name or "", coverUrl=artwork(album.picUrl or album.blurPicUrl), durationMs=value.dt or value.duration or 0, starred=value.starred == true, translatedTitle=value.tns and value.tns[1]}
end
local function album(value)
  value = value or {}; local artists = {}
  for _, artist in ipairs(value.artists or (value.artist and {value.artist} or {})) do table.insert(artists, {id=artist.id, name=artist.name or "", coverUrl=artwork(artist.picUrl or artist.img1v1Url)}) end
  return {id=value.id, title=value.name or value.title or "", artists=artists, coverUrl=artwork(value.picUrl or value.blurPicUrl or value.coverImgUrl), year=tonumber(value.year), publishTime=value.publishTime, songCount=value.size or value.trackCount or value.trackNumberUpdate or 0, description=value.description or value.briefDesc or "", releaseType=value.type or "", subType=value.subType or ""}
end
local function playlist(value)
  value = value or {}; return {id=value.id, name=value.name or "", description=value.description or value.copywriter or "", coverUrl=artwork(value.coverImgUrl or value.picUrl), songCount=value.trackCount or value.trackNumberUpdate or 0, owner=value.userId and tostring(value.userId) or nil, writable=account_user and value.creator and tostring(value.creator.userId)==tostring(account_user.id), isPublic=value.privacy ~= 10, isFavorites=value.specialType == 5}
end
local function page(items, limit, offset)
  local out = {}; for i=(offset or 0)+1, math.min(#items, (offset or 0)+(limit or #items)) do table.insert(out, items[i]) end
  return out
end

function M.session()
  if not cookie then return nil end
  local ok, body = pcall(request, "/api/w/nuser/account/get", {}, "weapi")
  if not ok then return nil end
  local data = body.data or body
  local profile = data.profile or body.profile
  local account = data.account or body.account
  if not profile and not account then return nil end
  account_user = {id=(profile and profile.userId) or (account and account.id), name=(profile and profile.nickname) or (account and account.userName) or "网易云用户", avatarUrl=profile and profile.avatarUrl}
  if not account_user.id or tonumber(account_user.id) == nil or tonumber(account_user.id) <= 0 then account_user=nil end
  return account_user
end
function M.login_cookie(value)
  local previous = cookie
  local previous_user = account_user
  local candidate = compact_cookie(value)
  if not candidate then return nil end
  cookie = candidate
  local ok, result = pcall(M.session)
  if not ok or not result then
    cookie = previous; account_user=previous_user
    host.storage_set(COOKIE_KEY, previous)
    return nil
  end
  favorite_ids=nil
  host.storage_set(COOKIE_KEY, cookie)
  return result
end
local function login_result(body)
  local profile=body.profile or (body.data and body.data.profile)
  local account=body.account or (body.data and body.data.account)
  if not profile and not account then return nil end
  account_user = {id=(profile and profile.userId) or (account and account.id), name=(profile and profile.nickname) or (account and account.userName) or "网易云用户", avatarUrl=profile and profile.avatarUrl}
  favorite_ids=nil
  return account_user
end
function M.login_password(account, password)
  if not account or not password then return nil end
  local body
  if string.find(account, "@", 1, true) then
    body=request("/api/w/login", {type=0, username=account, password=host.crypto({operation="md5", text=string.sub(password,1,16)}), rememberLogin=true}, "weapi")
  else
    body=request("/api/w/login/cellphone", {type=1, phone=account, countrycode=86, password=host.crypto({operation="md5", text=password}), remember=true, https=true}, "weapi")
  end
  return login_result(body)
end
function M.login_captcha(phone, captcha)
  local body=request("/api/w/login/cellphone", {type=1, phone=phone, countrycode=86, captcha=captcha, remember=true, https=true}, "weapi")
  return login_result(body)
end
function M.send_captcha(phone)
  return request("/api/middle/captcha/sent/v1", {ctcode=86, secrete="music_middleuser_pclogin", cellphone=phone, scene=0}, "eapi")
end
function M.qr_key()
  -- A new QR key must mint a fresh anonymous session. Reusing a previous
  -- scan's NMTID/MUSIC_U binds the new key to a session the phone cannot see.
  qr_cookie = nil
  local body=request("/api/login/qrcode/unikey", {type=3}, "api", nil, true)
  return body.unikey or (body.data and body.data.unikey) or ""
end
function M.qr_url(key)
  return "https://music.163.com/login?codekey=" .. url_encode(key)
end
function M.qr_check(key)
  local body=request("/api/login/qrcode/client/login", {key=key, type=3, secureCaptcha=""}, "api", nil, true)
  local code=tonumber(body.code) or 801
  if code == 803 then
    if not qr_cookie or not host.cookie_field(qr_cookie, "MUSIC_U") then
      -- The key is spent at this point. Report success only when the poll
      -- actually installed the session cookie; otherwise keep the client in
      -- the scanned state so it does not mistake this for an expired key.
      return 802
    end
    cookie=qr_cookie; account_user=nil; favorite_ids=nil; host.storage_set(COOKIE_KEY,cookie)
    return 803
  end
  return code
end
function M.logout()
  cookie = nil; qr_cookie=nil; account_user=nil; favorite_ids=nil
  host.storage_set(COOKIE_KEY, nil)
  return true
end
function M.search(query, limit, offset)
  local songs, albums, artists, playlists = {}, {}, {}, {}
  for _,kind in ipairs({1,10,100,1000}) do
    local body=request("/api/cloudsearch/pc", {s=query, type=kind, limit=limit or 30, offset=offset or 0, total=true}, "eapi")
    local result=body.result or {}
    for _,value in ipairs(result.songs or {}) do table.insert(songs,song(value)) end
    for _,value in ipairs(result.albums or {}) do table.insert(albums,album(value)) end
    for _,value in ipairs(result.artists or {}) do table.insert(artists,{id=value.id,name=value.name or "",coverUrl=artwork(value.picUrl or value.img1v1Url)}) end
    for _,value in ipairs(result.playlists or {}) do table.insert(playlists,playlist(value)) end
  end
  return {songs=songs,albums=albums,artists=artists,playlists=playlists}
end
function M.song(id)
  local body = request("/api/v3/song/detail", {c=encode({{id=tonumber(id)}})}, "weapi")
  return song((body.songs or {})[1])
end
function M.album(id)
  local body = request("/api/v1/album/" .. tostring(id), {}, "weapi"); return album(body.album)
end
function M.album_songs(id, limit, offset)
  local body = request("/api/v1/album/" .. tostring(id), {}, "weapi"); local out = {}
  for _, value in ipairs(body.songs or {}) do table.insert(out, song(value)) end
  return page(out, limit, offset)
end
function M.albums(sort, limit, offset)
  local body = request("/api/album/sublist", {limit=limit or 30, offset=offset or 0}, "weapi"); local out={}
  for _, value in ipairs(body.data or body.albums or {}) do table.insert(out, album(value)) end
  return out
end
function M.artist(id)
  local ok, body=pcall(request, "/api/artist/head/info/get", {id=id}, "eapi")
  if not ok then body=request("/api/artist/detail", {id=id}, "weapi") end
  local data=body.data or body
  local value=data.artist or data
  return {id=id,name=value.name or "",coverUrl=artwork(value.cover or value.picUrl or value.img1v1Url), description=value.briefDesc or "", albumCount=value.albumSize or value.albumCount or 0}
end
function M.artist_songs(id, limit, offset)
  local body=request("/api/v1/artist/songs", {id=id, limit=limit or 100, offset=offset or 0, order="hot", total=true}, "weapi")
  local out={}
  for _,value in ipairs(body.songs or body.hotSongs or {}) do table.insert(out, song(value.song or value)) end
  return page(out, limit, offset)
end
function M.artist_albums(id, limit, offset)
  local body=request("/api/artist/albums/" .. tostring(id), {limit=limit or 30, offset=offset or 0}, "weapi"); local out={}
  for _, value in ipairs(body.hotAlbums or body.albums or {}) do table.insert(out, album(value)) end
  return page(out, limit, offset)
end
function M.playlists(limit, offset)
  local result = account_user or M.session(); if not result then return {} end
  local body=request("/api/user/playlist", {uid=result.id, limit=limit or 30, offset=offset or 0}, "weapi"); local out={}
  for _, value in ipairs(body.playlist or {}) do table.insert(out, playlist(value)) end
  return out
end
function M.playlist(id)
  local body=request("/api/v6/playlist/detail", {id=id, n=100000, s=8}, "eapi"); return playlist(body.playlist)
end
local function detail_songs(ids)
  if #ids == 0 then return {} end
  local spec={}; for _,id in ipairs(ids) do table.insert(spec,{id=tonumber(id)}) end
  local body=request("/api/v3/song/detail", {c=encode(spec)}, "api")
  local by_id={}; for _,value in ipairs(body.songs or {}) do by_id[tostring(value.id)] = value end
  local out={}; for _,id in ipairs(ids) do
    local value=by_id[tostring(id)]; if value then table.insert(out,song(value)) end
  end
  return out
end
function M.playlist_songs(id, limit, offset)
  local body=request("/api/v6/playlist/detail", {id=id, n=100000, s=0}, "eapi")
  local value=body.playlist or {}; local ids={}
  if value.trackIds and #value.trackIds > 0 then
    for _,track in ipairs(page(value.trackIds,limit or 100,offset)) do table.insert(ids,track.id) end
    return detail_songs(ids)
  end
  local out={}; for _,track in ipairs(page(value.tracks or {},limit or 100,offset)) do table.insert(out,song(track)) end
  return out
end
function M.create_playlist(name, is_public)
  local body=request("/api/playlist/create", {name=name, privacy=is_public and 0 or 10, type="NORMAL"}, "weapi"); return playlist(body.playlist or {id=body.id,name=name})
end
function M.add_to_playlist(id, songs)
  local ids={}; for _, value in ipairs(songs or {}) do table.insert(ids, tonumber(value)) end
  return request("/api/playlist/manipulate/tracks", {op="add", pid=id, trackIds=encode(ids), imme="true"}, "weapi")
end
function M.remove_from_playlist(id, indexes)
  -- NetEase accepts IDs only. Resolve the current order first so duplicate rows remain safe.
  local values=M.playlist_songs(id, 1000, 0); local ids={}; for _, index in ipairs(indexes or {}) do if values[index+1] then table.insert(ids, values[index+1].id) end end
  return request("/api/playlist/manipulate/tracks", {op="del", pid=id, trackIds=encode(ids), imme="true"}, "weapi")
end
function M.favorites(limit, offset)
  local result=account_user or M.session(); if not result then return {} end
  if favorite_ids == nil then
    local body=request("/api/song/like/get", {uid=result.id}, "eapi")
    favorite_ids=body.ids or {}
  end
  return detail_songs(page(favorite_ids,limit or 100,offset))
end
function M.set_favorite(id, favorite)
  local result=account_user or M.session(); if not result then error("Sign in required") end
  local body=request("/api/song/like", {trackId=id, userid=result.id, like=favorite}, "eapi")
  favorite_ids=nil
  return body
end
function M.stream(id, quality)
  local bitrates={original=999000, high=320000, medium=192000, low=128000}
  local body=request("/api/song/enhance/player/url", {ids="["..tostring(id).."]", br=bitrates[quality] or 320000}, "weapi")
  local value=(body.data or {})[1] or {}; if not value.url then error("No playable stream") end
  return {url=string.gsub(value.url,"^http://","https://"), contentType=value.type == "flac" and "audio/flac" or "audio/mpeg", suffix=value.type, bitRate=value.br, size=value.size, transcoded=false, headers={Referer=WEB_DOMAIN.."/"}}
end
function M.lyrics(id)
  local body=request("/api/song/lyric/v1", {id=id, cp=false, tv=-1, lv=-1, rv=-1, kv=-1, yv=-1, ytv=-1, yrv=-1}, "eapi"); local out={}
  local lrc=body.lrc and body.lrc.lyric; if lrc then table.insert(out, {lrc=lrc, synced=true, lines={},wordByWord=body.yrc and body.yrc.lyric}) end
  if #out > 0 then
    out[1].translation=body.tlyric and body.tlyric.lyric
    out[1].wordTranslation=body.ytlrc and body.ytlrc.lyric
  end
  return out
end
function M.recommendations(limit)
  local body=request("/api/personalized/newsong", {limit=limit or 30}, "weapi"); local out={}
  for _, value in ipairs(body.result or {}) do table.insert(out, song(value.song or value)) end
  return page(out,limit,0)
end
function M.play_stats(limit, offset)
  local result = account_user or M.session(); if not result then return {records={}} end
  local body=request("/api/v1/play/record", {uid=result.id, type=0}, "weapi")
  local records={}; local all=body.allData or {}
  local start=(offset or 0)+1; local finish=math.min(#all, start+(limit or 100)-1)
  for i=start, finish do
    local value=all[i]; if value and value.song then table.insert(records, {song=song(value.song), playCount=value.playCount or 0}) end
  end
  return {records=records}
end
function M.scrobble(id, played_ms, submission)
  local result=account_user or M.session(); if not result then return {} end
  local source=tostring(id)
  local event = submission and {
    action="play", json={id=tonumber(id), type="song", time=math.floor((played_ms or 0)/1000), ["end"]="playend", source="list", sourceId=source, download=0, wifi=0, mainsite="1", mainsiteWeb="1", content="id="..source}
  } or {action="startplay", json={id=tonumber(id), type="song", mainsite="1", mainsiteWeb="1", content="id="..source}}
  return request("/api/feedback/weblog", {logs=encode({event})}, "eapi", "https://clientlog.music.163.com")
end
function M.export_cookie() return cookie end
function M.saved_albums(limit, offset) return M.albums("newest", limit, offset) end

local function songs(values)
  local out={}
  for _,value in ipairs(values or {}) do table.insert(out, song(value.song or value.songInfo or value)) end
  return out
end
local function playlists(values)
  local out={}
  for _,value in ipairs(values or {}) do table.insert(out, playlist(value)) end
  return out
end
function M.home_feed()
  local feed={quick={},daily={},recommended={},playlists={},albums={},editorialPlaylists={}}
  local ok,body=pcall(request,"/api/playlist/list",{cat="全部",order="hot",limit=12,offset=0,total=true},"weapi")
  if ok then feed.playlists=playlists(body.playlists) end
  ok,body=pcall(request,"/api/personalized/playlist",{limit=12,total=true,n=1000},"weapi")
  if ok then feed.recommended=playlists(body.result) end
  if cookie then
    ok,body=pcall(request,"/api/v3/discovery/recommend/songs",{},"weapi")
    if ok then feed.daily=songs((body.data and body.data.dailySongs) or body.recommend) end
    ok,body=pcall(request,"/api/v1/discovery/recommend/resource",{},"weapi")
    if ok and body.recommend and #body.recommend>0 then feed.recommended=playlists(body.recommend) end
  end
  ok,body=pcall(request,"/api/personalized/newsong",{type="recommend",limit=20,areaId=0},"weapi")
  if ok then feed.quick=songs(body.result) end
  ok,body=pcall(request,"/api/album/new",{area="ALL",limit=18,offset=0,total=true},"weapi")
  if ok then for _,value in ipairs(body.albums or {}) do table.insert(feed.albums,album(value)) end end
  -- NetEase's editorial shelf is published by the service's main editorial
  -- account rather than returned by the personalized recommendation route.
  -- Keep this separate from the user's own playlists so the home page can
  -- render the real editorial covers after a fresh Lua login.
  ok,body=pcall(request,"/api/user/playlist",{uid=1463586082,limit=24,offset=0},"weapi")
  if ok then
    for _,value in ipairs(body.playlist or {}) do
      if value.specialType ~= 5 then table.insert(feed.editorialPlaylists,playlist(value)) end
    end
  end
  if #feed.quick==0 and #feed.daily==0 and #feed.playlists==0 and #feed.albums==0 then error("Home unavailable") end
  if #feed.albums>0 then
    feed.featured=feed.albums[1]
    local success,tracks=pcall(M.album_songs,feed.featured.id,8,0)
    if success then feed.featuredSongs=tracks end
  end
  return feed
end
function M.charts()
  local body=request("/api/toplist/detail",{},"weapi")
  return playlists(body.list)
end
function M.radio(kind, seed, playlist_id, limit)
  if kind=="personal" then
    local body=request("/api/v1/radio/get",{},"weapi")
    return songs(body.data)
  elseif kind=="heart" then
    if not seed and playlist_id then
      local values=M.playlist_songs(playlist_id,1,0); seed=values[1] and values[1].id
    end
    if not seed then return {} end
    local body=request("/api/playmode/intelligence/list",{songId=seed,type="fromPlayOne",playlistId=playlist_id,startMusicId=seed,count=limit or 30},"eapi")
    return songs(body.data)
  elseif kind=="artist" then
    local artists={seed}
    local ok,similar=pcall(request,"/api/discovery/simiArtist",{artistid=seed},"weapi")
    if ok then for i,value in ipairs(similar.artists or {}) do if i<=4 then table.insert(artists,value.id) end end end
    local groups={}
    for _,artist_id in ipairs(artists) do
      local success,body=pcall(request,"/api/artist/top/song",{id=artist_id},"weapi")
      if success then table.insert(groups,songs(body.songs)) end
    end
    local out={}; local seen={}
    for row=1,8 do for _,group in ipairs(groups) do
      local value=group[row]
      if value and not seen[tostring(value.id)] then seen[tostring(value.id)]=true; table.insert(out,value) end
    end end
    return page(out,limit,0)
  end
  return {}
end
local function comment(value)
  local user=value.user or {}
  local replies={}
  for _,reply in ipairs(value.beReplied or value.replies or {}) do
    local reply_user=reply.user or {}
    table.insert(replies,{author=reply.author or reply_user.nickname or "",content=reply.content or ""})
  end
  return {
    id=tostring(value.commentId or value.id or ""),
    content=value.content or "",
    author=value.author or user.nickname or "",
    authorId=tostring(value.authorId or user.userId or ""),
    avatarUrl=artwork(value.avatarUrl or user.avatarUrl),
    time=value.time or value.timeStr,
    location=(value.ipLocation and value.ipLocation.location) or value.location,
    liked=value.liked==true,
    likedCount=value.likedCount or 0,
    replies=replies
  }
end
local function comment_body(path,payload)
  local ok,body=pcall(request,path,payload,"weapi")
  if ok then return body end
  return request(path,payload,"api")
end
function M.comments(id,limit,offset)
  local body=comment_body("/api/v1/resource/comments/R_SO_4_"..tostring(id),{rid=id,limit=limit or 20,offset=offset or 0,beforeTime=0})
  local data=body.data or body
  local hot={}; local latest={}
  for _,value in ipairs(data.hotComments or data.hot or {}) do table.insert(hot,comment(value)) end
  for _,value in ipairs(data.comments or data.latest or {}) do table.insert(latest,comment(value)) end
  return {hot=hot,latest=latest,total=data.total or 0,hasMore=data.more==true or data.hasMore==true}
end
function M.set_comment_liked(id,comment_id,liked)
  local path="/api/v1/comment/"..(liked and "like" or "unlike")
  local payload={threadId="R_SO_4_"..tostring(id),commentId=tostring(comment_id),rid=id}
  local ok=pcall(request,path,payload,"weapi")
  if not ok then request(path,payload,"api") end
end
function M.listen_together(operation,args)
  local paths={create="/room/create",join="/play/invitation/accept",status="/room/check",leave="/end/v2",heartbeat="/heartbeat",command="/play/command/report"}
  local suffix=paths[operation]; if not suffix then error("unsupported room operation") end
  local payload={roomId=args.roomId}
  if operation=="create" then payload={refer="songplay_more"} end
  if operation=="join" then payload.inviterId=args.inviterId;payload.refer="inbox_invite" end
  if operation=="heartbeat" then payload.songId=args.songId or "0";payload.playStatus=args.playStatus;payload.progress=args.progress;payload.playlistVersion="[]" end
  if operation=="command" then
    local command=args.command or {}
    local account=account_user or M.session(); if not account then error("Gateway code 301") end
    command.userId=tonumber(account.id); command.ignoreUserId={command.userId};command.serverSeq=0
    payload.commandInfo=encode(command)
  end
  local body=request("/api/listen/together"..suffix,payload,"eapi")
  local data=body.data or body
  local members={}
  for _,value in ipairs(data.members or data.users or data.participants or {}) do
    table.insert(members,{userId=tostring(value.userId or value.uid),name=value.nickname or value.name or value.userName or "",avatarUrl=artwork(value.avatarUrl or value.avatar)})
  end
  return {roomId=data.roomId or data.roomid,inviterId=data.inviterId or data.userId,members=members}
end
return M


