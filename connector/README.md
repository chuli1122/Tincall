# Tincall connector

## 组件与接法

连接端负责手机协议、通话状态和消息转发，AI 模型与上下文由所选接法管理。完整自建后端可以直接实现 [手机 HTTP 协议](../docs/backend_api.md)；复用本连接端时，后端只需配置真实的生成和取消接口。

| 组件 | 入口与职责 | 部署后还需配置 |
| --- | --- | --- |
| 通用数据／通话连接端 | `server.mjs` 为 Node 入口；Edge 入口是 `supabase/functions/tincall/index.ts`，共用 `_shared/tincall/` 生产逻辑。支持后端流式／完整回复、MCP、记录、计划和设备路由 | 手机 HTTPS 地址与令牌；按模式配置 MCP 联系人或 HTTP 绑定 |
| Node 存储 | `store.mjs` 选择存储；`sqlite-store.mjs` 实现本地存储，Supabase 实现位于共享目录 | SQLite 数据库及 `.media/` 持久化，或完整的 Supabase 配置 |
| MCP 唤醒适配器 | [`wake-adapter.mjs`](wake-adapter.mjs) 持续订阅事件、读齐输入、运行外部 AI 命令；AI 经专用 MCP 提交完整回复 | 每位联系人的桥接 JSON、能续接会话的 AI 启动命令及 MCP 配置；见 [唤醒桥接入](#唤醒桥接入) |
| Codex HTTP 适配器 | [`codex-backend.mjs`](codex-backend.mjs) 通过本机 Codex CLI 实现 `/generate`、`/cancel`、鉴权 `/health`；当前完整回复、文字输入，不支持图片或 AI 主动拨挂工具 | 已安装并认证的 Codex、私密运行配置、连接端 HTTP 绑定；见 [运行说明](#local-codex-voice-backend) |
| 可选 Node APNs 发送端 | `apns-server.mjs`、`apns-sender.mjs`、`live-activity-push.mjs`，独立处理设备与推送 | Node 24、匹配 App 签名的 APNs 凭据、私密数据库和 HTTPS；见 [推送说明](#apns-sender-devices-and-schedules) |
| 发行者推送 Worker | [`cloudflare/`](../cloudflare) 提供另一种发送端实现 | 发行者部署、对应服务凭据与设备绑定；见 [Worker 说明](../cloudflare/README.md) |

本地安装器／Docker 默认只启动通用连接端，以及选择启用的隧道；不会自动运行唤醒适配器、Codex 适配器或 APNs 发送端。Supabase 一键部署也不安装本机进程或提供 AI 模型。两个适配器用途不同，不要求同时部署。

后端 HTTP 生成支持 NDJSON 增量流与完整 JSON；MCP 目前提交完整消息。普通 MCP 回复带回一个 8 字符 `call` 标记；唤醒桥由适配器隐藏绑定，AI 只传 `text`。手机到连接端的通话事件使用长轮询，来电／唤醒通知使用 SSE，这些传输方式不能直接用来判断模型回复是否流式。

使用说明按部署方式见下文；当前代码契约见 [后端接口](../docs/backend_api.md) 和 [MCP 工具](../docs/mcp.md)。每个部署需分别验证连接、真实生成、取消、手机播放与可选推送。

## 前台来电订阅（2026-10-20）

手机通过 `GET /calls/incoming/events`（手机令牌、`Accept: text/event-stream`）接收来电状态，不再每两秒查询当前通话。连接建立时读取一次当前状态，随后仅由状态变更推送；心跳不查询数据库。Supabase 使用私有 Realtime 广播，SQLite 使用本服务进程内的提交通知。保留系统来电界面，后台／锁屏仍需要推送。

Supabase 一键部署／更新已打包 `202610200002_tincall_incoming_events.sql` 和对应函数源码；首次部署自动安装，已有服务由使用者在 App「部署或更新服务」中更新，无需另外执行该项 SQL 或配置 Realtime。流格式见 [接口说明](../docs/backend_api.md)。

## 图片消息（2026-10-18）

手机可在 `POST /calls/:id/input` 增加可选字段：

```json
{"request_id":"UUID","message_id":"UUID","epoch":0,"text":"","images":[{"id":"图片 UUID","mime_type":"image/jpeg","data_base64":"完整标准 Base64"}]}
```

每条最多四张、每张解码后最多 5 MiB；支持 JPEG／PNG，HEIC 无转换能力时明确拒绝。Base64 不带 data URI 前缀，不换行。图片 UUID 及请求内容在重试时保持不变。有图可省略 `text` 或留空，无图仍按原文字协议处理。含图输入／备份 JSON 最大 28 MiB，无图仍为 8 MiB；手机负责 JPEG 长边不超过 1568、质量 0.8 的预处理。

图片复用私有媒体存储，消息只保存 `{id,mime_type,bytes}` 引用。MCP 的读取／等待及回复后等待工具会返回标准 `{type:"image",data:"Base64",mimeType:"image/jpeg"}` content，原生图片块紧随所属消息的 XML 文字块。后端生成请求在有图的 `messages[]` 项上增加 `images:[{mime_type,data_base64}]`；选择内联数据以避免签名链接过期和额外媒体鉴权，历史消息的图片也会转发。

备份 `record.messages[]` 或 `record.call.messages[]` 同样支持内联图片和已保存引用。`/delete` 会一并清理图片及同 UUID 通话图片引用；App 的清空云端备份使用 `/delete-backup`，保留仍被通话引用的图片。手机仍须上传真实文件并按引用下载恢复；仅有本机路径不能构成图片备份。

Supabase 图片支持已纳入 [正式迁移](../supabase/migrations/202610210003_tincall_message_images.sql)，新版 App 的“部署或更新服务”和 CLI `db push` 都会自动执行，无需另开 SQL 编辑器。曾按旧说明手动执行图片 SQL 的服务也可直接升级，保留已有图片和录音。SQLite 自动增量升级。完整字段、错误码、失败清理及数据库升级见 [图片消息契约](../docs/message_images.md)。

This is the user-hosted call connector, MCP endpoint, generation bridge, cloud backup API and APNs sender. The iPhone sends text to the connector, the connector invokes the configured platform's real generation entry, and durable reply events return to the iPhone. Audio capture, STT and TTS remain on the phone. There is no publisher chat service.

The data service supports Node 22.5+ with working built-in SQLite (Node 24 recommended), using either local SQLite or Supabase storage. The Supabase Edge Function uses Supabase storage and the migrations. Push is a separate service: choose the Node HTTP/2 sender or the publisher's Cloudflare Worker as documented below. The connector's Node programs use built-in modules; external AI executables and tunnel/deployment tools are separate prerequisites.

## 部署到自己的电脑或服务器

**推荐直接安装 [Node.js LTS](https://nodejs.org/)**，无需 Docker，也无需安装 npm 依赖。最低支持 Node 22.5，且必须有可用的内置 `node:sqlite`。取得本仓库源码后，macOS／Linux 在仓库根目录运行：

```sh
sh connector/install-local.sh
```

Windows 可直接使用 PowerShell 5.1 或 PowerShell 7，无需 WSL。在仓库根目录复制执行以下命令即可；`Bypass` 只作用于这一次 PowerShell 进程，不修改系统执行策略：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1
```

### 手机和 AI 平台怎么连进来

Tincall 和 AI 平台都只接受 HTTPS 地址。脚本启动后显示的 `http://127.0.0.1:8787` 只有本机能访问，请按自己的情况选一种方式换成 HTTPS 地址，再把它和手机访问令牌填入 Tincall「连接已有服务」页：

| 你的情况 | 用什么 | 手机能连 | AI 平台能连 |
|---|---|---|---|
| 家用电脑，没有别的工具 | 安装 cloudflared 后加 `--tunnel`（Windows 为 `-Tunnel`） | 能 | 能 |
| 电脑和手机都装了 Tailscale，只自己用 | 在电脑上运行 `tailscale serve --bg 8787` | 能，手机需开着 Tailscale | 不能 |
| 装了 Tailscale，还要让 AI 平台连 | 在电脑上运行 `tailscale funnel --bg 8787` | 能 | 能 |
| 已有 ngrok 账号 | 登录后运行 `ngrok http 8787`，显示的 https 地址即可填入；需注册并配置 authtoken | 能 | 能 |
| 有公网地址和域名的服务器 | 用 Caddy 等反向代理转到 8787，自动申请证书 | 能 | 能 |

使用 Tailscale 时，先在 Tailscale 管理后台开启 MagicDNS 和 HTTPS 证书；Funnel 首次使用会提示到后台授权。命令显示的 `https://设备名.xxx.ts.net` 就是要填的地址，不需要再加隧道参数。较旧版本的 Tailscale 不支持上述写法，请先升级。


Windows 参数对应为 `-Node`、`-Docker`、`-Tunnel`、`-Stop`，可组合 `-Node -Tunnel` 或 `-Docker -Tunnel`。使用 PowerShell 7 时也可将命令开头的 `powershell` 改成 `pwsh`。例如没有公网地址时运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1 -Tunnel
```

Windows 的私密配置在 `%LOCALAPPDATA%\Tincall\local.env`，目录和 env 的 ACL 仅允许当前用户访问；随机令牌、所有者 UUID 格式及复用规则与 sh 版一致，使用 Windows 内置加密随机源，不需要 OpenSSL。Node 数据在该目录的 `data\`，日志为 `connector.stdout.log`／`connector.stderr.log` 和可选的 `tunnel.stdout.log`／`tunnel.stderr.log`，每次启动重新写入日志。

Windows Node 使用任务计划程序，以当前用户普通权限后台运行，不需要管理员权限、NSSM 或第三方服务工具。任务在当前用户登录时启动，失败后每分钟重试、最多 999 次，不受默认三天运行时限影响。任务名称为 `Tincall-connector-用户SID` 和可选的 `Tincall-tunnel-用户SID`；保持用户登录，注销后不会继续提供服务。保留源码和 Node 可执行文件，移动目录或升级 Node 后重新运行安装命令。`-Stop` 停止本安装的进程及子进程，并删除这两个计划任务，保留令牌、数据库和媒体：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1 -Stop
```

首次优先使用可用的 Node；没有合适的 Node 时才选择 Docker。两者都不可用时，脚本提示安装 Node 后退出，不会替使用者安装任何软件。sh 版可用 `--node`／`--docker`，Windows 版可用 `-Node`／`-Docker` 强制选择。脚本实际探测 SQLite 模块：Node 22.5–22.12 及早期 Node 23 自动加 `--experimental-sqlite`；22.13、23.4 及后续版本无需此参数。版本规则见 [Node 22 SQLite 文档](https://nodejs.org/docs/latest-v22.x/api/sqlite.html) 和 [Node 23.4 发布说明](https://nodejs.org/en/blog/release/v23.4.0)。建议使用当前 LTS；本机离线业务测试使用 Node 24。

两种方式共用随机手机令牌、后台任务令牌和稳定的所有者 UUID，macOS／Linux 保存在 Git 忽略的 `connector/.local/local.env`（文件权限 600，目录权限 700），Windows 则使用上文的用户私密目录。重复运行复用原文件，不自动轮换令牌。`TINCALL_CLIENTS` 中的手机令牌与 `TINCALL_LOCAL_PHONE_TOKEN` 是同一值，不要单独修改其中一项。默认使用 SQLite，无需 Supabase 账号。

macOS／Linux 的 Node 数据库、WAL／SHM 文件及媒体位于 `connector/.local/data/`，日志位于同一私密目录中的 `connector.log` 和 `tunnel.log`。后台运行与自启方式如下：

- macOS：使用 `~/Library/LaunchAgents/com.tincall.connector.plist`，需要隧道时另建 `com.tincall.tunnel.plist`；当前启动，以后在用户登录时自动启动，不能在尚未登录时运行。
- Linux：有可用的 systemd 用户管理器时，使用 `~/.config/systemd/user/tincall-connector.service` 及可选的 `tincall-tunnel.service`。脚本尝试启用当前用户的 linger，使服务在开机后无需登录即可启动；如系统不允许，会提示管理员执行 `loginctl enable-linger 用户名`，未开启时仅登录后自启。
- 没有可用的上述管理器时：使用 nohup 后台运行，重启后必须重新执行安装命令。停止时只根据 pid 记录和匹配的启动命令终止本安装的进程。

安装后保留源码目录和所用的 Node 可执行文件，勿移动或删除它们。使用 nvm 等版本管理器升级 Node 后，请重新运行安装命令，以更新自启配置中的绝对路径。Windows 使用上文的原生 PowerShell 脚本和计划任务，无需 Linux 环境。

**Docker 是可选方式**，适合 NAS 或已经使用 Docker 的服务器，需要 Docker Engine／Docker Desktop 和 Compose 插件：

```sh
sh connector/install-local.sh --docker
```

Docker 使用官方 Node 24 精简镜像，以非 root 用户运行，宿主机无需 Node；sh 版首次生成令牌需有 OpenSSL，Windows 版使用系统内置加密随机源。构建只发送必需源码，数据保存在命名卷 `tincall-local-data`。Docker 启动时需要联网下载镜像；Docker 本身也需配置开机启动。停止服务不会删除命名卷。不要执行 `docker compose down -v` 或手动删除该卷。

两种方式默认仅在本机 `http://127.0.0.1:8787` 提供服务。端口可在私密 env 中修改 `TINCALL_LOCAL_PORT` 后重新运行。手机不能直接使用此地址；有公网地址和域名的服务器需配置 HTTPS 反向代理，转发到该本机地址，代理空闲超时需长于联系人配置的 MCP 等待时长，并留出返回结果的余量。

**没有公网地址的家用电脑**可启用 Cloudflare 快速隧道：

```sh
sh connector/install-local.sh --tunnel
# 强制使用 Docker 时：sh connector/install-local.sh --docker --tunnel
```

Node 方式需要本机已有 `cloudflared`（Windows 为 PATH 中的 `cloudflared.exe`）；未安装时会提示 [官方安装地址](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/) 并跳过隧道，连接端仍在本机运行，不替使用者安装。Docker 方式使用可选的 cloudflared 容器，默认不启动。两者都从本次隧道日志中提取 `https://…trycloudflare.com` 地址。快速隧道无需 Cloudflare 账号，但网络须能访问 Cloudflare，服务会经 Cloudflare 转发。

安装 cloudflared：Windows 在 PowerShell 中运行 `winget install --id Cloudflare.cloudflared`；macOS 运行 `brew install cloudflared`；Linux 请参照官方下载页。安装后重新运行脚本并加上隧道参数。

将显示的 **HTTPS 基础地址**和**手机访问令牌**填入 Tincall「连接已有服务」页。MCP 地址为基础地址加 `/mcp`，联系人的 MCP 专用令牌仍由 App 保存联系人时登记，不能用手机令牌代替。快速隧道地址每次重启或更新都可能变化，变化后须更新 App 和 AI 平台的 MCP 地址；长期使用建议绑定自己的 Cloudflare 隧道，或使用有公网地址的服务器和 HTTPS 反向代理。Node 隧道重启后的新地址可在私密 `tunnel.log` 中查看；Windows 查看 `tunnel.stderr.log`／`tunnel.stdout.log`。

取得新源码后，重复执行原安装命令即更新并重启，保留令牌和数据；需要隧道就继续加 `--tunnel`（Windows 为 `-Tunnel`），不加会关闭原快速隧道。重复运行沿用已保存的 Node／Docker 方式（也会识别上一版 Docker 安装），不会因安装了 Node 就自动切换数据库。两种存储位置不同，强制切换会拒绝执行；如确需迁移，应先停止服务，手动迁移完整 SQLite 数据、WAL／SHM 和媒体后再调整 `connector/.local/backend`（Windows 为 `%LOCALAPPDATA%\Tincall\backend`），不要用切换方式代替更新。

```sh
sh connector/install-local.sh --stop
```

`--stop` 按已记录的方式停止连接端和隧道，移除 Node 自启配置，并保留令牌和数据；Windows 对应参数为 `-Stop`，会删除计划任务。停止时无需重新提供 `--node`／`--docker`。再次运行即可恢复。备份前先停止服务及其他使用数据库的进程，再备份完整数据目录／命名卷和私密 env 文件。不要分享终端显示的令牌、私密配置或日志。

**电脑必须一直开机且不能休眠。** 此安装提供连接端、备份、任务及 MCP 服务；平台真实的生成／取消入口、APNs 发送服务、Apple 凭据和设备绑定仍需分别配置。

## Deploy on your own computer or server

Install [Node.js LTS](https://nodejs.org/) with a working built-in `node:sqlite` (Node 22.5 or later; Node 24 recommended). Docker and npm dependencies are not required. From the repository root:

```sh
# macOS / Linux
sh connector/install-local.sh
```

```powershell
# Windows, no WSL required
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1
```

The installer creates or reuses the private phone token, worker token and owner UUID, then runs the connector in the background on `http://127.0.0.1:8787`. It does not install Node, Docker or cloudflared for you. Add `--docker` (Windows: `-Docker`) to use Docker instead. `--stop` (Windows: `-Stop`) stops the service and keeps tokens and data. After pulling new source, run the same command again to update.

### Reach the connector from your phone and AI platform

Tincall and AI platforms accept HTTPS addresses only. Choose one option below, then enter the HTTPS base URL and the phone token under **Connect to an existing service** in Tincall. The MCP URL is the base URL followed by `/mcp`.

| Your setup | What to use | Phone | AI platform |
|---|---|---|---|
| Home computer, no other tools | Install cloudflared and add `--tunnel` (Windows: `-Tunnel`) | Yes | Yes |
| Tailscale on computer and phone, personal use only | Run `tailscale serve --bg 8787` on the computer | Yes, with Tailscale on | No |
| Tailscale, and the AI platform also needs access | Run `tailscale funnel --bg 8787` on the computer | Yes | Yes |
| An ngrok account | Configure your authtoken, then run `ngrok http 8787` | Yes | Yes |
| A server with a public address and domain | A reverse proxy such as Caddy forwarding to port 8787 | Yes | Yes |

With Tailscale, enable MagicDNS and HTTPS certificates in the admin console first. Reverse proxies must allow idle requests longer than the contact's configured MCP wait, with room to return the result. Quick tunnel URLs can change after a restart; update the app and the MCP settings when they do. The computer must stay on and awake.

Background service, log location and Docker volume details are in the Chinese section above.

## Choose Node storage (no Supabase account required)

Node 24 is recommended (verified with v24.15.0). The installer also accepts Node 22.5+ after a SQLite availability probe; older versions need `--experimental-sqlite` as described above. SQLite uses the built-in `node:sqlite`, so neither npm packages nor native addons are needed. The connector uses the same production HTTP/MCP service with an injected SQLite store; the Supabase service and migrations are unchanged.

| Configuration | Selected storage |
| --- | --- |
| No Supabase URL/key configured; `TINCALL_STORAGE` empty | SQLite (default) |
| Supabase URL or either key configured; `TINCALL_STORAGE` empty | Supabase; all three credentials are required |
| `TINCALL_STORAGE=sqlite` | SQLite, even if Supabase credentials are present |
| `TINCALL_STORAGE=supabase` | Supabase; all three credentials are required |

An incomplete Supabase configuration fails startup rather than silently switching databases. Switching storage does not copy existing data between backends.

For a standalone server:

1. Copy `connector/env.example` to a private file outside the checkout. Leave the three `SUPABASE_*` values blank. Optionally set `TINCALL_STORAGE=sqlite`.
2. Set `TINCALL_CLIENTS` to a JSON array containing a long private bearer token and a stable owner UUID, for example `[{"token":"REPLACE_WITH_PRIVATE_RANDOM_PHONE_TOKEN","owner_id":"10000000-0000-4000-8000-000000000001"}]`. Choose your own UUID and token; no Auth user registration is involved. Different owner UUIDs isolate data. Use that same owner UUID in static generation bindings. Dynamically enrolled MCP role credentials are stored locally and survive restarts.
3. Optionally set `TINCALL_SQLITE_PATH=/absolute/persistent/path/tincall.sqlite`. The default is `connector/data/tincall.sqlite`, located beside the server source regardless of the working directory. Custom relative paths resolve against the process working directory. The directory is created automatically, and new databases/files have private permissions.
4. Run `node --env-file=/absolute/path/to/private-secrets.env connector/server.mjs`. It listens on `127.0.0.1:8787`; configure your TLS reverse proxy and use its HTTPS base URL in the app (append `/mcp` for MCP). The phone uses the configured client bearer token.

SQLite automatically creates all connector tables on first startup and adds missing schema columns on later startups, retaining existing rows. Calls, messages, events, receipts, generation/push jobs, devices, schedules, backups and MCP roles are persisted. Owner commands, claims and worker transitions use `BEGIN IMMEDIATE` transactions with a busy timeout; voice instructions use one conditional `UPDATE ... RETURNING`, so concurrent processes can claim them only once per call. A prompt retry does not reset that marker.

Media is streamed into `<database-path>.media/` with metadata in SQLite, preserving immutable owner/record/asset paths and bounded deletion retries. Persist **both** the database and media directory. SQLite uses WAL: stop the connector and other processes using the database before copying the database, any remaining `-wal`/`-shm` sidecars, and media directory together. Keep these files and the private env file outside Git and off ephemeral container storage. Use a local filesystem that supports SQLite locking; this is one server's file storage.

The Node process runs the durable worker every 15 seconds, replacing hosted Cron for this deployment. Daily scheduling uses Node's ICU timezone data, including DST gaps/folds; keep the server's timezone data current. Background ringing still requires the separate APNs sender, Apple credentials and a registered phone; storage selection does not change that setup.

## Deploy to your Supabase project

图片消息所需的数据库迁移随以下部署流程自动应用，然后更新函数。录音与图片共用的私有存储桶和访问权限由基础迁移创建；部署本身不会上传记录或自动启用录音备份。

For first-time backup setup, follow the app's Settings → 云端同步与备份 → 开始配置 wizard, or run `sh connector/setup-cloud.sh PROJECT_REF AUTH_USER_UUID` from this checkout after installing and signing into the official Supabase CLI. The installer generates private phone/worker credentials outside the checkout, calls the deployment script, and produces `tincall-cloud.json` for import in the app. It refuses a first install over existing Tincall secrets; retries with the same private directory preserve credentials. No records are uploaded by installation. See the [Chinese setup guide](../docs/cloud_setup.md). The steps below cover manual setup, existing configurations and optional calling features.

1. Create or select your own Supabase project and an Auth user. Decide your region and plan. Sign into the official Supabase CLI locally.
2. Copy `connector/env.example` to a private file outside the checkout. Configure credentials and bindings. Keep the service-role key, platform token, worker token and APNs key on the server.
3. From the repository root, run `sh connector/deploy.sh PROJECT_REF /absolute/path/to/private-secrets.env`. It links the project, applies the migrations, sets secrets and deploys the `tincall` function. It does not create an organization, select a paid plan, change Apple accounts or upload an App Store build.
4. In that project's **Vault**, create `tincall_function_base` with `https://PROJECT.supabase.co/functions/v1/tincall` and `tincall_worker_token` with the same private value as `TINCALL_WORKER_TOKEN`. The installed Cron job calls the short worker every minute. Without both Vault entries it makes no request.
5. Deploy the APNs sender described below if background incoming calls are needed, then register the phone's actual PushKit token through `/devices`.

The App's base URL is `https://PROJECT.supabase.co/functions/v1/tincall`; the MCP URL is the same base plus `/mcp`. For Supabase storage, their bearer credential is either a Supabase Auth access token or an explicitly configured `TINCALL_CLIENTS` token bound to an existing Auth user. Supabase sessions must be refreshed by their client. A service-role key must never be used as the App/MCP token. Phone access uses the existing bearer credential. ChatGPT MCP additionally supports OAuth authorization code + S256 PKCE with public-client dynamic registration; approval in the authenticated Tincall app grants access to one registered MCP contact only.

`TINCALL_CLIENTS` and `TINCALL_BINDINGS` are JSON arrays; keep each complete array on one env-file line. Example shape, using replacement values:

```json
[
  {"token":"REPLACE_WITH_PRIVATE_RANDOM_PHONE_TOKEN","owner_id":"AUTH_USER_UUID"},
  {"token":"REPLACE_WITH_DIFFERENT_PLATFORM_TOKEN","owner_id":"AUTH_USER_UUID","contact_id":"platform-role-17"}
]
```

```json
[
  {"owner_id":"AUTH_USER_UUID","contact_id":"platform-role-17","display_name":"Example role","mode":"http",
   "generation_url":"https://YOUR_PLATFORM/tincall/generate",
   "cancel_url":"https://YOUR_PLATFORM/tincall/cancel","token":"YOUR_PLATFORM_TOKEN"}
]
```

The role-scoped token can operate only its bound contact and cannot access backups or device registration. HTTP bindings require both generation and cancellation endpoints on the same origin; remote endpoints require HTTPS. These endpoints must actually start and cancel the target platform's generation; a save-message-only endpoint does not implement this contract. Missing configuration returns `generation_not_configured`. There is no fake or fallback model reply.

An optional `display_name` labels each binding in the app's connection configuration. `GET /capabilities` returns only the authenticated owner's bindings (or the one allowed by a role-scoped token), including this name when configured. The app reads this list while configuring a connection, selects the sole available target automatically, or lets the user choose among several. It saves the target with that connection; the contact editor only selects the complete saved configuration and never asks for a contact ID. Existing connectors without names remain readable by their binding keys.

For a private generation service on the same host, a binding may explicitly set `allow_local_http:true`. This is a deployment option, not a test-only mode: HTTP is then allowed only for the exact hostnames `127.0.0.1`, `localhost` or IPv6 `::1` (written as `[::1]` in a URL), with generation and cancellation on the same origin. Other IPs, LAN addresses and remote hostnames still require HTTPS. With the Node connector, loopback reaches a service in that process's host/network namespace; inside a container it reaches that container. In a Supabase Edge Function, loopback refers to the Edge runtime's own network namespace, not the deployer's computer or an external platform. Use a reachable HTTPS endpoint for a remotely hosted Edge deployment. This option does not relax the phone-facing connection or the APNs sender's HTTPS requirements.

An explicit `{"owner_id":"...","contact_id":"...","mode":"tools"}` binding supports an already-running MCP role polling for input and returning replies. `/capabilities` reports `wake_supported:false` for this mode. Installing MCP tools alone cannot wake an idle platform. A phone-origin MCP call creates an opening reply target; an ordinary platform must already be running to read it. The optional event-driven wake bridge below advertises its separate `wake_bridge:"sse"` capability and starts AI tasks through the platform integration. HTTP generation bindings still start on submitted input.

To run the same connector locally against a configured Supabase project:

```sh
node --env-file=/absolute/path/to/private-secrets.env connector/server.mjs
```

It listens on `127.0.0.1:8787`. A deployed Node service requires your own TLS reverse proxy. `supabase start` plus the migrations/Edge serve workflow can be used for a complete local Supabase stack when the official CLI is installed. The automated tests below use an isolated PostgreSQL container; they do not claim to be a hosted Supabase deployment test.

## Phone HTTP contract

Authenticated `GET /capabilities` includes `server_version`, the deployment revision from `supabase/functions/_shared/tincall/server-version.json`. It is separate from the existing protocol `version: 1`. When a service lacks this field or reports a revision older than the App's bundled deployment, Settings → Tincall 云端 prompts the user to update the service; connection or authorization failures are reported separately.

Increment the JSON revision when a new App release requires updated server behavior. Supabase uploads, the App's bundled deployment and the Node Docker image all include this same file. Updating the App does not deploy the service automatically.

### Local Codex voice backend

`codex-backend.mjs` adapts a locally installed, authenticated Codex CLI to the HTTP generation/cancellation contract. Run it with `node connector/codex-backend.mjs /absolute/path/to/private-config.json`. The private JSON contains `command` (the Codex executable), `args` (options after `codex exec`), `cwd` (an empty working directory), `token` (a separate adapter credential), and optional `port` (default 8788). Keep this file outside version control. The adapter listens only on loopback; expose the **connector**, not this process, through your HTTPS entry point.

Use `--json`, `--ephemeral`, `--skip-git-repo-check`, `--sandbox read-only`, `--ignore-user-config` and `--ignore-rules` in `args`; explicitly supply the selected model/provider configuration and disable shell tools, apps, memories and skill discovery for a conversation-only setup. Confirm these options with the installed CLI version. Credentials remain with the existing Codex authentication provider. Keep private runtime configuration outside version control, use an empty working directory, and do not resume desktop chats. See [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive).

Bind `generation_url` to `http://127.0.0.1:8788/generate`, `cancel_url` to `http://127.0.0.1:8788/cancel`, and set `allow_local_http:true` plus the same private adapter token. Each generation receives the current call's messages, interruption annotations and `expression_prompt`; it returns the real final Codex answer as JSON. This adapter currently supports transcribed speech and text, rejects images explicitly, and does not provide token-by-token streaming. Identical job retries reuse the result. Cancellation, client disconnect and timeout terminate the matching Codex process group; cancellation is acknowledged after process exit. Errors return stable codes, without upstream stderr, conversation text or credentials.

Phone and MCP requests require `Authorization: Bearer ...`; public OAuth discovery, registration, authorization, token exchange and revocation use the OAuth contract below. POST bodies use `Content-Type: application/json`. Errors contain only `{ "error": { "code": "stable_code", "message": "stable_code" } }`; upstream bodies, credential URLs and secrets are not reflected.

All mutation `request_id` values are UUIDs in one owner-wide namespace. Retry with the **same ID and identical body**, including the original epoch; changing the body produces `idempotency_conflict`. Do not reuse the call UUID as every operation's request UUID.

| Method and path | Body or result |
| --- | --- |
| `GET /capabilities` | Version, poll/append-only support, configured contact bindings, `push_configured`; unscoped users also receive `owner_id` |
| `POST /calls` | `{request_id,call_id,contact_id,source:"backend"|"mcp"}` |
| `GET /calls/current` | `{call: object|null}` |
| `GET /calls` | `{calls:[...]}` (latest 100) |
| `POST /calls/incoming` | `{request_id,call_id,contact_id,source:"backend"|"mcp"|"independent"}` |
| `POST /calls/:id/answer` | `{request_id,epoch}`; ringing becomes active |
| `POST /calls/:id/input` | `{request_id,message_id,epoch,text,images?}`；图片格式与限制见上文；返回 `{call,input_id,reply_id,epoch}` |
| `POST /calls/:id/interrupt` | `{request_id,epoch}`; invalidates the generation and keeps the call active |
| `POST /calls/:id/end` | `{request_id,epoch,reason?}`; `declined`, `hangup` and `missed` are reasons |
| `GET /calls/:id/events?after=0&limit=100` | `{call,events,cursor,has_more}`; 1–100 events |
| `GET /calls/:id/record` | `{call,messages,job,push}`; `push` exposes pending/running/sent/failed and stable error code |
| `GET /calls/:id/inputs` | Persisted user messages and the current reply job; caller deduplicates message IDs |
| `POST /calls/:id/reply` | `{request_id,reply_id,epoch,complete:false,delta}` or `{request_id,reply_id,epoch,complete:true,text}` |
| `POST /calls/:id/summary` | `{request_id,text}`; stores an explicitly supplied summary, does not generate one |

Calls contain `id`, `contact_id`, `source`, `status` (`ringing`, `active`, `ended`), `epoch`, `last_sequence`, timestamps and optional summary. A new call starts at epoch 0; an accepted input, interrupt or end increments it. One owner can have one live call. Answer requires the current epoch. Independent scheduled calls use the same answer/end/state protocol, but the phone generates locally and does not send model input to this bridge.

Events contain `sequence`, `call_id`, `epoch`, `type`, `payload` and timestamp. Sequences are strictly increasing **within one call**. Save the last applied sequence and poll about once per second; immediately fetch another page when `has_more` is true. Ended calls remain readable. Events are not automatically pruned, and an `after` value beyond the call's last sequence returns `invalid_cursor`.

Reply events are `reply.started`, `reply.delta` (`{reply_id,input_id,delta}`), `reply.completed` (`{reply_id,input_id,text}`), `reply.failed` (`{reply_id,input_id,code}`) and `reply.interrupted` (`{reply_id,input_id,reason}`). Final text must preserve the already-received prefix; a rewritten final snapshot is rejected with `final_text_rewrite`. No reset is silently interpreted as a delta. Interruption preserves received text and an explicit reason; generation context carries that reason rather than guessing playback position.

## MCP wake bridge

The repository includes [`wake-adapter.mjs`](wake-adapter.mjs), a runnable,
dependency-free Node adapter. It maintains the wake subscription, fetches and
drains input, and launches the external AI command with that input. The AI uses
the dedicated MCP to reply and ends its task. See **唤醒桥接入** below for setup.

You must configure the AI platform's launch command and dedicated MCP yourself,
or implement the same workflow in that platform's automation system. Tincall
cannot determine how an arbitrary external platform starts its AI tasks. An
ordinary MCP connection alone does not install this workflow.

### 唤醒桥接入

需要一台保持运行的电脑或服务器、Node.js 22.5 以上，以及能从命令行启动任务的 AI 平台。平台如果只有聊天界面、没有任务启动入口，不能直接使用本程序；需要在该平台支持的自动化功能中自行配置下述流程。

1. 在 App 的联系人页选择「MCP＋唤醒桥」，复制完整接入 JSON，存到仓库外的私密文件，例如 `~/tincall-private/wake.json`。macOS／Linux 可用 `chmod 600 ~/tincall-private/wake.json` 限制访问。
2. **自行配置外部 AI 的启动命令。** 这个命令应从标准输入读取一份 JSON，携带其中的消息和实际图片启动一次 AI 任务；任务须连接 App 提供的专用 MCP，使用 `tincall_reply` 回复，随后结束并退出。若平台已有命令行入口，可用一个脚本将下面的输入映射到该入口；不能把不接收这些输入的聊天命令直接填进来。
3. 在仓库根目录运行：

   ```sh
   node connector/wake-adapter.mjs "$HOME/tincall-private/wake.json" -- /absolute/path/to/your-ai-launcher
   ```

   `--` 后面填你在上一步配置好的真实 AI 启动命令及其参数。例如启动程序是 Python 脚本时，填 `-- python3 /absolute/path/to/start_ai.py`。这些路径是需要替换的配置位置，不是仓库自带的平台启动器。不经过 shell 解释；引号、管道和重定向请放在自己的脚本里。
4. 看到 `Wake subscription connected.` 后即可在 Tincall 拨号。程序会在通话建立和每轮新输入时自动启动你的命令。按 Ctrl+C 停止。电脑需保持开机；一键部署安装的是 Tincall 服务，接入程序需运行在能启动你所用 AI 的设备上。

**AI 启动命令的输入与配置约定：**

- 标准输入的 `content` 按发言顺序包含 XML 文字块及紧随对应发言的原生图片块；不再另传重复的 `messages`。`<message>` 的 `name` 属性仅在名字非空时提供，开启时间感知时附带 `timestamp` 属性，`<text>` 保留原话。接通时另有简短提示；`voice_instructions` 仅在通话开始时提供一次。平台启动脚本读取 `content`，续接同一会话并保留人设和已收到的通话要求。
- 专用 MCP 设置通过环境变量传给启动命令：`TINCALL_MCP_URL`、`TINCALL_MCP_TRANSPORT`、`TINCALL_MCP_HEADERS`（JSON 对象）。由你的启动脚本将它们完整映射到本次任务的平台 MCP 设置；请求头包含凭据和自动绑定原通话的 `Tincall-Call-ID`，不能只复制固定的 Authorization，也不能在旧任务里换成新通话。凭据和路由标识不要放进模型提示词、命令行参数或日志。HTTP MCP 的每个请求须带 `Accept: application/json, text/event-stream`；SSE 配置由支持该传输的平台处理。
- 把发言和实际图片交给模型。AI 用 `tincall_reply({"text":"完整回复"})` 说话，然后结束本次任务；不需要回复编号、轮次或游标。首次收到的 `voice_instructions` 应随平台会话保留。
- 命令必须在该 AI 任务结束后退出，正常完成返回退出码 0；不能只把任务丢到后台就退出。接入程序会确认回复目标已完成或已被新一轮替代。失败时重读并核对原目标，1 秒、2 秒后重试，最多三次尝试；整个任务含重试最多三分钟。目标失效或新通话到来时释放旧任务，不把旧文本换个目标重发。命令应处理 SIGTERM，并结束自己启动的 AI 子进程。
- 启动命令的标准输出不会被当作通话回复，也不会输出到接入程序日志；标准错误同样不转储，避免泄漏消息和凭据。平台启动失败时需检查你配置的命令及平台自身的诊断，不要让其日志包含私人输入。

**已经由接入程序处理的部分：** SSE 断开重连，401／403 停止；同一联系人串行启动、合并重复唤醒；读取新增输入和实际媒体；同一通话的后续输入排队，当前 AI 写完后照常提交完整回复；失败任务只在原目标仍有效时有限重试，空闲时不轮询。机器标识只用于适配器内部处理，不交给 AI。

默认处理 `answered`（接通后开场）和 `input`（每轮说话／文字）。只想说话后唤醒时，在 `--` 前加 `--input-only`：

```sh
node connector/wake-adapter.mjs "$HOME/tincall-private/wake.json" --input-only -- /absolute/path/to/your-ai-launcher
```

也可不运行本程序，在支持自动化的平台自行配置：保持认证 SSE → 收到事件后自动 GET 输入并读完分页 → 带消息和实际媒体启动 AI → AI 通过专用 MCP 回复 → 本轮任务结束。这与普通 MCP 回复后挂起等待下一句话的用法不同。

### Wake protocol

One-click deployment includes the Tincall-side wake endpoints after migration `202610200006`.
The deployment completion screen and each saved service's **Wake Bridge** page
let the owner select a saved MCP contact and copy its integration JSON again.
Create and save an MCP contact first if this is a new service. This is a separate
integration from a platform's ordinary MCP settings; it does not install or start
an adapter inside any particular platform.

The owner uses `GET /wake/contacts` and `POST /wake/config` with
`{"contact_id":"CONTACT"}`. Repeated reads recover the same bridge credential;
`{"contact_id":"CONTACT","rotate":true}` replaces it. Returned JSON contains
`version:2`, `contact_id`, `wake:{transport:"sse",url,headers,event:"wake"}`,
`input:{transport:"http",url,headers}`, `mcp:{transport:"streamable-http",url,headers}`,
and integration instructions. The input URL is `/wake/input`; the dedicated AI
MCP URL is `/mcp/wake`. After updating an existing service, copy the configuration
again, apply all current migrations and update both the function and adapter.
The `tcwake_` credential is scoped to this contact's wake stream and MCP tools;
it cannot manage the service, access backups or other contacts. It is distinct
from both the phone token and ordinary MCP credentials. Configuration responses
must not enter logs or public settings/backup exports.

The platform integration keeps an authenticated `GET /wake/events` SSE connection
**outside AI/tool tasks**, with `Accept: text/event-stream` and the supplied
Authorization header. This is a subscription, not repeated current-call polling.
`ready` confirms the stream, comments are keepalives, and each `wake` frame has:

```json
{"version":1,"event_id":"REPLY_UUID","call_id":"CALL_UUID","contact_id":"CONTACT","reason":"answered","reply_to":"OPAQUE_TURN_REFERENCE"}
```

An opening and every new user input create wake events (`reason` is `answered`
or `input`). Only routing metadata travels in the event, never chat text or
recordings. On a wake the **adapter first reads the input**, sending GET to
`input.url` with `input.headers` and `Accept: application/json`. The response has
`structuredContent` (call, messages, reply, cursor, has_more, voice_instructions,
event) and MCP `content` blocks carrying the actual images. It drains `has_more`
pages by sending `cursor.sequence` and `cursor.epoch` as `sequence` and `epoch`
query parameters and deduplicates messages by ID before starting the AI. With
`idle` or `ended`, do not start an AI task. For `answered` or `input`, start the
AI with the XML message blocks and their following native image blocks. Supply `voice_instructions`
only when present at call start and retain the linked platform conversation.
Keep all machine routing fields inside the adapter. The AI submits complete
`text` through `tincall_reply`, which returns immediately in bridge mode, then
finishes its task. It does not fetch or wait for input. The dedicated MCP does
not list `tincall_wait`; an obsolete wait call simply explains that another
wake will deliver new input. A dial still waits for the phone to answer, so its
initiating task can speak immediately; that answer does not start a duplicate
opening task. Keep authorization headers in private integration settings.

Streams rotate after 120 seconds. Reconnect on EOF or a stream error with
1–30 second backoff; stop on HTTP 401/403 and obtain valid configuration again.
Subscribe-before-snapshot recovers the current unanswered
target on every connection, even when a client sends Last-Event-ID; completed
targets are not replayed. Delivery is at least once. Coalesce in-flight duplicate
`event_id` values. Before retrying, reread input and verify the original call and reply
target. Make at most three command attempts within a three-minute total deadline;
retire exhausted tasks until new input arrives. Pass the original `input.call.id` in
the task-specific `Tincall-Call-ID` MCP request header, never in the AI prompt.
Serialize tasks per contact; queue subsequent input in the same call while the
current task completes its reply, and cancel an old task when a new call arrives. Resetting a
credential rejects subsequent connections/tool requests and stops an old stream
on its next wake; switching away from MCP also disables bridge authentication.
Ordinary MCP credentials are unaffected by a bridge reset.

A platform must support authenticated SSE subscriptions and starting AI tasks,
or run a persistent adapter with those capabilities. Copying JSON into an
ordinary MCP server form does not supply that adapter. Platform adapters and
their actual wake/cancel behavior require separate integration and acceptance.

## Platform generation adapter

For the choice between a complete custom backend and reusing this connector, including required interfaces, TTS expression instructions and optional call controls, see the [backend integration boundaries](../docs/backend_api.md#接入范围tincall-提供什么后端需要接什么). This adapter requires generation and cancellation; exposing dial/hangup as AI tools is the integrating platform's choice. It supplies no automatic call-start/call-end webhook or model message, and generation begins on submitted input, not on dial/answer alone.

The connector makes one bounded POST per generation to the configured `generation_url`:

```json
{
  "version":1,"job_id":"UUID","call_id":"UUID","contact_id":"platform-role-17",
  "epoch":1,"input_id":"UUID","reply_id":"UUID","expression_prompt":"语音表达要求；未设置时为空字符串",
  "messages":[{"id":"UUID","role":"user","text":"...","status":"complete","interruption_reason":null}]
}
```

`Idempotency-Key` is the durable job UUID. The platform must deduplicate this job, use its configured role/history and cancel that same job when requested. The optional binding `token` is sent as a bearer credential only to the configured origin. Redirects are refused.

With time awareness enabled, the phone prefixes incoming text with
`[yyyy-MM-dd HH:mm:ss]` in its local time. Backend `messages[].text` retains that
prefix; no extra time-awareness prompt is injected into backend generation. The
phone removes these protocol timestamps from line starts in replies before
display or speech. MCP presents the input timestamp as an XML attribute instead.

`expression_prompt` carries the phone's saved speech-expression instructions on each generation request; the platform adapter should include it in the generation context. It does not replace the platform's persona/history. Backend calls require an HTTP binding: `tools` returns `backend_binding_required` before creating a call or accepting input. Capability discovery validates both URLs with the same rules used for calls; incomplete or invalid HTTP bindings are not advertised as ready.

Return `application/json` with `{"text":"final reply"}`, or `application/x-ndjson` with append-only lines:

```json
{"type":"delta","delta":"first part"}
{"type":"delta","delta":" next part"}
{"type":"completed","text":"first part next part"}
```

A completed line may omit `text` to finalize accumulated deltas. A `{"type":"failed"}` line reports failure. EOF without completion is a failure. The bridge limits one generation to 90 seconds and 100,000 characters. If the platform requires longer work, its adapter must support bounded asynchronous tasks before that platform can be considered compatible with this synchronous contract.

On interrupt/end the database immediately invalidates the old epoch. The running worker checks this at most once per second, aborts its actual fetch and POSTs `{job_id,call_id,epoch}` to `cancel_url`. The platform must actually cancel the job before acknowledging that request. `generation.cancel_result` records `cancel_accepted` or `cancel_delivery_failed`; failure cannot allow old replies back into the call. A lost worker becomes `worker_expired`; it is not blindly regenerated and billed a second time. Pending jobs are picked up by Cron or the Node worker.

Cancellation retries network errors, HTTP 408/429 and 5xx up to three attempts, with the same job identity and a five-second timeout per attempt. Other HTTP failures stop immediately. The final result is emitted once. The phone reports failed or unconfirmed cancellation and checks the control's event tail even after manual hangup has stopped the live event loop. Local audio still stops immediately; an HTTP control success alone is not proof that the platform stopped generation.

MCP Streamable HTTP supports `initialize`, `ping`, `tools/list`, `tools/call` and initialization/cancellation notifications. It is stateless JSON transport; no long-lived SSE connection is required. Clients send both `application/json` and `text/event-stream` in Accept and the negotiated `MCP-Protocol-Version`. The six tools are `tincall_call`, `tincall_get_call`, `tincall_wait`, `tincall_reply`, `tincall_end`, and `tincall_list_calls`. HTTP origins are rejected unless explicitly listed in `TINCALL_ALLOWED_ORIGINS`.

### ChatGPT / Claude OAuth

Update the function and apply migrations through `202610200005_tincall_contact_mode.sql` (or use the updated app's **部署或更新服务**). In ChatGPT, add the copied HTTP `/mcp` URL and choose OAuth; leave advanced client credentials blank and use dynamic registration. In Claude's custom connector, add the same `/mcp` URL, choose **Sign in now**, and choose **Register automatically** for the OAuth client. The authorization page shows an eight-character code. Open this saved cloud connection in Tincall → **MCP OAuth 授权**, enter the code, select the registered MCP contact and approve. Return to the original browser page and refresh. Approval works across devices; refresh in the browser that started the connection.

Supabase's default domain rewrites HTML function responses to plain text, so consent is native in Tincall and the browser uses a text instruction page. No separate website or custom domain is required. This is MCP authorization, separate from the deployment PAT and Supabase management OAuth. The server never asks for the phone credential in a browser. Existing raw bearer clients continue to work.

For Node behind a public HTTPS proxy/tunnel, configure `TINCALL_PUBLIC_URL` to its exact external connector base URL, with no trailing `/mcp`; otherwise the Node server only knows its internal loopback address. Supabase derives the standard gateway base automatically. Discovery is available under the base's `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server` and `/.well-known/openid-configuration`; unauthenticated MCP 401 responses advertise the resource metadata. The OIDC metadata route supports issuer paths beneath the Supabase gateway. Supported OAuth endpoints are `/oauth/register`, `/oauth/authorize`, `/oauth/consent`, `/oauth/token` and `/oauth/revoke`; phone-only JSON endpoints `/oauth/requests/lookup` and `/oauth/requests/decide` require the existing owner credential. DCR accepts the exact ChatGPT callbacks and Claude's `https://claude.ai/api/mcp/auth_callback` callback. Authorization requests last ten minutes; codes are single-use, bound to client/redirect/resource and PKCE. Access tokens expire after one hour; refresh tokens rotate with a thirty-day grant lifetime. OAuth credentials authorize MCP routes only, not backup, device or owner-management APIs.

A cloud account has one live-call slot. `call_busy` can concern a different contact, hidden from a contact-scoped credential; the MCP error now reports `scope:contact|account` and recovery guidance without exposing another contact's identity. The app's **云端当前通话** screen lets the owner inspect and explicitly end an abandoned call. Active phone event reads renew presence, including during silence; idle incoming subscriptions and MCP reads/replies do not. A call with no phone presence for three minutes ends with `reason:phone_disconnected` when the worker or next dial runs. Missed rings older than sixty seconds are also reclaimed on the next dial. A connected old call is retained; no extra idle polling is introduced.

The owner-only `POST /mcp/roles/mode` accepts `{role_id,call_mode}` with `standalone`, `mcp` or `backend`. It keeps the enrolled credential and ends that contact's pending MCP rings when leaving MCP mode; active calls remain intact. New MCP calls check this mode before checking occupancy and return `contact_mode_mismatch`, `current_mode` and recovery guidance when the contact uses another mode. Updating from the app synchronizes its saved MCP contact modes; switching back to MCP reuses the original credential.

**Prefer HTTP (Streamable HTTP)**. For clients that only support legacy SSE, choose SSE in the contact editor and copy its URL (`/mcp/sse`) and the same `Authorization: Bearer …` header. GET establishes the event stream and announces a relative POST endpoint; POST returns 202 while JSON-RPC results arrive as SSE `message` events. This path negotiates protocol `2024-11-05` and reuses the same authenticated tools. Both GET and POST require Authorization. Existing deployments must apply `202610190001_tincall_mcp_sse.sql` and update the function before using SSE.

SSE mailboxes are private, scoped to the authenticated owner/contact, and shared across Edge instances or Node processes. Streams send heartbeat comments and close after 120 seconds to leave headroom below the Free Edge worker lifetime; clients must reconnect and send `Last-Event-ID` to resume the same session. Sessions expire after three minutes without reads; recent delivered events are retained for reconnection, with bounded queues. Platforms that cannot reconnect reliably should use HTTP. Neither transport can override a platform's own tool timeout or automatically restart an idle AI.

A platform-initiated call is `tincall_call → tincall_reply → … → tincall_end`.
The dial stays pending until the phone answers, the call ends, or the contact's
configured wait expires (120 seconds by default). On answer it returns “通话已接通，可以打招呼了。” and the first-call
voice instructions, so the AI can speak immediately. A timeout says whether the
phone has not answered or the person has not spoken, and directs the AI to
`tincall_wait`.

For a contact-scoped credential, dialing needs no arguments. Ordinary MCP replies
use `{"call":"XXXXXXXX","text":"完整回复"}`, copying the 8-character marker
returned when that call was opened or discovered. Use the same marker for end and subsequent waits;
omit it from wait only to discover a new call. Never replace an old task's marker
with a newer call. The service resolves it within the authenticated owner/contact,
rejects unknown or ambiguous references, and refuses mutations on ended calls.
The model does not supply UUIDs, reply IDs, epochs or cursors. Bridge tasks still
submit text only: their adapter supplies the fixed `Tincall-Call-ID` request header.
Refresh tool definitions after applying the current migrations and function update.
A repeated dial reuses the unfinished call.

Ordinary tool results contain XML message text and actual images, without duplicate
`structuredContent`. Incoming messages have an optional `name` from the phone
profile; assistant history uses `name="TA"`. With time awareness enabled, incoming
messages have a `timestamp` in the phone's local time (`yyyy-MM-dd HH:mm:ss`).
`<text>` contains the original words, with XML metacharacters escaped. Blank
names are omitted. Generating, interrupted or failed messages can also carry
`status` and `reason` attributes. Native image
blocks immediately follow their message; image-only messages have an empty
`<text>`. Receipt announcements and per-turn routing metadata are not added.
Opening or discovering a call and explicitly looking
one up returns its short `call` marker; replies and waits that already specify it
do not repeat the marker after each message. History lists and pagination links
also use eight-character IDs: pass one as `call_id` to `tincall_get_call` to read
that call. Voice requirements are delivered once at call start,
including when using the wake bridge. Wait reads new messages and drains pages
internally; later waits do not repeat delivered messages. History recovery is an
explicit `tincall_get_call` operation, with older-page links when needed.
`tincall_list_calls` includes IDs only for deliberate history selection. Summaries
are shown for ended calls when available; active calls do not claim a summary.

A normal reply waits for the next input using that contact's saved wait duration. Use
`wait_for_input:false` to return immediately, such as before `tincall_end`.
Successful immediate submission returns `已发送。`. If storing succeeds but
waiting or loading the next image fails, the result says the reply was saved and
to keep waiting, without resending it. A timeout does not hang up. Internal wait
progress persists across service restarts, and failed media delivery does not
consume unread inputs. Integration code can explicitly set `timeout_seconds`
from 1–130 to override the preference for one request; the model-facing schema
omits that setting.

### Choosing the MCP wait duration

`POST /mcp/roles/upsert` accepts the optional integer
`mcp_wait_timeout_seconds` (1–130). New and upgraded contacts default to 120
seconds. Re-saving an existing role without this field preserves its saved value;
the response and contact binding include the saved duration. A changed duration
applies to subsequent `tincall_call`, `tincall_wait`, and waiting `tincall_reply`
requests for that contact, including when an owner credential discovers the call.
Changing it does not end an existing request or change wake-bridge replies into
long waits. Supabase deployments need
`202610250001_tincall_mcp_wait_preferences.sql` and the updated function;
SQLite upgrades its column on startup. Existing tokens and call history remain.

The contact editor accepts 1–130 seconds and adjusts out-of-range entries
automatically. Set the platform's tool timeout longer than Tincall's wait,
leaving time to return the result and issue the next wait.

Kelivo defaults to a 30-second MCP timeout. Set it to 180 seconds in Kelivo's
MCP settings, reconnect Tincall and keep Kelivo in the foreground during calls.

Muse defaults to a 45-second tool wait and moves the tool invocation to the background at
120 seconds. For Muse, set the Tincall contact's wait to 90 seconds and ask the
AI in Muse to set its tool wait to 110 seconds. Tincall can return first; if it
does not, Muse can report its timeout before moving the invocation to the background.
Other platforms should use their own tool limits.

The 130-second maximum is an application limit, not an assured hosting lifetime.
[Supabase's current hosted limits](https://supabase.com/docs/guides/functions/limits)
are a 150-second Free worker lifetime, 400 seconds on paid plans, and a
150-second request idle timeout. A 130-second wait leaves at most 20 seconds for
other work on a fresh Free worker; worker age, network latency, CPU limits and
the client's own timeout can shorten it. The legacy SSE stream still rotates
after 120 seconds and must
resume with `Last-Event-ID`; its durable mailbox can deliver a pending tool result
on the next stream. Stream rotation and tool suspension are separate clocks.

`tincall_end` asks the phone to finish reading received text before hanging up.
It does not claim that audio has already finished. Phone manual hangup remains
immediate. Ordinary MCP alone cannot restart an idle external model: the wake
adapter or platform integration must maintain the linked conversation.

## APNs sender, devices and schedules

Schedule controls require `202610200001_tincall_schedule_controls.sql` and the current service; SQLite adds the nullable column on startup. `POST /schedules` accepts `enabled` (default true) and optional `week_day` (ISO weekday 1 Monday through 7 Sunday; omit for daily), alongside `daily_time` and `time_zone`. `POST /schedules/enabled` takes `request_id`, `schedule_id` and boolean `enabled`. Writes are scoped to the owner, atomic and idempotent. Resuming recalculates the next future local occurrence; paused edits retain their status when the phone passes `enabled:false`. The worker keeps local clock time across DST. Deletion continues to use `/schedules/remove`.

The publisher-hosted shipping path uses the [Cloudflare push Worker](../cloudflare/README.md), retaining these device and push routes. The Node sender below remains available for a self-hosted installation; it is not the publisher's required hosting architecture.

Run `PORT=8788 node --env-file=/absolute/path/to/private-apns.env connector/apns-server.mjs` on a host supporting Node 24 and outbound HTTP/2 to Apple. Put a TLS reverse proxy in front and configure its HTTPS base as `TINCALL_PUSH_URL` on the data service. The matching `TINCALL_PUSH_TOKEN` must have at least 24 characters. Set team ID, key ID, `.p8` key path, topic such as `com.tincall.app.voip`, and a persistent SQLite path. Keep the key and database outside the checkout and back up the device binding database. Do not mount an empty ephemeral filesystem for production.

The sender signs APNs provider JWTs with ES256, caches them for less than one hour and uses the device's actual sandbox/production environment. It sends `apns-push-type: voip`, priority 10, expiration 0 and the configured VoIP topic over HTTP/2. Only Apple HTTP 200 yields `accepted_by_apns:true`; this does **not** establish that the device displayed or answered the call. An APNs 410 disables the expired device binding. The sender prevents cross-owner device use, deduplicates accepted call IDs without imposing a cooldown between different calls. Delivery receipts are retained for seven days. This is a user-owned sender template, not a deployed publisher push service.

Register from the phone:

```json
{"request_id":"UUID","device_id":"STABLE_PHONE_UUID","device_token":"PUSHKIT_HEX_TOKEN","environment":"sandbox"}
```

`POST /devices` returns `{ok:true,binding_id:"UUID"}`. `POST /devices/remove` takes `{request_id,device_id}` and disables the sender binding and removes the local routing entry. Up to five devices per owner are supported. The owner is derived from authentication; the phone cannot select a sender URL, owner or topic. The connector forwards token registration only to the configured sender. Do not log these request bodies.

The APNs payload has exactly the routing fields used by the App:

```json
{"aps":{"content-available":1},"event":"incoming_call","call_id":"UUID","contact_id":"LOCAL_OR_EXTERNAL_ROLE_ID","source":"independent"}
```

No text, summary, image, model credential or arbitrary URL is carried. The App must map the role and source to an already configured connection and promptly report the VoIP call through CallKit. Signing capabilities, APNs credentials, environment and topic must match the installed app. Free short-lived signing is not a promise of background incoming-call support.

`POST /schedules` takes `{request_id,schedule_id,contact_id,source,daily_time:"09:00",time_zone:"Asia/Shanghai"}` for daily local time. For a single occurrence use `next_at` in ISO 8601 instead; optional `repeat_seconds` (at least 300) provides interval scheduling. Daily and interval modes are mutually exclusive. Both backends preserve local clock time over daylight-saving changes (PostgreSQL timezone rules or Node ICU timezone rules). `GET /schedules` lists the owner's schedules; `POST /schedules/remove` with `{request_id,schedule_id}` removes one.

Cron creates a real ringing call and queues a push. A busy owner skips that occurrence. A ring expires after about 60–120 seconds depending on Cron timing. A failed push remains visible in `/calls/:id/record`; no missing configuration is reported as delivered. Cron's one-minute resolution is not a precise-second alarm guarantee.

## Optional cloud backup and media

`POST /records/:id` 使用 `{request_id,expected_revision,record}`。创建时使用 revision 0，更新时使用最近读取的版本。`record` 可保存 App 的版本化清单；无图请求上限仍为 8 MiB，包含内联消息图片时为 28 MiB，图片格式见上文。返回 `{record:{id,revision,deleted,record,updated_at}}`。旧版本返回 `revision_conflict`，应重新读取并由使用者处理冲突，不自动覆盖。

`GET /records` returns up to 100 index rows `{id,revision,deleted,updated_at}` and `next_cursor:{after,after_id}`. Pass both cursor fields into the next request and continue until `records` is empty. Fetch changed record bodies individually from `GET /records/:id`. Scope local revision caches by the `/capabilities` owner ID as well as the configured connection. `POST /records/:id/delete` takes `{request_id,expected_revision}`; it stores a tombstone, removes old backup payloads from idempotency receipts and cleans the record's media. Retries of retired old upload operations return `operation_retired`. 连接端文字通话历史独立保留；同一通话 UUID 的图片共用媒体命名空间，删除备份也会删除这些图片并清空通话消息中的图片引用。

Media is a separate opt-in operation. `PUT /records/:recordID/media/:assetID` uploads raw bytes with an audio/image/octet-stream Content-Type; both IDs are UUIDs, and one file is limited to 512 MiB. `GET` downloads bytes; `DELETE` removes that object. The server derives `ownerUUID/recordUUID/assetUUID` in Supabase's `tincall-private` bucket or the private local media store and never returns a permanent credential or signed address. Objects are immutable; use a new asset UUID for a new upload. `media_exists` does not certify that a new body matches existing bytes. An App may upload media before committing the manifest; it should remove any unreferenced upload if its manifest update fails.

`POST /records/:id/delete-backup` takes the same `{request_id,expected_revision}` and stores the same tombstone, but preserves connector call history, its referenced images, and schedules. It rejects a linked call that has not ended with `call_busy` (409). Owner capabilities advertise `backup_only_deletion:true`; bulk backup clearing must require this capability and use this route, never fall back to `/delete`. No additional SQL migration is needed for this route.

A deleted record rejects media PUT and backup media GET with `record_deleted`; GET remains allowed for images still referenced by the preserved connector call. Cleanup is bounded; `media_cleanup_pending` or `media_cleanup_failed` requires retrying the **same** delete request ID. The tombstone remains in place during retries, so old devices cannot resurrect the backup. Audio never uploads merely because text synchronization is enabled.

## Checks and current limits

Run the same connector tests against both backends:

```sh
export PATH="$HOME/.nvm/versions/node/v24.15.0/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
TINCALL_TEST_STORAGE=postgres node --test connector/tests/*.test.mjs
TINCALL_TEST_STORAGE=sqlite node --test connector/tests/*.test.mjs
```

`TINCALL_TEST_STORAGE` accepts only `sqlite` or `postgres`; when unset, it defaults to `postgres`. Other values fail immediately. PostgreSQL needs Docker with `postgres:18-alpine`. SQLite runs use temporary local files; PostgreSQL-only RLS checks are replaced with owner/auth isolation checks there. The PostgreSQL run retains the original SQL/RLS assertions. Additional SQLite tests cover schema upgrades with retained data, restart persistence, concurrent claims from independent processes, worker expiry, media and storage selection. Supabase tests execute the real SQL migrations, RLS policies and production HTTP/MCP service against isolated PostgreSQL, and drive the generation/cancellation adapter over localhost HTTP. All content is synthetic and the test container is removed afterward. Push tests exercise the production binding, deduplication, immediate redial and failure logic with a transport fixture; they do not contact Apple. Storage tests exercise the production streaming proxy against an HTTP protocol fixture; they do not upload to a real Supabase project.

The Cron extension migration requires a Supabase-compatible database. The App has a Supabase deployment/update flow; this connector module also supplies CLI installers. Neither flow provisions arbitrary AI platforms or automatically enrolls users into a publisher push account.

Official references checked for this implementation: [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [Supabase function limits](https://supabase.com/docs/guides/functions/limits), [Supabase function auth](https://supabase.com/docs/guides/functions/auth), [Supabase Storage API implementation](https://github.com/supabase/storage-js/blob/master/src/packages/StorageFileApi.ts), [Supabase Cron](https://supabase.com/docs/guides/cron), [APNs token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).
## 后台接听后的实时活动

Node APNs sender 与 Cloudflare sender 共用 `live-activity-push.mjs`。手工部署 sender 时一并复制此文件。设备注册支持可选 `live_activity_start_token`，接听后的 owner 手机请求 `/calls/{id}/activity` 经数据服务转发 `/activities/start`。使用原 APNs 签名，topic 为去掉 `.voip` 后加 `.push-type.liveactivity`；该签名必须允许对应 topic。令牌轮换、设备解绑与相同通话去重独立于 VoIP 投递。远端启动仅在接听及音频交接成功、App 仍在后台且没有本次通话活动时发送；前台或已有活动时跳过。启动提示包含联系人显示名和本地化「通话中」，不附声音；显示名仅用于当次发送，不写入发送端数据库，头像保留在手机。

卡片后续更新及挂断由手机 ActivityKit 执行。旧服务没有 `live_activity_push: true` 时，客户端保留打开通话页的回退。远端启动失败不结束通话，打开 App 后仍可创建本地活动。主 App 的实时活动开关、APNs 环境与 topic 须正确配置，详见[推送指南](../cloudflare/README.md)。
