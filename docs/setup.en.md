# Install and configure Tincall

[中文自签指南](SELF_SIGN.md) · [中文云端指南](cloud_setup.md) · [中文推送指南](../cloudflare/README.md)

## Choose what you need

Tincall requires an iPhone running iOS 26 or later. The source edition does not require a trial or purchase. You supply your own model and speech-service accounts; their fees are separate from Tincall.

| Mode | What you configure | Is a connector needed? |
| --- | --- | --- |
| Standalone | Model API, speech recognition and speech synthesis | No, unless you also want cloud sync or scheduled/background calls |
| Standard MCP | An external AI platform, a connector and a contact's MCP URL and Authorization header | Yes; the AI must already be running and using the tools |
| MCP with wake bridge | The above plus an event subscriber that can start a task on your AI platform | Yes; adding an MCP URL alone does not wake an idle AI |
| Backend | A service implementing Tincall's backend protocol, or a connector with real generation and cancellation endpoints | A custom backend can implement the protocol directly |

## Install a self-signing IPA

Download `*-selfsign-unsigned.ipa` from Assets on the [latest release page](https://github.com/chuli1122/Tincall/releases/latest), then re-sign and install it using your own signing method. An IPA does not authorize arbitrary devices to install it. Re-signing normally avoids recompiling, but the signing tool must correctly handle:

- The main app, embedded frameworks, Live Activity extension and Call Intents extension, with matching profiles and entitlements. The main app requires its Siri and calling-app capabilities as well as any enabled push capability.
- Unique bundle IDs for `Tincall`, `TincallCallWidget` and `TincallCallIntents`. Each extension ID must start with the main app ID followed by a dot, for example `com.yourname.tincall.CallWidget` and `com.yourname.tincall.callintents`.
- The same authorized App Group in the main app and widget, their signing entitlements, and both packages' **resolved** `Info.plist` field `TincallAppGroupIdentifier`. The Call Intents extension does not use this group. Changing an xcconfig cannot change an already compiled IPA.
- `aps-environment` authorized by the main app's profile, if you need background calls.

If your tool cannot preserve these settings, build from source. A free Personal Team cannot provide the APNs capabilities needed for background calls. Do not assume deleting App Group entitlements preserves widgets and shared state. Signing duration and supported capabilities depend on your account and tool.

For updates, keep the same signing identity, bundle IDs and shared group; back up important data and install over the previous version instead of uninstalling it. Do not redistribute original or re-signed packages or provide signing/install services without authorization. Sharing the official release link is allowed by the project license.

## Build from source

1. On a Mac, install Xcode with the iOS 26 SDK or later and support for your device's current OS. Open `ios/Tincall.xcodeproj` and select the **Tincall** scheme. The App Store scheme has a separate trial/purchase flow.
2. For all three targets—`Tincall`, `TincallCallWidget` and `TincallCallIntents`—choose your Team and unique bundle IDs in Signing & Capabilities. Check the configurations you will build and keep their version/build numbers aligned. Do not override all targets with one global `PRODUCT_BUNDLE_IDENTIFIER` command argument.
3. Set your shared group in `ios/TincallCallWidget/CallActivityAppGroup.xcconfig`, under `TINCALL_APP_GROUP_IDENTIFIER`. The main app and widget entitlements reference this variable. Authorize the same group for those two app IDs and retain the resolved `TincallAppGroupIdentifier` in both packages. The Call Intents extension has no separate entitlements file and does not use the group.
4. The shared configuration enables push by default: development for Debug, production for Release. A team without push must locally set `TINCALL_PUSH_ENTITLEMENTS` to `Tincall/Resources/Tincall.entitlements` and ensure the final signature has no `aps-environment`. Do not enable background calls in this case. App Group support must also be checked separately.
5. Connect and trust your iPhone, enable Developer Mode, select it in Xcode and Run. Complete any device trust prompts. Configure your own services in the app.

The project resolves ONNX Runtime 1.24.2 through Swift Package Manager and includes LAME source. Notices are retained in the source and app. To create an unsigned IPA with matching library materials, see [release packaging](release.md).

## Make a first standalone call

In Settings, configure a model connection using its real model ID, API endpoint and credential. Configure speech recognition, such as Apple on-device recognition, and a speech-synthesis connection with a supported model and voice. Apple recognition may need to download a system language model first.

In each external connection’s settings, review the recipient and data disclosure and enable data sharing before testing or calling. Permission is stored locally, outside Tincall configuration backups; changing the destination or provider requires permission again. Apple on-device recognition does not need third-party sharing permission.

Create a contact, select Standalone mode and the saved connections, then place a call. Check microphone input, transcription, model replies, speech playback, interruption, hang-up and saved records.

## Deploy a connector, only if needed

### Supabase from the app

1. Create a project in your own Supabase organization and wait for it to be ready. The Free plan can be a starting point; check its limits, billing and inactivity rules. Keep the database password privately; do not enter it in Tincall.
2. In account settings, create a scoped Personal Access Token restricted to that project with the access needed to deploy. Do not use an unrestricted organization token, a project anon/publishable key, or a service-role key as the deployment token.
3. Open Settings → Tincall Cloud → Deploy or update service. Enter the project URL/reference and management token, then start deployment. The app applies migrations, creates private storage, deploys the function, configures worker scheduling and saves the regular phone connection. App Store build 11 and later also enroll the official incoming-call push service when no sender is configured.
4. Choose the next feature. Sync is under Tincall Cloud → Cloud Sync; MCP is configured on a contact; background calls are under Background & Scheduled Calls. Deployment does not enable these features or enable background calls. A self-signed/source build still needs its own matching sender; the Store build uses the official sender after enrollment.

The management token is not persisted and may be revoked after deployment. Regular phone/worker credentials and deployment records are kept separately. If deployment fails, retry on the original phone: existing resources are preserved. If the project has another installation but this phone has no matching deployment record, connect to the existing service instead of initializing over it.

### Node on your computer or server

Install Node.js LTS with built-in SQLite, at least 22.5; Node 24 is recommended. From the source root:

```sh
sh connector/install-local.sh
```

On Windows, WSL is not required:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File connector\install-local.ps1
```

The installer creates/reuses private phone and worker tokens, prepares storage and starts the service. It does not install Node or Docker. Docker is another supported deployment option. The service listens on loopback by default; expose it to your phone through your own HTTPS reverse proxy or the documented tunnel option. Keep the computer awake and online. Temporary tunnel URLs can change after restart. See the [connector reference](../connector/README.md#deploy-on-your-own-computer-or-server).

### Supabase from a computer

Install and authorize the Supabase CLI. Create an Auth user in the project and keep its UUID. Copy `connector/env.example` to a private file outside the repository, and set at least:

```dotenv
TINCALL_CLIENTS=[{"token":"REPLACE_WITH_PRIVATE_RANDOM_PHONE_TOKEN","owner_id":"AUTH_USER_UUID"}]
TINCALL_WORKER_TOKEN=REPLACE_WITH_DIFFERENT_RANDOM_WORKER_TOKEN
TINCALL_BINDINGS=[]
TINCALL_ALLOWED_ORIGINS=[]
```

Run `sh connector/deploy.sh YOUR_PROJECT_REF /absolute/private/secrets.env` from the source root. It applies migrations and deploys the function. A phone token used for backups must not be restricted to one `contact_id`. Never use a service-role, worker or management token as the phone token. Supabase provides its reserved `SUPABASE_*` variables; do not replace them with example values.

In the app, Connect to an existing service uses `https://PROJECT_REF.supabase.co/functions/v1/tincall` and the regular phone token. Do not add `/mcp` to this connection URL.

## Sync and backups

Select and check the service in Cloud Sync. Enable automatic content sync or use Sync Now. Recordings require separate recording retention and recording-sync permission; both are opt-in. Contacts and settings stay local. Leaving or suspending the app does not guarantee continued sync.

Conflicting text or recordings require an explicit choice. Deleting local data does not automatically delete cloud copies or exported backups. The app's Clear current cloud backup action preserves local data, MCP call data and schedules; it requires a current service supporting backup-only deletion. Do not empty database tables manually to imitate this action.

Local backup folders contain contacts, connection settings, pictures, text, summaries and retained recordings, but **exclude API keys and access tokens**. Re-enter credentials after moving to another device. Review any exported recordings, conversations or logs before sharing them.

## Connect an external AI

### Standard MCP

For Standard MCP, save a contact using MCP mode and your service. Copy its MCP URL and Authorization header into the external AI platform. HTTP uses `/mcp`; legacy SSE uses `/mcp/sse` and needs reconnect/Last-Event-ID support. A normal model API endpoint is not a Tincall backend or MCP service.

The AI submits each complete reply with `tincall_reply({call, text})`. Copy the 8-character `call` marker returned with the input for that task, and use the same marker for `tincall_end({call})` and `tincall_wait({call})`. No UUID, epoch or cursor is required. Never substitute a newer marker to retry an old reply or hang-up. Refresh the platform's tool definitions after updating the service and migrations. The contact's MCP wait duration defaults to 120 seconds and accepts 1–130 seconds; out-of-range entries in the app are adjusted automatically. Set the platform's tool timeout longer than that wait, allowing time to return the result. Continue waiting after a normal timeout; it does not end the call or prove that a reply was not sent, so do not blindly resend it.

Messages arrive as XML, for example `<message name="Alex" timestamp="2026-10-26 18:30:00"><text>Hello.</text></message>`. A blank name is omitted. Time awareness adds the phone's local timestamp to incoming messages. Native MCP image blocks follow their message directly.

Kelivo defaults to a 30-second MCP request timeout: change it to 180 seconds, reconnect Tincall and keep Kelivo in the foreground throughout the call.

Muse waits 45 seconds for tool results by default and moves the tool invocation to the background at 120 seconds. For Muse, set the Tincall contact's MCP wait to 90 seconds and ask the AI in Muse to set its tool wait to 110 seconds. Tincall can then return first; if it does not, Muse can report its timeout before moving the invocation to the background.

### MCP with a wake bridge

For a wake bridge, copy the contact's version-2 bridge JSON and run `connector/wake-adapter.mjs` on a computer/server with an actual command that can start the external AI task. The adapter subscribes outside the model task, reads input and resumes the contact's conversation. Adding the URL alone does not provide that task-starting capability. Keep bridge credentials private. See the [agent integration guide](agent_prompt.md).

Bridge mode keeps `tincall_reply({text})`: the adapter binds the original call through a task-specific `Tincall-Call-ID` MCP header, so the AI does not copy a marker. Custom adapters must preserve that header for every request in the task. Failed tasks recheck their target before retrying, with at most three attempts and a three-minute total limit; a new call releases the old task.

### Backend

For Backend mode, implement the [backend protocol](backend_api.md), or configure real HTTPS `generation_url` and `cancel_url` endpoints through the connector. The backend manages its model and conversation; Tincall handles phone-side speech. `expression_prompt` carries TTS expression guidance. The supplied Codex adapter returns complete text, has no image support and does not automatically implement autonomous AI dialing tools.

### Ending calls and testing

An AI's `tincall_end` waits for already-received speech to finish playing; a manual hang-up stops immediately. Ordinary interruption stops the current generation/playback while retaining the call. Test these with your actual platform and voice configuration.

## Configure background calls for your signing team

Foreground incoming calls can work without APNs if the configured service subscription is connected. Background or locked-screen calls additionally need matching Apple capabilities, an APNs sender and a device binding.

1. Register explicit main/extension App IDs in a team with push capability, authorize their shared group, and create matching profiles. The final main app profile and signature must contain `aps-environment`.
2. Create an APNs authentication key permitted for the required topics and environment. Keep its `.p8` on the sender only. A signing certificate alone does not grant APNs sending access.
3. Use the **final re-signed main bundle ID**, for example `com.yourname.tincall`. The VoIP topic is `com.yourname.tincall.voip`; the optional Live Activity topic is `com.yourname.tincall.push-type.liveactivity`. Development means sandbox; production means production. Rebind after changing team, ID or environment.
4. For a self-signed/source build, deploy one sender: Node 24 with outbound HTTP/2, or a Cloudflare Worker. That connector's Supabase deployment does not create this sender. App Store build 11 and later use the official sender enrolled by the app; the publisher's sender is not authorized for personal signatures.

### Node sender

Create a private env file outside the repository:

```dotenv
PORT=8788
TINCALL_APNS_TEAM_ID=YOUR_TEAM_ID
TINCALL_APNS_KEY_ID=YOUR_KEY_ID
TINCALL_APNS_KEY_FILE=/absolute/private/AuthKey_YOUR_KEY_ID.p8
TINCALL_APNS_TOPIC=com.yourname.tincall.voip
TINCALL_APNS_DATABASE=/absolute/private/tincall-apns.sqlite
TINCALL_PUSH_TOKEN=REPLACE_WITH_RANDOM_SERVICE_TOKEN_AT_LEAST_24_CHARACTERS
```

Run `node --env-file=/absolute/private/apns.env connector/apns-server.mjs`. Put an HTTPS reverse proxy in front of its loopback listener, persist its device database and keep it running. If another service such as the Codex adapter uses port 8788, change one port. This sender reads `TINCALL_APNS_*`, not the Worker's `APNS_*` secrets.

### Cloudflare sender

In `cloudflare/wrangler.jsonc`, change the Worker name and `vars.APNS_TOPIC` to your own. Authorize Wrangler with your account, then run:

```sh
npx wrangler deploy --config cloudflare/wrangler.jsonc
npx wrangler secret put APNS_TEAM_ID --config cloudflare/wrangler.jsonc
npx wrangler secret put APNS_SANDBOX_KEY_ID --config cloudflare/wrangler.jsonc
npx wrangler secret put APNS_SANDBOX_KEY_P8 --config cloudflare/wrangler.jsonc < /absolute/private/AuthKey_SANDBOX.p8
npx wrangler secret put PUSH_CLIENTS --config cloudflare/wrangler.jsonc
```

Enter `PUSH_CLIENTS` as JSON, with a separate token of at least 24 characters per connector:

```json
[{"id":"my-service","token":"REPLACE_WITH_RANDOM_SERVICE_TOKEN_AT_LEAST_24_CHARACTERS"}]
```

For production signing, also configure `APNS_PRODUCTION_KEY_ID` and `APNS_PRODUCTION_KEY_P8` using the corresponding `wrangler secret put` commands. Configure only the environments you use; missing environments reject bindings. Each key must permit its actual environment and topics. P8 secret values are the complete PEM file contents, not a file path. Check Durable Objects availability and fees for your account. Keep the deployed Worker's HTTPS root URL.

### Connect the sender and phone

Set these in your **connector's** private configuration, preserving its other values:

```dotenv
TINCALL_PUSH_URL=https://YOUR_PUSH_SENDER_HOST
TINCALL_PUSH_TOKEN=THE_SAME_RANDOM_SERVICE_TOKEN
```

For Node, restart that connector. For Supabase, set these Edge Function secrets in the dashboard or use `supabase secrets set --project-ref YOUR_PROJECT_REF --env-file /absolute/private/push.env`. Do not put the Apple private key in this file. The service token matches the Node sender token or the corresponding Worker's `PUSH_CLIENTS` entry; it is not the phone or MCP token.

On the phone, check the saved connector, enable Allow background calls under Background & Scheduled Calls, and confirm it is bound. PushKit tokens are registered automatically; never paste the P8 into the app. Test a real MCP/backend incoming call or a standalone scheduled call. Scheduled calls also need the connector worker; Supabase uses Cron/Vault, configured by the app deployment or the CLI installer.

Check foreground, background and locked-screen ringing, then microphone input, replies, playback and hang-up. For Live Activities, enable them in iOS Settings and authorize the Live Activity topic listed above. If calls do not ring after binding, check sender errors, signing, Focus settings and the phone's network.

## Update and troubleshoot

App updates do not update your deployed connector. Use the original deployment path and preserve its tokens, database and settings:

- An app-deployed Supabase installation: on the original phone, run Deploy or update service against the original project with a current scoped management token. The token is not persisted and must be entered again. Do not use this as a first-time installer for a service deployed elsewhere.
- A CLI-deployed Supabase installation: obtain updated source and rerun the original deployment command with the same private settings. It applies migrations and updates the function; do not generate replacement phone/worker tokens.
- Node/Docker: rerun the original installer using updated source and the existing private configuration/data paths. Do not delete the database to update the program.

Image/storage and MCP wait-preference migrations are included; no extra manual image SQL is needed. In Tincall Cloud, refresh the service version after upgrading. The connector reports `server_version` separately from its protocol `version`; a missing or older service revision prompts an update, while a failed check requires checking the connection or token. Refresh or reconnect the external AI client's MCP tools: ordinary `tincall_reply` requires `call` and `text`, with optional `wait_for_input`; wake-bridge replies require only `text`.

| Symptom | Check first |
| --- | --- |
| 401 from the phone | Connector URL, phone token and owner mapping; never disable authorization rules to bypass it |
| Missing service capability | Update through the original deployment path, then check the connection again |
| MCP timeout or old parameters | Follow the Kelivo/Muse settings above or your platform's limits; refresh tools and remove obsolete fields; do not resend blindly |
| No push entitlement | Actual main app profile/signature; a cloud deployment cannot add device signing capabilities |
| Sender 401 | Matching connector-to-sender service token |
| `apns_configuration_missing` / `apns_configuration_invalid` | Team, key, full PEM, configured environment and `.voip` topic |
| `apns_rejected` | Final app ID, team, topic, key permissions and device environment; do not retry a device token across environments |
| Schedule exists but no ringing | Worker/Cron, sender result, binding, device network and Focus settings |

After an upgrade, check existing data and a real call or sync for your chosen features. Background calls require their own locked-screen and audio checks; build/deployment success alone is insufficient.
