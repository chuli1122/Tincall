// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

enum ConnectionProvider: String, Codable, CaseIterable, Sendable {
    case openAICompatible, anthropic, gemini, xunfei, elevenLabs, appleSpeech, bailian, miniMax, whisperCompatible, fishAudio, genericConnector
    var isLanguageModel: Bool { self == .openAICompatible || self == .anthropic || self == .gemini }
    var isSpeechRecognition: Bool { self == .appleSpeech || self == .xunfei || self == .bailian || self == .whisperCompatible }
    var isSpeechSynthesis: Bool { self == .elevenLabs || self == .miniMax || self == .fishAudio }
}

enum OpenAIReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none, minimal, low, medium, high, xhigh, max
}

enum AnthropicThinkingMode: String, Codable, CaseIterable, Sendable { case off, adaptive, manual }
enum AnthropicEffort: String, Codable, CaseIterable, Sendable { case low, medium, high, xhigh, max }
enum GeminiThinkingLevel: String, Codable, CaseIterable, Sendable { case minimal, low, medium, high }

/// Only public configuration. Secrets are stored by connection ID in Keychain.
struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var provider: ConnectionProvider
    /// Model connections accept a HTTPS base URL or the selected protocol's complete endpoint.
    /// Xunfei/ElevenLabs use fixed supplier addresses and require nil.
    var endpoint: URL?
    var model: String = ""
    var applicationID: String = ""
    var voiceID: String = ""
    /// Supplier-specific language and official service region; nil preserves legacy defaults.
    var language: String?
    var region: String?
    /// Nil uses the supplier/model default; an explicitly empty value disables these instructions.
    var expressionPrompt: String?
    /// Nil leaves the voice's ElevenLabs setting unchanged.
    var elevenLabsStability: Double?
    var elevenLabsSimilarityBoost: Double?
    /// Nil omits optional generation parameters. Anthropic requires an output limit and defaults to 4096.
    var temperature: Double?
    var topP: Double?
    var maxOutputTokens: Int?
    /// Explicit provider-specific settings. Nil follows the model default without sending a thinking field.
    var openAIReasoningEffort: OpenAIReasoningEffort?
    var anthropicThinkingMode: AnthropicThinkingMode?
    var anthropicThinkingBudget: Int?
    var anthropicEffort: AnthropicEffort?
    var geminiThinkingLevel: GeminiThinkingLevel?
    /// -1 requests a dynamic budget; 0 disables thinking only on models that support it.
    var geminiThinkingBudget: Int?
    /// Decode-only legacy defaults, migrated into existing contacts by LocalConfigurationStore.
    var externalRoleID: String?
    var externalRoleName: String?

    var defaultExpressionPrompt: String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if provider == .fishAudio, ["s2.1-pro", "s2.1-pro-free", "s2-pro"].contains(model) {
            return "回复将由 Fish Audio S2 系列合成语音。保持当前人物的自然口语回复，不输出 emoji、Markdown 或无声动作旁白。根据语境，用 [自然语言声音描述] 表达情绪、说话方式、声音质感、力度、节奏或非语言声音；不限固定词表，例如 [whisper]、[excited]、[emphasis]、[whispers sweetly]、[laughing nervously]。把指示放在其作用话语附近，笑声、叹息、吸气或停顿等可在发生处写 [laugh]、[sigh]、[gasp]、[inhale]、[exhale]、[pause]。S2 使用方括号，不使用 S1 的圆括号格式；此为单人通话回复，不切换说话人。"
        }
        if provider == .elevenLabs, ["eleven_v3", "eleven_v4", "eleven_v4_turbo"].contains(model) {
            return "回复将由 ElevenLabs 当前所选模型合成语音。保持当前人物的自然口语回复，不输出 emoji、Markdown 或无声动作旁白。根据语境，用方括号中的自然语言指示表达情绪、说话方式、声音质感、力度和节奏；不限固定词表，例如 [whispers]、[excited]、[curious]、[sarcastic]、[low, gravelly voice]、[frustrated sigh]、[laughing nervously]、[exhales sharply]、[short pause]。把指示放在其作用话语附近或声音实际发生的位置，不把普通对白放进方括号。用标点、省略号与适当的词语强调辅助节奏，不输出 SSML break 标签。结合所选声音的特点选择表达，实际效果取决于模型和声音。"
        }
        if provider == .miniMax {
            if model == "speech-2.8-hd" || model == "speech-2.8-turbo" {
                return "回复将由 MiniMax Speech 2.8 合成语音。保持当前人物的自然口语回复，不输出 emoji、Markdown 或无声动作旁白。通过措辞、句式和标点表达情绪，语音模型会从文本判断语气。需要非语言声音时，在发生处使用对应语气音：(laughs)、(chuckle)、(coughs)、(clear-throat)、(groans)、(breath)、(pant)、(inhale)、(exhale)、(gasps)、(sniffs)、(sighs)、(snorts)、(burps)、(lip-smacking)、(humming)、(hissing)、(emm)、(sneezes)。需要明确停顿时用 <#秒数#>，范围 0.01–99.99、最多两位小数，必须放在两段可朗读文字之间，不能放开头或结尾，也不能连续使用，例如 等等<#0.3#>我想起来了。不使用方括号情绪标签，不把 voice_setting.emotion 参数写进正文。"
            }
            return "回复将由 MiniMax 合成语音。保持当前人物的自然口语回复，不输出 emoji、Markdown 或无声动作旁白。通过措辞、句式和标点表达情绪，语音模型会从文本判断语气。需要明确停顿时用 <#秒数#>，范围 0.01–99.99、最多两位小数，放在两段可朗读文字之间，不放开头或结尾且不连续使用。当前型号不使用仅 Speech 2.8 支持的圆括号语气音，也不使用方括号情绪标签或将 voice_setting.emotion 参数写进正文。"
        }
        return "回复将被直接朗读。只写自然、适合口语的句子，用措辞和标点表达情绪与节奏。避免 emoji、Markdown、动作旁白和文字表演标签，不输出语音服务参数。"
    }
    var mcpURL: URL? {
        guard provider == .genericConnector, let endpoint,
              endpoint.scheme == "https", endpoint.host?.isEmpty == false,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { return nil }
        return endpoint.appendingPathComponent("mcp")
    }

    var effectiveExpressionPrompt: String { expressionPrompt ?? defaultExpressionPrompt }
}

