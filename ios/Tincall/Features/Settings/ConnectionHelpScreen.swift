// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

enum TincallAgentPrompt {
    static let text = String(localized: """
    你是 Tincall 的接入助手。先确认对方要用独立模式、普通 MCP、MCP＋唤醒桥还是后端直连，再提供对应步骤。不要把普通模型 API 地址当成 Tincall 服务地址，也不要让对方把令牌贴进聊天。MCP 用于支持 MCP 工具的 AI 平台；后端接法用于自行实现 Tincall 通话接口的服务。

    资料仓库：https://github.com/chuli1122/Tincall
    接入细节和部署说明以仓库中的 README、connector 和文档为准。

    普通 MCP 接法

    一、在 AI 平台配置服务
    先在 Tincall「设置 → Tincall 云端」部署或连接支持 MCP 的服务，再编辑联系人，通话方式选 MCP、选择连接并保存。联系人页直接提供传输方式、URL 和 Authorization 的复制，推荐 HTTP（Streamable HTTP），平台仅支持旧 SSE 时再选 SSE。将 URL 填入平台 MCP 服务地址，将复制的 Authorization 填入同名请求头；地址已完整，不要重复追加 /mcp。Authorization 包含 Bearer 和联系人专用令牌，不要替换为手机令牌或 service-role 密钥。令牌只放私密服务配置，不贴进聊天。

    二、可用工具
    参数及必填项以 tools/list 为准：
    • tincall_call(contact_id?)：向手机发起来电，等待接听后返回，随后可通过 tincall_reply 打招呼。联系人专用凭据无需参数；其他身份按工具定义填写 contact_id。
    • tincall_get_call(call_id?, limit?, before_sequence?)：查看保存的通话文字、图片和当前状态；结束的通话可能另有摘要。按结果指引翻阅更早记录。日常对话使用 tincall_wait。
    • tincall_wait(call?)：等待新消息、接听或挂断，时长使用对应联系人的 MCP 等待设置。沿用本通电话返回的 8 字符 call 标记；仅发现新通话时省略。超时继续调用，不会挂断；播放停止不会让等待提前结束。
    • tincall_reply(call, text, wait_for_input?)：原样带回产生本次任务的 call 短标记，用 text 一次提交完整回复，默认继续等下一句话。告别时设置 wait_for_input:false，再调用 tincall_end。
    • tincall_end(call)：沿用同一个 call 短标记，通知手机等已收到的回复播放完成后挂断。手机手动挂断仍立即结束。
    • tincall_list_calls(limit?, before?)：列出保存的通话，按结果指引继续翻页，再用 get_call 查看选中的记录。

    三、接听、回复与续等
    对方要求主动打来时，AI 直接调用 tincall_call()，等接通结果返回后用 tincall_reply 提交问候。发言以 XML 返回：<message name="小白" timestamp="2026-10-26 18:30:00"><text>你好。</text></message>。未填写名字时省略 name，timestamp 仅在开启时间感知时提供，使用手机本地时间；图片作为紧随对应消息的原生 MCP image block 返回，不放进 XML 正文。AI 应读取实际图片，并用 text 提交完整回复。

    普通 MCP 的工具结果另有一行 call: XXXXXXXX。回复、挂断和继续等待时沿用这个 8 字符标记，不需要 UUID、轮次或游标。标记绑定原通话；原通话结束后迟到操作会被拒绝，不要换用新通话的标记重发旧回复或挂断指令。更新服务后，在平台刷新工具定义或重新连接。

    朗读要求在通话开始时提供一次，平台需保留同一对话的上下文并遵循要求。AI 写完全文再调用 tincall_reply。手机打断播放后，后续提交的完整回复仍可正常接收；等待应继续到对方说完并提交新消息。

    普通 MCP 的等待时长在联系人页设置，默认 120 秒，可填 1–130 秒，越界会自动调整。没有新消息时，按该联系人设置的时长等待，正常超时后继续调用 tincall_wait，整通电话不会因此结束。客户端若先报 Request timed out: tools/call，只说明没有取得结果，不能据此判断回复没有发送；不要重发已提交的正文，调用 tincall_wait 继续。通话结束后停止等待。

    时间感知在联系人「通话偏好」中设置，默认关闭。开启后，MCP 消息的 timestamp 属性表示发送时间，使用手机本地时区。可据此理解消息之间的时间间隔，不必每次提及时间。回复中无需附带时间戳。

    四、平台设置
    Kelivo 的 MCP 请求超时默认 30 秒。请在 Kelivo 的 MCP 设置中调至 180 秒，再重新连接 Tincall。通话过程中，Kelivo 需要保持在前台。

    Muse 默认等待工具结果 45 秒，需要让 TA 调整调用工具时的等待时间；单次调用达到 120 秒会被转入后台，影响 TA 继续等待。建议将 Tincall 对应联系人的 MCP 等待时长设为 90 秒，并让 Muse 中的 TA 将工具等待时间设为 110 秒。这样 Tincall 会先结束本次等待；即使没有正常返回，Muse 也能在 110 秒时报告超时，让 TA 继续处理，避免拖到 120 秒被转入后台。

    Tincall 的回复工具发送完整文字后，会继续等你下一句话；朗读和等待都占用这次请求的时间。Request timed out: tools/call 表示 AI 所在的平台没有及时收到工具结果，不代表回复没有发送，也不代表电话已经挂断。

    等待超时不会挂断通话，可以让 TA 继续等待。如果这一轮工具调用已经结束，可以主动发消息唤醒 TA，继续通话。播放停止不会提前结束等待。

    更新云端后，在 AI 平台刷新 Tincall 工具列表或断开后重连。

    MCP 不能自行唤醒任意闲置平台，也不能强制取消宿主模型的生成；手机拨号需外部平台保持运行或已有可用唤醒桥。工具请求时限和连续调用次数还受平台限制。历史摘要由手机在通话结束后实际生成并提交，没有摘要时不推测其原因。

    MCP＋唤醒桥接法

    在联系人编辑页的 MCP 模式中选择唤醒桥并保存，复制这位联系人的唤醒桥配置。接入程序负责持续订阅事件、读取完整输入，再启动外部 AI 任务；可使用仓库中的 connector/wake-adapter.mjs，具体配置按 connector/README.md 操作。平台启动命令需续接同一对话，读取 content 中的 XML 发言与紧随其后的原生图片块，保留首次朗读要求，并配置专用 MCP。AI 使用 tincall_reply 提交完整 text 后结束任务，新消息再触发下一次任务，无需调用 wait。仅导入普通 MCP 地址不会自动启动闲置的 AI。

    唤醒桥由适配器在任务专用的 MCP 请求头里自动绑定原通话，AI 仍然只提交 text，不需要填写 call。使用其他适配器时，也必须将取到的 input.call.id 固定到该任务每次 MCP 请求的 Tincall-Call-ID 头，不能换成后来的通话。

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

    reply.completed 只结束一句回复。收到 call.ended 或确认 call.status 为 ended 时，结束这通电话的上下文。若要在挂断后将摘要写回其他对话，应由后端的通话结束流程实现并去重，不能把每句完成、空事件页或网络超时当作挂断。
    """)
}

