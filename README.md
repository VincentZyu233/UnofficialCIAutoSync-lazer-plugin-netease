# 网易云音乐 Lua Gateway

Lazer 的跨平台音乐平台插件：登录、搜索、歌单、专辑、歌手、歌词、评论、排行榜、电台、一起听与播放统计全部由 Lua 实现，客户端不内置任何网易云协议代码。

## 安装

把 `manifest.json`、`main.lua`、`ncm/` 和 `README.md` 放在 ZIP 根目录打包，然后在客户端「设置 → 扩展 → 插件管理」导入。导入时会先用临时目录启动 Lua VM 校验入口，成功后替换旧版本；失败会保留旧版本。

ZIP 内的路径必须是正斜杠：用系统「发送到 → 压缩(zipped)文件夹」或 7-Zip。PowerShell 5.1 的 `Compress-Archive` 会把条目写成反斜杠，客户端会整包拒收。

插件只使用宿主提供的 `host.http`、`host.crypto`、`host.storage_*`、`host.cookie_*`、`host.url_encode`、`host.random_hex` 与 JSON helpers，不访问文件系统、进程、动态库或平台 API。

## 模块结构

```text
manifest.json        清单与网络/存储权限
main.lua             操作分发表、错误码映射、封面素材规则
ncm/config.lua       固定协议常量（域名、密钥、音质、分页上限、客户端标识）
ncm/store.lua        持久化会话 Cookie 与内存态（用户、缓存注册、失效通知）
ncm/transport.lua    weapi / eapi / plain 三种封包与 Cookie 轮换
ncm/models.lua       响应 → 客户端模型（歌曲、专辑、歌手、歌单、评论、分页窗口）
ncm/account.lua      会话、Cookie/扫码/密码/短信登录、登出、导出 Cookie
ncm/catalog.lua      搜索、专辑、歌手、歌单、喜欢、播放地址、歌词、播放统计、上报
ncm/discover.lua     首页信息流、排行榜、私人漫游/心动模式/歌手电台
ncm/social.lua       歌曲评论、评论点赞、一起听房间
```

`require("ncm.transport")` 对应 ZIP 内的 `ncm/transport.lua`，路径只能用正斜杠。

## 支持的客户端操作

| 能力 | 操作 | 说明 |
| --- | --- | --- |
| 登录 | `session` `loginCookie` `loginPassword` `loginCaptcha` `sendCaptcha` `qrKey` `qrUrl` `qrCheck` `logout` `exportCookie` | 扫码 / 短信 / 密码 / Cookie；登录失败不会覆盖已有的有效会话 |
| 搜索 | `search` | 单曲、专辑、歌手、歌单四类，分页透传 |
| 目录 | `song` `album` `albums` `albumSongs` `artist` `artistSongs` `artistAlbums` | `albums` 为新碟上架，`savedAlbums` 为收藏的专辑 |
| 歌单 | `playlists` `playlist` `playlistSongs` `createPlaylist` `addToPlaylist` `removeFromPlaylist` | 删除按位置整页生效；同一首出现多次时拒绝变更，避免误删 |
| 喜欢 | `favorites` `setFavorite` | 喜欢列表的 id 顺序在内存缓存 5 分钟，写入后立即失效 |
| 播放 | `stream` `lyrics` `scrobble` `playStats` | 音质按 `original/high/medium/low` 取 999000/320000/192000/128000；`stream` 在一次调用内逐级降档，只有全部档位都没有地址时才返回 `code = 70`；逐字歌词与翻译分别返回 |
| 推荐 | `recommendations` `homeFeed` `charts` `radio` | 首页含精选、新碟、每日推荐、猜你喜欢；排行榜最多 8 个榜；三种电台 |
| 社交 | `comments` `setCommentLiked` `listenTogether` | 评论热评 + 最新、点赞；一起听 `create/createMulti/join/status/leave/heartbeat/command`（可选 `syncPlaylist/syncList`） |

