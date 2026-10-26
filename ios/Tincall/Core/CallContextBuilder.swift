// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct CallRequestPreview: Sendable {
    let requestJSON: String
    let characterCount: Int
    let characterBudget: Int
    let includedSummaryCount: Int
    let omittedMessageCount: Int
}

struct CallContext: Sendable {
    let messages: [ModelMessage]
    let characterCount: Int
    let includedSummaryCount: Int
    let omittedMessageCount: Int
    let omittedTurnCount: Int
}

/// Shared by the actual model request and its preview. Never mutates the original records.
enum CallContextBuilder {
    static func timeAwareInput(_ text: String, createdAt: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        "[\(timeFormatter(timeZone: timeZone).string(from: createdAt))]\n\(text)"
    }

    private static func timeFormatter(timeZone: TimeZone = .autoupdatingCurrent) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    static func requestPreview(role: CallRole, connection: ConnectionProfile, historyRecords: [CallRecord], input: String,
                               currentMessages: [CallMessage] = [], ttsConnection: ConnectionProfile? = nil, userName: String = "",
                               loadImages: ((CallMessage) throws -> [Data])? = nil) throws -> CallRequestPreview {
        guard connection.provider.isLanguageModel else { throw TincallError(message: String(localized: "请求预览需要模型连接")) }
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw TincallError(message: String(localized: "请填写本轮输入后预览请求")) }
        let messages = currentMessages + [CallMessage(turnID: UUID(), role: .user, text: input)]
        let context = try build(role: role, historyRecords: historyRecords, currentMessages: messages, ttsConnection: ttsConnection, userName: userName, loadImages: loadImages)
        let body = try ModelRequestCodec.requestBody(connection: connection, messages: context.messages)
        guard let json = String(data: body, encoding: .utf8) else { throw TincallError(message: String(localized: "请求预览编码失败")) }
        return CallRequestPreview(requestJSON: json, characterCount: context.characterCount,
                                  characterBudget: role.effectiveContextCharacterBudget,
                                  includedSummaryCount: context.includedSummaryCount, omittedMessageCount: context.omittedMessageCount)
    }

    static func build(role: CallRole, historyRecords: [CallRecord], currentMessages: [CallMessage], ttsConnection: ConnectionProfile? = nil, userName: String = "",
                      loadImages: ((CallMessage) throws -> [Data])? = nil, assistantInitiated: Bool = false,
                      audioInput: (messageID: UUID, audio: Data)? = nil) throws -> CallContext {
        guard role.effectiveCallMode == .standalone else {
            throw TincallError(message: String(localized: "外部模式的上下文由连接端管理，不在手机重复拼接人设和历史"))
        }
        let budget = role.effectiveContextCharacterBudget
        let timeAware = role.timeAwarenessEnabled == true
        let formatter = timeFormatter()
        func content(for message: CallMessage) -> String {
            let text = message.id == audioInput?.messageID ? "" : message.recordedText
            guard timeAware else { return text }
            if message.role == .user {
                return "[\(formatter.string(from: message.createdAt))]\n\(text)"
            }
            return CallTimestampStreamFilter.clean(message.recordedText)
        }
        let messages = currentMessages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.images?.isEmpty == false }
        // At least the latest complete input must remain intact; silently clipping it changes the question.
        let latest = messages.last
        if let audioInput {
            guard latest?.id == audioInput.messageID, latest?.role == .user else {
                throw TincallError(message: String(localized: "原声录音与本轮发言不匹配"))
            }
        }
        let openingEvent = assistantInitiated && messages.isEmpty ? """
        <call_event>
        这是 Tincall 发出的通话状态通知，不是对方发言。你正在主动给对方打电话，请结合你的人设与已有上下文，准备一句自然的开场白，在对方接听后先开口。对方尚未说话，不要编造对方的发言，也不要朗读这条通知。
        </call_event>
        """ : ""
        guard latest != nil || !openingEvent.isEmpty else { throw TincallError(message: String(localized: "请填写本轮输入后预览请求")) }
        let latestCount = latest.map { content(for: $0).count } ?? openingEvent.count
        let direction = assistantInitiated ? "\n本次通话由你主动打给对方，请以主叫方的身份自然交流。" : ""
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = """
        <call_context>
        你正在通过 Tincall 与对方通话。通话双方：\(name.isEmpty ? "" : "user 是「\(name)」，")assistant 是「\(role.displayName)」。
        对方的消息可能来自语音转写、原声音频、文字输入或主动发送的图片。你的回复会显示在通话界面，并在开启语音时朗读。\(direction)
        当你确实决定结束本次通话时，先自然说完告别语，再在回复末尾另起一行输出 <end_call/>。这行是挂断指令，不会显示或朗读；App 会等本轮语音播完后挂断。不结束通话时不要输出此指令。
        </call_context>
        """
        let personaText = role.effectivePersonaEnabled ? role.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let expressionText = ttsConnection?.effectiveExpressionPrompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let persona = personaText.isEmpty ? "" : "<conversation_settings>\n\(personaText)\n</conversation_settings>"
        let expression = expressionText.isEmpty ? "" : "<tts_instructions>\n\(expressionText)\n</tts_instructions>"
        let timeInstruction = timeAware ? """
        <time_awareness>
        对方消息开头的 [yyyy-MM-dd HH:mm:ss] 是该消息的发送时间，使用手机本地时区。据此理解消息之间的时间间隔，不必每次提及时间。
        这些时间标记是系统元数据，不是对话正文。回复中不要复制或生成这些标记。
        </time_awareness>
        """ : ""
        let instructionCount = scene.count + persona.count + expression.count + timeInstruction.count
        guard instructionCount + latestCount <= budget else {
            throw TincallError(message: String(localized: "系统提示与本轮输入已超出上下文字符预算，请缩短内容或增加预算"))
        }
        let candidates = historyRecords.filter {
            $0.roleID == role.id && ($0.callMode ?? .standalone) == .standalone && $0.endedAt != nil &&
            $0.summaryStatus == .completed && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        let selected = candidates.prefix(role.effectiveHistorySummaryCount).reversed().map {
            "<call_summary>\n历史通话摘要（\($0.startedAt.formatted(.iso8601))）：\n\($0.summary)\n</call_summary>"
        }
        let summaryCount = selected.reduce(0) { $0 + $1.count }
        guard instructionCount + summaryCount + latestCount <= budget else {
            throw TincallError(message: String(localized: "系统提示、历史摘要与本轮发言已超出上下文上限，请调大上限或减少引用的历史通话数"))
        }
        var remaining = budget - instructionCount - summaryCount - openingEvent.count
        var included: [CallMessage] = []
        // Current conversation remains in chronological, complete turns after system modules.
        var groups: [[CallMessage]] = []
        for message in messages {
            if groups.last?.first?.turnID == message.turnID { groups[groups.count - 1].append(message) }
            else { groups.append([message]) }
        }
        for group in groups.reversed() {
            let count = group.reduce(0) { $0 + content(for: $1).count }
            guard count <= remaining else { break }
            included.insert(contentsOf: group, at: 0)
            remaining -= count
        }
        if let latest, !included.contains(where: { $0.id == latest.id }) {
            throw TincallError(message: String(localized: "本轮完整发言超出上下文字符预算"))
        }
        var result = [ModelMessage(role: "system", content: scene)]
        if !timeInstruction.isEmpty { result.append(ModelMessage(role: "system", content: timeInstruction)) }
        // Keep system instructions ahead of chronological user/assistant history for all model protocols.
        for module in role.effectiveContextModuleOrder {
            switch module {
            case .persona:
                if !persona.isEmpty { result.append(ModelMessage(role: "system", content: persona)) }
            case .historySummaries:
                result.append(contentsOf: selected.map { ModelMessage(role: "system", content: $0) })
            case .currentConversation: break
            }
        }
        if !expression.isEmpty { result.append(ModelMessage(role: "system", content: expression)) }
        // Providers require a conversational input; keep this explicit lifecycle event out of call records.
        if !openingEvent.isEmpty { result.append(ModelMessage(role: "user", content: openingEvent)) }
        result.append(contentsOf: try included.map { message in
            var images: [Data] = []
            if let assets = message.images, !assets.isEmpty {
                guard let loadImages else { throw TincallError(message: String(localized: "无法读取消息图片")) }
                images = try loadImages(message)
                guard images.count == assets.count else { throw TincallError(message: String(localized: "无法读取消息图片")) }
            }
            return ModelMessage(role: message.role.rawValue, content: content(for: message), images: images,
                                audio: message.id == audioInput?.messageID ? audioInput?.audio : nil)
        })
        return CallContext(messages: result, characterCount: budget - remaining,
                           includedSummaryCount: selected.count, omittedMessageCount: messages.count - included.count,
                           omittedTurnCount: Set(messages.prefix(messages.count - included.count).map(\.turnID)).count)
    }
}