enum CallContextModule: String, Codable, CaseIterable, Sendable {
    case persona, historySummaries, currentConversation
}

struct LinkedContact: Codable, Equatable, Sendable {
    var identifier: String
    var name: String
    var avatarData: Data?
    var familyName: String?
    var givenName: String?
    /// Selected contact only; used locally for system incoming-call matching.
    var phoneNumber: String?
    var phoneNumbers: [String]?
    var emailAddress: String?
}

enum CallMode: String, Codable, CaseIterable, Sendable {
    case standalone, mcp, backend
}

/// This entire value is secret and may only be persisted in Keychain.
struct MCPRoleConfiguration: Codable, Equatable, Sendable {
    let mcp_url: URL
    let contact_id: String
    let display_name: String
    let token: String
    let token_created: Bool
    var mcp_wait_timeout_seconds: Int? = nil

    var effectiveMCPWaitTimeoutSeconds: Int { min(130, max(1, mcp_wait_timeout_seconds ?? 120)) }

    func validate(connection: ConnectionProfile, contactID: String) throws {
        guard connection.provider == .genericConnector, let base = connection.endpoint,
              base.scheme == "https", base.host?.isEmpty == false,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              mcp_url == base.appendingPathComponent("mcp"), contact_id == contactID,
              !display_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.isEmpty, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw TincallError(message: String(localized: "云端返回的联系人 MCP 配置无效，请检查服务后重试。"))
        }
    }

    func platformConfigurationJSON() throws -> String {
        let object = ["mcpServers": ["tincall-\(contact_id)": [
            "url": mcp_url.absoluteString,
            "headers": ["Authorization": "Bearer \(token)"]
        ]]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else {
            throw TincallError(message: String(localized: "无法生成 MCP 配置。"))
        }
        return result
    }
}

