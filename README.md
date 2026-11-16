# UnofficialCIAutoSync-lazer-plugin-netease

> [!IMPORTANT]
> **非官方项目声明 / Disclaimer**：
> 本仓库为 **非官方（Unofficial）** 的网易云音乐 Lazer 插件（`lazer.netease`）上游版本跟踪、自动化 PR 同步及测试工具仓库。
> 插件本体代码与设计归原作者 **Illusion / Naominet** 所有。本仓库仅用于提供：
> 1. 完整的历史版本 Commit 与 Tag 溯源；
> 2. 自动化 GitHub Actions PR 更新流水线（类似 Dependabot，绝不强制覆盖）；
> 3. 内置的逐字动态歌词（YRC）与音频流自动化诊断工具箱。

---

## 自动化同步机制 (CI Auto-Sync)

- **轮询周期**：每天**北京时间中午 12:00（UTC 04:00）**，GitHub Actions 自动查询官方市场清单（`https://lazer.naominet.dev/plugin/plugins.json`）。
- **非侵入式 PR 机制**：
  - 当发现上游有新版本（如 `1.3.4`）时，自动校验官方 SHA-256 并拉取包。
  - **白名单文件保护**：严格保护本仓库的 `scripts/` 工具目录、`.github/` 流水线及配置，绝不会被上游覆盖。
  - 自动向本仓库发起 Pull Request，**不会自动合并**。经人工审查与脚本回归测试通过后，方可手动合并。

---

## 测试工具箱 (Scripts)

本仓库根目录自带持久化的测试脚本，可直接用于验证插件或网易云接口状态：

### 1. 逐字动态歌词 (YRC) 测试套件
验证网易云逐字歌词接口可用性，内置了涵盖中文、日文、英文及术力口（Vocaloid）的 10 首代表曲目：
- 《千本桜》（初音ミク）
- 《晴天》（周杰伦）
- 《江南》（林俊杰）
- 《Shape of You》（Ed Sheeran）
- 《夜に駆ける》（YOASOBI）
- 《打上花火》（DAOKO × 米津玄師）
- 《群青》（YOASOBI）
- 《Lemon》（米津玄師）
- 《青花瓷》（周杰伦）
- 《Rolling in the Deep》（Adele）

运行方式：
```bash
node scripts/check_yrc.js
```
脚本将按顺序请求并统计各歌曲的 YRC 逐字歌词返回率、字级时间戳格式与耗时。

### 2. 本地检查上游更新
```bash
node scripts/sync_upstream.js
```

---

<!-- UPSTREAM_README_START -->

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

## 变更（1.3.1）

- 封面 URL 只保留图片路径：编辑精选歌单的封面带 `?imageView=1&…&watermark…` 变换链，客户端会按自己的尺寸重写查询串，重写后的地址会被 CDN 判为 400，导致整排封面空白。插件现在直接给纯图片地址，由客户端决定缩略尺寸；带 `param` 的旧封面与头像不受影响。

## 变更（1.3.2）

- 心动模式沿用客户端的种子策略：优先使用当前歌曲，没有当前歌曲时从喜欢歌单取首曲。
- 心动接口暂时无结果、限流或返回异常时，回退到喜欢歌单曲目，避免心动模式进入空队列。
- 编辑精选继续读取网易云编辑部账号歌单，并在编辑部接口不可用时回退到精品歌单，保证首页仍有可展示内容。

## 变更（1.3.3）

- 首页发现接口在 weapi 返回空响应时回退到公开 web 请求，避免单个接口波动让首页分区消失。
- 新碟接口暂时不可用时从推荐新歌的专辑信息构建新发行分区；编辑精选在编辑部和精品歌单都不可用时回退到热门歌单。

## 变更（1.3.4）

- 对齐 api-enhanced 的短信验证码流程：发送验证码使用 `/api/sms/captcha/sent` 与 weapi 封包，手机登录补齐 `secureCaptcha`，网页请求使用对应的浏览器身份。
- 手机号在发送和登录时统一移除 `+86`、空格与连字符，避免两步请求使用不同的账号格式。
- 登录失败保留原有效会话，并将上游状态交给客户端处理，风控和限流不会再被吞成普通的账号错误。
- 歌词提供服务端返回的逐行与逐字罗马音（`rlyric` / `yromalrc`）；未提供罗马音的歌曲不会自动生成。

短信接口对照：[api-enhanced captcha_sent](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/75bf2e5ca209f4f1b3f822fa65d9f7b67e4b53ec/module/captcha_sent.js)、[login_cellphone](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/75bf2e5ca209f4f1b3f822fa65d9f7b67e4b53ec/module/login_cellphone.js)。

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
