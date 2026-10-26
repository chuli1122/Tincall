# Tincall

[![build](https://github.com/chuli1122/Tincall/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/chuli1122/Tincall/actions/workflows/build.yml) [![release](https://img.shields.io/github/v/release/chuli1122/Tincall)](https://github.com/chuli1122/Tincall/releases/latest) [![iOS 26+](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white)](#) [![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#) [![license](https://img.shields.io/badge/license-Personal%20use-blue)](LICENSE)

[简体中文](README.md) · **English**

<p align="center">
  <img src="docs/images/01-tincall-incoming.png" width="19%" alt="Calls: answer your AI on the iOS system call screen">
  <img src="docs/images/02-your-own-cloud.png" width="19%" alt="Your cloud: deploy to your own Supabase project from the app">
  <img src="docs/images/03-connect-your-ai.png" width="19%" alt="Connect your AI: model API, your own backend, or an MCP platform">
  <img src="docs/images/04-share-during-a-call.png" width="19%" alt="Share during a call: send a screenshot or text with a shortcut">
  <img src="docs/images/05-call-records.png" width="19%" alt="Call records: summaries, transcripts and saved audio">
</p>

Tincall is a native AI voice calling app for iOS 26 and later. It supports direct model connections, your own backend, and MCP (Model Context Protocol), which lets external AI platforms call Tincall's tools. The iPhone handles audio capture, speech service integration, playback, and local call records.

The source is available for personal use, modification, and source sharing under the [license](LICENSE). Source availability does not grant unrestricted open-source rights. Third-party components retain their own licenses; see [third-party notices](docs/third_party.md).

## Choose a call mode

A connector is a service you deploy in your own cloud, on a computer, or on a server to connect the phone to an external AI, relay messages, and manage call state. Click a mode name below for setup steps.

| Mode | Where the AI and context run | What you need | How replies arrive |
| --- | --- | --- | --- |
| [Standalone](docs/setup.en.md#make-a-first-standalone-call) | The iPhone connects directly to your chosen model API | Model, STT, and TTS settings; no connector is needed for everyday calls | Streaming model output, synthesized and played in segments on the phone |
| [Standard MCP](docs/setup.en.md#standard-mcp) | An external AI platform | A Tincall connector, the contact's MCP configuration, and a running AI that can call tools | The AI submits a complete reply with `tincall_reply({call, text})`, copying the returned 8-character call marker, then waits for the next input by default |
| [MCP with a wake bridge](docs/setup.en.md#mcp-with-a-wake-bridge) | An external AI platform | A connector, an event subscriber, a platform task command, and the dedicated MCP configuration | Each event starts a task; the AI submits a complete reply and ends the task, then wakes again for new input |
| [Backend](docs/setup.en.md#backend) | Your own backend | Implement the phone protocol, or reuse the connector and supply generation and cancellation endpoints | Streaming deltas or complete replies, as implemented by your backend |

Contacts have three modes: standalone, MCP, and backend. A wake bridge is one way to connect MCP. Your backend determines the model, persona, memory, tools, and application logic; Tincall does not require a new model session for every call.

Standalone mode supports OpenAI-compatible, Anthropic, and Gemini protocols. STT options include Apple, iFlytek, Alibaba Cloud Bailian, and Whisper-compatible services. TTS options include ElevenLabs, MiniMax, and Fish Audio. Available models, voices, regions, quotas, and fees depend on your chosen provider.

## Source builds and the App Store edition

The default `Tincall` scheme is for personal source builds. Its full core calling functionality does not require a trial or purchase. The `Tincall-AppStore` scheme uses `StoreDebug` / `StoreRelease` configurations and `TINCALL_APP_STORE` to enable the official store edition's trial and one-time unlock flow.

Model, speech, and self-hosting costs depend on their respective providers; purchasing Tincall does not include those third-party services. A source build does not automatically receive access to the publisher's push service. Configure background calls according to the signing and push documentation.

## Get started

1. **Install the iPhone app.** Download `*-selfsign-unsigned.ipa` from the [latest release](https://github.com/chuli1122/Tincall/releases/latest) and follow the [signing guide](docs/setup.en.md#install-a-self-signing-ipa) to re-sign and install it with your own signing credentials, without recompiling. You need an iPhone running iOS 26 or later, and a signing tool that correctly configures the app and extension identifiers and App Group. You can also [build from source](docs/setup.en.md#build-from-source) using a Mac and Xcode.
2. **Configure recognition and speech.** Follow the [first-call setup](docs/setup.en.md#make-a-first-standalone-call) to add STT and TTS settings in the app, including the provider, model, and voice. TTS expression prompts have model-specific defaults and can be edited. Expand Advanced Parameters in an ElevenLabs connection to adjust stability and similarity. Before using each external service connection, review its recipient and data disclosure and explicitly allow data sharing. A changed address or provider requires confirmation again.
3. **Configure a contact.** In standalone mode, select a model and enter a persona. For MCP or backend mode, follow [Connect an external AI](docs/setup.en.md#connect-an-external-ai).
4. **Test a complete call.** Check service and model availability, then verify audio capture, replies, playback, interruption, and hang-up.

Hanging up on the phone immediately stops generation and playback. Interrupting a reply keeps the call connected. When the AI hangs up through MCP, the phone waits for already received replies to finish playing; playback failure also ends the call. Received content is preserved, with interruption reasons recorded where applicable.

If an upgraded or restored configuration has no sharing permission yet, review each required service in its connection settings before calling. Existing permissions survive normal app updates but are not included in configuration backups.

## Connector and included adapters

The repository includes a runnable general-purpose connector. It handles the phone protocol, MCP, call state, message delivery, optional backups, and incoming-call routing. Model generation still requires a real external AI service.

| Component | Purpose | Requirements and limits |
| --- | --- | --- |
| [Node / Supabase connector](connector/README.md) | Reuse the call and storage protocols | Node uses SQLite by default; Supabase uses Edge Functions and a database. Both share production logic and support streaming or complete backend replies |
| [MCP wake adapter](connector/wake-adapter.mjs) | Subscribe to events, read input, and start an external AI command | Configure your platform command, session continuation, and dedicated MCP connection. The AI replies through MCP; command stdout is not used as a reply |
| [Codex HTTP adapter](connector/codex-backend.mjs) | Forward generation and cancellation requests to a local Codex CLI | Requires an installed, authenticated Codex CLI and private adapter configuration. Currently returns complete text replies; images and AI-initiated dialing or hang-up tools are not supported |
| [Push sender](cloudflare/README.md) | Device registration, VoIP incoming calls, and optional Live Activity pushes | Node 24 or a Cloudflare Worker; requires APNs capabilities and credentials that match the app's signing |

The connector installer does not automatically start the adapters or push sender. Standard MCP configuration alone cannot wake an idle AI platform. The current Codex adapter returns complete replies; the Tincall backend protocol itself supports streaming.

Backend mode can use an entirely custom service, or provide only `generation_url` and `cancel_url` to the connector. TTS expression instructions are passed as `expression_prompt`. Implement proactive dialing and hang-up, opening messages, end notifications, and summary write-back as needed. See the [backend documentation](docs/backend_api.md) for responsibilities and formats.

## Deploy a connector

### Your computer or server

Install Node.js LTS. Node 24 is recommended; Node 22.5 is the minimum and must have built-in SQLite available. Run from the source root:

```sh
# macOS / Linux
sh connector/install-local.sh
```

```powershell
# Windows; WSL is not required
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1
```

Docker is also supported. The connector listens on loopback by default. The phone needs a reachable HTTPS address; follow the [computer/server setup guide](docs/setup.en.md#node-on-your-computer-or-server) to configure access through a reverse proxy or tunnel. Enter the HTTPS base address and phone token under “Connect to an existing service” in the app. Keep the computer running. Temporary tunnel addresses may change after restarting.

### Supabase

In the app, open Settings → Tincall Cloud → Deploy or update service, then deploy using your own project and a management token restricted to that project. Save the regular connection after deployment. Adding an MCP contact does not require redeployment. CLI deployment is also available; see the [deployment guide](docs/setup.en.md#supabase-from-a-computer).

Updating the app does not update an existing cloud service. Tincall Cloud in Settings checks the service version. If an update is needed, upgrade through the original deployment method and preserve its tokens and data. Required database migrations are included in the app's deployment flow and CLI deployment; no manual SQL step is needed. See the [deployment guide](docs/setup.en.md#supabase-from-a-computer). The base migration creates the private storage bucket and permissions used by recordings and images. Recording retention and backup must still be enabled separately.

## Optional features and data

- Time Awareness in a contact's Call Preferences lets the AI understand the time between messages. It is off by default and uses the phone's time.
- Call text and summaries can be saved locally. Recording retention is opt-in for each side of the call. Cloud sync, recording backups, and background incoming calls are configured separately.
- Local Data & Backups lets you separately clear recordings, message images, or all call records, with confirmation. This affects only local data; contacts, connection settings, cloud copies, and exported files remain. Image changes that conflict with cloud data require a manual sync choice.
- Saved service, STT, and TTS connections can be deleted from the bottom of their edit screen. One confirmation removes local settings, credentials, and associated selections while preserving contacts, call records, and cloud data. Remote device unbinding runs in the background. An unreachable service does not block local deletion; the app explains that its remote binding may still need cleanup. Other services remain enabled. Wait until an active call or sync finishes before deleting a connection.
- Standalone mode sends requests to your configured model and speech services. MCP and backend modes send call content to the connected platform, which processes it according to its own implementation.
- Credentials are kept in Keychain or the deployer's private configuration and are excluded from ordinary configuration backups. Phone tokens, contact MCP tokens, wake credentials, model credentials, and push credentials serve different purposes.
- Foreground calls use the configured service subscription. Background and locked-screen calls also need matching push entitlements, a device binding and an APNs sender; see the [push setup guide](docs/setup.en.md#configure-background-calls-for-your-signing-team).
- Shortcuts can send text or screenshots to the current call; see [Shortcuts](shortcuts/README.md).

## Code and documentation

The [English setup guide](docs/setup.en.md) covers signing, a first call, connector deployment, MCP/backend setup, push and upgrades. See [release packaging](docs/release.md) for versioning and IPA builds. Detailed protocol references below are primarily in Chinese.

| Path | Contents |
| --- | --- |
| `ios/Tincall/App/` | App entry point, runtime, and system intents |
| `ios/Tincall/Core/` | Model protocols, call coordination, external interfaces, context and summaries, credentials, deployment |
| `ios/Tincall/Voice/` | Audio capture, VAD, STT, TTS, segmentation, playback, and audio routing |
| `ios/Tincall/Features/`, `Storage/` | UI, configuration and records, backups, and cloud sync |
| `ios/TincallCallWidget/`, `ios/TincallCallIntents/` | Live Activity and system calling intent extensions |
| `ios/LocalPackages/` | Bundled third-party components |
| `connector/` | Node entry point, SQLite, adapters, installers, and optional Node push sender |
| `supabase/functions/`, `supabase/migrations/` | Shared connector logic, Edge entry point, and database migrations |
| `cloudflare/` | Optional push Worker |
| `ios/Tests/`, `connector/tests/`, `cloudflare/tests/` | Module and protocol checks |

- [Signing and installation](docs/setup.en.md#install-a-self-signing-ipa)
- [Cloud deployment](docs/setup.en.md#deploy-a-connector-only-if-needed)
- [MCP and backend setup](docs/setup.en.md#connect-an-external-ai)
- [MCP tool parameters and behavior](docs/mcp.md)
- [Backend HTTP protocol](docs/backend_api.md)
- [Image messages](docs/message_images.md)
- [iOS checks and CI coverage](docs/ios_checks.md)
- [Development and testing: environment, commands, and scope](connector/README.md#checks-and-current-limits)
- [Third-party components and assets](docs/third_party.md)

## Feedback

If you encounter a bug or have a suggestion, please contact me through Settings → Help & Guides → Send Feedback in the app. Include what happened, steps to reproduce it, and your app and iOS versions. Hide API keys and private information in screenshots.

## License and acknowledgments

Personal use, modification, and source sharing are permitted under the license. Source redistribution must retain attribution to Chuli (GitHub: chuli1122), the original project link, copyright notices, and the license. Modified versions must identify their changes and unofficial status. Commercial use, distributing installable builds, deploying for others, or providing the original or modified service to others requires authorization under the [license](LICENSE), whether paid or free. Third-party components retain their own licenses.

An IPA provided by the author on the official release page for personal signing may be downloaded, re-signed, and updated for your own use under the license. This does not authorize redistributing the IPA or signing and installing it for others.

The SPDX identifier LicenseRef-Tincall-Personal-Use in source file headers refers to this repository's LICENSE.

Thanks to [すみか (@wxynora)](https://github.com/wxynora) for the [AI voice calling optimization tutorial](https://xhslink.cn/o/7FanSmgKZKv), which informed Tincall's streaming speech and segmentation work.

Thanks to the [Silero Team](https://github.com/snakers4/silero-vad), the [Microsoft ONNX Runtime team](https://github.com/microsoft/onnxruntime), [The LAME Project](https://lame.sourceforge.net/), and their contributors for local voice activity detection, model inference, and audio encoding. See [third-party notices](docs/third_party.md) for component purposes, sources, and license texts. The app's About Tincall screen also includes licenses and acknowledgments.