struct CallRole: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var familyName: String?
    var givenName: String?
    var modelConnectionID: UUID? = nil
    /// Nil disables summaries; this model selection is independent of the call model.
    var summaryConnectionID: UUID?
    var callBackgroundData: Data?
    var sttConnectionID: UUID?
    var ttsConnectionID: UUID?
    var callMode: CallMode?
    /// A local choice of MCP integration; missing in older contacts means ordinary MCP.
    var mcpWakeBridgeEnabled: Bool?
    /// Missing in existing contacts uses the recommended wait below client timeouts.
    var mcpWaitTimeoutSeconds: Int?
    /// Overrides the reusable TTS connection's default voice for this role.
    var voiceID: String = ""
    var systemPrompt: String = ""
    /// Missing in existing contacts keeps timestamp injection disabled.
    var timeAwarenessEnabled: Bool?
    var historySummaryCount: Int?
    /// Unicode character budget, deliberately not advertised as an exact token count.
    var contextCharacterBudget: Int?
    var contextModuleOrder: [CallContextModule]?
    var summaryPrompt: String?
    /// Requested length, not a guarantee that the model returns exactly this many characters.
    var summaryMaxCharacters: Int?
    var externalConnectionID: UUID?
    var externalRoleID: String?
    var externalRoleName: String?
    /// Manual details remain intact while a system contact is linked.
    var avatarData: Data?
    var linkedContact: LinkedContact?
    /// Stable local calling address, allocated once and saved with the role.
    var systemCallPhoneNumber: String?
    /// Missing in legacy records means follow the linked contact, as before.
    var syncSystemContactDetails: Bool?

    var effectiveCallMode: CallMode { callMode ?? .standalone }
    var effectiveMCPWaitTimeoutSeconds: Int { min(130, max(1, mcpWaitTimeoutSeconds ?? 120)) }

    /// Each newly registered role has its own stable identity, independent of connection defaults.
    var mcpContactID: String {
        let existing = externalRoleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return existing.isEmpty ? id.uuidString.lowercased() : existing
    }
    var effectivePersonaEnabled: Bool { !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var effectiveHistorySummaryCount: Int { summaryConnectionID == nil ? 0 : min(5, max(0, historySummaryCount ?? 3)) }
    var canReorderContextModules: Bool {
        effectiveCallMode == .standalone && effectivePersonaEnabled && effectiveHistorySummaryCount > 0
    }
    var effectiveContextCharacterBudget: Int { min(200_000, max(1_000, contextCharacterBudget ?? 60_000)) }
    var effectiveSummaryMaxCharacters: Int {
        guard let summaryMaxCharacters, summaryMaxCharacters > 0 else { return 500 }
        return summaryMaxCharacters
    }
    static var defaultSummaryPrompt: String {
        String(localized: """
        请阅读以下通话记录，生成一份简洁、完整的摘要。

        要求：
        1. 按话题归纳主要内容，合并重复信息，不逐句复述。
        2. 保留关键细节、前后变化，以及对话中明确达成的约定。
        3. 准确区分双方的表述，不把提问、假设或未确认的信息写成事实。
        4. 忠实于原文，不添加推测，不补全未说完或被打断的内容。

        直接输出摘要正文，不要添加开场白或解释总结过程。
        """)
    }
    var effectiveSummaryPrompt: String {
        let value = summaryPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? Self.defaultSummaryPrompt : value
    }
    var effectiveContextModuleOrder: [CallContextModule] {
        var result: [CallContextModule] = []
        for item in (contextModuleOrder ?? []) + CallContextModule.allCases where !result.contains(item) {
            result.append(item)
        }
        return result
    }

    var usesSystemContactDetails: Bool {
        linkedContact != nil && syncSystemContactDetails != false
    }

    var displayName: String {
        if usesSystemContactDetails, let linkedContact, !linkedContact.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return linkedContact.name
        }
        return name
    }

    var displayAvatarData: Data? {
        if usesSystemContactDetails, let linkedContact { return linkedContact.avatarData }
        return avatarData
    }

    mutating func updateManualName(familyName: String, givenName: String) {
        let familyName = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let givenName = givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.familyName = familyName
        self.givenName = givenName
        guard !familyName.isEmpty || !givenName.isEmpty else { name = ""; return }
        var components = PersonNameComponents()
        components.familyName = familyName
        components.givenName = givenName
        name = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
    }

    mutating func stopSyncingContactDetails() {
        fillMissingManualDetailsFromLinkedContact()
        syncSystemContactDetails = false
    }

    mutating func unlinkContact() {
        fillMissingManualDetailsFromLinkedContact()
        linkedContact = nil
    }

    private mutating func fillMissingManualDetailsFromLinkedContact() {
        guard let linkedContact else { return }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = linkedContact.name
            familyName = linkedContact.familyName
            givenName = linkedContact.givenName
        }
        if avatarData?.isEmpty != false { avatarData = linkedContact.avatarData }
    }
}

struct AudioRetention: Codable, Equatable, Sendable {
    var user: Bool = false
    var assistant: Bool = false
}

