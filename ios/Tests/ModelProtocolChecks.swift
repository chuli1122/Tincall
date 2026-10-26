// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct ModelProtocolChecks {
    static func main() throws {
        try checkProfilesAndRequests()
        try checkRequestSerializationOrder()
        try checkImageRequests()
        try checkOriginalAudioRequests()
        try checkSummaryRequests()
        try checkTimeAwareness()
        checkCallEndControl()
        try checkContextInstructionBlocks()
        try checkContextConfiguration()
        try checkContextSummaryPriority()
        try checkContextSummaryOverflow()
        try checkThinkingParameters()
        try checkStreams()
        try checkResponsesAndModels()
        print("PASS: legacy profiles, native request bodies and endpoints, optional parameters, summary overrides, three SSE protocols, termination failures, reasoning exclusion, model-list pagination, provider thinking settings and budget conflicts")
    }

    private static func checkOriginalAudioRequests() throws {
        let wave = PCM16Wave.data(pcm: Data(repeating: 0x12, count: 32_000), sampleRate: 16_000)
        let first = CallMessage(turnID: UUID(), role: .user, text: "Earlier transcript")
        let answer = CallMessage(turnID: first.turnID, role: .assistant, text: "Earlier reply")
        let current = CallMessage(turnID: UUID(), role: .user, text: "Local caption only")
        var role = CallRole(name: "Synthetic")
        let input = (messageID: current.id, audio: wave)
        let context = try CallContextBuilder.build(role: role, historyRecords: [], currentMessages: [first, answer, current], audioInput: input)
        precondition(context.messages.last?.content == "" && context.messages.last?.audio == wave)
        precondition(context.messages.contains { $0.content == first.text && $0.audio == nil })
        precondition(context.messages.contains { $0.content == answer.text && $0.audio == nil })
        for provider in [ConnectionProvider.gemini, .openAICompatible] {
            let connection = ConnectionProfile(name: "Synthetic", provider: provider, model: "synthetic")
            let body = try ModelRequestCodec.requestBody(connection: connection, messages: context.messages)
            let json = String(decoding: body, as: UTF8.self)
            precondition(json.contains(wave.base64EncodedString()) && !json.contains(current.text))
            precondition(json.contains(provider == .gemini ? "audio/wav" : "input_audio"))
            let logged = RequestLogText.requestJSON(body)!
            precondition(!logged.contains(wave.base64EncodedString()) && logged.contains("原声音频已省略"))
        }
        precondition(!ModelMessage.logText(context.messages).contains(wave.base64EncodedString()))
        let mp3 = try OriginalAudioEncoder.mp3(wave: wave)
        for provider in [ConnectionProvider.gemini, .openAICompatible] {
            let message = ModelMessage(role: "user", content: "", audio: mp3, audioFormat: .mp3)
            let body = try ModelRequestCodec.requestBody(connection: ConnectionProfile(name: "Synthetic", provider: provider, model: "synthetic"), messages: [message])
            let json = String(decoding: body, as: UTF8.self)
            precondition(json.contains(mp3.base64EncodedString()))
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            if provider == .gemini {
                let contents = object["contents"] as! [[String: Any]]
                let parts = contents.last!["parts"] as! [[String: Any]]
                precondition((parts.last!["inline_data"] as? [String: Any])?["mime_type"] as? String == "audio/mp3")
            } else {
                let messages = object["messages"] as! [[String: Any]]
                let parts = messages.last!["content"] as! [[String: Any]]
                precondition((parts.last!["input_audio"] as? [String: Any])?["format"] as? String == "mp3")
            }
            let logged = RequestLogText.requestJSON(body)!
            precondition(!logged.contains(mp3.base64EncodedString()) && logged.contains("原声音频已省略"))
            precondition(ModelMessage.logText([message]).contains("MP3") && !ModelMessage.logText([message]).contains(mp3.base64EncodedString()))
        }
        role.timeAwarenessEnabled = true
        let timed = try CallContextBuilder.build(role: role, historyRecords: [], currentMessages: [current], audioInput: input)
        precondition(timed.messages.last!.content.hasPrefix("[") && !timed.messages.last!.content.contains(current.text))
        let next = CallMessage(turnID: UUID(), role: .user, text: "Next caption")
        let history = try CallContextBuilder.build(role: CallRole(name: "Synthetic"), historyRecords: [],
            currentMessages: [current, next], audioInput: (messageID: next.id, audio: wave))
        precondition(history.messages.contains { $0.content == current.text && $0.audio == nil })
        let corrected = TranscriptResult(inputID: current.id, text: "Original", isFinal: true, audio: wave)
            .corrected(using: [SpeechRecognitionCorrection(source: "Original", replacement: "Corrected")])
        precondition(corrected.text == "Corrected" && corrected.audio == wave)
        let unsupported = ConnectionProfile(name: "Synthetic", provider: .anthropic, model: "synthetic")
        do {
            _ = try ModelRequestCodec.requestBody(connection: unsupported, messages: context.messages)
            preconditionFailure("Unsupported protocols must reject audio instead of dropping it")
        } catch is TincallError { }
        for audio in [Data(), Data(repeating: 0, count: 12 * 1_024 * 1_024 + 1)] {
            do {
                _ = try ModelRequestCodec.requestBody(connection: ConnectionProfile(name: "Synthetic", provider: .gemini, model: "synthetic"),
                    messages: [ModelMessage(role: "user", content: "", audio: audio)])
                preconditionFailure("Missing and oversized audio must fail explicitly")
            } catch is TincallError { }
        }
        print("PASS: current-turn audio, text-only history, timestamps, correction, protocol rejection and audio-free logs")
    }

    private static func checkCallEndControl() {
        for raw in ["再见。\n<end_call/>", "再见。\r\n  <end_call/> \n", "<end_call/>"] {
            let expected = raw.hasPrefix("再见") ? "再见。" : ""
            for split in 0...raw.count {
                var filter = CallEndStreamFilter()
                let first = filter.append(String(raw.prefix(split)))
                precondition(!filter.requestsEnd, "streaming command cannot hang up before completion")
                let output = first + filter.append(String(raw.dropFirst(split)), final: true)
                precondition(output == expected && filter.requestsEnd, "fragmented terminal command must be consumed")
            }
        }
        for literal in ["普通回复。", "标签是 `<end_call/>`", "再见。<end_call/>", "<end_call/>\n还有话", "<other_xml/>"] {
            var filter = CallEndStreamFilter()
            let output = literal.map { filter.append(String($0)) }.joined() + filter.append("", final: true)
            precondition(output == literal && !filter.requestsEnd, "quoted or nonterminal text must not hang up")
        }
        var incomplete = CallEndStreamFilter()
        precondition(incomplete.append("再见。\n<end_call", final: true) == "再见。" && !incomplete.requestsEnd)
        let role = CallRole(name: "Synthetic")
        let context = try! CallContextBuilder.build(role: role, historyRecords: [], currentMessages: [CallMessage(turnID: UUID(), role: .user, text: "Synthetic input")])
        precondition(context.messages.first?.content.contains("<end_call/>") == true)
    }

    private static func checkTimeAwareness() throws {
        var role = CallRole(name: "Synthetic")
        let user = CallMessage(turnID: UUID(), role: .user, text: "Test at 12:30", createdAt: Date(timeIntervalSince1970: 0))
        let plain = try CallContextBuilder.build(role: role, historyRecords: [], currentMessages: [user])
        precondition(plain.messages.last?.content == user.text)
        role.timeAwarenessEnabled = true
        let context = try CallContextBuilder.build(role: role, historyRecords: [], currentMessages: [user])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        precondition(context.messages.last?.content == "[\(formatter.string(from: user.createdAt))]\n" + user.text)
        precondition(context.messages.contains { $0.content.contains("<time_awareness>") })
        precondition(context.characterCount == context.messages.reduce(0) { $0 + $1.content.count })
        let restored = try JSONDecoder().decode(CallRole.self, from: JSONEncoder().encode(role))
        precondition(restored.timeAwarenessEnabled == true)
        let legacy = try JSONDecoder().decode(CallRole.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Legacy\",\"systemPrompt\":\"\",\"voiceID\":\"\"}".utf8))
        precondition(legacy.timeAwarenessEnabled == nil)
        precondition(legacy.mcpWaitTimeoutSeconds == nil && legacy.effectiveMCPWaitTimeoutSeconds == 120)
        role.mcpWaitTimeoutSeconds = 0
        precondition(role.effectiveMCPWaitTimeoutSeconds == 1)
        role.mcpWaitTimeoutSeconds = 131
        precondition(role.effectiveMCPWaitTimeoutSeconds == 130)
        precondition(CallContextBuilder.timeAwareInput(user.text, createdAt: user.createdAt,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!) == "[1970-01-01 08:00:00]\n" + user.text)
        precondition(CallContextBuilder.timeAwareInput(user.text, createdAt: user.createdAt,
            timeZone: TimeZone(identifier: "America/New_York")!) == "[1969-12-31 19:00:00]\n" + user.text)
        for stamp in ["[2026-10-19 08:01]", "[2026.10.19 8:01:02]"] {
            let raw = stamp + "\nHello\n" + stamp + " World at 12:30, on 2026-10-19."
            let expected = "Hello\nWorld at 12:30, on 2026-10-19."
            precondition(CallTimestampStreamFilter.clean(raw) == expected)
            for split in 0...raw.count {
                var filter = CallTimestampStreamFilter()
                let output = filter.append(String(raw.prefix(split))) + filter.append(String(raw.dropFirst(split)), final: true)
                precondition(output == expected, "split timestamp must not reach transcript or speech")
            }
        }
        for normal in ["Meet at 12:30", "2026-10-19 was a Monday", "[laughs] Hello", "The date [2026-10-19 08:01] is quoted."] {
            precondition(CallTimestampStreamFilter.clean(normal) == normal)
        }
    }

    private static func profile(_ provider: ConnectionProvider, endpoint: String = "https://models.example.test", model: String = "synthetic-model") -> ConnectionProfile {
        ConnectionProfile(name: "Synthetic", provider: provider, endpoint: URL(string: endpoint)!, model: model)
    }

    private static func checkSummaryRequests() throws {
        let turnID = UUID()
        let original = [CallMessage(turnID: turnID, role: .user, text: String(repeating: "完整通话", count: 20_000)),
                        CallMessage(turnID: turnID, role: .assistant, text: "Incomplete reply", status: .interrupted, interruption: .interrupt)]
        let transcript = CallSummaryRequestBuilder.transcript(from: original)
        precondition(transcript.hasPrefix("user: " + original[0].text))
        precondition(transcript.hasSuffix("assistant: " + original[1].recordedText), "Summary input must retain interruption notes and the full call")
        let customPrompt = "Custom summary instructions"
        let messages = CallSummaryRequestBuilder.messages(prompt: customPrompt, targetLength: 750, transcript: transcript, userName: "Test User", contactName: "Test Contact")
        precondition(messages.count == 2 && messages[0].role == "system" && messages[1].role == "user")
        precondition(messages[0].content.hasPrefix(customPrompt) && messages[0].content.contains("750"))
        precondition(messages[0].content.contains("user：Test User") && messages[0].content.contains("assistant：Test Contact"))
        precondition(messages[1].content == transcript && messages.allSatisfy { $0.images.isEmpty })
        let defaults = CallSummaryRequestBuilder.messages(prompt: " \n ", targetLength: 500, transcript: "", userName: "", contactName: "")
        precondition(defaults[0].content.hasPrefix(CallRole.defaultSummaryPrompt))
        for provider in [ConnectionProvider.openAICompatible, .anthropic, .gemini] {
            var connection = profile(provider)
            connection.temperature = 0.3
            connection.maxOutputTokens = 2400
            let body = try object(ModelRequestCodec.requestBody(connection: connection, messages: messages, stream: false))
            if provider == .gemini {
                let contents = body["contents"] as! [[String: Any]]
                let parts = contents[0]["parts"] as! [[String: String]]
                precondition(parts[0]["text"] == transcript)
                precondition((body["generationConfig"] as! [String: Any])["maxOutputTokens"] as? Int == 2400)
            } else {
                precondition(body["stream"] as? Bool == false)
                let sent = body["messages"] as! [[String: Any]]
                precondition(sent.last?["content"] as? String == transcript)
                precondition(body["max_tokens"] as? Int == 2400)
            }
        }
    }

    private static func checkRequestSerializationOrder() throws {
        func keys(_ json: String, indent: Int) -> [String] {
            let prefix = String(repeating: " ", count: indent) + "\""
            return json.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(indent + 1).prefix(while: { $0 != "\"" })) }
        }
        func equivalent(_ actual: Data, _ expected: [String: Any]) throws {
            let legacy = try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let oldObject = try object(legacy) as NSDictionary
            let newObject = try object(actual) as NSDictionary
            precondition(newObject.isEqual(oldObject), "Ordered encoding must preserve every field and value")
        }
        let text = "中文🙂 / \"quote\" \\ slash\n\r\t\u{0000}\u{001F}"
        let scalars: [String: Any] = ["text": text, "values": [true, false, NSNull(), 0, 1, -1, Int64.max, 0.25, -0.0, 1e-30] as [Any],
                                    "emptyObject": [String: Any](), "emptyArray": [Any](),
                                    "nested": [["content": text, "role": "user"]], "key\"\\\n": "escaped key"]
        try equivalent(ModelRequestJSON.data(withJSONObject: scalars), scalars)
        do {
            _ = try ModelRequestJSON.data(withJSONObject: ["temperature": Double.nan])
            preconditionFailure("Non-finite numbers must fail")
        } catch { }

        let image = Data([0xff, 0xd8, 0xff, 0xd9])
        let base64 = image.base64EncodedString()
        let messages = [ModelMessage(role: "system", content: "Synthetic system"),
                        ModelMessage(role: "user", content: text, images: [image]),
                        ModelMessage(role: "assistant", content: "Synthetic answer")]
        for provider in [ConnectionProvider.openAICompatible, .anthropic, .gemini] {
            for thinking in [false, true] {
                var connection = profile(provider)
                connection.maxOutputTokens = 2048
                if thinking {
                    switch provider {
                    case .openAICompatible: connection.openAIReasoningEffort = .high
                    case .anthropic:
                        connection.anthropicThinkingMode = .manual
                        connection.anthropicThinkingBudget = 1024
                    case .gemini:
                        connection.model = "gemini-2.5-flash"
                        connection.geminiThinkingBudget = 1024
                    default: preconditionFailure()
                    }
                } else {
                    connection.temperature = 0.25
                    if provider != .anthropic { connection.topP = 0.9 }
                }
                for stream in [true, false] {
                    var expected: [String: Any]
                    let topKeys: [String]
                    switch provider {
                    case .openAICompatible:
                        expected = ["model": connection.model, "stream": stream, "n": 1,
                                    "messages": [["role": "system", "content": "Synthetic system"],
                                                 ["role": "user", "content": [["type": "text", "text": text],
                                                     ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + base64]]]],
                                                 ["role": "assistant", "content": "Synthetic answer"]]]
                        expected[thinking ? "max_completion_tokens" : "max_tokens"] = 2048
                        if thinking { expected["reasoning_effort"] = "high" }
                        else { expected["temperature"] = 0.25; expected["top_p"] = 0.9 }
                        topKeys = ["model", "stream", "n"] + (thinking ? ["max_completion_tokens", "reasoning_effort"] : ["max_tokens", "temperature", "top_p"]) + ["messages"]
                    case .anthropic:
                        expected = ["model": connection.model, "stream": stream, "max_tokens": 2048, "system": "Synthetic system",
                                    "messages": [["role": "user", "content": [["type": "text", "text": text],
                                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]]],
                                                 ["role": "assistant", "content": "Synthetic answer"]]]
                        if thinking { expected["thinking"] = ["type": "enabled", "budget_tokens": 1024] }
                        else { expected["temperature"] = 0.25 }
                        topKeys = ["model", "stream", "max_tokens", thinking ? "thinking" : "temperature", "system", "messages"]
                    case .gemini:
                        var config: [String: Any] = ["maxOutputTokens": 2048]
                        if thinking { config["thinkingConfig"] = ["thinkingBudget": 1024] }
                        else { config["temperature"] = 0.25; config["topP"] = 0.9 }
                        expected = ["generationConfig": config, "systemInstruction": ["parts": [["text": "Synthetic system"]]],
                                    "contents": [["role": "user", "parts": [["text": text], ["inline_data": ["mime_type": "image/jpeg", "data": base64]]]],
                                                 ["role": "model", "parts": [["text": "Synthetic answer"]]]]]
                        topKeys = ["generationConfig", "systemInstruction", "contents"]
                    default: preconditionFailure()
                    }
                    let data = try ModelRequestCodec.requestBody(connection: connection, messages: messages, stream: stream)
                    try equivalent(data, expected)
                    let json = String(decoding: data, as: UTF8.self)
                    precondition(keys(json, indent: 2) == topKeys)
                    let messageJSON = json.components(separatedBy: "  \"\(provider == .gemini ? "contents" : "messages")\": ").last!
                    let messageKeys = keys(messageJSON, indent: 6)
                    let count = provider == .openAICompatible ? 3 : 2
                    precondition(messageKeys == Array(repeating: ["role", provider == .gemini ? "parts" : "content"], count: count).flatMap { $0 })
                    if provider == .gemini {
                        precondition(keys(json, indent: 4) == (thinking ? ["maxOutputTokens", "thinkingConfig", "parts"] : ["maxOutputTokens", "temperature", "topP", "parts"]))
                        precondition(keys(json, indent: 12) == ["mime_type", "data"])
                    } else {
                        precondition(keys(json, indent: 10) == ["type", "text", "type", provider == .anthropic ? "source" : "image_url"])
                        precondition(keys(json, indent: 12) == (provider == .anthropic ? ["type", "media_type", "data"] : ["url"]))
                        if thinking && provider == .anthropic { precondition(keys(json, indent: 4) == ["type", "budget_tokens"]) }
                    }
                }
                let role = CallRole(name: "Synthetic", systemPrompt: "Synthetic system")
                let preview = try CallContextBuilder.requestPreview(role: role, connection: connection, historyRecords: [], input: "Preview")
                let context = try CallContextBuilder.build(role: role, historyRecords: [], currentMessages: [
                    CallMessage(turnID: UUID(), role: .user, text: "Preview")
                ])
                let wire = try ModelRequestCodec.requestBody(connection: connection, messages: context.messages)
                precondition(Data(preview.requestJSON.utf8) == wire)
            }
        }
        // Defaults, empty text, image-only input, and per-request output overrides retain
        // the legacy payload too; Gemini's model and streaming mode live in the URL.
        for provider in [ConnectionProvider.openAICompatible, .anthropic, .gemini] {
            for images in [[], [image]] as [[Data]] {
                let messages = [ModelMessage(role: "user", content: "", images: images)]
                let blocks: [[String: Any]]
                switch provider {
                case .openAICompatible: blocks = [["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + base64]]]
                case .anthropic: blocks = [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]]
                case .gemini: blocks = [["inline_data": ["mime_type": "image/jpeg", "data": base64]]]
                default: preconditionFailure()
                }
                for maximum in [nil, 512] as [Int?] {
                    var expected: [String: Any]
                    switch provider {
                    case .openAICompatible:
                        expected = ["model": "synthetic-model", "stream": false, "n": 1,
                                    "messages": [["role": "user", "content": images.isEmpty ? "" as Any : blocks]]]
                        expected["max_tokens"] = maximum
                    case .anthropic:
                        expected = ["model": "synthetic-model", "stream": false, "max_tokens": maximum ?? 4096,
                                    "messages": [["role": "user", "content": images.isEmpty ? "" as Any : blocks]]]
                    case .gemini:
                        expected = ["contents": [["role": "user", "parts": images.isEmpty ? [] : blocks]]]
                        if let maximum { expected["generationConfig"] = ["maxOutputTokens": maximum] }
                    default: preconditionFailure()
                    }
                    let data = try ModelRequestCodec.requestBody(connection: profile(provider), messages: messages, maxOutputTokens: maximum, stream: false)
                    try equivalent(data, expected)
                }
            }
        }
        let modes: [(ConnectionProfile, String, [String: Any])] = {
            var off = profile(.anthropic); off.anthropicThinkingMode = .off
            var adaptive = profile(.anthropic); adaptive.anthropicThinkingMode = .adaptive; adaptive.anthropicEffort = .high
            var level = profile(.gemini, model: "gemini-3-pro"); level.geminiThinkingLevel = .high
            return [(off, "thinking", ["type": "disabled"]),
                    (adaptive, "thinking", ["type": "adaptive"]),
                    (level, "generationConfig", ["thinkingConfig": ["thinkingLevel": "HIGH"]])]
        }()
        for (connection, key, config) in modes {
            let data = try ModelRequestCodec.requestBody(connection: connection, messages: [ModelMessage(role: "user", content: text)])
            var legacy: [String: Any] = connection.provider == .gemini
                ? ["contents": [["role": "user", "parts": [["text": text]]]]]
                : ["model": connection.model, "stream": true, "max_tokens": 4096,
                   "messages": [["role": "user", "content": text]]]
            legacy[key] = config
            if connection.anthropicEffort != nil { legacy["output_config"] = ["effort": "high"] }
            try equivalent(data, legacy)
            let json = String(decoding: data, as: UTF8.self)
            precondition(keys(json, indent: 2) == (connection.provider == .gemini
                ? ["generationConfig", "contents"]
                : ["model", "stream", "max_tokens", "thinking"] + (connection.anthropicEffort == nil ? [] : ["output_config"]) + ["messages"]))
            if connection.provider == .anthropic { precondition(keys(json, indent: 4).first == "type") }
        }
        print("PASS: ordered request JSON preserves legacy objects, scalar types/escaping, three providers, thinking, images and preview/wire identity")
    }

    private static func checkImageRequests() throws {
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        for caption in ["", "Synthetic caption"] {
            let message = ModelMessage(role: "user", content: caption, images: [bytes, bytes])
            for provider in [ConnectionProvider.openAICompatible, .anthropic, .gemini] {
                let body = try object(ModelRequestCodec.requestBody(connection: profile(provider), messages: [message]))
                let conversation = body[provider == .gemini ? "contents" : "messages"] as! [[String: Any]]
                let blocks = conversation[0][provider == .gemini ? "parts" : "content"] as! [[String: Any]]
                precondition(conversation.count == 1 && blocks.count == (caption.isEmpty ? 2 : 3))
                if !caption.isEmpty { precondition(blocks[0]["text"] as? String == caption) }
                for block in blocks.suffix(2) {
                    switch provider {
                    case .openAICompatible:
                        precondition(block["type"] as? String == "image_url")
                        precondition((block["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64," + bytes.base64EncodedString())
                    case .anthropic:
                        let source = block["source"] as! [String: String]
                        precondition(block["type"] as? String == "image" && source["type"] == "base64")
                        precondition(source["media_type"] == "image/jpeg" && source["data"] == bytes.base64EncodedString())
                    case .gemini:
                        let data = block["inline_data"] as! [String: String]
                        precondition(data["mime_type"] == "image/jpeg" && data["data"] == bytes.base64EncodedString())
                    default: preconditionFailure()
                    }
                }
            }
            let logged = ModelMessage.logText([message])
            precondition(logged.hasPrefix("[user]\n" + caption))
            for index in 1...2 {
                precondition(logged.contains(String(localized: "[图片 \(index)：JPEG，\(bytes.count) 字节]")))
            }
            precondition(!logged.contains(bytes.base64EncodedString()))
        }
        let id = UUID(), imageID = UUID()
        let message = CallMessage(id: id, turnID: UUID(), role: .user, text: "", images: [
            CallImageAsset(id: imageID, relativePath: "synthetic.jpg")
        ])
        let context = try CallContextBuilder.build(role: CallRole(name: "Synthetic"), historyRecords: [], currentMessages: [message], loadImages: { _ in [bytes] })
        precondition(context.messages.last?.images == [bytes] && context.messages.last?.content == "")
        try expectFailure { _ = try CallContextBuilder.build(role: CallRole(name: "Synthetic"), historyRecords: [], currentMessages: [message]) }
        let legacy = CallMessage(turnID: UUID(), role: .user, text: "Legacy")
        let decoded = try JSONDecoder().decode(CallMessage.self, from: JSONEncoder().encode(legacy))
        precondition(decoded.images == nil)
    }

    private static func checkContextInstructionBlocks() throws {
        let persona = "双方的设定\n\n<relationship>合成测试</relationship>"
        let role = CallRole(name: "Test Contact", systemPrompt: persona)
        var tts = profile(.elevenLabs)
        tts.expressionPrompt = "保留 [laughs] 与换行\n合成测试"
        let input = CallMessage(turnID: UUID(), role: .user, text: "Test input")
        let context = try CallContextBuilder.build(role: role, historyRecords: [], currentMessages: [input],
                                                   ttsConnection: tts, userName: "Test User")
        precondition(context.messages.map(\.role) == ["system", "system", "system", "user"])
        let scene = context.messages[0].content
        precondition(scene.hasPrefix("<call_context>\n") && scene.hasSuffix("\n</call_context>"))
        precondition(scene.contains("Test User") && scene.contains("Test Contact") && scene.contains("语音转写"))
        precondition(context.messages[1].content == "<conversation_settings>\n" + persona + "\n</conversation_settings>")
        precondition(context.messages[2].content == "<tts_instructions>\n" + tts.expressionPrompt! + "\n</tts_instructions>")
        precondition(context.messages.last?.content == input.text && role.systemPrompt == persona)
        precondition(context.characterCount == context.messages.reduce(0) { $0 + $1.content.count })
        for provider in [ConnectionProvider.openAICompatible, .anthropic, .gemini] {
            let connection = profile(provider)
            let preview = try CallContextBuilder.requestPreview(role: role, connection: connection, historyRecords: [], input: input.text,
                                                                ttsConnection: tts, userName: "Test User")
            let wire = try ModelRequestCodec.requestBody(connection: connection, messages: context.messages)
            precondition(Data(preview.requestJSON.utf8) == wire && preview.characterCount == context.characterCount)
        }
        let empty = try CallContextBuilder.build(role: CallRole(name: "Test Contact"), historyRecords: [], currentMessages: [input])
        precondition(empty.messages.count == 2 && !empty.messages[0].content.contains("user 是"))
        precondition(empty.messages[0].content.contains("assistant 是「Test Contact」"))
        precondition(!empty.messages.contains { $0.content.contains("<conversation_settings>") || $0.content.contains("<tts_instructions>") })
        var limited = role
        limited.contextCharacterBudget = 1_000
        try expectFailure {
            _ = try CallContextBuilder.build(role: limited, historyRecords: [], currentMessages: [
                CallMessage(turnID: UUID(), role: .user, text: String(repeating: "字", count: 900))
            ], ttsConnection: tts, userName: "Test User")
        }
        print("PASS: tagged call context, conversation settings and TTS instructions, names, empty blocks, exact character budget and three-provider preview/wire identity")
    }

    private static func checkContextConfiguration() throws {
        var role = CallRole(name: "Synthetic", summaryConnectionID: UUID(), systemPrompt: "Synthetic persona", historySummaryCount: 2)
        let summaryID = role.summaryConnectionID
        let record = CallRecord(roleID: role.id, roleName: role.name, endedAt: Date(), summaryStatus: .completed, summary: "Synthetic prior summary")
        let input = CallMessage(turnID: UUID(), role: .user, text: "Synthetic input")
        func context() throws -> CallContext {
            try CallContextBuilder.build(role: role, historyRecords: [record], currentMessages: [input])
        }
        precondition(role.canReorderContextModules)
        let initial = try context()
        precondition(initial.includedSummaryCount == 1 && initial.messages[1].content == "<conversation_settings>\nSynthetic persona\n</conversation_settings>")
        precondition(initial.omittedTurnCount == 0)
        role.contextModuleOrder = [.historySummaries, .persona, .currentConversation]
        let reordered = try context()
        precondition(reordered.messages[1].content.contains("Synthetic prior summary"))
        precondition(reordered.messages.last?.content == input.text)

        role.summaryConnectionID = nil
        precondition(role.effectiveHistorySummaryCount == 0 && !role.canReorderContextModules)
        let withoutSummary = try context()
        precondition(withoutSummary.includedSummaryCount == 0 && withoutSummary.messages.count == 3)
        role.summaryConnectionID = summaryID
        precondition(role.effectiveHistorySummaryCount == 2 && role.canReorderContextModules)
        role.historySummaryCount = 0
        precondition(!role.canReorderContextModules)
        let zeroSummaries = try context()
        precondition(zeroSummaries.includedSummaryCount == 0)

        role.historySummaryCount = 2
        role.systemPrompt = " \n "
        precondition(!role.effectivePersonaEnabled && !role.canReorderContextModules)
        let withoutPersona = try context()
        precondition(withoutPersona.includedSummaryCount == 1 && withoutPersona.messages.count == 3)

        role.systemPrompt = "Synthetic persona"
        var legacy = try object(JSONEncoder().encode(role))
        legacy["personaEnabled"] = false
        role = try JSONDecoder().decode(CallRole.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(role.effectivePersonaEnabled && role.canReorderContextModules)
        let restored = try context()
        precondition(restored.messages.contains { $0.content == "<conversation_settings>\nSynthetic persona\n</conversation_settings>" }, "Legacy hidden switches must not suppress a filled persona")

        role.contextCharacterBudget = 1_000
        let limited = try context()
        precondition(limited.characterCount <= 1_000 && limited.messages.last?.content == input.text)
        role.callMode = .mcp
        precondition(!role.canReorderContextModules)
        try expectFailure { _ = try context() }
    }

    private static func checkContextSummaryPriority() throws {
        var role = CallRole(name: "Synthetic", summaryConnectionID: UUID(), systemPrompt: "Synthetic persona", historySummaryCount: 2,
                            contextCharacterBudget: 1_250)
        var tts = profile(.elevenLabs)
        tts.expressionPrompt = "Synthetic expression"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let histories = (0..<3).map { index in
            CallRecord(roleID: role.id, roleName: role.name, startedAt: date.addingTimeInterval(Double(index * 60)),
                       endedAt: date.addingTimeInterval(Double(index * 60 + 30)), summaryStatus: .completed,
                       summary: "Summary \(index): " + String(repeating: "摘", count: 120))
        }
        var messages: [CallMessage] = []
        for index in 0..<4 {
            let turnID = UUID()
            messages.append(CallMessage(turnID: turnID, role: .user, text: "Input \(index): " + String(repeating: "问", count: 130)))
            messages.append(CallMessage(turnID: turnID, role: .assistant, text: "Answer \(index): " + String(repeating: "答", count: 130)))
        }
        messages.append(CallMessage(turnID: UUID(), role: .user, text: String(repeating: "新", count: 100)))
        let record = CallRecord(roleID: role.id, roleName: role.name, messages: messages)
        for order: [CallContextModule] in [[.persona, .historySummaries, .currentConversation], [.historySummaries, .persona, .currentConversation]] {
            role.contextModuleOrder = order
            let context = try CallContextBuilder.build(role: role, historyRecords: histories.reversed(), currentMessages: record.messages, ttsConnection: tts)
            precondition(context.includedSummaryCount == 2)
            let systems = context.messages.filter { $0.role == "system" }
            let summaries = systems.filter { $0.content.hasPrefix("<call_summary>\n") }
            precondition(summaries.count == 2 && summaries[0].content.hasSuffix(histories[1].summary + "\n</call_summary>") && summaries[1].content.hasSuffix(histories[2].summary + "\n</call_summary>"))
            precondition(systems.dropFirst().first?.content == (order.first == .persona ? "<conversation_settings>\n\(role.systemPrompt)\n</conversation_settings>" : summaries[0].content))
            precondition(systems.last?.content == "<tts_instructions>\n\(tts.expressionPrompt!)\n</tts_instructions>")
            let retained = Array(messages.suffix(3)).map { ModelMessage(role: $0.role.rawValue, content: $0.recordedText) }
            precondition(Array(context.messages.dropFirst(systems.count)) == retained, "Only the latest complete turn and new input should fit")
            precondition(context.omittedMessageCount == 6)
            precondition(context.omittedTurnCount == 3, "Two messages sharing a turnID count as one omitted turn")
            precondition(context.characterCount == context.messages.reduce(0) { $0 + $1.content.count } && context.characterCount <= role.effectiveContextCharacterBudget)
            precondition(record.messages == messages, "Request trimming must preserve the complete local transcript")
        }
    }

    private static func checkContextSummaryOverflow() throws {
        let role = CallRole(name: "Synthetic", summaryConnectionID: UUID(), systemPrompt: "Synthetic persona", historySummaryCount: 2,
                            contextCharacterBudget: 1_000)
        let histories = (0..<2).map { _ in
            CallRecord(roleID: role.id, roleName: role.name, endedAt: Date(), summaryStatus: .completed,
                       summary: String(repeating: "摘", count: 500))
        }
        let input = CallMessage(turnID: UUID(), role: .user, text: "Synthetic input")
        do {
            _ = try CallContextBuilder.build(role: role, historyRecords: histories, currentMessages: [input])
            preconditionFailure("All selected summaries must fit; silently dropping one is not allowed")
        } catch let error as TincallError {
            precondition(error.message == "系统提示、历史摘要与本轮发言已超出上下文上限，请调大上限或减少引用的历史通话数")
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static func checkProfilesAndRequests() throws {
        let messages = [ModelMessage(role: "system", content: "Persona"), ModelMessage(role: "system", content: "Prior summary"),
                        ModelMessage(role: "user", content: "First input"), ModelMessage(role: "assistant", content: "Earlier answer"),
                        ModelMessage(role: "user", content: "New input")]
        precondition(ModelMessage.logText(messages) == "[system]\nPersona\n\n[system]\nPrior summary\n\n[user]\nFirst input\n\n[assistant]\nEarlier answer\n\n[user]\nNew input")
        let legacyData = Data("{\"id\":\"B708B4BF-348F-44FB-B4B3-BAE3F2BCDC76\",\"name\":\"Legacy\",\"provider\":\"openAICompatible\",\"model\":\"legacy\",\"applicationID\":\"\",\"voiceID\":\"\"}".utf8)
        let legacy = try JSONDecoder().decode(ConnectionProfile.self, from: legacyData)
        precondition(legacy.temperature == nil && legacy.topP == nil && legacy.maxOutputTokens == nil)
        precondition(legacy.openAIReasoningEffort == nil && legacy.anthropicThinkingMode == nil && legacy.anthropicThinkingBudget == nil && legacy.anthropicEffort == nil && legacy.geminiThinkingLevel == nil && legacy.geminiThinkingBudget == nil)
        precondition(ConnectionProvider.whisperCompatible.isSpeechRecognition && ConnectionProvider.fishAudio.isSpeechSynthesis)
        var role = CallRole(name: "Synthetic", summaryConnectionID: UUID(), historySummaryCount: 99)
        precondition(role.effectiveHistorySummaryCount == 5)
        role.historySummaryCount = -2
        precondition(role.effectiveHistorySummaryCount == 0)

        for provider in [ConnectionProvider.openAICompatible, .anthropic, .gemini] {
            var connection = profile(provider)
            let plain = try object(ModelRequestCodec.requestBody(connection: connection, messages: messages))
            if provider == .gemini {
                precondition(plain["generationConfig"] == nil && plain["stream"] == nil)
                let rows = plain["contents"] as! [[String: Any]]
                precondition(rows.count == 3 && rows[1]["role"] as? String == "model")
                let system = plain["systemInstruction"] as! [String: Any]
                precondition((system["parts"] as! [[String: String]])[0]["text"] == "Persona\n\nPrior summary")
            } else {
                precondition(plain["temperature"] == nil && plain["top_p"] == nil && plain["reasoning_effort"] == nil && plain["thinking"] == nil && plain["output_config"] == nil)
                precondition(plain["stream"] as? Bool == true)
                if provider == .anthropic {
                    precondition(plain["max_tokens"] as? Int == 4096 && plain["system"] as? String == "Persona\n\nPrior summary")
                    precondition((plain["messages"] as! [[String: String]]).count == 3)
                } else { precondition(plain["max_tokens"] == nil && (plain["messages"] as! [[String: String]]).count == 5) }
            }
            connection.temperature = 0.5; connection.topP = 0.9; connection.maxOutputTokens = 700
            if provider == .anthropic {
                try expectFailure { _ = try ModelRequestCodec.requestBody(connection: connection, messages: messages) }
                connection.topP = nil
            }
            let body = try object(ModelRequestCodec.requestBody(connection: connection, messages: messages, maxOutputTokens: 1200, stream: false))
            if provider == .gemini {
                let config = body["generationConfig"] as! [String: Any]
                precondition(config["maxOutputTokens"] as? Int == 1200 && config["temperature"] as? Double == 0.5 && config["topP"] as? Double == 0.9)
            } else {
                precondition(body["max_tokens"] as? Int == 1200 && body["stream"] as? Bool == false && body["temperature"] as? Double == 0.5 && body["top_p"] as? Double == (provider == .anthropic ? nil : 0.9))
            }
            let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(connection))
            precondition(restored == connection)
            connection.temperature = .nan
            try expectFailure { _ = try ModelRequestCodec.requestBody(connection: connection, messages: messages) }
            connection.temperature = nil; connection.maxOutputTokens = 0
            try expectFailure { _ = try ModelRequestCodec.requestBody(connection: connection, messages: messages) }
        }
        let endpointCases: [(ConnectionProvider, String, String)] = [
            (.openAICompatible, "https://models.example.test", "/v1/chat/completions"),
            (.openAICompatible, "https://models.example.test/v1/", "/v1/chat/completions"),
            (.openAICompatible, "https://models.example.test/custom/chat/completions", "/custom/chat/completions"),
            (.openAICompatible, "https://models.example.test/chat/completions", "/chat/completions"),
            (.anthropic, "https://models.example.test", "/v1/messages"),
            (.anthropic, "https://models.example.test/proxy/v1/messages", "/proxy/v1/messages"),
            (.anthropic, "https://models.example.test/messages", "/messages"),
            (.gemini, "https://models.example.test", "/v1beta/models/synthetic-model:streamGenerateContent"),
            (.gemini, "https://models.example.test/v1beta/models/old:generateContent", "/v1beta/models/synthetic-model:streamGenerateContent")
        ]
        for (provider, input, path) in endpointCases {
            let connection = profile(provider, endpoint: input)
            let url = try ModelRequestCodec.resolvedEndpoint(connection: connection)
            precondition(url.path == path)
            precondition(url.query == (provider == .gemini ? "alt=sse" : nil))
        }
        let gemini = profile(.gemini, model: "models/gemini-synthetic")
        let nonstream = try ModelRequestCodec.resolvedEndpoint(connection: gemini, stream: false)
        precondition(nonstream.path == "/v1beta/models/gemini-synthetic:generateContent" && nonstream.query == nil)
        for invalid in ["http://models.example.test", "https://private@models.example.test", "https://models.example.test?key=private", "https://models.example.test#fragment"] {
            try expectFailure { _ = try ModelRequestCodec.resolvedEndpoint(connection: profile(.openAICompatible, endpoint: invalid)) }
        }
        try expectFailure { _ = try ModelRequestCodec.resolvedEndpoint(connection: profile(.gemini, model: "../other:method")) }
        let listURL = try ModelRequestCodec.modelsEndpoint(connection: profile(.anthropic, endpoint: "https://models.example.test/prefix/messages", model: ""))
        precondition(listURL.path == "/prefix/models")
        let preview = try CallContextBuilder.requestPreview(role: CallRole(name: "Synthetic"), connection: gemini, historyRecords: [], input: "Preview")
        check(try object(Data(preview.requestJSON.utf8))["contents"] != nil)
    }

    private static func checkThinkingParameters() throws {
        let messages = [ModelMessage(role: "user", content: "Synthetic input")]
        var openAI = profile(.openAICompatible)
        openAI.maxOutputTokens = 2000
        for effort in OpenAIReasoningEffort.allCases {
            openAI.openAIReasoningEffort = effort
            let body = try object(ModelRequestCodec.requestBody(connection: openAI, messages: messages))
            precondition(body["reasoning_effort"] as? String == effort.rawValue)
            precondition(body["max_completion_tokens"] as? Int == 2000 && body["max_tokens"] == nil)
        }
        let decodedOpenAI = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(openAI))
        precondition(decodedOpenAI == openAI)
        precondition(ModelRequestCodec.connectionTestOutputLimit(openAI) == nil)
        openAI.model = "gpt-6-astra"; openAI.openAIReasoningEffort = OpenAIReasoningEffort.none
        try expectFailure { try ModelRequestCodec.validateParameters(openAI) }
        openAI.model = "gpt-6.1-sol"; openAI.openAIReasoningEffort = .minimal
        try expectFailure { try ModelRequestCodec.validateParameters(openAI) }
        openAI.openAIReasoningEffort = .low
        try ModelRequestCodec.validateParameters(openAI)
        openAI.provider = .gemini
        try expectFailure { try ModelRequestCodec.validateParameters(openAI) }

        var anthropic = profile(.anthropic, model: "claude-sonnet-4-6")
        anthropic.anthropicThinkingMode = .off
        var body = try object(ModelRequestCodec.requestBody(connection: anthropic, messages: messages))
        precondition((body["thinking"] as? [String: String])?["type"] == "disabled" && body["output_config"] == nil)
        anthropic.anthropicThinkingMode = .adaptive
        for effort in AnthropicEffort.allCases {
            anthropic.anthropicEffort = effort
            body = try object(ModelRequestCodec.requestBody(connection: anthropic, messages: messages, stream: false))
            precondition((body["thinking"] as? [String: String])?["type"] == "adaptive")
            precondition((body["output_config"] as? [String: String])?["effort"] == effort.rawValue)
        }
        let decodedAdaptive = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(anthropic))
        precondition(decodedAdaptive == anthropic)
        anthropic.anthropicThinkingMode = .manual; anthropic.anthropicThinkingBudget = 1024
        try expectFailure { try ModelRequestCodec.validateParameters(anthropic) }
        anthropic.anthropicEffort = nil
        precondition(ModelRequestCodec.connectionTestOutputLimit(anthropic) == nil)
        body = try object(ModelRequestCodec.requestBody(connection: anthropic, messages: messages,
            maxOutputTokens: ModelRequestCodec.connectionTestOutputLimit(anthropic), stream: false))
        precondition((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 1024 && body["max_tokens"] as? Int == 4096)
        body = try object(ModelRequestCodec.requestBody(connection: anthropic, messages: messages, maxOutputTokens: 2048, stream: false))
        precondition(body["max_tokens"] as? Int == 2048)
        try expectFailure { _ = try ModelRequestCodec.requestBody(connection: anthropic, messages: messages, maxOutputTokens: 1024, stream: false) }
        anthropic.anthropicThinkingBudget = 1023
        try expectFailure { try ModelRequestCodec.validateParameters(anthropic) }
        anthropic.anthropicThinkingBudget = 1024; anthropic.temperature = 1
        try expectFailure { try ModelRequestCodec.validateParameters(anthropic) }
        anthropic.temperature = nil; anthropic.topP = 0.99
        try expectFailure { try ModelRequestCodec.validateParameters(anthropic) }
        anthropic.topP = nil; anthropic.anthropicThinkingMode = .adaptive
        try expectFailure { try ModelRequestCodec.validateParameters(anthropic) }
        anthropic.anthropicThinkingMode = .off
        try expectFailure { try ModelRequestCodec.validateParameters(anthropic) }
        anthropic.anthropicThinkingMode = nil
        try expectFailure { try ModelRequestCodec.validateParameters(anthropic) }
        anthropic.anthropicThinkingMode = .manual
        let decodedManual = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(anthropic))
        precondition(decodedManual == anthropic)

        var gemini = profile(.gemini, model: "gemini-3.1-pro-preview")
        for level in [GeminiThinkingLevel.low, .medium, .high] {
            gemini.geminiThinkingLevel = level
            body = try object(ModelRequestCodec.requestBody(connection: gemini, messages: messages))
            let generation = body["generationConfig"] as! [String: Any]
            let thinking = generation["thinkingConfig"] as! [String: Any]
            precondition(thinking["thinkingLevel"] as? String == level.rawValue.uppercased() && thinking["thinkingBudget"] == nil && thinking["includeThoughts"] == nil)
        }
        precondition(ModelRequestCodec.connectionTestOutputLimit(gemini) == nil)
        let decodedGemini = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(gemini))
        precondition(decodedGemini == gemini)
        gemini.geminiThinkingLevel = .minimal
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingLevel = .low; gemini.geminiThinkingBudget = 1024
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingBudget = nil; gemini.model = "gemini-2.5-flash"
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingLevel = nil
        for budget in [-1, 0, 1, 1024, 24576] {
            gemini.geminiThinkingBudget = budget
            body = try object(ModelRequestCodec.requestBody(connection: gemini, messages: messages))
            let generation = body["generationConfig"] as! [String: Any]
            precondition((generation["thinkingConfig"] as? [String: Int])?["thinkingBudget"] == budget)
        }
        gemini.geminiThinkingBudget = 24577
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingBudget = 1024; gemini.maxOutputTokens = 1024
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.maxOutputTokens = 2048
        try ModelRequestCodec.validateParameters(gemini)
        try expectFailure { try ModelRequestCodec.validateParameters(gemini, maxOutputTokens: 512) }
        gemini.maxOutputTokens = nil; gemini.model = "gemini-2.5-pro"; gemini.geminiThinkingBudget = 0
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingBudget = 127
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingBudget = 128
        try ModelRequestCodec.validateParameters(gemini)
        gemini.model = "gemini-2.5-flash-lite"; gemini.geminiThinkingBudget = 511
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingBudget = 0
        try ModelRequestCodec.validateParameters(gemini)
        precondition(ModelRequestCodec.connectionTestOutputLimit(gemini) == 64)
        gemini.geminiThinkingBudget = -1
        try ModelRequestCodec.validateParameters(gemini)
        gemini.model = "gemini-3.1-pro-preview"
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.model = "custom-supported-model"; gemini.geminiThinkingBudget = -2
        try expectFailure { try ModelRequestCodec.validateParameters(gemini) }
        gemini.geminiThinkingBudget = 1024
        let decodedBudget = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(gemini))
        precondition(decodedBudget == gemini)
    }

    @discardableResult
    private static func event(_ payload: String, decoder: inout ChatCompletionStreamDecoder) throws -> String {
        _ = try decoder.consume(line: "event: ignored-by-data-parser")
        _ = try decoder.consume(line: "data: " + payload)
        return try decoder.consume(line: "") ?? ""
    }

    private static func checkStreams() throws {
        var openAI = ChatCompletionStreamDecoder()
        check(try event(#"{"choices":[{"index":0,"delta":{"reasoning_content":"Internal synthetic reasoning"}}]}"#, decoder: &openAI) == "")
        check(try event(#"{"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}"#, decoder: &openAI) == "你好")
        check(try event(#"{"choices":[{"index":0,"delta":{"content":"。"},"finish_reason":"stop"}]}"#, decoder: &openAI) == "。")
        try event("[DONE]", decoder: &openAI)
        _ = try openAI.finish()
        precondition(openAI.text == "你好。")
        precondition(openAI.reasoning == "Internal synthetic reasoning")
        var reasoningAlias = ChatCompletionStreamDecoder()
        try event(#"{"choices":[{"delta":{"reasoning":"alias"}}]}"#, decoder: &reasoningAlias)
        precondition(reasoningAlias.reasoning == "alias" && reasoningAlias.text.isEmpty)

        var anthropic = ChatCompletionStreamDecoder(provider: .anthropic)
        try event(#"{"type":"message_start","message":{"content":[]}}"#, decoder: &anthropic)
        try event(#"{"type":"content_block_start","content_block":{"type":"thinking","thinking":"private reasoning"}}"#, decoder: &anthropic)
        try event(#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"never speak"}}"#, decoder: &anthropic)
        check(try event(#"{"type":"content_block_start","content_block":{"type":"text","text":"Hello "}}"#, decoder: &anthropic) == "Hello ")
        check(try event(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"there"}}"#, decoder: &anthropic) == "there")
        try event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, decoder: &anthropic)
        try expectFailure { _ = try anthropic.finish() }
        try event(#"{"type":"message_stop"}"#, decoder: &anthropic)
        _ = try anthropic.finish()
        precondition(anthropic.text == "Hello there")
        precondition(anthropic.reasoning == "private reasoningnever speak")

        var gemini = ChatCompletionStreamDecoder(provider: .gemini)
        check(try event(#"{"candidates":[{"index":0,"content":{"parts":[{"thought":true,"text":"never speak"},{"text":"Real "}]}}]}"#, decoder: &gemini) == "Real ")
        check(try event(#"{"candidates":[{"index":0,"content":{"parts":[{"text":"answer"}]},"finishReason":"STOP"}]}"#, decoder: &gemini) == "answer")
        _ = try gemini.finish()
        precondition(gemini.text == "Real answer")
        precondition(gemini.reasoning == "never speak")

        for (provider, payload) in [(ConnectionProvider.openAICompatible, #"{"choices":[{"index":0,"delta":{"content":"Retained"},"finish_reason":"length"}]}"#),
                                    (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"Retained"}]},"finishReason":"MAX_TOKENS"}]}"#)] {
            var decoder = ChatCompletionStreamDecoder(provider: provider)
            check(try event(payload, decoder: &decoder) == "Retained")
            try expectFailure { _ = try decoder.finish() }
            precondition(decoder.text == "Retained")
        }
        var safety = ChatCompletionStreamDecoder(provider: .gemini)
        try event(#"{"candidates":[{"finishReason":"SAFETY"}]}"#, decoder: &safety)
        try expectFailure { _ = try safety.finish() }
        var blocked = ChatCompletionStreamDecoder(provider: .gemini)
        try event(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#, decoder: &blocked)
        try expectFailure { _ = try blocked.finish() }
        var incomplete = ChatCompletionStreamDecoder()
        try event(#"{"choices":[{"index":0,"delta":{"content":"Partial"}}]}"#, decoder: &incomplete)
        try expectFailure { _ = try incomplete.finish() }
        precondition(incomplete.text == "Partial")
        var tool = ChatCompletionStreamDecoder(provider: .anthropic)
        try event(#"{"type":"content_block_start","content_block":{"type":"tool_use","id":"synthetic"}}"#, decoder: &tool)
        try expectFailure { _ = try tool.finish() }
        var failure = ChatCompletionStreamDecoder(provider: .gemini)
        try expectFailure { _ = try event(#"{"error":{"message":"synthetic service error"}}"#, decoder: &failure) }
        var empty = ChatCompletionStreamDecoder()
        try event(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, decoder: &empty)
        try event("[DONE]", decoder: &empty)
        try expectFailure { _ = try empty.finish() }
    }

    private static func checkResponsesAndModels() throws {
        let responses: [(ConnectionProvider, String)] = [
            (.openAICompatible, #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Summary"},"finish_reason":"stop"}]}"#),
            (.anthropic, #"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Summary"}],"stop_reason":"end_turn"}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"private"},{"text":"Summary"}]},"finishReason":"STOP"}]}"#)
        ]
        for (provider, response) in responses {
            check(try ModelResponseCodec.responseText(Data(response.utf8), provider: provider) == "Summary")
            check(try ModelResponseCodec.responseReasoning(Data(response.utf8), provider: provider) == (provider == .openAICompatible ? "" : "private"))
        }
        for key in ["reasoning_content", "reasoning"] {
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": [key: "summary reasoning"]]]])
            check(try ModelResponseCodec.responseReasoning(data, provider: .openAICompatible) == "summary reasoning")
        }
        try expectFailure { _ = try ModelResponseCodec.responseText(Data(#"{"content":[{"type":"text","text":"Incomplete"}],"stop_reason":"max_tokens"}"#.utf8), provider: .anthropic) }
        try expectFailure { _ = try ModelResponseCodec.responseText(Data(#"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"do_not_execute"}}]},"finishReason":"STOP"}]}"#.utf8), provider: .gemini) }
        let anthropic = try ModelResponseCodec.modelListPage(Data(#"{"data":[{"id":"claude-synthetic"}],"has_more":true,"last_id":"cursor-1"}"#.utf8), provider: .anthropic)
        precondition(anthropic.models == ["claude-synthetic"] && anthropic.nextCursor == "cursor-1")
        let gemini = try ModelResponseCodec.modelListPage(Data(#"{"models":[{"name":"models/gemini-synthetic","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-only","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"cursor-2"}"#.utf8), provider: .gemini)
        precondition(gemini.models == ["gemini-synthetic"] && gemini.nextCursor == "cursor-2")
        try expectFailure { _ = try ModelResponseCodec.modelListPage(Data(#"{"data":[],"has_more":true}"#.utf8), provider: .anthropic) }
    }

    private static func check(_ value: Bool) { precondition(value) }

    private static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() }
        catch is TincallError { return }
        throw TincallError(message: "Expected explicit protocol failure")
    }
}
