-- Catalogue operations: search, albums, artists, playlists, likes, playback.
--
-- Paging contract: every list endpoint forwards `limit + 1` rows (or slices one
-- extra locally). The host trims the page to `limit` and derives `hasMore` from
-- the row count it received, so the extra row is what stops a list one request
-- short of its end instead of one request past it.
local config = require("ncm.config")
local models = require("ncm.models")
local store = require("ncm.store")
local transport = require("ncm.transport")
local account = require("ncm.account")

local M = {}

local favorites = { ids = nil, at = 0 }
local albums = {}
local playlists = {}

store.on_reset(function()
  favorites.ids = nil
  favorites.at = 0
  albums = {}
  playlists = {}
end)

local function page_size(limit, fallback)
  local value = models.number(limit, fallback or 30)
  if value < 1 then value = 1 end
  if value > config.max_page then value = config.max_page end
  return value
end

local function page_offset(offset)
  local value = models.number(offset, 0)
  if value < 0 then value = 0 end
  return value
end

local function account_id()
  if store.user == nil then return nil end
  return store.user.id
end

-- Song details are fetched in chunks: one request for a 5000-track playlist
-- would exceed the host's 2 MB request budget and its 8 MB response budget.
local function detail_chunk(ids)
  local spec = {}
  for index = 1, #ids do
    spec[#spec + 1] = { id = models.number(ids[index], 0) }
  end
  if #spec == 0 then return {} end
  local body = transport.request("/api/v3/song/detail", { c = host.json_encode(spec) }, "weapi")
  return models.list(body.songs)
end

-- Returns mapped songs in the requested order; the service answers in its own
-- order and may omit tracks that no longer exist.
local function song_details(ids)
  local total = #ids
  if total == 0 then return {} end
  local by_id = {}
  local index = 1
  while index <= total do
    local stop = index + config.detail_chunk - 1
    if stop > total then stop = total end
    local batch = {}
    for position = index, stop do
      batch[#batch + 1] = ids[position]
    end
    local rows = detail_chunk(batch)
    for position = 1, #rows do
      local value = rows[position]
      if type(value) == "table" then
        by_id[models.text(value.id)] = value
      end
    end
    index = stop + 1
  end
  local out = {}
  for position = 1, total do
    local value = by_id[models.text(ids[position])]
    if value ~= nil then out[#out + 1] = models.song(value) end
  end
  return out
end

function M.search(query, limit, offset)
  local keyword = models.trim(query)
  local result = { songs = {}, albums = {}, artists = {}, playlists = {} }
  if keyword == "" then return result end
  local take = page_size(limit, 30)
  local skip = page_offset(offset)
  local kinds = { { 1, "songs" }, { 10, "albums" }, { 100, "artists" }, { 1000, "playlists" } }
  for index = 1, #kinds do
    local kind = kinds[index]
    local body = transport.request("/api/cloudsearch/pc", {
      s = keyword, type = kind[1], limit = take + 1, offset = skip, total = true,
    }, "eapi")
    local data = type(body.result) == "table" and body.result or {}
    local rows = models.list(data[kind[2]])
    local mapped = {}
    for position = 1, #rows do
      local value = rows[position]
      if type(value) == "table" then
        if kind[2] == "songs" then
          mapped[#mapped + 1] = models.song(value)
        elseif kind[2] == "albums" then
          mapped[#mapped + 1] = models.album(value)
        elseif kind[2] == "artists" then
          mapped[#mapped + 1] = models.artist(value)
        else
          mapped[#mapped + 1] = models.playlist(value, account_id())
        end
      end
    end
    result[kind[2]] = mapped
  end
  return result
end

function M.song(id)
  local numeric = models.number(id, 0)
  if numeric <= 0 then error("Gateway code 70", 0) end
  local songs = song_details({ numeric })
  if #songs == 0 then error("Gateway code 70", 0) end
  return songs[1]
end

local function album_body(id)
  local key = models.text(id)
  if models.number(key, 0) <= 0 then error("Gateway code 70", 0) end
  local cached = albums[key]
  local now = host.now()
  if cached ~= nil and now - cached.at < config.album_ttl then return cached.body end
  local body = transport.request("/api/v1/album/" .. key, {}, "weapi")
  albums[key] = { at = now, body = body }
  return body
end

function M.album(id)
  local body = album_body(id)
  local value = body.album
  if type(value) ~= "table" then error("Gateway code 70", 0) end
  return models.album(value)
end

function M.album_songs(id, limit, offset)
  local take = page_size(limit, 100)
  local skip = page_offset(offset)
  local body = album_body(id)
  return models.map_rows(models.window(body.songs, take + 1, skip), models.song)
end

function M.albums(limit, offset)
  local take = page_size(limit, 30)
  local skip = page_offset(offset)
  local body = transport.request("/api/album/new", {
    area = "ALL", limit = take + 1, offset = skip, total = true,
  }, "weapi")
  return models.map_rows(models.list(body.albums), models.album)
end

function M.saved_albums(limit, offset)
  account.require_user()
  local take = page_size(limit, 30)
  local skip = page_offset(offset)
  local body = transport.request("/api/album/sublist", {
    limit = take + 1, offset = skip, total = true,
  }, "weapi")
  local rows = type(body.data) == "table" and body.data or body.albums
  return models.map_rows(models.list(rows), models.album)
end

function M.artist(id)
  local numeric = models.number(id, 0)
  if numeric <= 0 then error("Gateway code 70", 0) end
  local ok, body = pcall(transport.request, "/api/artist/head/info/get", { id = numeric }, "eapi")
  local data = ok and (type(body.data) == "table" and body.data or body) or {}
  local value = type(data.artist) == "table" and data.artist or nil
  if value == nil then
    -- The head endpoint is the desktop surface; the web detail route carries
    -- the same description and album count when it answers empty.
    body = transport.request("/api/artist/detail", { id = numeric }, "weapi")
    data = type(body.data) == "table" and body.data or body
    value = type(data.artist) == "table" and data.artist or body.artist
  end
  if type(value) ~= "table" then error("Gateway code 70", 0) end
  return models.artist(value)
end

function M.artist_songs(id, limit, offset)
  local numeric = models.number(id, 0)
  if numeric <= 0 then error("Gateway code 70", 0) end
  local take = page_size(limit, 100)
  local skip = page_offset(offset)
  local body = transport.request("/api/v1/artist/songs", {
    id = numeric, limit = take + 1, offset = skip, order = "hot",
    private_cloud = "true", work_type = 1, total = true,
  }, "eapi")
  return models.map_rows(models.list(body.songs), models.song)
end

function M.artist_albums(id, limit, offset)
  local numeric = models.number(id, 0)
  if numeric <= 0 then error("Gateway code 70", 0) end
  local take = page_size(limit, 30)
  local skip = page_offset(offset)
  local body = transport.request("/api/artist/albums/" .. tostring(numeric), {
    limit = take + 1, offset = skip, total = true,
  }, "weapi")
  local rows = models.list(body.hotAlbums)
  if #rows == 0 then rows = models.list(body.albums) end
  return models.map_rows(rows, models.album)
end

function M.playlists(limit, offset)
  local user = account.require_user()
  local take = page_size(limit, 30)
  local skip = page_offset(offset)
  local body = transport.request("/api/user/playlist", {
    uid = models.number(user.id, 0), limit = take + 1, offset = skip, includeVideo = true,
  }, "weapi")
  local owner = user.id
  return models.map_rows(models.list(body.playlist), function(value)
    return models.playlist(value, owner)
  end)
end

-- One playlist detail request per page at most, and only when the cached track
-- ids cannot answer the requested window. `n` is capped: the host refuses an
-- 8 MB response, and `trackIds` already carries the whole order.
local function playlist_detail(id, count)
  local numeric = models.number(id, 0)
  if numeric <= 0 then error("Gateway code 70", 0) end
  local key = tostring(numeric)
  local requested = models.number(count, 1)
  if requested < 1 then requested = 1 end
  if requested > 2000 then requested = 2000 end
  local now = host.now()
  local body = transport.request("/api/v6/playlist/detail", {
    id = numeric, n = requested, s = 8,
  }, "eapi")
  local value = body.playlist
  if type(value) ~= "table" then error("Gateway code 70", 0) end
  local entry = playlists[key]
  if entry == nil then
    entry = {}
    playlists[key] = entry
  end
  entry.at = now
  entry.playlist = value
  entry.count = models.number(value.trackCount, 0)
  local ids = {}
  local raw = models.list(value.trackIds)
  for index = 1, #raw do
    local item = raw[index]
    local track_id = type(item) == "table" and item.id or item
    if track_id ~= nil then ids[#ids + 1] = models.number(track_id, 0) end
  end
  if #ids > 0 then entry.track_ids = ids end
  if type(value.tracks) == "table" and #value.tracks > 0 then entry.tracks = value.tracks end
  return entry
end

function M.playlist(id)
  local entry = playlist_detail(id, 1)
  return models.playlist(entry.playlist, account_id())
end

function M.playlist_songs(id, limit, offset)
  local take = page_size(limit, 100)
  local skip = page_offset(offset)
  local key = tostring(models.number(id, 0))
  local entry = playlists[key]
  if entry ~= nil and entry.at ~= nil and host.now() - entry.at > config.playlist_ttl then
    entry = nil
  end
  local ids = entry ~= nil and entry.track_ids or nil
  local count = entry ~= nil and entry.count or 0
  -- `complete` means the cached id list is the whole playlist, so a window
  -- past its end is the end of the list rather than a reason to refetch.
  local complete = ids ~= nil and (count == 0 or #ids >= count)
  if ids == nil or (not complete and #ids < skip + take + 1) then
    entry = playlist_detail(id, skip + take + 1)
    ids = entry.track_ids
  end
  if ids ~= nil and #ids > 0 then
    return song_details(models.window(ids, take + 1, skip))
  end
  local tracks = entry ~= nil and entry.tracks or {}
  return models.map_rows(models.window(tracks, take + 1, skip), models.song)
end

function M.create_playlist(name, is_public)
  local user = account.require_user()
  local title = models.trim(name)
  if title == "" then error("Gateway code 70", 0) end
  if string.len(title) > 40 then title = string.sub(title, 1, 40) end
  local body = transport.request("/api/playlist/create", {
    name = title, privacy = is_public == true and "0" or "10", type = "NORMAL",
  }, "weapi")
  local raw = type(body.playlist) == "table" and body.playlist or nil
  if raw ~= nil then
    local mapped = models.playlist(raw, user.id)
    mapped.writable = true
    return mapped
  end
  local identifier = body.id
  if identifier == nil and type(body.data) == "table" then identifier = body.data.id end
  if identifier == nil then error("Gateway code 70", 0) end
  return {
    id = models.text(identifier),
    name = title,
    description = "",
    songCount = 0,
    owner = models.text(user.id),
    writable = true,
    isPublic = is_public == true,
    isFavorites = false,
  }
end

function M.add_to_playlist(id, songs)
  local playlist_id = models.number(id, 0)
  if playlist_id <= 0 then error("Gateway code 70", 0) end
  local values = models.list(songs)
  local ids = {}
  for index = 1, #values do
    local song_id = models.number(values[index], 0)
    if song_id > 0 then ids[#ids + 1] = tostring(song_id) end
  end
  if #ids == 0 then return true end
  transport.request("/api/playlist/manipulate/tracks", {
    op = "add", pid = playlist_id, trackIds = "[" .. table.concat(ids, ",") .. "]", imme = "true",
  }, "weapi")
  playlists[tostring(playlist_id)] = nil
  return true
end

-- The service can only delete by track id. Removing a position whose song also
-- appears elsewhere in the playlist would therefore delete more than asked, so
-- that case fails before anything is mutated.
function M.remove_from_playlist(id, indexes)
  local playlist_id = models.number(id, 0)
  if playlist_id <= 0 then error("Gateway code 70", 0) end
  local values = models.list(indexes)
  local positions = {}
  for index = 1, #values do
    local position = models.number(values[index], -1)
    if position >= 0 then positions[#positions + 1] = position end
  end
  if #positions == 0 then return true end
  table.sort(positions)
  local highest = positions[#positions] + 1
  local key = tostring(playlist_id)
  local entry = playlists[key]
  local ids = entry ~= nil and entry.track_ids or nil
  local count = entry ~= nil and entry.count or 0
  if ids == nil or (#ids < highest and (count == 0 or #ids < count)) then
    entry = playlist_detail(id, highest + 1)
    ids = entry.track_ids
  end
  if ids == nil or #ids == 0 then error("Gateway code 70", 0) end
  local removals = {}
  local seen = {}
  for index = 1, #positions do
    local track_id = ids[positions[index] + 1]
    if track_id == nil then error("playlist position out of range", 0) end
    local occurrences = 0
    for position = 1, #ids do
      if ids[position] == track_id then occurrences = occurrences + 1 end
    end
    if occurrences > 1 then error("playlist has duplicate tracks at that position", 0) end
    if not seen[track_id] then
      seen[track_id] = true
      removals[#removals + 1] = track_id
    end
  end
  transport.request("/api/playlist/manipulate/tracks", {
    op = "del", pid = playlist_id, trackIds = host.json_encode(removals), imme = "true",
  }, "weapi")
  playlists[key] = nil
  return true
end

local function liked_ids(user)
  local now = host.now()
  if favorites.ids ~= nil and now - favorites.at < config.favorites_ttl then
    return favorites.ids
  end
  local body = transport.request("/api/song/like/get", { uid = models.number(user.id, 0) }, "eapi")
  local raw = models.list(body.ids)
  local ids = {}
  for index = 1, #raw do
    ids[#ids + 1] = models.number(raw[index], 0)
  end
  favorites.ids = ids
  favorites.at = now
  return ids
end

function M.favorites(limit, offset)
  local user = account.require_user()
  local take = page_size(limit, 100)
  local skip = page_offset(offset)
  local songs = song_details(models.window(liked_ids(user), take + 1, skip))
  for index = 1, #songs do songs[index].starred = true end
  return songs
end

function M.set_favorite(id, favorite)
  local user = account.require_user()
  local song_id = models.number(id, 0)
  if song_id <= 0 then error("Gateway code 70", 0) end
  transport.request("/api/song/like", {
    trackId = song_id, userid = models.number(user.id, 0), like = favorite == true,
  }, "eapi")
  favorites.ids = nil
  return true
end

local function content_type(suffix)
  if suffix == "flac" then return "audio/flac" end
  if suffix == "mp3" then return "audio/mpeg" end
  if suffix == "m4a" or suffix == "aac" then return "audio/mp4" end
  if suffix == "" then return nil end
  return "audio/" .. suffix
end

-- A locked song answers with a preview. No lower tier unlocks it, so the ladder
-- stops instead of spending three more requests on the same answer.
local STREAM_LOCKED = {}

local function stream_result(value)
  local url = value ~= nil and models.https(value.url) or nil
  if url == nil or url == "" then return nil end
  -- A locked song still answers with 200 and a 30 second preview. Playing it
  -- looks like a broken player that stops mid-song, so it is reported as
  -- unavailable and the host skips the track instead. A "preview" badge would
  -- need a protocol field the host does not have yet.
  if value.freeTrialInfo ~= nil then return STREAM_LOCKED end
  local suffix = models.text(value.type)
  local result = {
    url = url,
    suffix = suffix,
    transcoded = false,
    -- Signed CDN links are fetched by the audio engine, not by the plugin.
    headers = { ["Referer"] = config.api .. "/" },
  }
  local kind = content_type(suffix)
  if kind ~= nil then result.contentType = kind end
  local reported = models.number(value.br, 0)
  if reported > 0 then result.bitRate = reported end
  local size = models.number(value.size, 0)
  if size > 0 then result.size = size end
  return result
end

-- An account without the requested tier gets an empty url for that br, which is
-- the normal case rather than an error. Asking again for the next lower tier
-- here keeps the host queue free: the app used to spend up to four serial calls
-- per track on this ladder, and a user skipping through a queue paid for all of
-- them before the next song could even be resolved.
local STREAM_LADDER = { 999000, 320000, 192000, 128000 }

function M.stream(id, quality)
  local song_id = models.number(id, 0)
  if song_id <= 0 then error("Gateway code 70", 0) end
  local bitrate = config.quality[models.text(quality)]
  if bitrate == nil then bitrate = config.quality.high end
  local attempts = { bitrate }
  for _, lower in ipairs(STREAM_LADDER) do
    if lower < bitrate then attempts[#attempts + 1] = lower end
  end
  for _, br in ipairs(attempts) do
    local body = transport.request("/api/song/enhance/player/url", {
      ids = "[" .. tostring(song_id) .. "]", br = br,
    }, "weapi")
    local rows = models.list(body.data)
    local result = stream_result(rows[1])
    if result == STREAM_LOCKED then error("Gateway code 70", 0) end
    if result ~= nil then return result end
  end
  error("Gateway code 70", 0)
end

local function lyric_text(value)
  if type(value) ~= "table" then return "" end
  return models.text(value.lyric)
end

local function timed(lrc, yrc)
  if string.find(lrc, "[", 1, true) ~= nil and string.find(lrc, ":", 1, true) ~= nil then
    return true
  end
  if string.find(yrc, "[", 1, true) ~= nil and string.find(yrc, ",", 1, true) ~= nil then
    return true
  end
  return false
end

function M.lyrics(id)
  local song_id = models.number(id, 0)
  if song_id <= 0 then error("Gateway code 70", 0) end
  local body = transport.request("/api/song/lyric/v1", {
    id = song_id, cp = false, tv = -1, lv = -1, rv = -1, kv = -1, yv = -1, ytv = -1, yrv = -1,
  }, "eapi")
  local lrc = lyric_text(body.lrc)
  local yrc = lyric_text(body.yrc)
  local translation = lyric_text(body.tlyric)
  local word_translation = lyric_text(body.ytlrc)
  local romanization = lyric_text(body.rlyric)
  local word_romanization = lyric_text(body.yromalrc)
  if body.pureMusic == true or body.nolyric == true then return {} end
  if lrc == "" and yrc == "" then
    local ok, fallback = pcall(transport.request, "/api/song/lyric", {
      id = song_id, tv = -1, lv = -1, rv = -1, kv = -1, _nmclfl = 1,
    }, "eapi")
    if ok then
      if fallback.pureMusic == true or fallback.nolyric == true then return {} end
      lrc = lyric_text(fallback.lrc)
      yrc = lyric_text(fallback.yrc)
      translation = lyric_text(fallback.tlyric)
      word_translation = lyric_text(fallback.ytlrc)
      romanization = lyric_text(fallback.rlyric)
      word_romanization = lyric_text(fallback.yromalrc)
    end
  end
  -- A missing lyric that is not flagged as instrumental stays retryable: the
  -- client caches an empty reply as "pure music" and would never ask again.
  if lrc == "" and yrc == "" then error("Gateway code 70", 0) end
  if translation == "" then translation = word_translation end
  local entry = { lrc = lrc, synced = timed(lrc, yrc), offsetMs = 0 }
  if yrc ~= "" then entry.wordByWord = yrc end
  if translation ~= "" then entry.translation = translation end
  if word_translation ~= "" and word_translation ~= translation then
    entry.wordTranslation = word_translation
  end
  if romanization ~= "" then entry.romanization = romanization end
  if word_romanization ~= "" then entry.wordRomanization = word_romanization end
  return { entry }
end

function M.recommendations(limit)
  local take = page_size(limit, 30)
  local songs = {}
  if store.user ~= nil then
    local ok, body = pcall(transport.request, "/api/v3/discovery/recommend/songs", {}, "weapi")
    if ok then
      local data = type(body.data) == "table" and body.data or {}
      songs = models.map_rows(models.list(data.dailySongs), models.song)
      if #songs == 0 then songs = models.map_rows(models.list(body.recommend), models.song) end
    end
  end
  if #songs == 0 then
    local body = transport.request("/api/personalized/newsong", {
      type = "recommend", limit = take, areaId = 0,
    }, "weapi")
    songs = models.map_rows(models.list(body.result), function(value)
      local song = type(value.song) == "table" and value.song or value
      return models.song(song)
    end)
  end
  return models.window(songs, take, 0)
end

function M.play_stats(limit, offset)
  local user = account.require_user()
  local take = page_size(limit, 100)
  local skip = page_offset(offset)
  local body = transport.request("/api/v1/play/record", {
    uid = models.number(user.id, 0), type = 0,
  }, "weapi")
  -- The host does not trim this reply (it is a record list, not a page), so
  -- this window is exactly `take` rows instead of the paging `take + 1`.
  local rows = models.window(models.list(body.allData), take, skip)
  local records = {}
  for index = 1, #rows do
    local item = rows[index]
    if type(item) == "table" and type(item.song) == "table" then
      records[#records + 1] = {
        song = models.song(item.song),
        playCount = models.number(item.playCount, 0),
      }
    end
  end
  return { records = records }
end

function M.scrobble(id, played_ms, submission)
  account.require_user()
  local song_id = models.number(id, 0)
  if song_id <= 0 then return true end
  local seconds = math.floor(models.number(played_ms, 0) / 1000)
  local event
  if submission == false then
    event = {
      action = "startplay",
      json = { id = song_id, type = "song", mainsite = "1", mainsiteWeb = "1", content = "id=0" },
    }
  else
    if seconds <= 0 then return true end
    event = {
      action = "play",
      json = {
        download = 0, ["end"] = "playend", id = song_id, sourceId = "0", time = seconds,
        type = "song", wifi = 0, source = "list", mainsite = "1", mainsiteWeb = "1",
        content = "id=0",
      },
    }
  end
  -- The play record only counts deposits on the client-log host, through the
  -- desktop-client eapi envelope.
  transport.request("/api/feedback/weblog", { logs = host.json_encode({ event }) }, "eapi", {
    domain = config.client_log_host,
    desktop = true,
  })
  return true
end

return M
