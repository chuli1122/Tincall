# Tincall 自建后端接口

本文对应当前手机端 `ExternalCallClient.swift`、`CallCoordinator.swift`，以及 Node / Supabase Edge 共用的 `supabase/functions/_shared/tincall/service.mjs`。定时来电、备份部分另对照 `CallScheduleClient.swift`、`CloudSyncClient.swift` 和实际存储实现。

图片消息契约见 [图片消息](message_images.md)：手机 `images[]` 项为 `{id,mime_type,data_base64}`，MCP 返回标准 image content，后端生成请求使用 `messages[].images:[{mime_type,data_base64}]`。接入者需验证自己的图片传输、模型处理与备份恢复路径。

## 后端模式与 MCP

**后端模式不需要 MCP。** 已有自己的 AI 后端时，实现下述 HTTPS / JSON 接口，在后端完成上下文管理和模型生成即可。手机负责语音识别、提交文字、读取回复事件，以及合成和播放语音。

MCP 面向没有自己后端、AI 运行在其他平台上的使用者，由该平台调用连接端工具来收取输入和提交回复。后端模式无需实现 `/mcp`、`/mcp/roles/upsert` 或 MCP 工具，也无需注册 MCP 联系人。

MCP 工具调用与本文的手机 HTTP 接口是两套契约。本文说明后端接入，HTTP 写接口使用 `request_id`／`call_id`／`epoch`；无需让模型自行填写这些路由字段。

## 接入范围：Tincall 提供什么，后端需要接什么

后端自行选择模型、人物设定、记忆、上下文组织、工具调用和业务流程。Tincall 约定手机与服务之间的数据和通话状态，不规定后端的 Agent 框架，也不要求将拨号／挂断包装成某种固定的 AI 工具。

先选择一种接法，不需要同时实现两套：

