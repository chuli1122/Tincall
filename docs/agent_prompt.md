# Tincall 接入指引

自行配置时，阅读所选接法对应的步骤；让 AI 协助接入时，可把本文交给 TA。

给 AI 接入助手：先确认对方要用独立模式、普通 MCP、MCP＋唤醒桥还是后端直连，再提供对应步骤。不要把普通模型 API 地址当成 Tincall 服务地址，也不要让对方把令牌贴进聊天。MCP 用于支持 MCP 工具的 AI 平台；后端接法用于自行实现 Tincall 通话接口的服务。

资料仓库：https://github.com/chuli1122/Tincall
接入细节和部署说明以仓库中的 README、connector 和文档为准。

普通 MCP 接法

一、在 AI 平台配置服务
先在 Tincall「设置 → Tincall 云端」部署或连接支持 MCP 的服务，再编辑联系人，通话方式选 MCP、选择连接并保存。联系人页直接提供传输方式、URL 和 Authorization 的复制，推荐 HTTP（Streamable HTTP），平台仅支持旧 SSE 时再选 SSE。将 URL 填入平台 MCP 服务地址，将复制的 Authorization 填入同名请求头；地址已完整，不要重复追加 /mcp。Authorization 包含 Bearer 和联系人专用令牌，不要替换为手机令牌或 service-role 密钥。令牌只放私密服务配置，不贴进聊天。旧云端须升级数据库迁移和服务函数，再刷新平台工具列表。

二、可用工具
参数及必填项以 tools/list 为准：
• tincall_call(contact_id?)：向手机发起来电，等待接听后返回，随后可通过 tincall_reply 打招呼。联系人专用凭据无需参数；其他身份按工具定义填写 contact_id。
• tincall_get_call(call_id?, limit?, before_sequence?)：查看保存的通话文字、图片和当前状态；结束的通话可能另有摘要。按结果指引翻阅更早记录。日常对话使用 tincall_wait。
• tincall_wait(call?)：等待新消息、接听或挂断，时长使用对应联系人的 MCP 等待设置。沿用本通电话返回的 8 字符 call 标记；仅发现新通话时省略。超时继续调用，不会挂断；播放停止不会让等待提前结束。
• tincall_reply(call, text, wait_for_input?)：原样带回产生本次任务的 call 短标记，用 text 一次提交完整回复，默认继续等下一句话。告别时设置 wait_for_input:false，再调用 tincall_end。
• tincall_end(call)：沿用同一个 call 短标记，通知手机等已收到的回复播放完成后挂断。手机手动挂断仍立即结束。
• tincall_list_calls(limit?, before?)：列出保存的通话，按结果指引继续翻页，再用 get_call 查看选中的记录。

三、接听、回复与续等
对方要求主动打来时，AI 直接调用 tincall_call()，等接通结果返回后用 tincall_reply 提交问候。发言以 XML 返回：`<message name="小白" timestamp="2026-10-26 18:30:00"><text>你好。</text></message>`。未填写名字时省略 name，timestamp 仅在开启时间感知时提供，使用手机本地时间；图片作为紧随对应消息的原生 MCP image block 返回，不放进 XML 正文。AI 应读取实际图片，并用 text 提交完整回复。

普通 MCP 的工具结果另有一行 `call: XXXXXXXX`。回复、挂断和继续等待时只需带回这个 8 字符标记，不需要 UUID、轮次或游标。它绑定原通话；原通话结束后迟到操作会被拒绝，不要换用新通话的标记重发旧回复或挂断指令。更新服务后，请在平台刷新工具定义或重新连接。

朗读要求在通话开始时提供一次，平台需保留同一对话的上下文并遵循要求。AI 写完全文再调用 tincall_reply。手机打断播放后，后续提交的完整回复仍可正常接收；等待应继续到对方说完并提交新消息。