enum MessageRole: String, Codable, Sendable { case user, assistant }
enum MessageStatus: String, Codable, Sendable { case generating, completed, interrupted, failed }
enum MessageInterruption: String, Codable, Sendable { case hangUp, interrupt }
enum CallPhase: String, Codable, Sendable { case idle, connecting, active, ended, failed }
enum GenerationState: String, Sendable { case idle, generating, completed, interrupted, failed }
enum PlaybackState: String, Sendable { case idle, synthesizing, playing, drained, failed }
enum SummaryStatus: String, Codable, Sendable { case notRequested, pending, generating, completed, failed }

struct CallMessage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var turnID: UUID
    var role: MessageRole
    var text: String
    var createdAt: Date = Date()
    var status: MessageStatus = .completed
    var interruption: MessageInterruption?
    var images: [CallImageAsset]? = nil

    /// Use the same end note in the UI, subsequent model context and summaries.
    /// Keep received text intact; no guessed playback position is inserted.
    var recordedText: String {
        // An empty assistant placeholder has no received content to annotate.
        // Showing only an interruption note makes a silent, never-started reply
        // look like audio was actually cut off.
        if role == .assistant && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        let note: String
        switch interruption {
        case .hangUp:
            note = role == .user
                ? String(localized: "（本条发言因通话挂断而中断，转写尚未确认）")
                : String(localized: "（本条回复因通话挂断而中断，可能未完整播放）")
        case .interrupt: note = String(localized: "（本条回复被打断，可能未完整播放）")
        case nil:
            guard status == .interrupted else { return text }
            note = String(localized: "（本条被打断）")
        }
        return text.isEmpty ? note : text + "\n" + note
    }
}

struct CallImageAsset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var relativePath: String
    var mimeType: String { relativePath.hasSuffix(".png") ? "image/png" : "image/jpeg" }

    init(id: UUID = UUID(), relativePath: String) { self.id = id; self.relativePath = relativePath }

    private enum CodingKeys: String, CodingKey { case id, relativePath }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        // Cloud references have no local path; the cloud adapter assigns a validated path.
        relativePath = try values.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
    }
}

/// Shared connector input format; persisted local assets retain the UUID across retries.
struct ConnectorMessageImage: Codable, Sendable {
    static let maximumBytes = 5 * 1024 * 1024
    let id: UUID
    let mime_type: String
    let data_base64: String

    static func inputs(assets: [CallImageAsset], data: [Data]) throws -> [Self] {
        guard assets.count == data.count, assets.count <= 4 else {
            throw TincallError(message: String(localized: "消息图片不完整或超过 4 张，未发送"))
        }
        return try zip(assets, data).map { asset, bytes in
            try validate(bytes, mimeType: asset.mimeType)
            return Self(id: asset.id, mime_type: asset.mimeType, data_base64: bytes.base64EncodedString())
        }
    }

    static func validate(_ data: Data, mimeType: String) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw TincallError(message: String(localized: "消息图片为空或超过 5 MiB，未发送"))
        }
        let valid = mimeType == "image/jpeg" ? data.starts(with: [0xff, 0xd8, 0xff])
            : mimeType == "image/png" && data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        guard valid else { throw TincallError(message: String(localized: "消息图片类型无效，未发送")) }
    }
}

/// Paths are relative to the record store's durable media directory, never tmp URLs.
struct CallAudioAsset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var messageID: UUID
    var segmentIndex: Int
    var relativePath: String
    var duration: TimeInterval?
}

struct CallRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var roleID: UUID
    var roleName: String
    var startedAt: Date = Date()
    var endedAt: Date?
    var messages: [CallMessage] = []
    var audioAssets: [CallAudioAsset] = []
    var summaryStatus: SummaryStatus = .notRequested
    var summary: String = ""
    /// Stable per generated summary, so later sync retries cannot replay an older write.
    var summaryUploadRequestID: UUID?
    /// Captured source prevents summaries from another dialogue source entering standalone context.
    var callMode: CallMode?
    var externalConnectionID: UUID?
    var externalRoleID: String?
    var externalCallID: UUID?
    var externalEventCursor: Int?
    var externalEpoch: Int?
    var externalReplyID: UUID?
    var externalAnswerRequestID: UUID?
    var externalPendingInput: ExternalPendingInput?
    var externalPendingControl: ExternalPendingControl?
    /// User messages saved before their reply can start, including while remote cancellation is unconfirmed.
    var queuedInputIDs: [UUID]?
    /// Original call UUID carried across backup imports and exports. Legacy records use their own ID.
    var sourceRecordID: UUID?
    /// Last time this installation confirmed that its call session was still active.
    var lastActiveAt: Date?
    /// Locally observed active intervals; excludes time spent outside a resumed session.
    var recordedActiveDuration: TimeInterval?
    /// An interrupted local session can finish without a known real ending timestamp.
    var endedAbnormally: Bool?

    var isFinished: Bool { endedAt != nil || endedAbnormally == true }

    var recordedDuration: TimeInterval? {
        if let recordedActiveDuration { return recordedActiveDuration }
        return lastActiveAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }
}