分页约定：列表接口向服务端请求（或本地切出）`limit + 1` 行，客户端裁到 `limit` 并用收到的行数判断 `hasMore`。客户端不做裁剪的两处（`playStats`、`comments`）由插件自己保证每页行数和 `hasMore`。

## 错误约定

Lua 抛出的错误在 `main.lua` 里被压成 `{error = {code, httpStatus, reason}}`，绝不包含上游正文、Cookie、带签名的 URL 或请求标识：

- `code = 40` / `httpStatus = 401`：未登录或登录失效（服务端 301/302/401/403）
- `httpStatus = 429`：限流或风控（服务端 406、-460 或 HTTP 429）
- `code = 70`：当前歌曲/歌词/专辑不可用，客户端可换音质或跳过
- 其它：只保留状态码，界面显示通用失败提示

## 凭据与隐私

- 会话 Cookie 是唯一写入插件存储的数据（`host.storage_*`，总量上限 1 MB）。值未变化时不会重复写盘。
- 扫码过程中的临时 Cookie 只存在内存里；登出时先尽力调用服务端注销，再清空本地凭据，离线也能登出。
- 封面规则只声明 `Referer` 与尺寸参数，不带任何 Cookie；音频地址只在单次 `stream` 结果里返回请求头，不进入队列快照。
- 插件不读取也不打印账号名、Cookie、签名 URL；错误只回传状态码。

## 已知限制

- 协议端点沿用客户端此前的内置网关路由表；服务端接口若调整，需要按新路由更新 `ncm/` 中的路径与参数。
- weapi 请求体被 RSA 包裹，开发期的本地 mock 只能覆盖它的路径与可观察行为；真机冒烟测试需自行使用账号。
- 评论分页使用服务端的 offset 语义；若服务端改为纯游标返回，缺失 `more` 时会退化为「整页即还有下一页」。
- 歌词接口未返回逐字歌词时只提供逐行歌词与翻译。

## 变更（1.3.0）

- 一起听请求补上移动端身份：房间端点会同时校验 eapi 信封与 Cookie 里的客户端标识，只有桌面 `os/appver` 会被服务端拒绝。现在这些字段只作用于单次请求头，存储里的会话 Cookie 不受影响。
- `status` 不带 `roomId` 时改走 `status/get`，客户端重启后可以取回仍在的房间；带 `roomId` 时仍走 `room/check`。
- 补齐参考路由：`createMulti`（带当前曲目建房）、`syncPlaylist`、`syncList`；缺少 `roomId` 的房间操作直接报 `400`。
- `command` 的 `targetSongId`/`formerSongId` 统一按字符串上报，与官方客户端的 `commandInfo` 一致。
- `429` 保留为 `httpStatus = 429`，不再退化成没有状态的裸错误码。

## 变更（1.2.1）

- `stream` 在一次调用内按 `original → high → medium → low` 逐级降档：服务端对没有版权的档位返回空地址是常态，交给宿主重试会让一首歌最多排 4 次串行调用，慢网络下还会把排队中的切歌一起拖住。上游命中即返回，全部为空才报 `code = 70`。
- 只有试听权限的歌曲（`freeTrialInfo` 非空）按不可用处理，直接报 `code = 70`，客户端会跳过而不是播 30 秒后自己停下；这类结果不再继续走降档，因为换档位不会解锁版权。

## 变更（1.2.0）

- 拆分为 `ncm/*` 模块；错误码、分页、缓存、Cookie 生命周期统一收口。
- 修复错误码解析（嵌入式 Lua 的 `string.match` 不支持 Lua 模式捕获）、封面素材规则被权限过滤掉、收藏专辑与新碟上架混淆、歌单详情请求整张歌单、邮箱登录截断密码、`Set-Cookie:` 粘贴导致登录失败、歌词缺失被缓存成纯音乐、每个响应都写盘等问题。
- 排行榜限制为 8 个；私人漫游一次返回多批歌曲；专辑补充年份与简介；歌单补充推荐语/更新频率；喜欢列表标记 `starred`。
