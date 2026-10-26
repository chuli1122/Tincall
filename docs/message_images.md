# 连接端图片消息契约

本文适用于 Node 连接端与 Supabase Edge 共用的图片消息和备份协议。实际部署需验证手机提交、存储、平台视觉处理与恢复；源码支持不代表所选模型支持图片。

## 手机提交输入

继续使用 `POST /calls/{call_id}/input`，携带原有 Bearer 鉴权及 `Content-Type: application/json`：

```json
{
  "request_id": "10000000-0000-4000-8000-000000000010",
  "message_id": "10000000-0000-4000-8000-000000000011",
  "epoch": 0,
  "text": "请看这张图片。",
  "images": [
    {
      "id": "10000000-0000-4000-8000-000000000012",
      "mime_type": "image/jpeg",
      "data_base64": "此处填写完整图片文件的标准 Base64"
    }
  ]
}
```

- `images` 是可选数组，每条消息最多四项。每项必须包含 `id`（图片 UUID）、`mime_type` 和 `data_base64`。图片 UUID 应为新生成的独立标识；重试时保持全部标识、文字、图片内容及原 `epoch` 不变。
- `data_base64` 使用标准 Base64 字母表及必要的 `=` 补位，不含换行、空白或 `data:image/...;base64,` 前缀，不使用 Base64URL。
- 每张图片解码后最多 5 MiB（5 × 1024 × 1024 字节）。只接受 `image/jpeg` 与 `image/png`；服务器核对文件标记和声明类型，不进行完整图像解码或尺寸调整。手机按当前约定先生成 JPEG、长边不超过 1568、质量 0.8。
- 当前运行环境没有 HEIC 转码依赖，`image/heic` 明确返回 HTTP 415 / `unsupported_image_type`。手机应先转换为 JPEG；不能转换时提示失败。
- 存在图片时，`text` 可以为空字符串，也可以省略；省略时保存为空字符串，不生成图片描述或替代发言。无图时仍要求原有的非空文字，原请求与回复字段不变。
- 含图片的输入 JSON 总上限为 28 MiB，容纳四张各 5 MiB 文件的 Base64 编码及字段开销；无图 JSON 仍为 8 MiB。反向代理也须允许相应请求大小。

`images` 非数组或超过四项返回 `invalid_images`，重复图片 UUID 返回 `duplicate_image_id`，非法编码返回 `invalid_image_data`，单图超限返回 HTTP 413 / `image_too_large`，声明类型与文件标记不符返回 HTTP 415 / `image_type_mismatch`。同一图片 UUID 已有不同类型、大小或内容时返回 HTTP 409 / `image_conflict`，不会覆盖已有文件。

## 私有存储与读取

图片复用既有私有媒体存储：Supabase 的 `tincall-private` bucket，或 SQLite 配套的私有本地媒体目录。逻辑路径为 `ownerUUID/callUUID/imageUUID`，不会生成公开链接。数据库消息和请求回执只保存引用，不保存 Base64：

```json
{
  "id": "消息 UUID",
  "text": "请看这张图片。",
  "images": [{"id": "图片 UUID", "mime_type": "image/jpeg", "bytes": 123456}]
}
```

`GET /calls/{id}/record` 和 `/inputs` 在所属消息上返回这些引用。账户令牌可通过既有 `GET /records/{call_id}/media/{image_id}` 下载原始文件；角色令牌仍不能访问备份或通用媒体接口，MCP 在核对通话所属联系人后内部读取图片。缺失、读取失败或大小不符会明确返回错误，不会静默退化为无图消息。

媒体文件先写入，再提交消息事务；文件不可变，重试直接比较已存实际内容后复用对象，不计算指纹。网络故障、旧 epoch 或清单版本冲突可能留下未引用的私有对象。此时应先补取当前消息／备份确认结果；确认对象未被引用后，用既有 `DELETE /records/{id}/media/{image_id}` 清理，或随整通备份删除一起清理，不能在结果不明时自动删除可能已提交的文件。

## MCP 工具返回

标准 MCP 模式下，`tincall_get_call` 返回通话状态和已保存的消息；`tincall_wait` 等待下一条消息、接听或挂断事件；`tincall_reply` 发送完整回复，默认随后等待下一条输入。结果中的每条发言以 XML 文字呈现，原生 MCP image block 紧随对应消息，不把图片塞进 XML 正文，也不返回 `structuredContent` 或重复的 JSON 消息快照。

普通 MCP 结果中的 `call` 是 8 字符通话标记，回复、挂断和继续等待时沿用它，防止旧任务串入新通话；不需要 UUID、轮次或旧版游标。唤醒桥由适配器在任务专用请求头里绑定原通话，AI 不填写标记。

下面是包含一张图片的返回示例，实际文字还可能包含通话状态和操作提示：