struct ExternalPendingInput: Codable, Equatable, Sendable {
    let requestID: UUID
    let messageID: UUID
    let replyMessageID: UUID
    let epoch: Int
    /// Freeze the timestamp format across retries; nil preserves legacy/plain input.
    var timeZone: String?
}

struct ExternalPendingControl: Codable, Equatable, Sendable {
    let requestID: UUID
    let epoch: Int
    let endsCall: Bool
    var prepared: Bool?
}

struct VoiceSessionID: Equatable, Sendable {
    let callID: UUID
    let epoch: UUID
}

struct VoiceTurnID: Equatable, Sendable {
    let session: VoiceSessionID
    let turnID: UUID
    let messageID: UUID
}

struct VoiceConfiguration: Sendable {
    let stt: ConnectionProfile
    let tts: ConnectionProfile
    let voiceID: String
    let retention: AudioRetention
}

struct TranscriptResult: Sendable {
    /// Stable across partial corrections and repeated final callbacks. Final user message ID equals inputID.
    let inputID: UUID
    let text: String
    let isFinal: Bool
    /// Temporary WAV input; independent of the user's recording-retention choice.
    var audio: Data? = nil

    func corrected(using rules: [SpeechRecognitionCorrection]) -> TranscriptResult {
        TranscriptResult(inputID: inputID, text: SpeechRecognitionCorrection.apply(to: text, rules: rules), isFinal: isFinal, audio: audio)
    }
}

struct SpeechRecognitionCorrection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var source = ""
    var replacement = ""

    /// Match the original transcript from left to right, preferring longer phrases.
    /// Replacement text is never processed again by another rule.
    static func apply(to text: String, rules: [Self]) -> String {
        let rules = rules.filter { !$0.source.isEmpty }.sorted { $0.source.count > $1.source.count }
        guard !rules.isEmpty else { return text }
        var corrected = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let match = rules.lazy.compactMap({ rule -> (String, String.Index)? in
                guard let range = text.range(of: rule.source, options: [.anchored, .literal], range: cursor..<text.endIndex) else { return nil }
                return (rule.replacement, range.upperBound)
            }).first {
                corrected += match.0
                cursor = match.1
            } else {
                corrected.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return corrected
    }
}

struct VoiceAudioSegment: Sendable {
    let id: UUID
    let messageID: UUID
    let segmentIndex: Int
    let fileURL: URL
    let duration: TimeInterval?
}

enum SpeechInterruptionAvailability: Equatable, Sendable {
    case unavailable
    case microphoneMuted
    case recognitionUnavailable
    case beforePlaybackOnly
    case headphones
}

enum VoiceEvent: Sendable {
    case transcript(VoiceSessionID, TranscriptResult)
    /// Actual microphone VAD state, independent of whether STT has produced words.
    case speechActivity(VoiceSessionID, Bool)
    case playback(VoiceTurnID, PlaybackState)
    /// Actual playing segment text; nil when its playback has ended. No estimated word timing.
    case playbackCaption(VoiceTurnID, String?)
    case speechInterruptionAvailability(VoiceSessionID, SpeechInterruptionAvailability)
    case microphoneState(VoiceSessionID, Bool)
    case speakerState(VoiceSessionID, Bool)
    /// Transfers ownership of an immutable temporary file. Voice must not delete it after emission.
    /// Coordinator deletes only after durable copy and atomic index save; failures retain the source.
    case audioReady(VoiceSessionID, VoiceAudioSegment)
    case failure(VoiceSessionID, String)
}

