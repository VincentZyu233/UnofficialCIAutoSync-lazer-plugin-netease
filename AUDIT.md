# 网易云音乐 Lua 插件审计（1.1.0 → 1.2.0）

审计对象：`D:\lazer_ncm` 的 1.1.0（`main.lua` + `netease.lua`）。审计方式：静态阅读 + 在真实宿主（`LuaPluginRuntime` + `LuaMusicGateway`）里跑离线 mock 回归。**没有向网易云发起任何请求**：mock 只在本机解密/应答，`host.http` 从未连外网。

宿主契约以 `docs/lua-plugins.md`、`lib/gateway/lua_music_gateway.dart`、`lib/plugins/lua_plugin_runtime_io.dart`、`lib/utils/media_requests.dart` 为准；协议路径以客户端此前的内置网关路由表（`lib/gateway/routes.dart` 的历史实现）为准。

## 结论摘要

| # | 严重度 | 问题 | 影响 |
| --- | --- | --- | --- |
| F1 | 阻断 | 错误码解析使用了嵌入式 Lua 不支持的 `string.match` 捕获与 `%` 字符类 | 401/429/70 全部丢失，客户端无法提示重新登录、限流退避或换音质 |
| F2 | 阻断 | `describe.media` 声明的 `*.music.126.net` 不在清单网络权限内 | 封面规则被宿主整条丢弃：没有缩图参数、Referer 与备用主机 |
| F3 | 高 | `albums()` 与 `savedAlbums()` 指向同一个「收藏的专辑」接口 | 新碟上架显示成个人收藏；游客点开即报需要登录 |
| F4 | 高 | 歌单详情固定 `n=100000`，且每翻一页都重新请求 | 大歌单超过宿主 8 MB 响应上限直接失败，小歌单也白传整张列表 |
| F5 | 高 | 邮箱登录把密码截断到 16 字符后再 md5 | 超过 16 位的密码无法登录（手机号登录却是完整密码） |
| F6 | 中 | 分页只请求 `limit` 行，但宿主用「收到行数」判断 `hasMore` | 每个列表末尾多一次空请求；固定长度列表永远显示「还有下一页」 |
| F7 | 中 | 歌词缺失时返回空列表 | 客户端把空结果缓存为「纯音乐」，之后不再重试；网络抖动会永久丢歌词 |
| F8 | 中 | 每个带 `Set-Cookie` 的响应都同步重写 `storage.json` | 浏览一页写入数十次，移动端明显卡顿、闪存磨损 |
| F9 | 中 | `hasMore` 只认 `data.more == true`；评论 offset 无防线 | 服务端不给 `more` 时分页直接结束；负数 offset 未处理 |
| F10 | 中 | 排行榜返回全部约 30 个榜 | 客户端为每个榜串行取 100 首歌，首屏长时间卡住 |
| F11 | 中 | 删除歌单曲目只取前 1000 首且不检查重复 | 超长歌单删错位置；同一首歌重复出现时会多删 |
| F12 | 中 | 粘贴 `Set-Cookie: MUSIC_U=…` 时首个字段被丢弃 | 用户从抓包面板复制 Cookie 会登录失败，且没有可读提示 |
| F13 | 低 | 网络错误等同于「未登录」 | 弱网启动时客户端把账号当成游客，不保留上次账号 |
| F14 | 低 | `logout` 不通知服务端 | 本地清理后旧 token 在服务端仍然有效直到过期 |
| F15 | 低 | 音质类型映射只区分 flac/其它 | `aac`/`m4a` 被标成 `audio/mpeg` |
| F16 | 低 | 单文件 474 行混合封包、模型、业务；无本地回归 | 任何改动都可能静默破坏协议或分页，回归只能依赖真机 |

## 逐条说明

### F1 错误码解析完全失效（阻断）

1.1.0 `main.lua`：

```lua
local code=tonumber(string.match(text,"Gateway code ([%-0-9]+)"))
local status=tonumber(string.match(text,"HTTP ([0-9]+)"))
```

宿主运行时基于 `lua_dardo_plus`，它的 `string` 库把 Lua 模式直接交给 Dart `RegExp`，并且 `string.match` 只返回 `group(0)`（整个匹配，不含捕获组）。实测（同一运行时）：

```text
string.match("abc 301", "(%d+)")                 -> nil        -- %d 不是 Dart 的类
string.match("abc 301", "([0-9]+)")              -> "301"      -- 只因为 group(0) 恰好是数字
string.match("Gateway code 301", "Gateway code ([%-0-9]+)") -> nil
```

于是 `"Gateway code 301"` 永远解析成 `nil`，`main.lua` 把包括登录失效、限流在内的所有失败都压成 `{error={code=nil,httpStatus=nil}}`。客户端据此只能显示通用失败：不会弹「重新登录」，不会对 429 退避，也不会在 `code=70` 时降音质重试。

修复：`main.lua` 用 `string.find(.., true)` 定位标记后按字节扫描符号与数字（`number_after`），不再依赖任何模式。
回归：`failures map to safe status pairs`、`failures never carry upstream text`、`streams … unavailability`、`lyrics … unavailability`。

