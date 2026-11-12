-- Song comments and listen-together rooms.
--
-- Comments page by offset, which is the surface the desktop client itself
-- uses; each page reports its own `more` flag so the client never has to guess
-- whether another page exists.
local account = require("ncm.account")
local models = require("ncm.models")
local transport = require("ncm.transport")

local M = {}

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

local function members_of(data)
  local candidates = { data.members, data.users, data.participants }
  if type(data.room) == "table" then candidates[#candidates + 1] = data.room.members end
  if type(data.roomInfo) == "table" then candidates[#candidates + 1] = data.roomInfo.members end
  for index = 1, #candidates do
    local rows = candidates[index]
    if type(rows) == "table" and #rows > 0 then
      return models.map_rows(rows, function(value)
        local user = type(value.user) == "table" and value.user or value
        return {
          userId = models.text(models.field(user, "userId", "uid", "id")),
          name = models.text(models.field(user, "nickname", "name", "userName")),
          avatarUrl = models.image(models.field(user, "avatarUrl", "avatar")),
        }
      end)
    end
  end
  return {}
end

local function room_result(body)
  local data = body
  if type(body.data) == "table" then
    data = body.data
  elseif type(body.result) == "table" then
    data = body.result
  end
  local room = type(data.room) == "table" and data.room or {}
  local room_id = models.field(data, "roomId", "roomid")
  if room_id == nil then room_id = models.field(room, "id", "roomId") end
  local inviter = models.field(data, "inviterId", "userId")
  local result = {
    code = models.number(body.code, 200),
    members = members_of(data),
  }
  if room_id ~= nil and models.text(room_id) ~= "" then result.roomId = models.text(room_id) end
  if inviter ~= nil and models.text(inviter) ~= "" then result.inviterId = models.text(inviter) end
  return result
end

local function room_required(args)
  local room = models.text(models.field(args, "roomId", "roomid"))
  if room == "" or room == "0" then error("Gateway code 400", 0) end
  return room
end

local function room_send(path, payload, mode)
  mode = mode or "eapi"
  return room_result(transport.request(path, payload, mode, { mobile = mode == "eapi" }))
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
        playedTime = models.number(args.playedTime, 0),
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
    return room_send("/api/listen/together/room/check", { roomId = room })
  elseif name == "leave" then
    return room_send("/api/listen/together/end/v2", { roomId = room })
  elseif name == "heartbeat" then
    local song = models.text(args.songId)
    if song == "" then song = "0" end
    local progress = models.number(args.progress, 0)
    if progress < 0 then progress = 0 end
    return room_send("/api/listen/together/heartbeat", {
      roomId = room,
      songId = song,
      playStatus = models.text(args.playStatus) == "PAUSE" and "PAUSE" or "PLAY",
      progress = progress,
      playlistVersion = "[]",
    })
  elseif name == "command" then
    local user = account.require_user()
    local command = type(args.command) == "table" and args.command or {}
    command.userId = models.number(user.id, 0)
    command.ignoreUserId = { command.userId }
    command.serverSeq = 0
    if command.targetSongId ~= nil then command.targetSongId = models.text(command.targetSongId) end
    if command.formerSongId ~= nil then command.formerSongId = models.text(command.formerSongId) end
    return room_send("/api/listen/together/play/command/report", {
      roomId = room,
      commandInfo = host.json_encode(command),
    })
  elseif name == "syncPlaylist" then
    return room_send("/api/listen/together/sync/playlist/get", { roomId = room })
  elseif name == "syncList" then
    return room_send("/api/listen/together/sync/list/command/report", {
      roomId = room,
      playlistParam = args.playlistParam or "[]",
    })
  end
  error("unsupported room operation", 0)
end

return M