| 接法 | Tincall 提供 | 接入方必须完成 |
| --- | --- | --- |
| 完整自建后端，手机直连自己的 HTTPS 服务 | 手机收音、STT、文字／图片输入、TTS 和播放、通话界面、本地记录 | 实现本文手机通话协议：`/capabilities`、`/calls`、`/calls/current`、每通电话的 `/input`、`/events`、`/interrupt`、`/end`；负责鉴权隔离、请求去重、事件顺序、真实生成／取消和旧代次失效 |
| 复用 Tincall 的 Node／Supabase 连接端 | 上述手机能力，以及手机 HTTP 协议、持久化通话状态／事件、任务调度和取消投递 | 配置 `mode: "http"` 绑定，实现同源的 `generation_url` 与 `cancel_url`；按 `job_id` 去重、组织模型上下文、返回回复并真正取消指定任务。完整格式见 [生成适配器契约](../connector/README.md#platform-generation-adapter) |

手机保存的是面向手机的 HTTPS 基础地址和访问令牌。复用连接端时，生成／取消地址及其独立凭据保存在服务端绑定中。仅部署连接端不会产生 AI 回复；仅有 MCP 的 `tools` 对象也不能代替 HTTP 生成绑定。同一联系人另有明确 HTTP 绑定时，可以走后端模式。

### 输入、回复与不同 TTS 的表达要求

| 数据 | Tincall 交付什么 | 后端如何使用 |
| --- | --- | --- |
| 对方输入 | 识别后的文字、手动文字，以及对方发送的图片；此接口不传麦克风原始音频流 | 送入自己选择的模型／工作流；图片按下文契约处理，不支持时明确报错 |
| 通话与生成标识 | `call_id` 区分电话，`contact_id` 定位对象，`epoch` 区分代次；生成适配器另收到 `job_id`、消息历史和中断标记 | 自行维护人物与记忆，避免重试重复生成、旧回复进入新轮次；连接端传来的历史不包含接入方自己的跨通话记忆 |
| 语音表达要求 | 手机拨出／接听时发送 `expression_prompt`；复用连接端时，每次生成请求都携带保存的值 | 放进模型上下文，指导输出适合当前 TTS 的文本；不替代人物设定，不是 TTS 密钥或语音参数接口 |
| AI 回复 | 手机接收完整文字或追加增量，再按手机所选 TTS 合成、播放 | 返回真实回复，按协议表示完成／失败；不要求后端上传合成音频 |

`expression_prompt` 默认由手机按 TTS 供应商和型号生成，用户可在该 TTS 配置的“语音表达提示词”中覆盖或留空关闭。例如 ElevenLabs 对应型号和 Fish Audio S2 使用各自的方括号表达规则，MiniMax Speech 2.8 使用圆括号语气音与 `<#秒数#>` 停顿，其他型号使用对应规则。接入方直接采用收到的内容即可，不必自行复制一套供应商判断。当前契约在拨出／接听时确定该值，没有通话中实时切换提示词的独立更新接口。

开启联系人时间感知后，手机在提交的输入文字前加一行 `[yyyy-MM-dd HH:mm:ss]`，使用该消息的手机本地时间。后端生成请求的 `messages[].text` 保留这一前缀；连接端不额外向后端注入时间提示词，由后端决定如何纳入上下文。手机会清理回复中行首的这类协议时间标记，避免显示和朗读。MCP 则将输入前缀转为 `<message timestamp="...">` 属性，格式见[图片消息](message_images.md)。

### 可选能力与通话通知

| 能力 | 已有接口／行为 | 接入方额外负责 |
| --- | --- | --- |
| 主动给手机打电话 | `POST /calls/incoming` 创建振铃，手机通过 `/answer` 接听 | 决定何时呼叫；需要 AI 自主呼叫时，由自己的平台封装工具。后台／锁屏来电还需设备注册与可用推送链路 |
| 后端结束电话 | `POST /calls/{call_id}/end` 结束通话，手机收到 `call.ended` | 按当前代次发起控制；需要 AI 自主挂断时，由自己的平台封装工具。普通 HTTP `reason: "hangup"` 立即结束手机收播，不承诺最后一句播放排空 |
| 开始／结束后的业务处理 | 连接端保存 `call.started`、`call.ended` 等状态事件 | 自行接入状态处理、开场或收尾逻辑；当前 HTTP 生成适配器没有自动生命周期 webhook，也不会自动把事件变成模型对话消息 |
| 摘要回写、长期记忆 | 通话 ID、已收到的内容和结束状态可用于关联业务 | 自行决定摘要生成和写回位置，不要求另建独立模型会话 |
| 定时来电、备份、前台来电订阅 | 本文后续章节给出对应接口 | 按需要启用；基础拨出通话不要求实现全部扩展 |

复用连接端时，HTTP 生成在手机提交 `/input` 后启动；单独拨号或接听不会调用 `generation_url` 生成开场白。打断／挂断时，仅正在执行的生成任务会收到 `cancel_url` 请求 `{job_id,call_id,epoch}`；模型已完成时，不能依赖取消请求获知电话结束。取消成功表示任务已停止，不表示模型收到了一条“对方挂断”的消息。

## ChatGPT MCP OAuth

自有连接端同时支持原有 Bearer 和 ChatGPT 的 OAuth 授权码 + S256 PKCE。部署需包含 `202610200003_tincall_mcp_oauth.sql`、`202610200004_tincall_call_presence.sql` 和共享 `oauth.mjs`。完整端点、期限、原生联系人授权与部署方式见 [连接端说明](../connector/README.md#chatgpt--claude-oauth)。OAuth 令牌只能访问已授权联系人的 MCP 路由，不能替代手机令牌访问本文的备份、设备或管理接口。

## 通用约定

- 下文路径相对于手机保存的 HTTPS 基础地址。例如基础地址为 `https://example.com/tincall`，开始通话请求就是 `POST https://example.com/tincall/calls`。Supabase 一键部署的基础路径为 `/functions/v1/tincall`。
- 手机发送 `Authorization: Bearer <访问令牌>`，JSON 请求另带 `Content-Type: application/json`、`Accept: application/json`。通话 JSON 响应必须带 `Content-Type: application/json`，成功状态为 HTTP 200。手机不跟随重定向。
- UUID 用 JSON 字符串表示，比较和存储时统一大小写；iOS 路径中的 UUID 可能为大写。`epoch`、`sequence`、`after`、`cursor`、`limit` 为非负整数。无图 JSON 请求体上限为 8 MiB；含图 `/input` 或备份写入最大 28 MiB，单消息最多四张，每张解码后最多 5 MiB。图片 UUID 在重试中保持不变。
- 每次写操作带 `request_id`。网络重试复用原 `request_id` 和原请求内容；同一身份下相同请求返回原结果，不重复生成或重复控制。相同 ID 改内容返回 `idempotency_conflict`（409）。
- 身份从访问令牌推导，手机不发送 `owner_id`。必须隔离不同所有者的通话、事件、设备和备份。

通话对象 `call` 的手机必需字段：

| 字段 | 类型 / 含义 |
| --- | --- |
| `id` | UUID，即 `call_id` |
| `contact_id` | 后端联系人标识 |
| `source` | 后端模式为 `backend`；连接端另支持 `mcp`、`independent` |
| `status` | `active`、`ringing`、`ended` |
| `epoch` | 当前生成代次；新输入、打断、挂断各递增一次 |
| `last_sequence` | 此通话最后一个事件的序号 |

连接端还返回 `created_at`（时间字符串）、`ended_at`（时间字符串或 null）、`summary`（字符串或 null）。公开通话对象不包含内部语音提示字段或所有者凭据。

## 一通电话与上下文的边界

**一个 `call_id` 标识一通电话，不强制对应独立的模型上下文。** 后端可以沿用自己的主会话、记忆或创建临时会话，但必须按通话隔离状态和生成任务。手机开始通话时生成 UUID；开始、接听、每句输入、打断和挂断都关联同一个 `call_id`。开始请求把它放在 JSON 中，后续请求把它放在路径 `/calls/{call_id}/...` 中；每个返回事件也带相同的 `call_id`。不要把每句输入的 `message_id` 或生成的 `reply_id` 当作通话 ID。

想让电话使用独立上下文，并在结束后将摘要放回主上下文的后端，可按以下生命周期处理：

1. 收到 `POST /calls` 时，以 `call_id` 建立通话上下文；后端主动来电时，也先按来电的 `call_id` 建立上下文。
2. `/answer` 只表示接听已有来电，继续使用该上下文。
3. `/input` 的每句输入进入该通话上下文；`epoch` 用来拒绝旧生成继续写入。
4. `/interrupt` 取消当前生成，保留已经收到的文字，电话和上下文继续存在。
5. **收到 `POST /calls/{call_id}/end`，且 `reason` 为 `hangup`，就是这通电话结束的时机。** 取消生成、保存已收到内容，结束该上下文，再生成摘要并按自己的规则写回主上下文。结束处理要按请求 ID 去重，避免重试重复插入摘要。

`reply.completed` 只结束一句回复；空事件页、长轮询超时和暂时断网都不等于挂断。连接端结束时发出的事件名称是 **`call.ended`**，不是 `end`；`end` 是 HTTP 路径。未接来电还可能以 `reason: "missed"` 结束。自带连接端会以现有通话事件读取确认手机在线；连续三分钟未读取的已接通通话，在 worker 或下次拨号时以 `reason: "phone_disconnected"` 结束。MCP 读取与回复不刷新手机在线状态。自建完整后端可实现等价回收，不要求暴露额外手机轮询接口。

现有连接端没有“自动将挂断摘要写回主上下文”的回调。若复用连接端的 HTTP 生成适配器，其取消通知只针对正在执行的生成任务；需要上述摘要策略时，应在自己的 `/end` 处理或持久化通话结束流程中实现。

## 手机通话接口

### GET /capabilities

无请求体。手机检查连接并获取联系人列表。`server_version` 是部署版本，与协议字段 `version` 分开；Tincall 云端将它与 App 内所需版本比较，缺少该字段或版本过旧时提示按原部署方式更新服务。连接端返回示例：

```json
{
  "version": 1,
  "server_version": 2026102601,
  "owner_id": "10000000-0000-4000-8000-000000000001",
  "events": "poll",
  "max_event_page": 100,
  "reply_protocol": "append_only",
  "mcp_role_management": false,
  "bindings": [
    {"contact_id": "assistant", "display_name": "助手", "mode": "http", "generation_configured": true, "wake_supported": true}
  ],
  "push_configured": false
}
```

`bindings` 每项的 `contact_id`、`generation_configured` 为手机必需；`display_name` 可省略。手机只把 `generation_configured: true` 且标识非空的项作为可选联系人。现有连接端的 `mode` 为 `http` 或 `tools`，`wake_supported` 在 `http` 时为 true。后端模式仅展示 `http` 对象，兼容未提供 `mode` 的原有直接后端；`tools` 对象保留在 MCP 路径，不作为后端对象。`events: "poll"` 同样用于长轮询，未新增能力枚举。`owner_id` 用于可选云端备份；联系人专用令牌不返回该字段。共享连接端对普通手机令牌返回 `mcp_role_management: true`，自建纯后端不需要实现 MCP 注册能力。

App 一键部署的 Supabase 是通话连接端，不自带人物回复生成。后端模式经它转发时，需在服务端绑定实际聊天后端的生成／取消接口；手机输入经连接端送到该后端，回复事件再返回手机。只部署 Supabase 或登记 MCP 对象不等于接入聊天后端。

### POST /calls

复用 Tincall 连接端时，后端模式必须绑定 `mode: "http"` 对象；误用 MCP 的 `tools` 对象时，创建通话和提交输入均返回 `backend_binding_required`（422）。能力列表与拨号复用同一校验：缺少生成／取消地址、URL 无效、HTTPS 不符或取消地址不同源时，`generation_configured` 和 `wake_supported` 均为 false。非法 URL 返回 `generation_url_invalid`（422）。完整自建后端按本节实现手机协议即可，内部不要求使用这套绑定配置。

请求体：`request_id`（UUID，手机此处与 `call_id` 相同）、`call_id`（UUID）、`contact_id`（1–200 字符字符串）、`source`（后端模式为 `backend`）、`expression_prompt`（字符串，语音表达提示，可为空）、`user_name`（手机个人资料名字，可为空）。开启时间感知时另带 `time_awareness_enabled: true` 和 IANA 时区 `time_zone`。

返回：`{"call": <call>}`，新通话为 `active`，初始 `epoch` 为 0；发出 `call.started` 事件。

相关错误：`invalid_request_id`、`invalid_call_id`、`invalid_contact_id`、`invalid_source`（400）；`generation_not_configured`、`generation_url_requires_https`、`cancel_origin_mismatch`（422，仅复用连接端绑定配置时）；`call_busy`、`invalid_expression_prompt`（409）。现有连接端每个所有者同时只允许一通未结束的电话。

### GET /calls/current

无请求体。返回 `{"call": <call 或 null>}`，用于查询未结束的通话；没有通话返回 null。它本身不会开始生成。

### POST /calls/{call_id}/answer

请求体：`request_id`（UUID）、`epoch`（当前通话代次）、`expression_prompt`（字符串，可为空）、`user_name`（手机个人资料名字，可为空）；开启时间感知时另带 `time_awareness_enabled: true` 和 `time_zone`（IANA 时区）。

返回：`{"call": <call>}`，状态从 `ringing` 变为 `active`，发出 `call.started`，不递增 `epoch`。

相关错误：`invalid_request_id`、`invalid_call_id`、`invalid_epoch`（400）；`call_not_found`（404）；`call_not_ringing`、`stale_epoch`、`invalid_expression_prompt`（409）。

### POST /calls/{call_id}/input

请求体：`request_id`（UUID）、`message_id`（此句用户消息 UUID）、`epoch`（提交前的当前代次）、`text`（最多 20000 字符）及可选的 `images`。无图时 `text` 必须非空；有图时可为空或省略。`images` 每项为 `{id:"图片 UUID",mime_type:"image/jpeg",data_base64:"完整标准 Base64"}`，最多四项、每张最多 5 MiB；还支持 PNG，HEIC 当前明确拒绝。Base64 不带 data URI 前缀或换行，重试复用图片 UUID。连接端在私有媒体存储保存文件，消息只存 `{id,mime_type,bytes}` 引用。

返回：`{"call": <call>, "input_id": "用户消息 UUID", "reply_id": "本轮回复 UUID", "epoch": 1}`。`input_id` 对应本次 `message_id`；返回的 `epoch` 是递增后的新代次。保存用户输入，取消旧回复（如有），再发出 `input.accepted`、`reply.started`，启动真实模型生成；后续文字由 events 接口返回。

相关错误：`invalid_request_id`、`invalid_call_id`、`invalid_message_id`、`invalid_epoch`、`invalid_text`（400）；`call_not_found`（404）；`call_ended`、`call_not_active`、`stale_epoch`（409）；绑定配置错误（422，同开始通话）。

### POST /calls/{call_id}/interrupt

请求体：`request_id`（UUID）、`epoch`（当前代次）、`reason: "interrupted"`。

返回：`{"call": <call>}`。取消当前生成，`epoch` 加 1，通话保持 `active`。如有未完成回复，先发 `reply.interrupted`，再发 `call.interrupted`。已生成内容保留，不能用后续迟到结果覆盖。

### POST /calls/{call_id}/end

请求体：`request_id`（UUID）、`epoch`（当前代次）、`reason: "hangup"`。

返回：`{"call": <call>}`。取消当前生成，`epoch` 加 1，状态变为 `ended`。如有未完成回复，先发 `reply.interrupted`（`reason: "hangup"`），再发 `call.ended`（`reason: "hangup"`）。

打断和挂断的相关错误：`invalid_request_id`、`invalid_call_id`、`invalid_epoch`（400）；`call_not_found`（404）；`call_ended`、`stale_epoch`（409）。重试已成功的同一个请求返回原结果；用新请求 ID 再控制已结束通话会得到 `call_ended`。

### GET /calls/{call_id}/events?after=N&limit=100&wait=20

HTTP 生成的取消投递遇到网络错误、408、429 或 5xx 时，最多尝试三次（同一 `job_id`、`call_id`、`epoch`，每次最多五秒），最终写入一条 `generation.cancel_result`。手机处理该失败事件；手动打断／挂断后还会独立读取控制事件尾页，必要时有界等待对应代次的取消结果，避免挂断停止监听后遗漏失败。未确认取消时明确提示，不能宣称远端已停止；本机手动挂断和停止播放不等待确认。没有未完成回复时不等待取消事件。

无请求体。查询参数：

| 参数 | 默认值 / 行为 |
| --- | --- |
| `after` | 默认 0，只取序号大于该值的事件；大于 `last_sequence` 返回 `invalid_cursor` |
| `limit` | 默认 100，非负整数，实际页大小限制为 1–100 |
| `wait` | 秒，默认 0；非负整数，大于 25 按 25 处理 |

返回结构示例（同一通话的事件序号从 1 连续递增）：

```json
{
  "call": {"id": "20000000-0000-4000-8000-000000000001", "contact_id": "assistant", "source": "backend", "status": "active", "epoch": 1, "last_sequence": 4},
  "events": [
    {"sequence": 4, "call_id": "20000000-0000-4000-8000-000000000001", "epoch": 1, "type": "reply.delta", "payload": {"input_id": "30000000-0000-4000-8000-000000000001", "reply_id": "40000000-0000-4000-8000-000000000001", "delta": "你好"}}
  ],
  "cursor": 4,
  "has_more": false
}
```

- `after` 之后已有事件时立即返回；没有事件且 `wait > 0` 时保持连接，有新事件即返回，到期仍没有则返回 `events: []`、`cursor: after`、`has_more: false`。当前共享实现每 250 毫秒检查持久化数据库，可接收其他实例写入的事件；查询耗时可能使实际响应稍晚于等待期限。
- 不传 `wait` 或传 0，保持原来的立即查询行为。接听、恢复和控制前的状态读取使用这种方式，避免延误控制。
- `cursor` 是本页最后一个事件的序号；空页保持 `after`。`has_more: true` 表示还有后续页，手机立即继续读取，不因本页状态快照已是 `ended` 就跳过剩余页。不能跳号、乱序或跳过未交付的事件来推进游标。
- 手机持续监听发送 `wait=20`，仅该类请求使用 40 秒请求超时、45 秒资源超时；其他通话请求仍为 20/30 秒。收到空页且请求耗时不足 1 秒时，再睡 1 秒；已等待至少 1 秒的空页直接继续请求。非空尾页保持原来的 1 秒间隔；`has_more` 页立即继续。失败仍按原来的 2、4 秒退避，连续第 3 次失败后停止该监听循环。
- **自建后端可以不实现 `wait`，直接忽略该未知查询参数。** 手机仍能按原来约每秒一次的方式工作，只是新事件送达较慢。不要仅因多了 `wait` 就拒绝请求。
- 手机打断时取消正在等待的请求，并为同一通话重新监听；挂断时取消监听。服务器应响应客户端断开，停止等待及相关数据库请求。Node 两种存储模式与 Supabase Edge 使用同一个实现，等待上限为 25 秒，低于 Edge 的请求空闲时限。

相关错误：`invalid_call_id`、`invalid_after`、`invalid_limit`、`invalid_wait`、`wait_cancelled`（400）；`call_not_found`（404）；`invalid_cursor`（409）；`forbidden`（403）。

事件字段为 `sequence`、`call_id`、`epoch`、`type`、`payload`；现有存储还返回 `created_at`。手机处理的事件如下：

| `type` | `payload` 字段 / 含义 |
| --- | --- |
| `call.ringing`、`call.started` | 空对象 |
| `input.accepted`、`reply.started` | `input_id`、`reply_id` |
| `reply.delta` | `input_id`、`reply_id`、`delta`（追加文字） |
| `reply.completed` | `input_id`、`reply_id`、`text`（本轮最终全文，必须以已发送增量文字为前缀） |
| `reply.failed` | `input_id`、`reply_id`、`code`（生成失败原因） |
| `reply.interrupted` | `input_id`、`reply_id`、`reason`（`interrupted` 或 `hangup`） |
| `call.interrupted` | `reason: "interrupted"` |
| `call.ended` | `reason`，通常 `hangup`，未接来电可为 `missed`，手机持续断开可为 `phone_disconnected` |
| `generation.cancel_result` | `epoch`、`code`（`cancel_accepted` 或 `cancel_delivery_failed`），连接端取消投递结果 |

回复相关事件的 `input_id`、`reply_id`、`epoch` 必须匹配对应输入与生成。打断或挂断后禁止把旧代次结果混入新回复。保留已收到文字并记录中断原因，不推测语音播放到了哪里。

## 前台来电订阅

`GET /calls/incoming/events` 使用手机所有者令牌和 `Accept: text/event-stream`；联系人专用令牌不可访问。共享连接端的 capabilities 返回 `incoming_events: "sse"`。连接建立时先订阅，再读取一次当前通话快照；随后仅推送该所有者的通话状态变更。帧格式为：

```text
event: call_state
data: {"call":{"id":"UUID","contact_id":"联系人标识","source":"mcp","status":"ringing","epoch":0,"last_sequence":1}}

```

无当前通话时发送 `{"call":null}`；非空快照仅包含示例中的六个字段，不携带正文、摘要或凭据。服务每 15 秒发送注释心跳，最长 120 秒结束一次流，客户端断线后重连并获取新快照；心跳不查询数据库。上游订阅失败可发送 `event: error`、`data: {"error":{"code":"incoming_subscription_unavailable"}}` 后关闭。手机退到后台取消订阅，后台／锁屏来电仍走原推送链路。已有来电状态监视及通话回复事件接口保持原协议。

Supabase 需要部署新版函数并应用 `202610200002_tincall_incoming_events.sql`，已包含在 App 一键部署／更新包内；SQLite 通知覆盖本服务进程内的写入。

## 可选：来电设备与定时计划

仅启用相应功能时需要；基本的手机主动拨出通话不依赖这些接口。

| 路径 / 方法 | 手机请求体 | 返回字段 |
| --- | --- | --- |
| `POST /devices` | `request_id`、`device_id`（UUID），`device_token`（32–256 位十六进制字符串），`environment`（`sandbox` / `production`） | `ok: true`、`binding_id`（推送网关绑定 ID） |
| `POST /devices/remove` | `request_id`、`device_id`（UUID） | `ok: true`、`binding_id: null` |
| `GET /schedules` | 无 | `schedules` 数组；每项 `id`、`contact_id`、`source`、`next_at`、`repeat_seconds`、`daily_time`、`time_zone`、`enabled` |
| `POST /schedules` | 当前手机发送 `request_id`、`schedule_id`（UUID）、`contact_id`（本地联系人 UUID 字符串）、`source: "independent"`、`daily_time`（本地时刻字符串）、`time_zone`（IANA 时区） | `ok: true` |
| `POST /schedules/remove` | `request_id`、`schedule_id`（UUID） | `ok: true` |

设备注册不能由手机传入 `binding_id`。相关错误：`invalid_request_id`、`invalid_device_id`、`invalid_device_token`、`invalid_environment`、`invalid_binding_id`（400，既用于拒绝手机自带绑定 ID，也用于检查网关返回的绑定 UUID）；`device_limit`（409，最多 5 个设备）；`push_not_configured`、`push_url_requires_https`（422）；`push_registration_failed`（502）；`push_registration_unavailable`（503）。设备移除不带 token 或 environment。

计划保存还支持后端 API 的 `source: "backend"` / `"mcp"`，以及 `next_at`、`repeat_seconds`（至少 300 秒）形式；`daily_time` 与 `repeat_seconds` 不能并用。当前手机的计划保存入口实际创建的是独立模式每日来电。计划字段或日期约束失败经存储层通常映射为 `database_request_failed`（400），跨所有者更新计划为 `forbidden`（403），写操作仍需有效 `request_id`。

后端主动呼叫时，连接端另提供 **`POST /calls/incoming`**（不是手机发出的请求），请求体为 `request_id`、`call_id`、`contact_id`、`source`，可带 `expression_prompt`；返回 `{"call": <call>}`，状态 `ringing`、事件 `call.ringing`。推送投递通过后台任务完成，返回成功不代表手机已响铃；手机接听后调用同一 `call_id` 的 `/answer`。创建错误同 `/calls`，推送失败保存在任务状态中。

## 可选：云端记录与录音备份

与通话上下文分开，是用户启用备份后手机调用的接口。记录 ID 和媒体对象 ID 都是 UUID；所有者由令牌决定。

| 路径 / 方法 | 请求字段 | 返回字段 |
| --- | --- | --- |
| `GET /records` | 查询参数 `after`（时间）、`after_id`（UUID），首次都可省略 | `records` 数组（每项 `id`、`revision`、`deleted`、`updated_at`），`next_cursor` 为 `{after, after_id}` 或 null；每页最多 100 项，无正文 |
| `GET /records/{record_id}` | 无请求体 | `record` 对象或 null；对象字段 `id`、`revision`、`deleted`、`updated_at`、`record`（备份正文或 null） |
| `POST /records/{record_id}` | `request_id`、`expected_revision`（首次为 0）、`record`（备份正文） | `record` 对象，`revision = expected_revision + 1` |
| `POST /records/{record_id}/delete` | `request_id`、`expected_revision` | `record` 对象，`deleted: true`、正文 `record: null`，版本加 1 |
| `POST /records/{record_id}/delete-backup` | `request_id`、`expected_revision` | 同上，但保留连接端通话数据、其引用的图片及来电计划 |
| `PUT /records/{record_id}/media/{asset_id}` | 原始媒体字节，`Content-Length`，`Content-Type` 为 `audio/*`、`image/*` 或 `application/octet-stream` | JSON `ok: true` |
| `GET /records/{record_id}/media/{asset_id}` | 无请求体 | 原始媒体字节、`Content-Type`，可带 `Content-Length` |
| `DELETE /records/{record_id}/media/{asset_id}` | 无请求体 | JSON `ok: true` |

备份正文为手机的 `CloudSyncDocument`：`format: "TincallRecord"`、`version: 1`、`call`（本地 `CallRecord`）、`media`（数组，每项 `object_id`、`asset`、`bytes`）。后端按 JSON 文档原样存取，完整本地记录结构见 [CloudSyncModels.swift](../ios/Tincall/Storage/CloudSyncModels.swift) 和 [CallModels.swift](../ios/Tincall/Core/CallModels.swift)。它不是前文简化的远端 `call` 对象，不能拿 `GET /calls/current` 的状态对象代替备份正文。

记录按 `(updated_at, id)` 排序分页；手机用返回游标继续，直到空页。删除保留 tombstone，旧版本写入返回 `revision_conflict`（409），已删除旧上传请求的重放返回 `operation_retired`（409）。媒体清理有单次工作量限制，`media_cleanup_pending` / `media_cleanup_failed`（503）时需重试同一个删除请求 ID。

批量清空备份需先确认 `/capabilities` 返回 `backup_only_deletion: true`，逐条调用 `/delete-backup`，不回退到会清除共享图片的 `/delete`。存在未结束的同 ID 连接端通话时返回 `call_busy`（409）。删除后，仍被连接端通话引用的图片可下载，其余备份媒体不可下载或重新上传。此接口无需新增 SQL 迁移，需更新服务程序。

媒体单文件上限 512 MiB，同一对象 ID 不允许覆盖。相关错误：`invalid_record_id`、`invalid_asset_id`、`invalid_media_path`、`body_required`（400）；`media_not_found`（404）；`media_exists`（409）；`record_deleted`（410）；`media_too_large`（413）；`unsupported_media_type`（415）；`media_request_failed`（502，Supabase 存储请求失败）；`media_unavailable`（503）。`media_exists` 不能证明已存内容与本次上传一致。仅启用文字备份不会上传录音。

## 通用错误格式与状态码

除媒体下载成功返回字节流外，接口失败返回 JSON：

```json
{"error":{"code":"stale_epoch","message":"stale_epoch"}}
```

手机依据 HTTP 状态及 `error.code` 判断失败，`message` 不是必须解析的字段。共享路由会返回两者；Node 最外层意外失败也可能只返回 `error.code`。

| HTTP | 代码（当前实现） |
| --- | --- |
| 400 | 各接口列出的 `invalid_*`；`invalid_object`、`invalid_json`、`body_required`、`database_request_failed`、`wait_cancelled` |
| 401 | `unauthorized`（缺少或无效令牌） |
| 403 | `forbidden`（身份范围不允许）、`origin_forbidden`（未允许的 Origin） |
| 404 | `route_not_found`、`call_not_found`、`reply_not_found`、`media_not_found` |
| 405 | `method_not_allowed`（显式限制方法的路由；其他不匹配的路由可能为 404） |
| 409 | `idempotency_conflict`、`call_busy`、`call_ended`、`stale_epoch`、`call_not_ringing`、`call_not_active`、`invalid_cursor`、`revision_conflict`、`operation_retired`、`device_limit`、`invalid_expression_prompt`；回复写入还可能有 `final_text_rewrite` |
| 410 | `record_deleted` |
| 413 | `body_too_large`、`media_too_large` |
| 415 | `json_required`、`unsupported_media_type` |
| 422 | `generation_not_configured`、`generation_url_requires_https`、`cancel_origin_mismatch`、`push_not_configured`、`push_url_requires_https` |
| 502 | `push_registration_failed`、`media_request_failed` |
| 503 | `database_unavailable`、`authentication_unavailable`、`push_registration_unavailable`、`media_unavailable`、`media_cleanup_failed`、`media_cleanup_pending`；部署配置错误还可能为 `server_configuration_missing`、`invalid_server_configuration` |
| 500 | `internal_error` |

存储层未列入公开错误白名单的校验错误会映射为 `database_request_failed`（400），不要把数据库内部报错原样暴露给手机。模型生成错误通常通过 HTTP 200 的事件页内 `reply.failed.payload.code` 传达，例如 `generation_timeout`、`generation_unavailable`、`generation_http_error`、`generation_failed`、`worker_expired`；这与读取 events 本身发生 HTTP 错误不同。
