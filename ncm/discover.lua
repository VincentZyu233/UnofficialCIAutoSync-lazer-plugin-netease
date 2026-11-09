-- Discovery surfaces: the home feed, the toplist shelf and the three radios.
--
-- Every section is independent. A slow or failing endpoint only empties its own
-- shelf; the feed itself fails only when there is nothing left to render.
local config = require("ncm.config")
local models = require("ncm.models")
local store = require("ncm.store")
local transport = require("ncm.transport")
local catalog = require("ncm.catalog")

local M = {}

local function fetch(path, payload)
  local ok, body = pcall(transport.request, path, payload, "weapi")
  if not ok then return nil end
  return body
end

local function rows_of(body, key, fallback_key)
  if type(body) ~= "table" then return {} end
  local rows = models.list(body[key])
  if #rows == 0 and fallback_key ~= nil then rows = models.list(body[fallback_key]) end
  return rows
end

local function playlist_rows(rows)
  local owner = store.user ~= nil and store.user.id or nil
  return models.map_rows(rows, function(value)
    return models.playlist(value, owner)
  end)
end

-- Appends rows whose id is not already present.
local function append_unique(target, rows)
  local seen = {}
  for index = 1, #target do seen[target[index].id] = true end
  for index = 1, #rows do
    local row = rows[index]
    if row ~= nil and row.id ~= "" and not seen[row.id] then
      seen[row.id] = true
      target[#target + 1] = row
    end
  end
  return target
end

local function song_rows(rows, unwrap)
  if not unwrap then return models.map_rows(rows, models.song) end
  return models.map_rows(rows, function(value)
    local song = type(value.song) == "table" and value.song or value
    return models.song(song)
  end)
end

function M.home_feed()
  local feed = {
    quick = {}, daily = {}, recommended = {},
    playlists = {}, albums = {}, editorialPlaylists = {},
  }
  local signed_in = store.user ~= nil

  -- 歌单广场: the widest playlist shelf, also used by the ten-foot layout.
  local top = playlist_rows(rows_of(fetch("/api/playlist/list", {
    cat = "全部", order = "hot", limit = 12, offset = 0, total = true,
  }), "playlists"))
  feed.playlists = models.window(top, 12, 0)

  -- 猜你喜欢: the daily recommendations when signed in, then the editorial
  -- recommendation route as the anonymous source.
  local recommended = {}
  if signed_in then
    append_unique(recommended, playlist_rows(rows_of(
      fetch("/api/v1/discovery/recommend/resource", {}), "recommend")))
  end
  append_unique(recommended, playlist_rows(rows_of(
    fetch("/api/personalized/playlist", { limit = 12, total = true, n = 1000 }), "result")))
  if #recommended == 0 then recommended = top end
  feed.recommended = models.window(recommended, 8, 0)

  -- 推荐新音乐: the mosaic material, and the daily list's stand-in as a guest.
  local quick = song_rows(rows_of(fetch("/api/personalized/newsong", {
    type = "recommend", limit = 20, areaId = 0,
  }), "result"), true)

  local daily = {}
  if signed_in then
    local body = fetch("/api/v3/discovery/recommend/songs", {})
    if type(body) == "table" then
      local data = type(body.data) == "table" and body.data or {}
      daily = song_rows(rows_of(data, "dailySongs", "recommend"), false)
    end
  end
  feed.daily = daily
  if #quick == 0 then quick = models.window(daily, 8, 0) end
  feed.quick = models.window(quick, 20, 0)

  -- 为你推荐的新发行.
  local albums = models.map_rows(rows_of(fetch("/api/album/new", {
    area = "ALL", limit = 18, offset = 0, total = true,
  }), "albums"), models.album)
  feed.albums = models.window(albums, 12, 0)

  -- 编辑精选: the service's editorial account, with the public high-quality
  -- shelf as a fallback so a guest (or a changed account) still sees covers.
  local editorial = {}
  local body = fetch("/api/user/playlist", {
    uid = config.editorial_uid, limit = 24, offset = 0,
  })
  if type(body) == "table" then
    local raw = models.list(body.playlist)
    for index = 1, #raw do
      local value = raw[index]
      if type(value) == "table" and models.number(value.specialType, 0) ~= 5 then
        editorial[#editorial + 1] = models.playlist(value, nil)
      end
    end
  end
  if #editorial == 0 then
    editorial = playlist_rows(rows_of(fetch("/api/playlist/highquality/list", {
      cat = "全部", limit = 12, lasttime = 0, total = true,
    }), "playlists"))
  end
  feed.editorialPlaylists = models.window(editorial, 12, 0)

  if #feed.albums > 0 then
    feed.featured = feed.albums[1]
  elseif #feed.quick > 0 and feed.quick[1].albumId ~= nil then
    -- Keep the hero card when the new-album shelf is unavailable.
    local song = feed.quick[1]
    feed.featured = {
      id = song.albumId,
      title = song.albumName,
      artists = song.artists,
      coverUrl = song.coverUrl,
      songCount = 0,
      description = "",
    }
  end
  if feed.featured ~= nil and feed.featured.id ~= "" then
    local ok, tracks = pcall(catalog.album_songs, feed.featured.id, 8, 0)
    if ok then feed.featuredSongs = models.window(tracks, 8, 0) end
  end

  if #feed.quick == 0 and #feed.daily == 0 and #feed.playlists == 0 and
      #feed.albums == 0 and #feed.recommended == 0 and #feed.editorialPlaylists == 0 then
    error("Gateway code 70", 0)
  end
  return feed
end

function M.charts()
  local body = transport.request("/api/toplist/detail", {}, "weapi")
  local rows = models.list(body.list)
  local out = {}
  for index = 1, #rows do
    if #out >= config.max_charts then break end
    local value = rows[index]
    if type(value) == "table" then
      local mapped = models.playlist(value, nil)
      if mapped.id ~= "" then
        -- The chart card has no issue label; the update cadence is the only
        -- description NetEase publishes for a ranking.
        if mapped.description == "" then
          mapped.description = models.text(value.updateFrequency)
        end
        out[#out + 1] = mapped
      end
    end
  end
  return out
end

local function page_size(limit, fallback)
  local value = models.number(limit, fallback or 30)
  if value < 1 then value = 1 end
  if value > 200 then value = 200 end
  return value
end

-- 私人漫游: the service answers three songs per call, and the client renders a
-- whole station from one answer, so ask a few times and de-duplicate.
local function personal_radio(take)
  local out = {}
  local seen = {}
  local attempts = 0
  while #out < take and attempts < 4 do
    attempts = attempts + 1
    local ok, body = pcall(transport.request, "/api/v1/radio/get", {}, "weapi")
    if not ok then break end
    local added = 0
    local rows = models.list(body.data)
    for index = 1, #rows do
      local song = models.song(rows[index])
      if song.id ~= "" and not seen[song.id] then
        seen[song.id] = true
        out[#out + 1] = song
        added = added + 1
      end
    end
    if added == 0 then break end
  end
  return models.window(out, take, 0)
end

-- 心动模式: seeded with the current song (or the playlist's first track),
-- answered with a personally ordered batch.
local function heart_radio(seed, playlist_id, take)
  local song_id = models.number(seed, 0)
  if song_id <= 0 and playlist_id ~= nil then
    local ok, rows = pcall(catalog.playlist_songs, playlist_id, 1, 0)
    if ok and rows[1] ~= nil then song_id = models.number(rows[1].id, 0) end
  end
  if song_id <= 0 then return {} end
  local body = transport.request("/api/playmode/intelligence/list", {
    songId = song_id,
    type = "fromPlayOne",
    playlistId = playlist_id,
    startMusicId = song_id,
    count = take,
  }, "eapi")
  local rows = models.list(body.data)
  local out = {}
  for index = 1, #rows do
    local item = rows[index]
    if type(item) == "table" then
      local value = item
      if type(item.songInfo) == "table" then
        value = item.songInfo
      elseif type(item.song) == "table" then
        value = item.song
      end
      out[#out + 1] = models.song(value)
    end
  end
  return models.window(out, take, 0)
end

-- 歌手电台: the artist's own top songs interleaved with a few similar artists,
-- which is what keeps a station from repeating one album.
local function artist_radio(seed, take)
  local artist_id = models.number(seed, 0)
  if artist_id <= 0 then return {} end
  local artists = { artist_id }
  local similar = fetch("/api/discovery/simiArtist", { artistid = artist_id })
  local rows = rows_of(similar, "artists")
  for index = 1, #rows do
    if #artists >= 5 then break end
    local value = models.number(rows[index].id, 0)
    if value > 0 and value ~= artist_id then artists[#artists + 1] = value end
  end
  local groups = {}
  for index = 1, #artists do
    local ok, body = pcall(transport.request, "/api/artist/top/song", { id = artists[index] }, "weapi")
    if ok then groups[#groups + 1] = models.map_rows(models.list(body.songs), models.song) end
  end
  local out = {}
  local seen = {}
  local row = 1
  while #out < take and row <= 100 do
    local had_row = false
    for index = 1, #groups do
      local song = groups[index][row]
      if song ~= nil then
        had_row = true
        if song.id ~= "" and not seen[song.id] then
          seen[song.id] = true
          out[#out + 1] = song
        end
      end
    end
    if not had_row then break end
    row = row + 1
  end
  return models.window(out, take, 0)
end

function M.radio(kind, seed, playlist_id, limit)
  local take = page_size(limit, 30)
  local name = models.text(kind)
  if name == "personal" then return personal_radio(take) end
  if name == "heart" then return heart_radio(seed, playlist_id, take) end
  if name == "artist" then return artist_radio(seed, take) end
  return {}
end

return M