struct ConnectionHelpScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var copied = false
    @State private var copyFeedbackTrigger: Date?
    @State private var showsPrompt = false
    @State private var expandedEntries: Set<Int> = []
    private let sections = [String(localized: "开始使用"), String(localized: "通话操作"), String(localized: "排查问题"), String(localized: "记录与云端")]
    private let entries: [(section: String, title: String, body: String)] = [
        (String(localized: "开始使用"), String(localized: "第一次打电话，按什么顺序配置？"), String(localized: "先用独立模式完成一次通话：\n\n1. 到「API设置」添加聊天模型，填写服务地址、API Key 和模型名称，运行测试。\n\n2. 到「文字转语音」添加声音预设，填写服务凭据、声音 ID 和合成模型，测试能否播放。\n\n3. 到「我的设置 → 语音识别」选择识别服务，完成配置并运行识别测试。Apple 本机识别需等待对应语言模型就绪。\n\n4. 添加联系人，通话方式选「独立模式」，选择刚才的聊天模型和声音，在「对话设定」填写人物与对话要求。\n\n5. 保存联系人并拨号，按系统提示允许麦克风权限，说一句话，确认能看到文字并听到回复。\n\n以上步骤无需部署云端。若要使用 MCP 或自己的后端，先看下方的模式说明，再使用「Agent辅助接入」指令。")),
        (String(localized: "开始使用"), String(localized: "独立模式、MCP、MCP＋唤醒桥、后端直连怎么选？"), String(localized: "独立模式：Tincall 直接连接模型 API，设定与对话由手机管理。日常通话和本地记录无需部署云端。\n\n普通 MCP：外部平台管理 AI，AI 可发起来电并处理 Tincall 发起的通话；从 Tincall 拨出不会自动唤醒外部 AI。AI 回复后默认每次等你的下一句话 120 秒；普通 MCP 可在联系人 MCP 设置中填写 1–130 秒。没有新消息会提示继续等待，不会挂断通话。\n\nMCP＋唤醒桥：仍使用 MCP 通话，但由接通和每轮新输入的事件触发 AI，AI 回复后结束本轮，下次消息再启动，不必持续等待。新版一键部署包含通用桥；在联系人编辑页选择该模式并复制配置。平台须支持 SSE 订阅和任务启动，或运行相应适配程序。普通 MCP 设置不能代替这部分接入。\n\n后端直连：已有聊天后端直接实现 Tincall 通话接口，由它管理设定、上下文和每轮生成，无需 MCP。也可通过一键部署的服务转发到真正的生成与取消接口。\n\n四种方式的识别与朗读均由 Tincall 处理。")),
        (String(localized: "开始使用"), String(localized: "API Key、声音和对话设定分别填在哪里？"), String(localized: "聊天模型与摘要模型在「API设置」管理；声音 ID、合成模型和语音表达提示词在「文字转语音」管理；识别服务在「我的设置」中选择。添加后可被多个联系人复用，不必重复填写。\n\n联系人的名字、头像、通话方式和声音在联系人编辑页设置。独立模式还可选择聊天模型，在「对话设定」填写对方的设定、你的信息、双方关系和对话要求，并选择携带的历史摘要；后端与 MCP 的人物设定、上下文及回复由外部服务管理。\n\n独立模式每轮自动携带语音表达提示词。使用 Tincall 连接端的 MCP 接入时，通话开始时会提供一次朗读要求，AI 平台需保留并遵循。自有后端会在开始通话或接听请求中收到 expression_prompt，是否用于生成需由后端实现。")),
        (String(localized: "通话操作"), String(localized: "怎么用文字或图片继续通话？"), String(localized: "左右滑动通话内容，或在通话内设置中切换「通话／文字」视图。文字视图可以查看完整对话、输入文字，并通过输入框左侧「＋」添加图片；图片能否被理解，取决于所选模型或外部服务是否支持。\n\n输入文字时临时暂停收音，退出输入后恢复；手动关麦状态保持不变。打字本身不会打断回复，发送新内容会中断当前回复并开始下一轮。点击已添加或已发送的图片可放大查看。")),
        (String(localized: "通话操作"), String(localized: "打断、关麦和挂断有什么区别？"), String(localized: "打断：停止当前回复和声音播放，电话保持接通，可以继续说话或输入。\n\n关麦：停止接收你接下来的语音，不结束电话，也不取消对方正在进行的回复。\n\n挂断：停止当前生成和播放，结束电话。已收到的文字仍保留，中断的回复会注明原因。\n\n「允许说话打断」在通话内设置中开启；它需要检测到持续人声并识别出文字，不是任意声音都会触发。未开启时仍可使用手动打断。")),
        (String(localized: "通话操作"), String(localized: "时间感知使用哪里的时间？"), String(localized: "在联系人「通话偏好」中开启「时间感知」，默认关闭。独立模式沿用原有时间上下文；MCP 和后端按手机记录的消息时间和时区提供协议时间标记，补发消息仍保留原来的消息时间，不改成重试时刻。\n\n这只是给 AI 的时间信息，不代表 AI 一定能准确判断现实时间。请先确认手机日期、时间和时区正确；后端或外部平台可能另有自己的时间上下文。\n\n回复中的协议时间标记会在手机显示和朗读前清理，正常对话里的日期与时间不会因此删除。")),
        (String(localized: "排查问题"), String(localized: "后台或定时来电没有响铃"), String(localized: "1. 先到「Tincall 云端」检查服务连接，再到「后台与定时来电」开启「允许后台来电」，确认设备已绑定；绑定失败时查看提示并重试。\n\n2. 后台或锁屏来电还需要支持推送的 App 签名，以及与该签名匹配的推送服务。App Store 版的来电通知发送端由作者维护，用户无需自行配置 Apple 推送凭据，也不另收推送费用；自行签名或自部署的版本需要自己准备匹配的签名和推送服务。免费 Apple ID 自行签名不具备这项能力；仅部署云端不能补上签名能力。\n\n3. 定时计划需已启用，并核对联系人、日期、时间和时区。App 内的计划仅用于独立模式联系人，MCP／后端的来电时间由外部平台安排。\n\n4. 确认手机和服务在线，并检查系统音量、静音与专注模式是否影响提醒。普通 MCP 还需要外部 AI 正在运行；使用唤醒桥时，接入程序也需保持运行。\n\n不开启后台来电，也可在 App 前台接听已配置联系人的来电；连接检查成功不代表推送绑定已经完成。")),
        (String(localized: "排查问题"), String(localized: "回复很慢，应该检查哪里？"), String(localized: "先看慢在什么地方：\n\n说完很久才出现文字：到「我的设置」测试识别服务，检查网络、识别语言和当前输入方式。Whisper 兼容服务会在一段话结束并上传后返回结果。\n\n文字已出现，但对方迟迟没有回复：检查聊天模型或外部平台的请求状态；模型推理、长上下文和平台排队都可能增加等待。普通 MCP 还需确认 AI 正在等新输入。\n\n回复文字已出现，但声音晚到：测试同一声音预设，并查看语音合成请求的耗时或错误。\n\n可在「请求日志」按服务类型查看对应请求，先确认慢在哪一段，再调整该项配置。")),
        (String(localized: "排查问题"), String(localized: "声音断断续续或句间停顿很长"), String(localized: "先区分声音本身卡顿，还是句子之间等待：\n\n1. 在「文字转语音」测试当前声音预设。测试也卡顿时，检查网络、服务额度与合成错误。\n\n2. 测试顺畅、通话中停顿较长时，查看回复文字是否仍在生成，以及后续语音合成是否还在等待。分段朗读需要等待下一段文字和音频到达。\n\n3. 临时切换到 iPhone 扬声器，确认是否只在某副蓝牙耳机上发生。\n\n4. 如果声音总在你说话或环境有声音时停下，检查是否启用了「允许说话打断」，并查看转写结果。\n\n反馈时请说明是整段卡顿、句间停顿，还是突然停止，以及当时的输出设备。")),
        (String(localized: "排查问题"), String(localized: "转写不准，名字总被识别错"), String(localized: "到「我的设置 → 语音识别」用同一句话做识别测试，检查识别语言是否正确，并尽量避开背景音乐、回声与多人同时说话。也可对比已配置的其他识别服务。\n\n名字或专有词反复出错时，可在「高频错词修正」添加原词与替换词；规则尽量具体，避免把正常句子也替换掉。\n\n通话内使用「原声输入」时，字幕由 Apple 本机识别产生，模型收到的是本轮录音；字幕不准不一定表示模型听到的内容也相同。紧急补充或纠正时，可切到文字视图直接发送。")),
        (String(localized: "排查问题"), String(localized: "说话没有打断对方"), String(localized: "在通话内设置中确认已开启「允许说话打断」，麦克风没有关闭，也没有停留在文字输入状态。\n\n说话打断需检测到持续人声并识别出文字。很短的声音、识别失败或识别服务延迟，可能不会立即触发；可先做识别测试。它不识别说话人的身份，背景人声也可能触发。\n\n需要立刻停止时，使用手动打断；发送新的文字或图片也会中断当前回复并开始下一轮。普通 MCP 能否取消外部 AI 的生成，还受所用平台限制。")),
        (String(localized: "排查问题"), String(localized: "说话后没有出现文字"), String(localized: "1. 检查通话页是否关麦、是否正在编辑文字；退出输入后再试。\n\n2. 在 iPhone「设置 → App → Tincall」检查麦克风权限。\n\n3. 回「我的设置 → 语音识别」运行识别测试。Apple 识别需要设备、语言与系统模型可用；讯飞、百炼等服务需要有效凭据、网络和服务额度。\n\n4. 使用 Whisper 兼容服务时，文字会在一段话结束并上传后返回，不会逐字出现。\n\n仍失败时，查看通话页错误提示和「请求日志」中的语音识别请求。")),
        (String(localized: "排查问题"), String(localized: "已经识别出文字，但没有回复"), String(localized: "独立模式：到「API设置」测试所选预设，核对模型名称、服务地址、账户额度，以及模型是否支持当前参数或图片输入。\n\n后端或 MCP：先检查已保存的服务连接。普通 MCP 需允许工具调用，并让 AI 等待通话输入；只复制 MCP 配置不会自动启动 AI。使用 MCP＋唤醒桥时，确认联系人页已复制桥接配置，且 Agent 或接入程序保持事件订阅并能启动 AI 任务；生成与取消接口属于后端接法，不是唤醒订阅。\n\n在「请求日志」中选择聊天模型或连接请求，查看状态和错误码；连接检查通过不等于模型、备份和来电功能都已可用。")),
        (String(localized: "排查问题"), String(localized: "普通 MCP 很快超时，或反复调用工具怎么办？"), String(localized: "Kelivo 的 MCP 请求超时默认 30 秒。请在 Kelivo 的 MCP 设置中调至 180 秒，再重新连接 Tincall。通话过程中，Kelivo 需要保持在前台。\n\nMuse 默认等待工具结果 45 秒，需要让 TA 调整调用工具时的等待时间；单次调用达到 120 秒会被转入后台，影响 TA 继续等待。建议将 Tincall 对应联系人的 MCP 等待时长设为 90 秒，并让 Muse 中的 TA 将工具等待时间设为 110 秒。这样 Tincall 会先结束本次等待；即使没有正常返回，Muse 也能在 110 秒时报告超时，让 TA 继续处理，避免拖到 120 秒被转入后台。\n\nTincall 的回复工具发送完整文字后，会继续等你下一句话；朗读和等待都占用这次请求的时间。Request timed out: tools/call 表示 AI 所在的平台没有及时收到工具结果，不代表回复没有发送，也不代表电话已经挂断。\n\n等待超时不会挂断通话，可以让 TA 继续等待。如果这一轮工具调用已经结束，可以主动发消息唤醒 TA，继续通话。播放停止不会提前结束等待。\n\n更新云端后，在 AI 平台刷新 Tincall 工具列表或断开后重连。")),
        (String(localized: "排查问题"), String(localized: "有回复文字，但听不到声音"), String(localized: "1. 检查 iPhone 音量，并在系统控制中心确认音频输出设备，确认声音没有播放到其他耳机或设备。\n\n2. 到「文字转语音」测试联系人正在使用的声音预设，核对 API Key、声音 ID、合成模型、服务地区和账户额度。\n\n3. 查看通话页的合成错误及「请求日志」中的语音合成请求。\n\n文字生成和声音合成是两项服务；模型回复成功不代表声音已合成。合成失败时，已收到的文字仍会保留。")),
        (String(localized: "排查问题"), String(localized: "外部服务断线后，怎么继续？"), String(localized: "先恢复网络或外部服务，再点通话页的「恢复通话连接」。App 重开后，原始且尚未结束的后端／MCP 通话可从记录恢复，前提是原联系人及连接配置仍然有效。恢复会补取未收到的事件，不会重新播放已有声音。\n\n独立模式记录、备份导入的记录及远端已结束的通话不能这样恢复，需要重新拨号。若错误持续，请检查服务地址、手机访问令牌与服务运行状态。")),
        (String(localized: "记录与云端"), String(localized: "文字、录音和备份分别保存什么？"), String(localized: "通话文字保存在本机，双方录音默认都不保存。可在「本机数据与备份」中分别开启「保存我的声音」和「保存对方声音」；关闭只停止保存后续录音，已有文件仍保留。\n\n本地备份包含联系人、连接配置、个人资料、头像与背景、识别纠错规则、通话文字、消息图片、摘要和已保存录音。API Key 与访问令牌不导出，换设备后需要重新填写。导入字体、通话显示偏好、请求日志和云端的计划／绑定状态不在这份备份中。\n\n云端自动同步通话文字、图片和摘要，录音同步单独开启，不会因为连接服务就自动上传所有内容。删除本机记录不会自动删除云端副本或已导出的文件。清理前先确认需要保留的备份；导出文件和录音包含隐私，请妥善保管。")),
        (String(localized: "记录与云端"), String(localized: "什么时候需要 Tincall 云端？"), String(localized: "使用独立模式日常通话与本地记录时不需要。需要 MCP、外部后端、云端备份或定时来电时，再按所需功能连接服务。\n\n可用自己的 Supabase 项目部署，也可在自己的电脑或服务器运行连接端，或连接已适配 Tincall 的后端。MCP、备份和来电可以共用同一服务，按服务实际能力分别启用，不必重复部署。多位联系人可共用地址，但各自的 MCP 配置应放到对应 AI 的 MCP 设置中。\n\n后台来电还需要设备绑定、支持推送的 App 签名和匹配的推送服务；定时独立模式来电还要设置计划。部署或连接成功本身不代表后台来电已经配置完成。")),
        (String(localized: "记录与云端"), String(localized: "排查问题时，能直接把日志发给别人吗？"), String(localized: "先查看导出内容，再决定分享范围。请求日志可能包含发送给模型的上下文、识别文字、回复、思考内容及错误信息，即使凭据被打码，也可能暴露对话隐私。\n\n建议先按服务类型和失败状态筛选，只分享与问题有关的请求，删除其中的个人信息。不要分享 API Key、手机访问令牌、联系人 MCP 令牌、录音或完整私人备份。"))
    ]

    var body: some View {
        let expandedIndices = expandedEntries
        return ScrollViewReader { proxy in
            SettingsList {
                SettingsField(title: String(localized: "查找问题")) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索帮助", text: $query)
                            .focused($searchFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除搜索")
                        }
                    }
                }
                ForEach(sections, id: \.self) { section in
                    let sectionEntries = filteredEntries.filter { $0.element.section == section }
                    if !sectionEntries.isEmpty {
                        Section {
                            ForEach(sectionEntries, id: \.offset) { index, entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    HelpExpansionRow(isExpanded: Binding(
                                        get: { expandedIndices.contains(index) },
                                        set: { if $0 { expandedEntries.insert(index) } else { expandedEntries.remove(index) } }
                                    )) {
                                        Text(entry.title).fontWeight(.medium)
                                    }
                                    if expandedIndices.contains(index) {
                                        helpText(entry.body)
                                    }
                                }
                            }
                        } header: { SettingsSectionHeading(title: section) }
                    }
                    if searchQuery.isEmpty && section == sections.first {
                        agentSetupSection
                    }
                }
                if filteredEntries.isEmpty {
                    Text("没有找到相关问题，试试服务名称或错误提示中的关键词。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HelpFeedbackSection()
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(SettingsPageStyle(title: String(localized: "帮助与指引"), subtitle: String(localized: "配置步骤、通话操作与常见问题"), symbol: "book", index: "FIELD NOTES",
                                        actionTitle: String(localized: "前往反馈"), actionSymbol: "envelope", onAction: {
                searchFocused = false
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                    proxy.scrollTo("help-feedback", anchor: .top)
                }
            }))
            .onChange(of: query) {
                expandedEntries = searchQuery.isEmpty ? [] : Set(filteredEntries.map(\.offset))
            }
            #if DEBUG
            .onAppear {
                let arguments = ProcessInfo.processInfo.arguments
                showsPrompt = arguments.contains("-TincallHelpExpandPrompt")
                expandedEntries = arguments.contains("-TincallHelpExpandFirstTwo") ? [0, 1] : []
            }
            #endif
        }
    }

    private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var agentSetupSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = TincallAgentPrompt.text
                copied = true
                copyFeedbackTrigger = Date()
            } label: {
                SettingsActionLabel(title: String(localized: "复制给 AI 的指令"), symbol: copied ? "checkmark" : "doc.on.doc",
                                    detail: String(localized: "让 Agent 协助你完成 Tincall 接入配置。"))
            }
            .sensoryFeedback(.success, trigger: copyFeedbackTrigger)
            .preference(key: CopySuccessPreferenceKey.self, value: copyFeedbackTrigger)
            .task(id: copyFeedbackTrigger) {
                guard copyFeedbackTrigger != nil else { return }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                copied = false
            }
            .onDisappear { copied = false }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            VStack(alignment: .leading, spacing: 4) {
                HelpExpansionRow(isExpanded: $showsPrompt) {
                    Text("查看指令全文")
                }
                if showsPrompt {
                    helpText(TincallAgentPrompt.text)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
        } header: { SettingsSectionHeading(title: String(localized: "Agent辅助接入")) }
    }

    private var filteredEntries: [(offset: Int, element: (section: String, title: String, body: String))] {
        Array(entries.enumerated()).filter {
            searchQuery.isEmpty || $0.element.title.localizedStandardContains(searchQuery) || $0.element.body.localizedStandardContains(searchQuery)
        }
    }

    private func helpText(_ text: String) -> some View {
        Text(text).font(.subheadline).lineSpacing(5).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.settingsSurface(), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct HelpExpansionRow<Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: $isExpanded) { label }
        }
    }
}