### F2 封面素材规则被权限过滤（阻断）

`describe` 返回：

```lua
{host="*.music.126.net", headers={Referer=...}, artworkResize={parameter="param",value="{size}y{size}"}, fallbackHosts={...}}
```

但 `manifest.json` 的 `permissions.network` 只有 `music.163.com`、`interfacepc.music.163.com`、`clientlog.music.163.com`。宿主 `MediaRequestRules.register(..., permittedDomains: manifest.domains)` 会丢掉主机不在清单作用域内的规则，于是整条 126.net 规则被静默丢弃：封面不缩图（按原图下载）、没有 Referer、也没有 p2/p3/p4 备用主机。

修复：清单加入 `*.music.126.net`。
回归：`description and media scope` 按插件管理器同样的方式注册规则，断言 `artworkResize`、`referer`、备用主机仍然生效。

### F3 新碟上架与收藏专辑混淆（高）

1.1.0：`M.albums()` 请求 `/api/album/sublist`（账号收藏）；`M.saved_albums()` 又转发给 `M.albums()`。`browseAlbums` 能力因此返回个人收藏；未登录时该接口返回 301，公开货架直接失败。

修复：`albums()` → `/api/album/new`（`area=ALL`）；`saved_albums()` → `/api/album/sublist` 且要求登录、带 `total=true`。
回归：`song, album and album track paging` 同时校验两条路径。

### F4 歌单详情传输整张歌单（高）

1.1.0 每个 `playlist()`/`playlistSongs()` 都请求 `n=100000`。宿主单次响应上限 8 MB，几千首的歌单会直接抛错；即使没超，翻页也反复传输整张歌单的全部曲目元数据，只为渲染 100 行。

修复：只请求 `offset + limit + 1` 首（上限 2000），排序仍用 `trackIds`；详情在内存缓存 120 秒，增删后立即失效；`trackIds` 缺失时回退到响应内的 `tracks`。
回归：137 首歌单两页读完，断言详情请求的 `n ≤ 300` 且只发生一次；`fallback` 用例模拟服务端不返回 `trackIds`。

### F5 邮箱登录截断密码（高）

1.1.0：

```lua
body=request("/api/w/login", {type=0, username=account, password=host.crypto({operation="md5", text=string.sub(password,1,16)}) ...})
```

手机号分支用的是完整密码，邮箱分支只取前 16 个字符。超过 16 位的密码在两个分支结果不一致。

修复：统一对完整密码做 md5；手机号/邮箱由 `phone_of` 判断（去空格、连字符、`+86`）。
回归：`password and SMS routes stay wired` + 源码守卫 `source.no-password-truncation`。

### F6 `hasMore` 恒为真（中）

宿主 `_page()` 用 `list.length >= limit` 判断还有下一页，而插件每页只给 `limit` 行，所以最后一页也会被当成「还有」；对长度恰好是 `limit` 倍数的列表会永远显示「加载更多」。

修复：列表接口统一请求/切出 `limit + 1` 行，由宿主裁到 `limit`。宿主不做裁剪的两处例外：`playStats` 返回恰好 `limit` 行（否则会超出页大小），`comments` 自己给 `hasMore`。
回归：`favorites`、`playlistSongs`、`savedAlbums`、`search`、`artistAlbums` 的末页断言。

### F7 歌词缺失被缓存为纯音乐（中）

1.1.0 在没有 `lrc` 时返回 `{}`。客户端把空歌词视作「纯音乐」并写入歌词缓存，之后不会再请求，网络抖动就会让一首歌永久无歌词。

修复：只有服务端显式 `pureMusic`/`nolyric` 才返回 `{}`；否则先尝试旧版 `/api/song/lyric`，仍然为空则抛 `code=70`（可重试，不会写入「纯音乐」）。
回归：`lyrics keep translation and word timing`（纯音乐、正常、不可用三种）。

### F8 每个响应都写盘（中）

宿主的 `storage_set` 会 `jsonEncode` 整份存储、写临时文件、`flush`、删除旧文件再重命名。1.1.0 的 `request()` 只要响应带 `Set-Cookie` 就写一次，而网易云几乎每个响应都会轮换 `NMTID`/`deviceId`。

修复：`ncm/store.lua` 比较新旧值，只在变化时写入；扫码临时 Cookie 只放内存；其它缓存全部留在内存。
回归：重启后会话仍在（`session survives a runtime restart`），登出后持久化为空（`signing out clears the persisted session`）。

### F9 评论分页（中）

1.1.0：`hasMore = data.more == true or data.hasMore == true`。服务端省略 `more` 时列表只有第一页；`offset` 未做负数保护。另外返回的是 `hasMore`，客户端 `SongCommentPage` 只读 `hasMore`（1.0.x 曾返回 `more`，导致永远无法加载更多）。

修复：`more`/`hasMore` 任一为真即继续，缺失时用「本页是否满页」推断；`limit` 夹在 1..100，`offset` 不为负。
回归：`comments page with hot rows and a more flag`。

### F10 排行榜无上限（中）

