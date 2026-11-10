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
    • tincall_call(contact_id?)：向手机发起来电，等到轮到 AI 时返回：由 AI 先开口时返回接听，随后通过 tincall_reply 打招呼；对方先开口时直接返回对方的第一句话。谁先开口由联系人的「接通后首先发言」设置决定。联系人专用凭据无需参数；其他身份按工具定义填写 contact_id。
    • tincall_get_call(call_id?, limit?, before_sequence?)：查看保存的通话文字、图片和当前状态；结束的通话可能另有摘要。按结果指引翻阅更早记录。日常对话使用 tincall_wait。
    • tincall_wait(call?)：等待新消息、接听或挂断，时长使用对应联系人的 MCP 等待设置。沿用本通电话返回的 8 字符 call 标记；仅发现新通话时省略。超时继续调用，不会挂断；播放停止不会让等待提前结束。
    • tincall_reply(call, text, wait_for_input?)：原样带回产生本次任务的 call 短标记，用 text 一次提交完整回复，默认继续等下一句话。告别时设置 wait_for_input:false，再调用 tincall_end。
    • tincall_end(call)：沿用同一个 call 短标记，通知手机等已收到的回复播放完成后挂断。手机手动挂断仍立即结束。
    • tincall_list_calls(limit?, before?)：列出保存的通话，按结果指引继续翻页，再用 get_call 查看选中的记录。

    三、接听、回复与续等
    对方要求主动打来时，AI 直接调用 tincall_call()，返回接听时用 tincall_reply 提交问候，返回对方发言时直接回复。发言以 XML 返回：<message name="小白" timestamp="2026-10-26 18:30:00"><text>你好。</text></message>。未填写名字时省略 name，timestamp 仅在开启时间感知时提供，使用手机本地时间；图片作为紧随对应消息的原生 MCP image block 返回，不放进 XML 正文。AI 应读取实际图片，并用 text 提交完整回复。

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
    @State private var copied = false
    @State private var copyFeedbackTrigger: Date?
    @State private var showsPrompt = false
    @State private var expandedEntries: Set<Int> = []
    private let sections = [String(localized: "开始使用"), String(localized: "通话操作"), String(localized: "排查问题"), String(localized: "记录与云端")]
    private let entries: [(section: String, title: String, body: String)] = [
        (String(localized: "开始使用"), String(localized: "第一次用，按什么顺序配置？"), String(localized: "先把要用的服务配好，再开始试用：\n\n1. 「API设置」添加聊天模型：填服务地址、API Key 和模型名，点测试。\n2. 「文字转语音」添加声音：填凭据、声音 ID 和合成模型，试听一下。\n3. 「我的设置 → 语音识别」选识别服务并测试。用 Apple 本机识别，要等语言模型下载好。\n4. 添加联系人：选通话方式、聊天模型和声音，在「对话设定」里写人设和对话要求。\n\n要用 MCP 或自己的后端，先到「Tincall 云端」部署或连接服务，再把联系人的通话方式改成对应模式。\n\n这些配置都不需要先开始试用。都弄好以后，商店版再到「试用与解锁」开始 7 天试用，打第一通电话；系统问麦克风权限时选允许。")),
        (String(localized: "开始使用"), String(localized: "独立模式、MCP、MCP＋唤醒桥、后端直连怎么选？"), String(localized: "独立模式：Tincall 直接调用模型 API，人设和聊天记录都在手机上。最简单，不用部署云端。\n\n普通 MCP：AI 在别的平台里，通过 MCP 工具和你通话。AI 可以主动给你打电话；你打给 AI 时，Tincall 叫不醒 TA，需要 TA 那边已经在运行、等着接。AI 回完一句后会等你下一句，默认等 120 秒，可以在联系人里改成 1–130 秒；没等到会提示继续等，不会挂断。\n\nMCP＋唤醒桥：也是 MCP，但你每说一句都会自动叫醒 AI，回完这句就结束，不用一直挂着等。需要平台支持订阅事件和启动任务，或者自己运行适配程序。在联系人编辑页选这个模式，复制配置即可。\n\n后端直连：你已经有自己的聊天后端，让它直接实现 Tincall 的通话接口，人设、上下文和生成都由后端负责。\n\n不管哪种方式，语音识别和朗读都由 Tincall 来做。")),
        (String(localized: "开始使用"), String(localized: "API Key、声音和对话设定分别填在哪里？"), String(localized: "• 聊天模型、摘要模型：「API设置」\n• 声音 ID、合成模型、语音表达提示词：「文字转语音」\n• 语音识别：「我的设置」\n\n这些添加一次，多个联系人都能选用。\n\n联系人的名字、头像、通话方式和声音，在联系人编辑页里设置。独立模式还能选聊天模型，在「对话设定」里写对方的人设、你的信息、你们的关系和对话要求，并选择带上哪些历史摘要。用 MCP 或后端时，人设和上下文由那边管理。\n\n语音表达提示词是让 AI 写出适合朗读的文字：独立模式每轮自动带上；MCP 在通话开始时给一次，需要平台记住；自己的后端会在请求里收到 expression_prompt，用不用由后端决定。")),
        (String(localized: "通话操作"), String(localized: "怎么用文字或图片继续通话？"), String(localized: "通话中左右滑动，或在通话内设置里切到「文字」视图，就能看完整对话、打字，点输入框左边的「＋」发图片。图片能不能看懂，要看所用的模型或平台支不支持。\n\n打字时会暂时停止收音，退出输入后恢复；如果你手动关了麦，会保持关闭。光打字不会打断对方，点发送才会打断当前回复、开始新一轮。点图片可以放大看。")),
        (String(localized: "通话操作"), String(localized: "接通后谁先说话？"), String(localized: "在联系人「通话偏好 → 接通后首先发言」中设置，打出和打来都适用。\n\n对方先发言：接通后对方直接开口。\n\n我先发言：等你说第一句或发送文字后，对方再回复。\n\n静默后由对方发言：接通后等待设定的秒数（1–10 秒），期间没人说话就由对方开口；你在这段时间开口或输入文字，就由你先说，说完不会再额外等待。\n\n普通 MCP 由你打出时无法唤醒对方，接通后请你先发言。")),
        (String(localized: "通话操作"), String(localized: "打断、关麦和挂断有什么区别？"), String(localized: "• 打断：让对方停下正在说的这句，电话不挂，你可以接着说或打字。\n• 关麦：你说的话不再被收进去，电话不挂，对方正在说的也不受影响。\n• 挂断：停止生成和播放，结束电话。已经收到的文字会保留，被打断的那句会注明原因。\n\n想开口就能打断对方，要在通话内设置里开「允许说话打断」。它要听到持续的人声、并识别出文字才会触发，咳嗽或杂音一般不会。没开的话，也可以手动点打断。")),
        (String(localized: "通话操作"), String(localized: "时间感知使用哪里的时间？"), String(localized: "在联系人「通话偏好」里开「时间感知」，默认关闭。开了以后，AI 会知道每条消息是什么时候发的，用的是手机的日期、时间和时区，所以先确认手机时间没错。补发的消息会保留原来的发送时间。\n\n这只是告诉 AI 时间，不保证 TA 一定说得准；外部平台或后端可能还有自己的时间信息。发给 AI 的时间标记不会显示，也不会被读出来，你们聊天里正常提到的日期时间不受影响。")),
        (String(localized: "排查问题"), String(localized: "后台或定时来电没有响铃"), String(localized: "按顺序检查：\n\n1. 「Tincall 云端」里服务连接正常；「后台与定时来电」里开了「允许后台来电」，并且设备已绑定。绑定失败会有提示，照着重试。\n2. 锁屏或后台响铃需要推送。App Store 版的推送由作者提供，不用配置；自己签名或自己部署的版本，要自己准备支持推送的签名和推送服务，免费 Apple ID 签名无法推送。\n3. 定时来电：计划要开着，再核对联系人、日期、时间和时区。App 里的计划只用于独立模式联系人；MCP 和后端什么时候打来，由外部平台决定。\n4. 手机和服务都在线；看看音量、静音和专注模式有没有挡住来电。普通 MCP 需要 AI 正在运行；用唤醒桥时，接入程序也要一直开着。\n\n不开后台来电，App 在前台时也能接到来电。另外，连接检查成功不代表推送已经绑好。")),
        (String(localized: "排查问题"), String(localized: "回复很慢，应该检查哪里？"), String(localized: "先看慢在哪一步：\n\n• 说完很久才出字：到「我的设置」测试识别服务，看网络和识别语言。Whisper 兼容服务要等一整段说完、上传后才出结果。\n• 字出来了，对方很久才回：看聊天模型或外部平台。模型思考、上下文太长、平台排队都会变慢。普通 MCP 还要确认 AI 正在等你说话。\n• 文字出来了，声音晚到：试听一下这个声音，看语音合成花了多久、有没有报错。\n\n「请求日志」里可以按服务类型看每个请求花了多久，先找到慢的那一步再去调。")),
        (String(localized: "排查问题"), String(localized: "声音断断续续或句间停顿很长"), String(localized: "1. 在「文字转语音」试听这个声音。试听也卡，就是网络、额度或合成服务的问题。\n2. 试听正常、通话里停顿长：一般是在等下一段文字生成，或等下一段语音合成。\n3. 换成手机扬声器试试，看是不是只有某个蓝牙耳机会这样。\n4. 如果总在你说话或周围有声音时停下，可能是开了「允许说话打断」，看看转写里有没有识别出东西。\n\n反馈时请说明是整段卡、句子之间停，还是突然断掉，以及当时用的是扬声器还是耳机。")),
        (String(localized: "排查问题"), String(localized: "转写不准，名字总被识别错"), String(localized: "到「我的设置 → 语音识别」用同一句话测试，确认识别语言选对了，尽量避开背景音乐、回声和多人同时说话。也可以换别的识别服务对比。\n\n名字或专有词总是错，可以在「高频错词修正」里加一条「错的词 → 正确的词」。写具体一点，免得把正常的词也换掉。\n\n用「原声输入」时，屏幕上的字幕是 Apple 本机识别的，模型收到的是你的原始录音，所以字幕错了不代表模型也听错了。要紧急纠正，可以切到文字视图直接发。")),
        (String(localized: "排查问题"), String(localized: "说话没有打断对方"), String(localized: "先确认三件事：通话内设置里开了「允许说话打断」；麦克风没关；没有停在打字状态。\n\n说话打断要听到持续的人声并识别出文字才会触发，太短的声音、或识别比较慢时，可能不会马上生效，可以先做一次识别测试。它分不出是谁在说话，旁边有人说话也可能触发。\n\n要马上停，就手动点打断；发新的文字或图片也会打断。普通 MCP 能不能真正停下 AI 的生成，还要看平台支不支持。")),
        (String(localized: "排查问题"), String(localized: "说话后没有出现文字"), String(localized: "1. 看看通话页是不是关了麦，或者正在打字；退出输入再试。\n2. 到 iPhone「设置 → App → Tincall」确认允许了麦克风。\n3. 回「我的设置 → 语音识别」测试一下。Apple 识别要设备和语言模型可用；讯飞、百炼等要凭据有效、有网络、有额度。\n4. 用 Whisper 兼容服务时，要说完一段、上传以后才出字，不会逐字出现。\n\n还不行的话，看通话页的错误提示和「请求日志」里的语音识别请求。")),
        (String(localized: "排查问题"), String(localized: "已经识别出文字，但没有回复"), String(localized: "独立模式：到「API设置」测试这个模型预设，核对模型名、服务地址、余额，以及模型支不支持当前参数或图片。\n\nMCP 或后端：先在连接设置里检查服务。普通 MCP 要允许 AI 调用工具，并且 AI 正在等你说话——只把 MCP 配置填进平台，AI 不会自己开始。用唤醒桥时，确认复制了桥接配置，接入程序在运行、能启动 AI。\n\n「请求日志」里可以看聊天模型或连接请求的状态和错误码。连接检查通过，不代表模型、备份、来电都已经能用。")),
        (String(localized: "排查问题"), String(localized: "普通 MCP 很快超时，或反复调用工具怎么办？"), String(localized: "Kelivo：MCP 请求超时默认 30 秒，到 Kelivo 的 MCP 设置里改成 180 秒，再重新连接 Tincall。通话时 Kelivo 要保持在前台。\n\nMuse：等工具结果默认 45 秒，单次超过 120 秒会被转到后台。建议把 Tincall 里这个联系人的 MCP 等待时长设为 90 秒，再让 Muse 里的 TA 把工具等待时间设为 110 秒。这样 Tincall 会先结束这次等待，不会拖到被转后台。\n\nTincall 的回复工具发完文字后会继续等你下一句，朗读和等待都算在这一次请求里。看到「Request timed out: tools/call」只是平台没及时拿到结果，不代表回复没发出去，也不代表电话挂了。\n\n等待超时不会挂断电话，让 TA 继续等就行；如果这轮工具调用已经结束，给 TA 发条消息就能接着聊。更新云端后，记得在 AI 平台刷新 Tincall 的工具列表，或者断开重连。")),
        (String(localized: "排查问题"), String(localized: "有回复文字，但听不到声音"), String(localized: "1. 看看手机音量，在控制中心确认声音没有跑到别的耳机或设备上。\n2. 到「文字转语音」试听这个联系人用的声音，核对 API Key、声音 ID、合成模型、地区和余额。\n3. 看通话页的合成错误，和「请求日志」里的语音合成请求。\n\n生成文字和合成声音是两个服务，有文字不代表声音也成功了。合成失败时文字照样保留。")),
        (String(localized: "排查问题"), String(localized: "外部服务断线后，怎么继续？"), String(localized: "先把网络或外部服务恢复，再点通话页的「恢复通话连接」。\n\nApp 重开后，还没结束的后端／MCP 通话可以从记录里恢复，前提是原联系人和连接配置还在。恢复时会补上没收到的内容，已经播过的声音不会重播。\n\n独立模式的通话、从备份导入的记录、已经结束的通话不能这样恢复，需要重新拨打。一直报错的话，检查服务地址、手机访问令牌和服务是否在运行。")),
        (String(localized: "记录与云端"), String(localized: "文字、录音和备份分别保存什么？"), String(localized: "• 通话文字：保存在手机上。\n• 录音：默认不保存。要保存，到「本机数据与备份」里分别打开「保存我的声音」和「保存对方声音」。关掉只是不再录以后的，已有的不会删。\n• 导出备份：包含联系人、连接配置、个人资料、头像和背景、错词修正、通话文字、图片、摘要和已保存的录音。不包含 API Key 和访问令牌，换手机后要重新填；导入的字体、显示偏好、请求日志、云端的来电计划和绑定也不在里面。\n• 云端同步：自动同步文字、图片和摘要，录音要另外打开。删除手机上的记录，不会删掉云端副本和导出的文件。\n\n在「云端同步 → 云端记录」可以看每通电话的云端内容，单独删除云端录音或图片，或者删除整通；「清理云端数据」可以一次清空全部云端录音、图片或备份。这些都只删云端，手机上的记录保留，之后同步也不会再传上去。\n\n导出文件和录音都是隐私，请保管好。")),
        (String(localized: "记录与云端"), String(localized: "什么时候需要 Tincall 云端？"), String(localized: "只用独立模式打电话、记录存在手机上，就不需要。要用 MCP、外部后端、云端备份或定时来电时才需要。\n\n可以用自己的 Supabase 项目一键部署，也可以在自己的电脑或服务器上运行，或者连接已经适配 Tincall 的后端。MCP、备份和来电可以共用同一个服务，不用重复部署。多个联系人可以共用一个服务地址，但每个联系人的 MCP 配置要分别填到对应 AI 那边。\n\n后台来电还需要绑定设备和推送，定时来电还要设计划；部署成功不等于来电已经设置好。\n\nSupabase 免费项目一段时间没有访问会被暂停。开了「云端同步 → 自动同步通话内容」以后，每次打开 App 或回到前台都会同步一次，经常用就不会被暂停。另外可以在 iPhone「设置 → 通用 → 后台 App 刷新」里打开 Tincall，系统会不定期让 Tincall 在后台访问一次服务；时间由系统决定，手动划掉 App 后不会运行，所以不能保证一定不被暂停。")),
        (String(localized: "记录与云端"), String(localized: "排查问题时，能直接把日志发给别人吗？"), String(localized: "先看看导出的内容再决定。请求日志里可能有发给模型的上下文、识别文字、回复、思考内容和错误信息，就算凭据打了码，也可能暴露聊天内容。\n\n建议按服务类型和失败状态筛一下，只发和问题有关的几条，并删掉个人信息。不要发 API Key、手机访问令牌、联系人 MCP 令牌、录音或完整备份。")),
    ]

    var body: some View {
        let expandedIndices = expandedEntries
        return ScrollViewReader { proxy in
            SettingsList {
                SettingsField(title: String(localized: "查找问题")) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        SettingsTextField(placeholder: String(localized: "搜索帮助"), text: $query, returnKey: .search, plain: true)
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
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