```json
{
  "content": [
    {"type": "text", "text": "<message name=\"小白\" timestamp=\"2026-10-26 18:30:00\">\n  <text>请看这张图片。</text>\n</message>"},
    {"type": "image", "data": "完整标准 Base64", "mimeType": "image/jpeg"}
  ],
  "isError": false
}
```

name 来自手机个人资料，名字为空时省略；历史中的 AI 发言使用 name="TA"。开启时间感知时，对方消息有 timestamp，格式为手机本地时间 `yyyy-MM-dd HH:mm:ss`。`<text>` 保留原话并转义 XML 特殊字符；纯图片消息为空 `<text>`。未完成／中断／失败消息可带 status、reason 属性。多张图片按原数组顺序紧随所属消息，无图消息不附图片块。所接平台需将原生图片交给具备视觉能力的模型。唤醒桥启动命令的 content 使用同一格式。

图片成功读取后才会推进消息交付位置，读取失败可重试。若回复已经保存、但随后等待或读取下一条输入的图片失败，工具仍返回 `isError:false`，并明确提示“回复已保存，等待下一条消息失败”，要求调用 `tincall_wait` 继续等待；不要重发已保存的回复，也不要自行构造旧版游标参数。其他失败按实际错误提示处理，不能一律视为回复已保存。

## 后端直连请求

连接端向配置的 `generation_url` 发起原有 POST，在有图的每条 `messages[]` 项中增加 `images`：

```json
{
  "version": 1,
  "job_id": "任务 UUID",
  "call_id": "通话 UUID",
  "contact_id": "联系人标识",
  "epoch": 1,
  "input_id": "消息 UUID",
  "reply_id": "回复 UUID",
  "messages": [
    {
      "id": "消息 UUID",
      "role": "user",
      "text": "",
      "status": "complete",
      "interruption_reason": null,
      "images": [{"mime_type": "image/jpeg", "data_base64": "完整标准 Base64"}]
    }
  ]
}
```

使用内联 `mime_type`／`data_base64`，不使用签名 URL：使用者的后端无需持有连接端媒体凭据，也不受链接过期或额外下载可达性影响。当前输入和历史消息的图片都按所属消息转发，便于使用者后端转换成模型要求的多模态结构。代价是 Base64 增大请求体，接收端必须配置合适的请求大小上限。无图消息不新增 `images` 字段；生成、取消、去重及回复事件协议不变。接收端须将图片提交给支持视觉的模型，不能只保存文字。

## 通话备份与云端同步

`POST /records/{record_id}` 的 `record.messages[]` 或既有 `record.call.messages[]` 支持相同的内联图片输入。连接端先保存文件，再把消息的 `images` 替换为 `{id,mime_type,bytes}` 引用并按原 CAS revision 提交清单。读取备份会保留这些消息引用；下载使用原有账户鉴权媒体接口。后续修改清单可直接提交已保存引用，连接端会确认文件可读、类型和大小一致。不接受仅有手机 `relativePath` 的图片项；手机必须上传文件，不能备份本机路径冒充云端图片。

手机按上述格式上传图片，在恢复时下载引用文件。图片随明确提交的消息备份上传；不改变录音单独许可，也不会自动上传未提交的本机记录。只提交文字的旧备份协议不变。

`POST /records/{id}/delete` 先保留墓碑并清空清单；随后复用既有有界媒体清理，删除该命名空间的全部图片和音频，失败时以同一 `request_id` 重试。若该 UUID 同时是连接端的通话 UUID，也清空对应消息的图片引用；文字通话历史继续保留。墓碑存在时拒绝图片上传和媒体下载，旧请求不能重新生成图片。挂断只结束通话，不删除记录或图片。

App 的“清空当前云端备份”使用 `/records/{id}/delete-backup`，需要 `backup_only_deletion: true`：该路径保留通话仍引用的图片及其下载权限，清理其余备份媒体，并拒绝正在进行的同 ID 通话。不能用上面的 `/delete` 代替。

## 数据库升级

SQLite 在打开存储时增量增加可空 `messages.images` 列，保留旧记录。Supabase 图片支持使用 [正式迁移](../supabase/migrations/202610210003_tincall_message_images.sql)，新版 App 的“部署或更新服务”与 CLI `supabase db push` 自动应用。迁移增量添加同一列及仅供 service role 调用的图片命令，在同一事务内复用原有通话锁、代次和幂等处理，并支持真实空文字的图片输入。按旧说明手动执行过图片 SQL 的服务可直接升级，保留已有数据，不需要再手动执行或重建数据库。已有服务需运行部署更新；仅更新手机 App 不会更新云端。

图片与录音共用 `tincall-private` 私有存储桶及所属用户的读写权限，这些由基础迁移自动创建。图片迁移不改动已有录音清单或媒体文件；保留录音、上传录音备份仍由用户分别启用，部署不会自动上传。

部署时应为反向代理和后端设置足够的请求大小上限，并确认所接平台支持 MCP 图片内容或后端图片字段。升级后可发送一张图片，检查对方能否读取；启用备份时，再检查图片的上传与恢复。
