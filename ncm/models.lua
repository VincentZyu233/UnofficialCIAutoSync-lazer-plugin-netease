-- Response to client model mapping.
--
-- Every helper is defensive: NetEase spells the same field differently across
-- endpoints (`ar`/`artists`, `dt`/`duration`, `coverImgUrl`/`picUrl`) and
-- sometimes answers an object where an array was expected. The client model
-- only needs the union, so one normalizer per entity keeps every operation
-- consistent.
local M = {}

local function byte_of(value, index)
  return string.byte(value, index)
end

function M.text(value)
  if value == nil then return "" end
  local kind = type(value)
  if kind == "string" then return value end
  if kind == "number" then
    if math.floor(value) == value then return tostring(math.floor(value)) end
    return tostring(value)
  end
  if kind == "boolean" then
    if value then return "true" end
    return "false"
  end
  return ""
end

function M.number(value, fallback)
  local result = fallback
  if result == nil then result = 0 end
  local kind = type(value)
  if kind == "number" then return math.floor(value) end
  if kind ~= "string" then return result end
  local parsed = tonumber(value)
  if parsed == nil then return result end
  return math.floor(parsed)
end

function M.list(value)
  if type(value) == "table" then return value end
  return {}
end

-- First non-nil field among `...`.
function M.field(value, ...)
  if type(value) ~= "table" then return nil end
  local count = select("#", ...)
  for index = 1, count do
    local key = select(index, ...)
    local item = value[key]
    if item ~= nil then return item end
  end
  return nil
end

-- Byte-boundary trim: the runtime's patterns are regular expressions, so
-- `gsub("^%s+")` would silently do nothing.
function M.trim(value)
  local source = M.text(value)
  local first = 1
  local last = string.len(source)
  while first <= last and byte_of(source, first) <= 32 do first = first + 1 end
  while last >= first and byte_of(source, last) <= 32 do last = last - 1 end
  return string.sub(source, first, last)
end

function M.lower(value)
  return string.lower(M.text(value))
end

-- HTTPS twin of a service URL. Signed audio URLs are returned as http:// by
-- some hosts; the client only plays https.
function M.https(value)
  if type(value) ~= "string" then return nil end
  local url = M.trim(value)
  if url == "" then return nil end
  if string.sub(url, 1, 2) == "//" then return "https:" .. url end
  if string.sub(url, 1, 7) == "http://" then return "https://" .. string.sub(url, 8) end
  return url
end

-- NetEase decorates editorial covers with a transform chain
-- (`?imageView=1&thumbnail=800y800&enlarge=1%7C...&watermark...`). The client
-- asks the CDN for its own rendition, and a client that rebuilds that chain
-- produces a URL the service answers with 400, so hand out the plain image
-- path and let the host size it.
local function public_cover(url)
  local question = string.find(url, "?", 1, true)
  if question == nil then return url end
  local query = string.lower(string.sub(url, question + 1))
  if string.find(query, "imageview=", 1, true) ~= nil or
      string.find(query, "watermark", 1, true) ~= nil then
    return string.sub(url, 1, question - 1)
  end
  return url
end

-- Cover URLs only: unlike M.https this rejects numeric picture ids, which some
-- legacy payloads put in `picUrl`.
function M.image(value)
  if type(value) ~= "string" then return nil end
  local url = M.https(value)
  if url == nil then return nil end
  return public_cover(url)
end