普通 MCP 的等待时长在联系人页设置，默认 120 秒，可填 1–130 秒，越界会自动调整。没有新消息时，正常超时后继续调用 tincall_wait；这不是整通电话的时长限制。客户端若先报 Request timed out: tools/call，只说明没有取得结果，不能据此判断回复没有发送；不要直接重发正文，可调用 tincall_wait 继续。通话结束后停止等待。

四、平台设置
Kelivo 的 MCP 请求超时默认 30 秒。请在 Kelivo 的 MCP 设置中调至 180 秒，再重新连接 Tincall。通话过程中，Kelivo 需要保持在前台。

Muse 默认等待工具结果 45 秒，需要让 TA 调整调用工具时的等待时间；单次调用达到 120 秒会被转入后台，影响 TA 继续等待。建议将 Tincall 对应联系人的 MCP 等待时长设为 90 秒，并让 Muse 中的 TA 将工具等待时间设为 110 秒。这样 Tincall 会先结束本次等待；即使没有正常返回，Muse 也能在 110 秒时报告超时，让 TA 继续处理，避免拖到 120 秒被转入后台。

Tincall 的回复工具发送完整文字后，会继续等你下一句话；朗读和等待都占用这次请求的时间。Request timed out: tools/call 表示 AI 所在的平台没有及时收到工具结果，不代表回复没有发送，也不代表电话已经挂断。

等待超时不会挂断通话，可以让 TA 继续等待。如果这一轮工具调用已经结束，可以主动发消息唤醒 TA，继续通话。播放停止不会提前结束等待。

更新云端后，在 AI 平台刷新 Tincall 工具列表或断开后重连。

MCP 不能自行唤醒任意闲置平台，也不能强制取消宿主模型的生成；手机拨号需外部平台保持运行或已有可用唤醒桥。工具请求时限和连续调用次数还受平台限制。历史摘要由手机在通话结束后实际生成并提交，没有摘要时不推测其原因。

MCP＋唤醒桥接法

在联系人编辑页的 MCP 模式中选择唤醒桥并保存，复制这位联系人的唤醒桥配置。接入程序负责持续订阅事件、读取完整输入，再启动外部 AI 任务；可使用仓库中的 connector/wake-adapter.mjs，具体配置按 connector/README.md 操作。平台启动命令需续接同一对话，读取 content 中的 XML 发言与紧随其后的原生图片块，保留首次朗读要求，并配置专用 MCP。AI 使用 tincall_reply 提交完整 text 后结束任务，新消息再触发下一次任务，无需调用 wait。仅导入普通 MCP 地址不会自动启动闲置的 AI。

唤醒桥由适配器在任务专用的 MCP 请求头里自动绑定原通话，AI 仍然只提交 text，不需要填写 call。使用其他适配器时，也必须将取到的 `input.call.id` 固定到该任务每次 MCP 请求的 `Tincall-Call-ID` 头，不能换成后来的通话。

后端接法

一、连接与基础格式
自有后端负责人物设定、上下文和真实生成，手机负责收音、识别、朗读和本地记录。后端实现下面的 HTTPS / JSON 通话接口，无需实现 MCP，也不必开启云端备份。手机在「Tincall 云端 → 连接已有服务」保存 HTTPS 基础地址和手机访问令牌、检查连接，再到联系人编辑页选择后端、该连接及对话对象。

以下路径相对于基础地址。手机发送 Authorization: Bearer <手机访问令牌>，JSON 请求带 Content-Type: application/json 和 Accept: application/json；成功响应为 HTTP 200 的 JSON，不依赖重定向。错误返回非成功 HTTP 状态及 {error:{code:"错误代码"}}。写请求按 request_id 去重，相同请求重试返回原结果；同一 ID 不能更改内容。隔离不同访问身份的数据，不让客户端自行声明所有者。

call 对象必须包含 id(UUID)、contact_id(字符串)、source("backend")、status("active"/"ringing"/"ended")、epoch(非负整数)、last_sequence(非负整数)。一个 call_id 对应一通电话，message_id 对应一条输入，reply_id 对应一轮回复，不可混用。