/// The service owns capture, STT, segmentation, synthesis, playback and audio routing.
/// CallCoordinator owns model generation. No method here cancels model work.
@MainActor
protocol VoiceService: AnyObject {
    var onEvent: ((VoiceEvent) -> Void)? { get set }
    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws
    func setMicrophoneMuted(_ muted: Bool) async throws
    func setSpeakerEnabled(_ enabled: Bool) async throws
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws
    func setTextInputActive(_ active: Bool)
    func setSpeechInterruptionEnabled(_ enabled: Bool)
    /// Synthesize silently while ringing; start releases prepared audio after media activation, before waiting for recognition.
    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws
    func beginReply(_ turn: VoiceTurnID) throws
    func appendReply(_ delta: String, to turn: VoiceTurnID) throws
    func finishReply(_ turn: VoiceTurnID) throws
    func interruptReply(_ turn: VoiceTurnID)
    func stop()
}

struct TincallError: LocalizedError, Sendable {
    let message: String
    var requestCode: String? = nil
    var errorDescription: String? { message }
}

/// Content-free device evidence. Only fixed events, local identities and counts
/// are accepted; existing request logs and call data are never read or changed.
@MainActor
enum CallAudioDiagnostics {
    enum Event: String {
        case microphoneChange, recognizerStart, recognizerReset
        case transcriptForwarded, transcriptDroppedPaused, transcriptDroppedGate, transcriptDroppedFinal
        case transcriptReceived, autoPartialInterrupt, autoFinalInterrupt, manualInterrupt
        case turnBegan, turnCompleted
        case replyBegin, replyInterrupt, replyStop, replyDrained, replyFailed
        case captureStart, captureStop, captureConfigurationRestart, captureRouteRestart
        case captureStage, captureFailed, microphoneFailed, audioRouteChanged, speakerChange
        case independentAudioStage, independentAudioFailed, audioRoutingFailed
        case incomingSubscriptionFailed
        case audioInterruption, otherAudioDucking
        case speechActive, speechGateOpened
        case sttAudioSent, sttResponse
        case ttsBegin, ttsStop, ttsSegment, ttsRequest, ttsFirstAudio, ttsReceiveEnd
        case ttsPlayStart, ttsPlayEnd, ttsRestore, ttsFinished, ttsFailed
        case ttsHTTPResponse, ttsRequestFailed, ttsDrainTimeout, ttsPrepareFailed
    }

    static var fileURL: URL { URL.cachesDirectory.appending(path: "CallAudioDiagnostics.log") }

    static func record(_ event: Event, turn: UUID? = nil, input: UUID? = nil,
                       generation: Int? = nil, segment: Int? = nil, count: Int? = nil, flag: Bool? = nil,
                       sourceStart: Int? = nil, sourceEnd: Int? = nil, receivedBytes: Int? = nil, playedBytes: Int? = nil,
                       phase: String? = nil, errorDomain: String? = nil, errorCode: Int? = nil,
                       category: String? = nil, mode: String? = nil, options: UInt? = nil,
                       inputPorts: String? = nil, outputPorts: String? = nil, appState: Int? = nil) {
        #if DEBUG
        var fields = [String(format: "%.3f", Date().timeIntervalSince1970), event.rawValue]
        if let turn { fields.append("turn=\(turn.uuidString)") }
        if let input { fields.append("input=\(input.uuidString)") }
        if let generation { fields.append("generation=\(generation)") }
        if let segment { fields.append("segment=\(segment)") }
        if let count { fields.append("count=\(count)") }
        if let flag { fields.append("flag=\(flag ? 1 : 0)") }
        if let sourceStart { fields.append("sourceStart=\(sourceStart)") }
        if let sourceEnd { fields.append("sourceEnd=\(sourceEnd)") }
        if let receivedBytes { fields.append("receivedBytes=\(receivedBytes)") }
        if let playedBytes { fields.append("playedBytes=\(playedBytes)") }
        if let phase { fields.append("phase=\(phase)") }
        if let errorDomain { fields.append("errorDomain=\(errorDomain)") }
        if let errorCode { fields.append("errorCode=\(errorCode)") }
        if let category { fields.append("category=\(category)") }
        if let mode { fields.append("mode=\(mode)") }
        if let options { fields.append("options=\(options)") }
        if let inputPorts { fields.append("inputPorts=\(inputPorts)") }
        if let outputPorts { fields.append("outputPorts=\(outputPorts)") }
        if let appState { fields.append("appState=\(appState)") }
        do {
            let existing = FileManager.default.fileExists(atPath: fileURL.path)
                ? try String(contentsOf: fileURL, encoding: .utf8) : ""
            let lines = existing.split(separator: "\n").suffix(299).map(String.init) + [fields.joined(separator: " ")]
            try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("audio_diagnostic_write_failed code=%ld", (error as NSError).code)
        }
        #endif
    }
}
