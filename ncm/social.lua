-- Song comments, listen-together rooms and play-activity reports.
--
-- Comments page by offset, which is the surface the desktop client itself
-- uses; each page reports its own `more` flag so the client never has to guess
-- whether another page exists.
--
-- Rooms follow the same shape the mobile client keeps on the wire: the room is
-- created once, kept alive by a heartbeat that carries the playing track, the
-- play state and a version of the room queue, and changed by play commands the
-- other members report. Every response is therefore reduced to one room view
-- (`{roomId,members,songId,playStatus,progress,playlistVersion,playlist,
-- command}`) so the client never has to know which envelope a field arrived in.
local account = require("ncm.account")
local models = require("ncm.models")
local transport = require("ncm.transport")

local M = {}

-- The first value that is not nil and not an empty string. Room responses move
-- the same field between `data`, `room` and `roomInfo` depending on the route,
-- so every read goes through a candidate list instead of one fixed path.
local function pick(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil then
      if type(value) == "table" then return value end
      local text = models.text(value)
      if text ~= "" then return value end
    end
  end
  return nil
end

local function text_of(...)
  local value = pick(...)
  if value == nil then return "" end
  return models.text(value)
end

local function number_of(fallback, ...)
  local value = pick(...)
  if value == nil then return fallback end
  return models.number(value, fallback)
end

local function map_of(value)
  if type(value) == "table" and value[1] == nil then return value end
  return nil
end

-- Flattens `{data=...}`, `{result=...}` and a bare object into the object that
-- actually carries the room.
local function envelope(body)
  if type(body) ~= "table" then return {} end
  local data = map_of(body.data)
  if data ~= nil then return data end
  local result = map_of(body.result)
  if result ~= nil then return result end
  return body
end

function M.comments(id, limit, offset)
  local numeric = models.number(id, 0)
  local thread = numeric > 0 and tostring(numeric) or models.text(id)
  local take = models.number(limit, 20)
  if take < 1 then take = 1 end
  if take > 100 then take = 100 end
  local skip = models.number(offset, 0)
  if skip < 0 then skip = 0 end

  local body = transport.request("/api/v1/resource/comments/R_SO_4_" .. thread, {
    rid = numeric > 0 and numeric or thread,
    limit = take,
    offset = skip,
    beforeTime = 0,
  }, "weapi")
  local data = type(body.data) == "table" and body.data or body
  local hot = models.map_rows(models.list(models.field(data, "hotComments", "hot")), models.comment)
  local latest = models.map_rows(models.list(models.field(data, "comments", "latest")), models.comment)
  local more = data.more
  if more == nil then more = data.hasMore end
  if more == nil then more = #latest >= take end
  return {
    hot = hot,
    latest = latest,
    total = models.number(data.total, 0),
    hasMore = more == true,
  }
end

function M.set_comment_liked(id, comment_id, liked)
  account.require_user()
  local numeric = models.number(id, 0)
  if numeric <= 0 then error("Gateway code 70", 0) end
  local comment = models.number(comment_id, 0)
  if comment <= 0 then error("Gateway code 70", 0) end
  local action = liked == true and "like" or "unlike"
  transport.request("/api/v1/comment/" .. action, {
    threadId = "R_SO_4_" .. tostring(numeric),
    commentId = comment,
  }, "weapi")
  return true
end

-- ---------------------------------------------------------------------------
-- Listen together
-- ---------------------------------------------------------------------------

local function member_rows(value)
  local user = map_of(value.user) or map_of(value.profile) or value
  return {
    userId = text_of(user.userId, user.uid, user.id),
    name = text_of(user.nickname, user.name, user.userName),
    avatarUrl = models.image(pick(user.avatarUrl, user.avatar)),
  }
end

-- Room members live under a different key per route; the list is only used to
-- render avatars, so the first non-empty candidate wins.
local function members_of(data)
  local rows = models.list(pick(
    data.members,
    data.users,
    data.participants,
    map_of(data.room) and data.room.members,
    map_of(data.roomInfo) and data.roomInfo.members
  ))
  if #rows == 0 then return {} end
  return models.map_rows(rows, member_rows)
end

-- One queue row of the room playlist. The client only needs enough to display
-- what the other listeners added, so unknown fields are simply absent.
local function queue_row(value)
  local song = map_of(value.song) or map_of(value.track) or value
  local artists = models.list(pick(song.artists, song.ar))
  local names = {}
  for index = 1, #artists do
    local name = text_of(artists[index].name, artists[index].nickname)
    if name ~= "" then names[#names + 1] = name end
  end
  local album = map_of(song.album) or map_of(song.al)
  return {
    id = text_of(song.id, song.songId),
    name = text_of(song.name, song.songName, song.title),
    artist = table.concat(names, ", "),
    album = album and text_of(album.name) or "",
    coverUrl = models.image(pick(album and album.picUrl, album and album.picUrl, song.coverUrl)),
    durationMs = number_of(0, song.duration, song.dt),
    version = number_of(0, value.version, song.version),
  }
end

local function playlist_of(data)
  local rows = models.list(pick(
    data.playlist,
    data.songs,
    data.queue,
    data.roomPlaylist,
    map_of(data.room) and data.room.playlist
  ))
  if #rows == 0 then return {} end
  return models.map_rows(rows, queue_row)
end

-- The version of the room queue. The service echoes the last array a member
-- reported, so a mismatch is how a client learns that somebody else changed
-- the queue and has to pull it (`syncPlaylist`).
local function playlist_version_of(data)
  local value = pick(
    data.playlistVersion,
    data.playlistVersionList,
    data.version,
    map_of(data.room) and data.room.playlistVersion
  )
  if type(value) == "table" then return host.json_encode(value) end
  return models.text(value)
end

-- The newest play command the room recorded. This is what makes another
-- member's track change visible: the command names the target song, the
-- position it should start at and who asked for it.
local function command_of(data)
  local raw = pick(
    data.playCommand,
    data.commandInfo,
    data.command,
    data.playCommandInfo,
    map_of(data.room) and data.room.playCommand
  )
  local command = raw
  if type(raw) == "string" then
    local ok, decoded = pcall(host.json_decode, raw)
    if ok then command = map_of(decoded) end
  end
  command = map_of(command)
  if command == nil then return nil end
  local type_name = string.upper(models.text(command.commandType))
  if type_name == "" then type_name = string.upper(models.text(command.type)) end
  if type_name == "" then return nil end
  return {
    clientSeq = number_of(0, command.clientSeq, command.seq),
    serverSeq = number_of(0, command.serverSeq),
    commandType = type_name,
    formerSongId = text_of(command.formerSongId),
    targetSongId = text_of(command.targetSongId, command.songId),
    playStatus = string.upper(models.text(command.playStatus)),
    progress = math.max(0, number_of(0, command.progress, command.playedTime)),
    triggerType = string.upper(models.text(command.triggerType)),
    userId = text_of(command.userId, command.uid),
  }
end

-- The room's own view of what is playing, used when the response carries no
-- play command (heartbeats and status checks answer with room state).
local function playback_of(data)
  local room = map_of(data.room) or map_of(data.roomInfo) or {}
  local current = pick(data.currentSongId, data.songId, room.currentSongId, room.songId)
  local status = string.upper(models.text(pick(data.playStatus, room.playStatus)))
  local progress = number_of(0, data.progress, room.progress, data.playedTime)
  if progress < 0 then progress = 0 end
  return {
    songId = models.text(current),
    playStatus = status,
    progress = progress,
  }
end

local function room_view(body)
  local data = envelope(body)
  local room = map_of(data.room) or map_of(data.roomInfo) or {}
  local playback = playback_of(data)
  local room_id = text_of(data.roomId, data.roomid, room.roomId, room.id)
  local inviter = text_of(data.inviterId, data.userId, room.inviterId)
  local result = {
    code = number_of(200, body and body.code),
    members = members_of(data),
    playlist = playlist_of(data),
    playlistVersion = playlist_version_of(data),
    songId = playback.songId,
    playStatus = playback.playStatus,
    progress = playback.progress,
    syncTime = number_of(0, data.syncTime, room.syncTime),
  }
  local command = command_of(data)
  if command ~= nil then result.command = command end
  if room_id ~= "" then result.roomId = room_id end
  if inviter ~= "" then result.inviterId = inviter end
  return result
end

local function room_required(args)
  local room = models.text(models.field(args, "roomId", "roomid"))
  if room == "" or room == "0" then error("Gateway code 400", 0) end
  return room
end

-- Room traffic is eapi with the mobile identity: the service validates the
-- envelope and the `os`/`appver` cookie attributes together, and answers a
-- desktop pair with a rejection on every room route.
local function room_send(path, payload, mode)
  mode = mode or "eapi"
  return room_view(transport.request(path, payload, mode, { mobile = mode == "eapi" }))
end

-- Reads the `playlistVersion` the client reports. A heartbeat must carry the
-- same array the queue was last reported with; re-encoding keeps a malformed
-- value from reaching the service as-is.
local function version_param(args)
  local value = pick(args.playlistVersion, args.version)
  if type(value) == "table" then return host.json_encode(value) end
  local text = models.text(value)
  if text == "" then return "[]" end
  local ok, decoded = pcall(host.json_decode, text)
  if ok and type(decoded) == "table" then return host.json_encode(decoded) end
  return "[]"
end

-- The queue the client wants the room to hold. Rows are reduced to the fields
-- the service understands; a nil queue reports "unchanged" instead of clearing
-- the room, which would drop what the other members added.
local function playlist_param(args)
  local rows = models.list(pick(args.playlist, args.songs))
  if #rows == 0 then return "[]" end
  local out = {}
  for index = 1, #rows do
    local row = rows[index]
    if type(row) ~= "table" then row = { id = row } end
    local song = map_of(row.song) or map_of(row.track) or row
    local id = models.text(pick(song.id, song.songId))
    if id ~= "" then
      out[#out + 1] = {
        id = id,
        type = "song",
        version = number_of(0, row.version, -1),
        expId = "",
        playStatus = "PLAY",
      }
    end
  end
  return host.json_encode(out)
end

function M.listen_together(operation, args)
  args = args or {}
  local name = models.text(operation)
  if name == "create" or name == "createMulti" then
    -- A room created from the playing track is what the APK share sheet does;
    -- without a song id the plain create route is all the service needs.
    local song = models.text(args.songId)
    if name == "createMulti" and song ~= "" and song ~= "0" then
      local payload = {
        type = 0,
        songId = models.number(song, song),
        ["from"] = "CREATE",
        playedTime = math.max(0, number_of(0, args.playedTime)),
        checkToken = "",
      }
      local next_ids = args.nextSongIds
      if type(next_ids) == "table" and #next_ids > 0 then payload.nextSongIds = next_ids end
      return room_send("/api/listen/together/multi/room/create", payload)
    end
    return room_send("/api/listen/together/room/create", { refer = "songplay_more" })
  end
  if name == "status" and models.text(args.roomId) == "" then
    -- No room id: ask the service which room the account is still in, so a
    -- restarted client recovers a session it never left.
    return room_send("/api/listen/together/status/get", {}, "weapi")
  end
  local room = room_required(args)
  if name == "join" then
    return room_send("/api/listen/together/play/invitation/accept", {
      refer = "inbox_invite",
      roomId = room,
      inviterId = args.inviterId,
    })
  elseif name == "status" then
    -- `room/check` answers with members, the playing track and the queue
    -- version, which is what a client needs after a resume or a long poll gap.
    return room_send("/api/listen/together/room/check", { roomId = room })
  elseif name == "leave" then
    return room_send("/api/listen/together/end/v2", { roomId = room })
  elseif name == "heartbeat" then
    local song = models.text(args.songId)
    if song == "" then song = "0" end
    local progress = number_of(0, args.progress)
    if progress < 0 then progress = 0 end
    -- The heartbeat is the room's clock: it refreshes the member's presence,
    -- republishes the queue version and returns the room's own state (members,
    -- playing track, newest command). The client uses that answer instead of
    -- polling `room/check` on every tick.
    return room_send("/api/listen/together/heartbeat", {
      roomId = room,
      songId = song,
      playStatus = string.upper(models.text(args.playStatus)) == "PAUSE" and "PAUSE" or "PLAY",
      progress = progress,
      playlistVersion = version_param(args),
      roomIdList = { room },
    })
  elseif name == "command" then
    local user = account.require_user()
    local command = map_of(args.command) or {}
    command.userId = number_of(0, user.id)
    command.ignoreUserId = { command.userId }
    command.serverSeq = number_of(0, command.serverSeq)
    if command.clientSeq == nil then command.clientSeq = 0 end
    if command.targetSongId ~= nil then command.targetSongId = models.text(command.targetSongId) end
    if command.formerSongId ~= nil then command.formerSongId = models.text(command.formerSongId) end
    local body = transport.request("/api/listen/together/play/command/report", {
      roomId = room,
      commandInfo = host.json_encode(command),
    }, "eapi", { mobile = true })
    local view = room_view(body)
    view.accepted = true
    return view
  elseif name == "syncPlaylist" then
    -- Pulls the room queue. The client calls this when its own version no
    -- longer matches the one the heartbeat echoed.
    return room_send("/api/listen/together/sync/playlist/get", { roomId = room })
  elseif name == "syncList" then
    local body = transport.request("/api/listen/together/sync/list/command/report", {
      roomId = room,
      playlistParam = playlist_param(args),
      playlistVersion = version_param(args),
    }, "eapi", { mobile = true })
    local view = room_view(body)
    view.accepted = true
    return view
  elseif name == "commands" then
    -- The command lane, for a client that wants the newest remote control
    -- without waiting for a heartbeat: the reply is reduced to one command and
    -- the room state around it.
    return room_send("/api/listen/together/play/command/list", {
      roomId = room,
      since = number_of(0, args.since),
      limit = 1,
    })
  end
  error("unsupported room operation", 0)
end

-- ---------------------------------------------------------------------------
-- Play activity
-- ---------------------------------------------------------------------------

-- Reports one play to the client-log weblog the desktop player itself posts.
--
-- This is what makes a play show up as *activity* on the account rather than
-- only in this client's own statistics. The service treats an unattended stream
-- of these as automation, so the caller keeps them rare and only while the user
-- has explicitly opted in.
function M.play_activity(args)
  args = args or {}
  local song = models.number(args.songId, 0)
  if song <= 0 then error("Gateway code 70", 0) end
  account.require_user()
  local played = math.max(0, number_of(0, args.playedMs))
  local duration = math.max(0, number_of(0, args.durationMs))
  local action = models.text(args.action)
  if action == "" then action = "play" end
  local logged = host.json_encode({
    id = song,
    type = "song",
    mainsite = 1,
    mainsiteWeb = 0,
    source = models.text(args.source) ~= "" and models.text(args.source) or "list",
    time = math.floor(played / 1000),
    duration = math.floor(duration / 1000),
    progress = math.floor(played / 1000),
    action = action,
    download = 0,
    toast = false,
    version = models.text(args.version),
  })
  local body = transport.request("/api/feedback/weblog", {
    logs = host.json_encode({
      { action = "play", json = logged, time = host.now() },
    }),
  }, "weapi")
  return {
    code = number_of(200, body and body.code),
    songId = tostring(song),
    action = action,
  }
end

return M