二、发现、开始和接听
GET /capabilities 返回 {bindings:[{contact_id:"联系人标识",display_name:"显示名",generation_configured:true}]}；display_name 可省略，只有标识非空且 generation_configured:true 的对象才可在手机选择。

POST /calls 接收 request_id、call_id、contact_id、source:"backend"、expression_prompt，返回 {call}；新通话为 active、epoch:0，并产生 call.started 事件。GET /calls/current 返回 {call:对象或null}。如支持后端主动来电，已有 ringing 通话由 POST /calls/{call_id}/answer 接收 request_id、epoch、expression_prompt，返回 active 的 {call}，产生 call.started。expression_prompt 为语音表达要求，可为空；后端负责将其用于生成。

三、输入与回复事件
POST /calls/{call_id}/input 接收 request_id、message_id、当前 epoch、text，以及可选 images。每张图片为 {id:"UUID",mime_type:"image/jpeg或image/png",data_base64:"标准Base64"}，最多四张、每张最多 5 MiB，Base64 不带 data URI 前缀。有图时 text 可为空，无图时文字须非空。返回 {call,input_id,reply_id,epoch}：input_id 等于 message_id，epoch 已递增一次。保存输入，取消旧生成，并产生 input.accepted、reply.started 后启动本轮生成。

GET /calls/{call_id}/events?after=N&limit=100&wait=20 返回 {call,events,cursor,has_more}。事件结构为 {sequence,call_id,epoch,type,payload}，sequence 从 1 连续递增。after 默认 0，后续使用上次 cursor；已有事件立即返回，没有则等待新事件或到期返回 events:[]、cursor:N、has_more:false。空页不是挂断；has_more:true 时手机立即续取，不因 call 快照已结束而漏掉尾页。

input.accepted 和 reply.started 的 payload 包含 input_id、reply_id。reply.delta 另带 delta(新增片段)；reply.completed 另带 text(最终全文，包含已发前缀)；reply.failed 另带 code；reply.interrupted 另带 reason。这些事件的通话、输入、回复和 epoch 必须匹配；手机只接收当前代次，旧结果不得覆盖已保存内容。

四、打断与挂断
POST /calls/{call_id}/interrupt 接收 request_id、epoch、reason:"interrupted"，取消生成、递增 epoch，返回保持 active 的 {call}；有未完成回复先产生 reply.interrupted，再产生 call.interrupted。POST /calls/{call_id}/end 接收 request_id、epoch、reason:"hangup"，取消生成、递增 epoch，返回 ended 的 {call}；有未完成回复先产生 reply.interrupted，再产生 call.ended。保留已收到文字与中断原因，拒绝旧代次写入；过期代次用 stale_epoch 错误说明。

reply.completed 只结束一句回复。收到 call.ended 或确认 call.status 为 ended 时，结束这通电话的任务；后端自行决定是否保留或复用模型上下文。若要在挂断后将摘要写回其他对话，应由后端的通话结束流程实现并去重，不能把每句完成、空事件页或网络超时当作挂断。

## 复用连接端的后端接法

上面的 HTTP 接口用于完整自建后端。也可以部署仓库提供的 Node／Supabase 连接端，只实现生成和取消两个入口，由连接端处理手机协议。完整字段、凭据边界与可选能力见 [后端接口](backend_api.md)，运行方式见 [连接端说明](../connector/README.md)。

生成入口可以返回完整 JSON，也可以持续返回 NDJSON 的 delta／completed，实现边生成边合成和播放。MCP 的完整消息工具与后端的流式协议分开。手机会把当前 TTS 的 expression_prompt 交给后端；使用连接端时，每次生成都会携带它，适配器应纳入模型上下文。

仓库的 connector/codex-backend.mjs 是具体的 Codex HTTP 适配器，当前仅返回完整回复，不支持图片和 AI 自主拨挂工具。connector/wake-adapter.mjs 是 MCP 的事件订阅／启动程序，要求平台保留会话并通过专用 MCP 回复；两者不需要同时安装，通用安装器不会自动启动它们。
