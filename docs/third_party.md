# 第三方组件与素材声明

本项目的源码许可只适用于作者有权许可的部分。第三方组件保留自己的版权和许可；不得用本项目的个人使用限制覆盖第三方已经授予的权利。分发相关材料时须保留其版权声明、许可文本，并遵守各自的分发条件。致谢不替代许可证。

## 随 App 使用的组件

| 组件 | 版本／来源 | 许可和保留位置 | 用途 |
| --- | --- | --- | --- |
| ONNX Runtime Swift Package 与 iOS 运行库 | 工程锁定 1.24.2；[Swift 包](https://github.com/microsoft/onnxruntime-swift-package-manager)、[运行库](https://github.com/microsoft/onnxruntime) | MIT 顶层许可；[随库许可](../ios/Tincall/Features/Settings/Licenses/ONNXRuntime-LICENSE.txt)。首次构建由 SPM 下载，不随源码快照复制二进制缓存 | 运行本机 VAD |
| Silero VAD | [v5.1 官方模型](https://github.com/snakers4/silero-vad/blob/v5.1/src/silero_vad/data/silero_vad.onnx)；随库模型内容与官方 v5.1、v5.1.1、v5.1.2 相同，这三个标签共用同一模型 | MIT；[模型目录许可](../ios/Tincall/Voice/Assets/VoiceCallVADAssets/LICENSE) 与 [App 声明](../ios/Tincall/Features/Settings/Licenses/SileroVAD-LICENSE.txt) | 人声活动检测，不用于声纹识别 |
| LAME | 3.100，C 源码来自 [SwiftLAME 0.1.0 的 Sources/LAME](https://github.com/hidden-spectrum/SwiftLAME/tree/0.1.0/Sources/LAME)；未使用其 Swift 包装层 | [LGPL 2.1 原文](../ios/LocalPackages/LAME/LAME-LICENSE.txt)；完整 C 源码与构建说明在 [本地包](../ios/LocalPackages/LAME/README.md)，文件内原声明保留 | 将临时原声模型输入编码成 MP3；工程使用动态库 |

App 关于页提供相关许可入口。源码分发保留 LAME 源码及构建说明；IPA 同时附带对应的 LAME 源码、许可和[库重建与替换步骤](../ios/LocalPackages/LAME/README.md)。打包与配套材料见[发行说明](release.md)，不能只发布动态库而省略这些材料。

随源码和 App 保留 ONNX Runtime 1.24.2 的[完整上游 ThirdPartyNotices](../ios/Tincall/Features/Settings/Licenses/ONNXRuntime-ThirdPartyNotices.txt)，来源为[该版本官方文件](https://github.com/microsoft/onnxruntime/blob/v1.24.2/ThirdPartyNotices.txt)，未翻译或删减；完整清单不表示每个组件均在 iOS 构建中启用。顶层 MIT 许可不替代这些声明。工程未使用 ONNX Runtime Extensions。

## 连接端、运行时与部署工具

- Node 连接端、唤醒适配器、Codex 适配器和 Node APNs 发送端使用 Node 内置模块及本仓库生产模块，没有额外 npm 运行依赖。Codex CLI 是使用者另行安装／认证的外部程序，不随快照分发。
- Supabase Edge 入口只导入仓库共享模块，使用原生 Web API，没有引入 supabase-js 或 MCP SDK。
- Cloudflare Worker 使用平台提供的 Durable Objects 和 Web API；Wrangler 是部署工具，不随库复制其运行环境或账号。
- Node、Docker／基础镜像、cloudflared、Tailscale、ngrok、Supabase CLI、Xcode 和 Apple SDK 各按其自己的许可／服务条款使用。部署脚本不授予对应账号、网络或推送权限。
- Supabase 数据库路径使用 PostgreSQL 以及 pg_cron、pg_net、Vault 等扩展；具体版本由部署环境决定，迁移文件不会将这些服务统一重新许可。

## 模型、声音和系统资源

语音消息发送音效来自 [Kenney Interface Sounds 1.0](https://kenney.nl/assets/interface-sounds) 的 `Audio/drop_002.ogg`，转换为 PCM WAV。素材按 CC0 许可，允许商用、修改和分发，无需署名；[原始许可](../ios/Tincall/Voice/Assets/Sounds/Kenney-Interface-Sounds-LICENSE.txt)随源码与 App 保留。

Apple、讯飞、百炼、Whisper 兼容服务、MiniMax、ElevenLabs、Fish Audio、OpenAI 兼容服务、Anthropic、Gemini 等是接口接入。除上表明确列出的 VAD 外，没有随源码分发这些供应商的模型权重或语音 SDK。模型、音色、音频和账户的使用权限按提供方条款处理。

系统字体与 SF Symbols 由 Apple 平台提供，不属于本项目重新许可的字体资产。项目不附带第三方字体文件。

App 图标由作者使用 ChatGPT 生成，由作者随项目提供；其使用按项目许可的名称与图标条款处理。

## 致谢

感谢 [すみか（@wxynora）](https://github.com/wxynora) 分享 [AI 语音通话优化教程](https://xhslink.cn/o/7FanSmgKZKv)，为 Tincall 的流式朗读与切段优化提供参考。

感谢 [Silero Team](https://github.com/snakers4/silero-vad)、[Microsoft ONNX Runtime 团队](https://github.com/microsoft/onnxruntime)、[The LAME Project](https://lame.sourceforge.net/) 及各项目贡献者，为本机人声检测、模型运行和音频编码提供支持。