-- Returns `count` rows starting at `offset` (0 based). Callers that need the
-- host's `hasMore` decision pass `limit + 1`: the host trims the page and only
-- reports another page when it received more rows than it asked for.
function M.window(values, count, offset)
  local out = {}
  local source = M.list(values)
  local start = M.number(offset, 0)
  if start < 0 then start = 0 end
  local take = M.number(count, 0)
  if take < 0 then take = 0 end
  local last = start + take
  if last > #source then last = #source end
  for index = start + 1, last do
    out[#out + 1] = source[index]
  end
  return out
end

function M.map_rows(values, mapper)
  local out = {}
  local source = M.list(values)
  for index = 1, #source do
    local mapped = mapper(source[index])
    if mapped ~= nil then out[#out + 1] = mapped end
  end
  return out
end

function M.artist(value)
  if type(value) ~= "table" then value = {} end
  return {
    id = M.text(M.field(value, "id", "userId")),
    name = M.text(value.name),
    coverUrl = M.image(M.field(value, "coverUrl", "cover", "picUrl", "img1v1Url", "avatarUrl")),
    description = M.text(M.field(value, "briefDesc", "description")),
    albumCount = M.number(M.field(value, "albumSize", "albumCount"), 0),
  }
end

local function translated_title(value)
  local names = M.list(M.field(value, "tns", "transNames"))
  local parts = {}
  local seen = {}
  local title = M.text(value.name)
  for index = 1, #names do
    local name = names[index]
    if type(name) == "string" then
      local trimmed = M.trim(name)
      if trimmed ~= "" and trimmed ~= title and not seen[trimmed] then
        seen[trimmed] = true
        parts[#parts + 1] = trimmed
      end
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " / ")
end

function M.song(value)
  if type(value) ~= "table" then value = {} end
  local album = M.field(value, "al", "album")
  if type(album) ~= "table" then album = {} end
  local album_id = M.number(album.id, 0)
  local artists = M.map_rows(M.field(value, "ar", "artists", "singer"), M.artist)
  if #artists == 0 then
    -- Some legacy rows name the performer only.
    local name = M.text(M.field(value, "artistName"))
    if name ~= "" then artists[1] = { id = "", name = name } end
  end
  local cover = M.image(M.field(album, "picUrl", "coverUrl", "blurPicUrl"))
  if cover == nil then cover = M.image(value.coverUrl) end
  return {
    id = M.text(value.id),
    title = M.text(M.field(value, "name", "title")),
    artists = artists,
    albumId = album_id > 0 and tostring(album_id) or nil,
    albumName = M.text(album.name),
    coverUrl = cover,
    durationMs = M.number(M.field(value, "dt", "duration", "durationMs"), 0),
    translatedTitle = translated_title(value),
    starred = value.starred == true,
  }
end

-- Milliseconds to the calendar year, without an `os` library and without
-- assuming leap years: the average Gregorian year is 365.2425 days.
local function year_of(milliseconds)
  local value = M.number(milliseconds, 0)
  if value <= 0 then return nil end
  return math.floor(value / 31556952000) + 1970
end

function M.album(value)
  if type(value) ~= "table" then value = {} end
  local raw = value.artists
  if type(raw) ~= "table" then
    raw = type(value.artist) == "table" and { value.artist } or nil
  end
  local year = M.number(value.year, 0)
  if year <= 0 then year = year_of(value.publishTime) end
  return {
    id = M.text(value.id),
    title = M.text(M.field(value, "name", "title")),
    artists = M.map_rows(raw, M.artist),
    coverUrl = M.image(M.field(value, "picUrl", "blurPicUrl", "coverUrl", "coverImgUrl")),
    year = year,
    publishTime = M.number(value.publishTime, 0),
    songCount = M.number(M.field(value, "size", "trackCount", "songCount"), 0),
    description = M.text(M.field(value, "description", "briefDesc")),
    releaseType = M.text(value.type),
    subType = M.text(value.subType),
  }
end

function M.playlist(value, account_id)
  if type(value) ~= "table" then value = {} end
  local creator = type(value.creator) == "table" and value.creator or {}
  local owner = M.text(M.field(creator, "userId", "id"))
  if owner == "" then owner = M.text(value.userId) end
  local description = M.text(value.description)
  if description == "" then description = M.text(value.copywriter) end
  if description == "" then description = M.text(value.updateFrequency) end
  local privacy = M.text(M.field(value, "privacy"))
  local writable = value.created == true
  if not writable and account_id ~= nil and owner ~= "" and owner == M.text(account_id) then
    writable = true
  end
  return {
    id = M.text(value.id),
    name = M.text(value.name),
    description = description,
    coverUrl = M.image(M.field(value, "coverImgUrl", "picUrl", "coverUrl")),
    songCount = M.number(M.field(value, "trackCount", "trackNumberUpdate", "songCount"), 0),
    owner = owner ~= "" and owner or nil,
    writable = writable,
    isPublic = privacy ~= "10" and privacy ~= "1",
    isFavorites = M.number(value.specialType, 0) == 5,
  }
end

function M.comment(value)
  if type(value) ~= "table" then value = {} end
  local user = type(value.user) == "table" and value.user or {}
  local replies = {}
  local raw = value.beReplied
  if type(raw) ~= "table" then raw = value.replies end
  for index = 1, #M.list(raw) do
    local reply = raw and raw[index]
    if type(reply) == "table" then
      local reply_user = type(reply.user) == "table" and reply.user or {}
      replies[#replies + 1] = {
        author = M.text(M.field(reply, "author", "nickname") or M.field(reply_user, "nickname")),
        content = M.text(reply.content),
      }
    end
  end
  local location = nil
  if type(value.ipLocation) == "table" then location = M.text(value.ipLocation.location) end
  if location == nil or location == "" then location = M.text(value.location) end
  return {
    id = M.text(M.field(value, "commentId", "id")),
    content = M.text(value.content),
    author = M.text(M.field(value, "author", "nickname") or M.field(user, "nickname")),
    authorId = M.text(M.field(value, "authorId", "userId") or M.field(user, "userId")),
    avatarUrl = M.image(M.field(value, "avatarUrl") or M.field(user, "avatarUrl")),
    time = M.number(value.time, 0),
    location = location,
    liked = value.liked == true,
    likedCount = M.number(value.likedCount, 0),
    replies = replies,
  }
end

return M