/// One source for the actual summary messages and the settings request preview.
enum CallSummaryRequestBuilder {
    static func transcript(from messages: [CallMessage]) -> String {
        messages.map { "\($0.role.rawValue): \($0.recordedText)" }.joined(separator: "\n")
    }

    static func messages(prompt: String, targetLength: Int, transcript: String, userName: String, contactName: String) -> [ModelMessage] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = trimmed.isEmpty ? CallRole.defaultSummaryPrompt : trimmed
        let user = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let participants = String(localized: "通话双方的姓名：\nuser：\(user.isEmpty ? String(localized: "用户") : user)\nassistant：\(contact.isEmpty ? String(localized: "联系人") : contact)")
        let lengthInstruction = "目标长度约 \(targetLength) 字。这是内容目标，不补造事实，也不省略中断说明。"
        return [ModelMessage(role: "system", content: instruction + "\n\n" + participants + "\n\n" + lengthInstruction),
                ModelMessage(role: "user", content: transcript)]
    }
}

/// A standalone terminal command is held until stream completion, so it never reaches speech.
struct CallEndStreamFilter {
    private var pending = ""
    private var whitespace = ""
    private var atLineStart = true
    private(set) var requestsEnd = false
    private static let command = "<end_call/>"

    mutating func append(_ delta: String, final: Bool = false) -> String {
        pending += delta
        var output = ""
        while let first = pending.first {
            if atLineStart, first == "<" {
                if pending.hasPrefix(Self.command), pending.dropFirst(Self.command.count).allSatisfy(\.isWhitespace) {
                    if !final { break }
                    requestsEnd = true
                    pending = ""; whitespace = ""
                    break
                }
                if Self.command.hasPrefix(pending) {
                    if !final { break }
                    // An incomplete control line never hangs up or leaks into speech.
                    if pending.count >= 4 { pending = ""; whitespace = ""; break }
                }
            }
            pending.removeFirst()
            if first.isWhitespace {
                whitespace.append(first)
                if first.isNewline { atLineStart = true }
            } else {
                output += whitespace
                whitespace = ""
                output.append(first)
                atLineStart = false
            }
        }
        if final { output += whitespace; whitespace = "" }
        return output
    }
}

