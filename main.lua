local ncm = require("netease")

-- The host only calls this table through one serialized entry point. Returning
-- plain Lua data keeps this plugin portable across Windows, macOS, Linux,
-- Android and iOS.
local function dispatch(operation, args)
    args = args or {}
    if operation == "describe" then
      return { media = {
        {host="*.music.126.net", headers={["Referer"]="https://music.163.com/"}, artworkResize={parameter="param",value="{size}y{size}"},fallbackHosts={"p2.music.126.net","p3.music.126.net","p4.music.126.net"}},
        {host="*.music.163.com",headers={["Referer"]="https://music.163.com/"}}
      }, providers = {{
        id="netease", name="网易云音乐",
        auth={"qr", "sms", "password", "cookie", "exportCookie"},
        loginHint="使用网易云音乐 App 扫码，或选择其他登录方式。",
        cookieHint="粘贴网易云音乐登录 Cookie",
        forgotPasswordUrl="https://music.163.com/#/forgetpassword",
        capabilities={"search", "browseAlbums", "playlists", "editPlaylists", "favorites", "lyrics", "scrobble", "recommendations", "savedAlbums", "comments", "listenTogether", "radio", "charts", "homeFeed"}
      }} }
    end
    if operation == "exportCookie" then return ncm.export_cookie() end
    if operation == "savedAlbums" then return ncm.saved_albums(args.limit,args.offset) end
    if operation == "homeFeed" then return ncm.home_feed() end
    if operation == "charts" then return ncm.charts() end
    if operation == "radio" then return ncm.radio(args.kind,args.seed,args.playlist,args.limit) end
    if operation == "comments" then return ncm.comments(args.id,args.limit,args.offset) end
    if operation == "setCommentLiked" then return ncm.set_comment_liked(args.id,args.commentId,args.liked) end
    if operation == "listenTogether" then return ncm.listen_together(args.operation,args) end
    if operation == "session" then return ncm.session() end
    if operation == "loginCookie" then return ncm.login_cookie(args.cookie) end
    if operation == "loginPassword" then return ncm.login_password(args.account or args.phone, args.password) end
    if operation == "loginCaptcha" then return ncm.login_captcha(args.phone, args.captcha) end
    if operation == "sendCaptcha" then return ncm.send_captcha(args.phone) end
    if operation == "qrKey" then return ncm.qr_key() end
    if operation == "qrUrl" then return ncm.qr_url(args.key) end
    if operation == "qrCheck" then return ncm.qr_check(args.key) end
    if operation == "logout" then return ncm.logout() end
    if operation == "search" then return ncm.search(args.query, args.limit, args.offset) end
    if operation == "song" then return ncm.song(args.id) end
    if operation == "album" then return ncm.album(args.id) end
    if operation == "albums" then return ncm.albums(args.sort, args.limit, args.offset) end
    if operation == "albumSongs" then return ncm.album_songs(args.id, args.limit, args.offset) end
    if operation == "artist" then return ncm.artist(args.id) end
    if operation == "artistSongs" then return ncm.artist_songs(args.id,args.limit,args.offset) end
    if operation == "artistAlbums" then return ncm.artist_albums(args.id, args.limit, args.offset) end
    if operation == "playlists" then return ncm.playlists(args.limit, args.offset) end
    if operation == "playlist" then return ncm.playlist(args.id) end
    if operation == "playlistSongs" then return ncm.playlist_songs(args.id, args.limit, args.offset) end
    if operation == "createPlaylist" then return ncm.create_playlist(args.name, args.isPublic) end
    if operation == "addToPlaylist" then return ncm.add_to_playlist(args.playlist, args.songs) end
    if operation == "removeFromPlaylist" then return ncm.remove_from_playlist(args.playlist, args.indexes) end
    if operation == "favorites" then return ncm.favorites(args.limit, args.offset) end
    if operation == "setFavorite" then return ncm.set_favorite(args.id, args.favorite) end
    if operation == "stream" then return ncm.stream(args.id, args.quality) end
    if operation == "lyrics" then return ncm.lyrics(args.id) end
    if operation == "recommendations" then return ncm.recommendations(args.limit) end
    if operation == "playStats" then return ncm.play_stats(args.limit, args.offset) end
    if operation == "scrobble" then return ncm.scrobble(args.id, args.playedMs, args.submission) end
    error("unsupported operation: " .. tostring(operation))
end
return {call=function(operation,args)
  local ok,value=pcall(dispatch,operation,args)
  if ok then return value end
  local text=tostring(value)
  local code=tonumber(string.match(text,"Gateway code ([%-0-9]+)"))
  if string.find(text,"No playable stream",1,true) then code=70 end
  local status=tonumber(string.match(text,"HTTP ([0-9]+)"))
  if code==301 or code==302 then code=40;status=401 end
  if code==-460 or code==406 or code==429 then status=429 end
  return {error={code=code,httpStatus=status,reason="Request failed"}}
end}
