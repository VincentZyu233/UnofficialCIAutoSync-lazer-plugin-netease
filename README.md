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

## 变更历史

- **1.3.3**: 首页发现接口在 weapi 返回空响应时回退到公开 web 请求；新碟接口回退到推荐新歌专辑信息。
- **1.3.2**: 心动模式回退到喜欢歌单曲目；编辑精选回退机制。
- **1.3.1**: 封面 URL 去除 query 重写参数，避免 CDN 400。
- **1.3.0**: 一起听接口补齐移动端身份标识与参考路由。
- **1.2.1**: 音频流自动逐级降档，无版权歌曲报 `code = 70` 跳过。
- **1.2.0**: 模块化重构为 `ncm/*`。