`charts()` 返回 `toplist/detail` 的全部条目（约 30 个）。客户端 `providerCharts` 会为每个榜取 100 首歌，而且 Lua 调用是串行的（每次都是「详情 + 歌曲详情」两次请求），首屏要等几十秒。

修复：最多返回 8 个榜（`config.max_charts`），并把 `updateFrequency` 作为榜单描述，客户端不再显示空描述。
回归：`charts are bounded and playable`。

### F11 歌单删除的越界与重复（中）

1.1.0 只读前 1000 首曲目映射位置，且直接按 id 删除。网易云 `op=del` 会删掉该 id 的所有出现，所以当同一首歌在歌单里出现两次时，删一个位置会连带删掉另一行（静默数据丢失）。索引越界时也不会提前失败。

修复：解析完整 id 顺序（缓存或重新拉详情），校验每个位置，目标 id 出现多于一次时在**任何变更前**报错，删除列表去重。
回归：`playlist edits address positions and guard duplicates`（含越界与重复两种失败）。

### F12 粘贴 `Set-Cookie:` 登录失败（中）

宿主的 `host.cookie_compact` 只剥离开头的 `cookie:`。用户从抓包面板复制的是 `Set-Cookie: MUSIC_U=…; Path=/`，第一段名字变成 `Set-Cookie: MUSIC_U` 而被字段名规则过滤（实测只剩后面的 `NMTID`），于是「粘贴了正确的 Cookie 却登录失败」。

修复：按行拆分后逐行剥离 `set-cookie:`/`cookie:` 前缀再交给宿主规范化。
回归：`a pasted Set-Cookie header signs in`。

### F13 网络错误被当成未登录（低）

1.1.0 `M.session()` 在任何异常下都返回 nil，客户端会把 `nil` 采纳为「游客」，弱网启动时就看不到账号。客户端本身已对 `checkSession()` 抛错做了「保留上次账号」的处理。

修复：只有服务端 301/302 才返回 nil；传输层失败继续抛出，让客户端保留账号并重试。
回归：`session survives a runtime restart`、`failures map to safe status pairs`。

### F14 登出不通知服务端（低）

修复：`logout` 先尽力 `POST /api/logout`（失败忽略），再清空本地 Cookie/缓存；离线也能登出。

### F15 音质类型（低）

修复：`flac → audio/flac`、`mp3 → audio/mpeg`、`m4a/aac → audio/mp4`，未知后缀回退 `audio/<suffix>`。

### F16 结构（低）

1.1.0 把封包、Cookie、模型、搜索、歌单、首页、评论、一起听全放在一个文件里，重复的字段兜底逻辑散落各处。

重构为 `ncm/{config,store,transport,models,account,catalog,discover,social}.lua` + 薄 `main.lua`；每层只做一件事，缓存/失效集中在 `store.reset()`，分页与模型各只有一处实现。

## 附带改进（体验对齐）

- 专辑补充 `year`（由 `publishTime` 推导，无 `os` 库）与简介；歌单描述回退到 `copywriter`/`updateFrequency`。
- 喜欢列表标记 `starred`；歌手详情在 eapi 返回空时回退 weapi。
- 私人漫游最多取 4 批（每批 3 首）并去重，客户端不再只拿到 3 首；心动模式支持从歌单首曲取种子。
- 首页：新碟上架、编辑精选（编辑部账号，失败回退精品歌单）、猜你喜欢（每日推荐歌单 + 推荐歌单去重）、每日推荐、推荐新音乐；任一接口失败只清空对应分区。
- 一起听：房间成员兼容 `members/users/participants/room.members/roomInfo.members`，`commandInfo` 自动补 `userId`/`ignoreUserId`/`serverSeq`。
- 播报日志（`/api/feedback/weblog`）改用桌面端身份与 `content=id=0`，和官方播放器的记录口径一致。

## 验证

审计期间用一套本地 mock 回归验证：真实 Lua 运行时 + 真实 `LuaMusicGateway`，eapi 封包逐条解密比对路径、客户端标识与负载，覆盖登录/分页/缓存/错误码/首页降级/一起听等 229 项。源码目录与打包后的 ZIP 各跑一轮，均为 `229 checks, 0 failed`；ZIP 由客户端同一个 `decodePluginPackage` 解码，确认路径与清单校验通过。

该脚本是开发期工具，不随插件包或本仓库提供；导入客户端后另做过真机验证：首页、排行榜（8 个榜 × 100 首）、账号库（1813 首喜欢、38 个歌单）与封面缩图均正常。

## 仍未覆盖的风险

1. **协议漂移**：端点与参数取自客户端此前的内置网关路由表；服务端升级后需要同步更新，离线回归无法发现。
2. **weapi 请求体不可离线解密**：RSA 层只能由服务端解开，所以离线回归对 weapi 只覆盖路径、封包结构与可观察的缓存效果；eapi 请求体则被完整解密校验。
3. **评论游标**：如果服务端彻底改为纯游标（忽略 offset），当前实现会退化为「满页即还有下一页」，可能出现重复页（客户端按评论 id 去重，不会重复显示）。
4. **未做真机播放**：音频地址、Range 请求、音质档位由客户端负责，插件只返回签名 URL 与 Referer。