/// Remove copied timestamps only at line starts. Hold fragmented prefixes
/// before they reach display, storage or TTS.
struct CallTimestampStreamFilter {
    private var pending = ""
    private var atLineStart = true
    private var afterTimestamp = false
    private static let masks = ["[dddd-dd-dd d:dd]", "[dddd-dd-dd dd:dd]",
                                "[dddd-dd-dd d:dd:dd]", "[dddd-dd-dd dd:dd:dd]"]
        .flatMap { [$0, $0.replacingOccurrences(of: "-", with: ".")] }

    mutating func append(_ delta: String, final: Bool = false) -> String {
        pending += delta
        var output = ""
        while let first = pending.first {
            if afterTimestamp {
                if first.isWhitespace { pending.removeFirst(); continue }
                afterTimestamp = false
            }
            if atLineStart && first == "[" {
                if let mask = Self.masks.first(where: { Self.matches(String(pending.prefix($0.count)), mask: $0) && pending.count >= $0.count }) {
                    pending.removeFirst(mask.count)
                    afterTimestamp = true
                    continue
                }
                if Self.masks.contains(where: { Self.matches(pending, mask: $0) }) {
                    if !final { break }
                    // An interrupted/ended response must not reveal a partial stamp.
                    if pending.count >= 6 { pending = ""; break }
                }
            }
            output.append(first)
            pending.removeFirst()
            if first == "\n" { atLineStart = true }
            else if !first.isWhitespace { atLineStart = false }
        }
        return output
    }

    static func clean(_ text: String) -> String {
        var filter = Self()
        return filter.append(text, final: true)
    }

    private static func matches(_ text: String, mask: String) -> Bool {
        guard text.count <= mask.count else { return false }
        return zip(text, mask).allSatisfy { value, expected in
            expected == "d" ? (value.isASCII && value.isNumber) : value == expected
        }
    }
}
