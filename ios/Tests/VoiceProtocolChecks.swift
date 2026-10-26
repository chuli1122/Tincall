// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct VoiceProtocolChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--speech-segments-only") {
            try checkTutorialSegments()
            try checkEnglishWordSegments()
            try checkTagScope()
            try checkExpressionSegments()
            checkDisplayText()
            print("PASS: speech segmentation, expression scope and transcript display")
            return
        }
        if CommandLine.arguments.contains("--whisper-only") {
            try checkWhisper()
            print("PASS: Whisper request, utterance and bounded input preservation")
            return
        }
        try checkWhisper()
        try checkFish()
        try checkTutorialSegments()
        try checkEnglishWordSegments()
        try checkTagScope()
        try checkExpressionSegments()
        checkDisplayText()
        print("PASS: Whisper HTTPS endpoint/multipart/auth/language/WAV/final response/utterance boundaries, Fish headers/PCM request/stream boundaries/error rejection, and provider expression segmentation")
    }

    private static func checkWhisper() throws {
        for (address, expected) in [
            ("https://voice.example.test", "/v1/audio/transcriptions"),
            ("https://voice.example.test/v1", "/v1/audio/transcriptions"),
            ("https://voice.example.test/proxy/v1/", "/proxy/v1/audio/transcriptions"),
            ("https://voice.example.test/custom/audio/transcriptions", "/custom/audio/transcriptions")
        ] {
            let configuration = try WhisperConfiguration(endpoint: URL(string: address), model: "", language: nil, apiKey: nil)
            precondition(configuration.endpoint.path == expected && configuration.model == "whisper-1")
        }
        for endpoint in ["http://voice.example.test", "https://user:secret@voice.example.test", "https://voice.example.test?key=secret", "https://voice.example.test/#token"] {
            try rejects { _ = try WhisperConfiguration(endpoint: URL(string: endpoint), model: "", language: nil, apiKey: nil) }
        }
        try rejects { _ = try WhisperConfiguration(endpoint: nil, model: "", language: nil, apiKey: nil) }
        try rejects { _ = try whisper(language: "zh-CN") }
        try rejects { _ = try whisper(model: "whisper-1\r\ninjected") }
        try rejects { _ = try whisper(key: "token\r\ninjected") }
        let pcm = Data([0, 0, 255, 127, 0, 128])
        let configuration = try whisper(model: "custom-model", language: "ZH", key: "synthetic-key")
        let request = try configuration.request(pcm: pcm)
        precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
        let contentType = request.value(forHTTPHeaderField: "Content-Type")!
        let boundary = String(contentType.split(separator: "=").last!)
        let body = request.httpBody!
        let strings = String(decoding: body, as: UTF8.self)
        precondition(strings.contains("name=\"model\"\r\n\r\ncustom-model\r\n"))
        precondition(strings.contains("name=\"language\"\r\n\r\nzh\r\n"))
        precondition(strings.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        precondition(strings.contains("filename=\"speech.wav\"\r\nContent-Type: audio/wav"))
        precondition(body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count) == Data("\r\n--\(boundary)--\r\n".utf8))
        precondition(!strings.contains("name=\"stream\""))
        let wave = PCM16Wave.data(pcm: pcm, sampleRate: 16_000)
        precondition(wave.count == pcm.count + 44 && body.range(of: wave) != nil && wave.suffix(pcm.count) == pcm)
        precondition(Array(wave[22..<24]) == [1, 0] && Array(wave[24..<28]) == [128, 62, 0, 0] && Array(wave[34..<36]) == [16, 0])
        let anonymous = try whisper().request(pcm: pcm)
        precondition(anonymous.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(!String(decoding: anonymous.httpBody!, as: UTF8.self).contains("name=\"language\""))
        try rejects { _ = try configuration.request(pcm: Data([1])) }
        try rejects { _ = try configuration.request(pcm: Data()) }
        check(try WhisperTranscription.text(from: Data(#"{"text":"  合成测试。  "}"#.utf8), statusCode: 200) == "合成测试。")
        check(try WhisperTranscription.text(from: Data(#"{"text":""}"#.utf8), statusCode: 200).isEmpty)
        try rejects { _ = try WhisperTranscription.text(from: Data(#"{"error":"private detail"}"#.utf8), statusCode: 401) }
        try rejects { _ = try WhisperTranscription.text(from: Data("plain text".utf8), statusCode: 200) }

        var utterance = WhisperUtteranceBuffer()
        let packet = Data(repeating: 0, count: 1024)
        check(try utterance.append(packet, hasSpeech: false) == nil && utterance.audio.isEmpty)
        check(try utterance.append(packet, hasSpeech: true) == nil)
        for _ in 0..<62 { check(try utterance.append(packet, hasSpeech: false) == nil) }
        let completed = try utterance.append(packet, hasSpeech: false)
        precondition(completed?.count == 64 * packet.count && utterance.audio.isEmpty)
        check(try utterance.append(packet, hasSpeech: true) == nil && utterance.audio == packet)
        utterance = WhisperUtteranceBuffer()
        for _ in 0..<599 { check(try utterance.append(Data(repeating: 1, count: 32_000), hasSpeech: true) == nil) }
        check(try utterance.append(Data(repeating: 1, count: 32_000), hasSpeech: true)?.count == 19_200_000)

        var continuous = WhisperInputBuffer()
        for _ in 0..<18750 { try continuous.append(packet, hasSpeech: true) }
        precondition(continuous.isFull)
        let longAudio = continuous.next()!
        precondition(longAudio.count == 19_200_000)
        let longResult = continuous.complete(text: "Long synthetic input")!
        precondition(longResult.pcm == longAudio && continuous.currentAudio.isEmpty && !continuous.isFull)

        // The same capacity applies across recognized, uploading and unfinished audio.
        for finishesEarly in [false, true] {
            var backlog = WhisperInputBuffer()
            let second = Data(repeating: 1, count: 32_000)
            try backlog.append(second, hasSpeech: true)
            for _ in 0..<2 { try backlog.append(second, hasSpeech: false) }
            let first = backlog.next()!
            try backlog.append(second, hasSpeech: true)
            if finishesEarly { precondition(backlog.complete(text: "First") == nil) }
            for _ in 0..<596 { try backlog.append(second, hasSpeech: true) }
            precondition(backlog.isFull && backlog.currentAudio.count == 19_200_000)
            if !finishesEarly {
                precondition(backlog.next() == nil)
                precondition(backlog.complete(text: "First") == nil)
            }
            let rest = backlog.next()!
            let result = backlog.complete(text: "Rest")!
            precondition(result.text == "First\nRest" && result.pcm == first + rest && !backlog.isFull)
        }

        var queued = WhisperInputBuffer()
        try queued.append(packet, hasSpeech: true)
        for _ in 0..<63 { try queued.append(packet, hasSpeech: false) }
        let first = queued.next()!
        precondition(queued.next() == nil)
        try queued.append(Data(repeating: 1, count: 1024), hasSpeech: true)
        precondition(queued.complete(text: "重复内容") == nil, "next utterance must survive an earlier HTTP completion")
        for _ in 0..<63 { try queued.append(packet, hasSpeech: false) }
        let second = queued.next()!
        let final = queued.complete(text: "重复内容")!
        precondition(final.text == "重复内容\n重复内容" && final.pcm == first + second)
        precondition(queued.currentAudio.isEmpty && queued.next() == nil && queued.complete(text: "late duplicate") == nil)
        try queued.append(packet, hasSpeech: true)
        queued = WhisperInputBuffer()
        precondition(queued.currentAudio.isEmpty && queued.next() == nil, "cancel discards only unfinished recognition")
    }

    private static func checkFish() throws {
        let configuration = try FishAudioConfiguration(apiKey: "synthetic-key", model: "", referenceID: "synthetic-voice")
        let request = try configuration.request(text: "合成测试。")
        precondition(request.url?.absoluteString == "https://api.fish.audio/v1/tts" && request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "model") == "s2.1-pro")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["text"] as? String == "合成测试。" && body["reference_id"] as? String == "synthetic-voice")
        precondition(body["format"] as? String == "pcm" && body["sample_rate"] as? Int == 24_000)
        precondition(body["stream"] == nil && body["model"] == nil)
        try rejects { _ = try FishAudioConfiguration(apiKey: "", model: "", referenceID: "voice") }
        try rejects { _ = try FishAudioConfiguration(apiKey: "key", model: "s2\r\ninjected", referenceID: "voice") }
        for mime in ["audio/pcm", "audio/pcm;rate=24000", "application/octet-stream"] {
            try FishPCMStream.validate(statusCode: 200, contentType: mime)
        }
        for mime in ["application/json", "text/html", "audio/mpeg", "audio/wav"] {
            try rejects { try FishPCMStream.validate(statusCode: 200, contentType: mime) }
        }
        try rejects { try FishPCMStream.validate(statusCode: 402, contentType: "application/octet-stream") }
        var stream = FishPCMStream()
        precondition(stream.consume(Data([1])).isEmpty)
        precondition(stream.consume(Data([2, 3, 4, 5])) == Data([1, 2, 3, 4]))
        precondition(stream.consume(Data([6])) == Data([5, 6]))
        try stream.finish()
        var incomplete = FishPCMStream()
        _ = incomplete.consume(Data([1, 2, 3]))
        try rejects { try incomplete.finish() }
        try rejects { try FishPCMStream().finish() }
        var segmenter = SpeechSegmenter(fishTags: true)
        let fishPartial = try segmenter.append("[whispers swe", final: false)
        precondition(fishPartial.isEmpty)
        let segments = try segmenter.append("etly]你好。[laughing]再见。", final: true)
        precondition(segments.map(\.text) == ["[whispers sweetly]你好。", "[laughing]再见。"])
        precondition(segments.map(\.caption) == ["你好。", "再见。"])
    }

    private static func checkTutorialSegments() throws {
        var first = SpeechSegmenter()
        let immediate = try first.append("短句。", final: false)
        precondition(immediate.map(\.text) == ["短句。"])
        var comma = SpeechSegmenter()
        let start = try comma.append(String(repeating: "甲", count: 11) + "，", final: false)
        precondition(start.count == 1 && start[0].bodyCount == 12)
        let short = try comma.append("短句。", final: false)
        precondition(short.isEmpty)
        let later = try comma.append(String(repeating: "乙", count: 17) + "：", final: false)
        precondition(later.count == 1 && later[0].bodyCount == 21)
        var exact = SpeechSegmenter()
        let cap = try exact.append(String(repeating: "甲", count: 48), final: false)
        precondition(cap.isEmpty, "Reaching the former character cap must not split a sentence")
        let naturalEnd = try exact.append(String(repeating: "乙", count: 25) + "。", final: false)
        precondition(naturalEnd.count == 1 && naturalEnd[0].bodyCount == 74)
        var unpunctuated = SpeechSegmenter()
        let long = try unpunctuated.append(String(repeating: "甲", count: 117), final: true)
        precondition(long.map(\.bodyCount) == [117], "An unpunctuated final sentence must be submitted intact")
        var finalTail = SpeechSegmenter()
        _ = try finalTail.append("首句。", final: false)
        let merged = try finalTail.append(String(repeating: "乙", count: 20) + "，短尾。", final: true)
        precondition(merged.count == 1 && merged[0].bodyCount == 24)
        for dots in ["…", "...", "."] {
            var protected = SpeechSegmenter()
            let text = String(repeating: "甲", count: 47) + dots + "乙。"
            let parts = try protected.append(text, final: true)
            precondition(parts.map(\.text).joined() == text)
            precondition(parts.count == 1 && parts[0].text == text)
            var splitDots = SpeechSegmenter()
            let awaiting = try splitDots.append(String(repeating: "甲", count: 47) + ".", final: false)
            precondition(awaiting.isEmpty)
            let completed = try splitDots.append(String(dots.dropFirst()) + "乙。", final: true)
            precondition(completed.map(\.text).joined() == String(repeating: "甲", count: 47) + "." + String(dots.dropFirst()) + "乙。")
        }
        var english = SpeechSegmenter()
        let sentence = try english.append("v1.2 example.test", final: false)
        precondition(sentence.isEmpty)
        let englishSentence = "This deliberately long English sentence should remain complete even after the former limit."
        var streamedEnglish = SpeechSegmenter()
        let beforePeriodBoundary = try streamedEnglish.append(englishSentence, final: false)
        precondition(beforePeriodBoundary.isEmpty)
        let atPeriod = try streamedEnglish.append(" Another sentence follows.", final: true)
        precondition(atPeriod.map(\.text) == [englishSentence, " Another sentence follows."])
    }

    private static func checkEnglishWordSegments() throws {
        let samples = [
            "This is an English sentence with a wonderful ending that must preserve every complete word.",
            "Please keep this deliberately long sentence readable: don't split mother-in-law or café anywhere.",
            String(repeating: "w", count: 80) + " is a single long word.",
            "中文和English混排时，也不能拆开wonderful这个单词。"
        ]
        for provider: ConnectionProvider in [.elevenLabs, .miniMax, .fishAudio] {
            for text in samples {
                for incremental in [false, true] {
                    var segmenter = SpeechSegmenter(provider: provider, model: "speech-02-hd")
                    var parts: [SpeechSegment] = []
                    if incremental {
                        for character in text { parts += try segmenter.append(String(character), final: false) }
                        parts += try segmenter.append("", final: true)
                    } else { parts = try segmenter.append(text, final: true) }
                    precondition(parts.map(\.text).joined() == text, "English streaming must preserve the original text")
                    var offset = 0
                    let characters = Array(text)
                    for part in parts.dropLast() {
                        offset += part.text.count
                        let before = characters[offset - 1]
                        let after = characters[offset]
                        let wordCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'-’é"
                        precondition(!(wordCharacters.contains(before) && wordCharacters.contains(after)),
                                     "A synthesis request must never split an English word")
                    }
                }
            }
        }
    }

    private static func checkTagScope() throws {
        var scoped = SpeechSegmenter(tagsEnabled: true)
        let long = String(repeating: "甲", count: 49)
        let values = try scoped.append("[whispers][sad]" + long + "，续句。下一句。", final: true)
        precondition(values[0].text == "[whispers][sad]" + long + "，")
        precondition(values[1].text == "[whispers][sad]续句。")
        precondition(values[2].text == "下一句。", "expression must end with its sentence")
        var replacement = SpeechSegmenter(tagsEnabled: true)
        let prefix = try replacement.append("[whis", final: false)
        precondition(prefix.isEmpty)
        let a = try replacement.append("pers][sad]" + long + "，", final: false)
        precondition(a.count == 1)
        let b = try replacement.append("[angry]" + long + "。", final: true)
        precondition(b.last!.text.hasPrefix("[angry]"))
        precondition(!b.last!.text.contains("[whispers]") && !b.last!.text.contains("[sad]"))
        var events = SpeechSegmenter(tagsEnabled: true)
        let once = try events.append("[sighs][unknown]" + long + "，尾句。", final: true)
        precondition(once.map(\.text).joined().components(separatedBy: "[sighs]").count == 2)
        precondition(!once.last!.text.contains("[unknown]"))
    }

    private static func checkExpressionSegments() throws {
        var eleven = SpeechSegmenter(tagsEnabled: true)
        let elevenPartial = try eleven.append("[low, gravelly", final: false)
        precondition(elevenPartial.isEmpty)
        let first = try eleven.append(" voice]你好。", final: false)
        precondition(first.map(\.text) == ["[low, gravelly voice]你好。"])
        precondition(first.map(\.caption) == ["你好。"])
        let second = try eleven.append("[frustrated sigh]继续。", final: true)
        precondition(second.map(\.text) == ["[frustrated sigh]继续。"])
        precondition(second.map(\.caption) == ["继续。"])

        var persistent = SpeechSegmenter(tagsEnabled: true)
        let persistentSegments = try persistent.append("[whispers]第一句。[laughing nervously]第二句。第三句。", final: true)
        precondition(persistentSegments.map(\.text) == [
            "[whispers]第一句。",
            "[laughing nervously]第二句。第三句。"
        ])
        precondition(persistentSegments.map(\.caption) == ["第一句。", "第二句。第三句。"])
        var persistentOnly = SpeechSegmenter(tagsEnabled: true)
        let persistentOnlySegments = try persistentOnly.append("[whispers]", final: true)
        precondition(persistentOnlySegments.isEmpty)

        var event = SpeechSegmenter(tagsEnabled: true)
        let eventSegments = try event.append("[exhales sharply]", final: true)
        precondition(eventSegments.map(\.text) == ["[exhales sharply]"] && eventSegments[0].caption.isEmpty)

        var unsupported = SpeechSegmenter()
        let literal = try unsupported.append("[whispers]普通文本。", final: true)
        precondition(literal.map(\.text) == ["[whispers]普通文本。"])
        precondition(literal.map(\.caption) == ["[whispers]普通文本。"])

        var malformed = SpeechSegmenter(tagsEnabled: true)
        let malformedPartial = try malformed.append("[", final: false)
        precondition(malformedPartial.isEmpty)
        let malformedFinal = try malformed.append("", final: true)
        precondition(malformedFinal.isEmpty && malformed.droppedIncompleteTags == 1)
        var partialTail = SpeechSegmenter(tagsEnabled: true)
        let kept = try partialTail.append("保留正文[whis", final: true)
        precondition(kept.map(\.text) == ["保留正文"] && partialTail.droppedIncompleteTags == 1)
        var ordinaryBracket = SpeechSegmenter()
        let ordinaryTail = try ordinaryBracket.append("普通[文字", final: true)
        precondition(ordinaryTail.map(\.text) == ["普通[文字"])
        var emptyCue = SpeechSegmenter(tagsEnabled: true)
        let emptyCueSegments = try emptyCue.append("[]文本。", final: true)
        precondition(emptyCueSegments.map(\.text) == ["[]文本。"])
        let overlong = "[" + String(repeating: "x", count: 129) + "]文本。"
        var overlongCue = SpeechSegmenter(tagsEnabled: true)
        let overlongSegments = try overlongCue.append(overlong, final: true)
        precondition(overlongSegments.map(\.text).joined() == overlong)
        precondition(overlongSegments.map(\.caption).joined() == "文本。")

        var miniMax = SpeechSegmenter(miniMax: true)
        let sentencePartial = try miniMax.append("前句。", final: false)
        precondition(sentencePartial.isEmpty)
        let pausePartial = try miniMax.append("<#0.3", final: false)
        precondition(pausePartial.isEmpty)
        let paused = try miniMax.append("#>后句。", final: true)
        precondition(paused.count == 1)
        precondition(paused[0].text == "前句。<#0.3#>后句。" && paused[0].caption == "前句。后句。")

        for duration in ["0.01", "1", "1.2", "99.99"] {
            var valid = SpeechSegmenter(miniMax: true)
            let segments = try valid.append("甲<#\(duration)#>乙。", final: true)
            precondition(segments.map(\.text) == ["甲<#\(duration)#>乙。"])
        }
        for invalid in ["<#0#>甲", "<#0.001#>甲", "<#1e0#>甲", "<#+.3#>甲", "<#100#>甲", "<#.3#>甲", "<#1.#>甲"] {
            var invalidSegmenter = SpeechSegmenter(miniMax: true)
            try rejects { _ = try invalidSegmenter.append(invalid, final: true) }
        }
        for invalidPlacement in ["<#0.3#>甲", "甲<#0.3#>", "甲<#0.3#><#0.4#>乙"] {
            var invalidSegmenter = SpeechSegmenter(miniMax: true)
            try rejects { _ = try invalidSegmenter.append(invalidPlacement, final: true) }
        }
        var ordinaryAngleText = SpeechSegmenter(miniMax: true)
        let ordinary = try ordinaryAngleText.append("保留<note>普通文本。", final: true)
        precondition(ordinary.map(\.text) == ["保留<note>普通文本。"] && ordinary[0].caption == "保留<note>普通文本。")

        var capped = SpeechSegmenter(miniMax: true)
        let cappedPrefix = String(repeating: "字", count: 47)
        let cappedSegments = try capped.append(cappedPrefix + "<#0.3#>后文。", final: true)
        precondition(cappedSegments.map(\.text) == [cappedPrefix + "<#0.3#>后文。"])
        precondition(cappedSegments.map(\.bodyCount) == [50])

        var noPause = SpeechSegmenter(miniMax: true)
        let noPausePartial = try noPause.append("普通句。", final: false)
        precondition(noPausePartial.isEmpty)
        let tail = try noPause.append("", final: true)
        precondition(tail.map(\.text) == ["普通句。"])
    }

    private static func whisper(model: String = "", language: String? = nil, key: String? = nil) throws -> WhisperConfiguration {
        try WhisperConfiguration(endpoint: URL(string: "https://voice.example.test"), model: model, language: language, apiKey: key)
    }

    private static func checkDisplayText() {
        func display(_ text: String, _ provider: ConnectionProvider = .elevenLabs,
                     _ model: String = "eleven_v3", streaming: Bool = false) -> String {
            SpeechSegmenter.displayText(text, provider: provider, model: model, isStreaming: streaming)
        }
        precondition(display("[whispers]你好。[laughing nervously]接着说。") == "你好。接着说。")
        precondition(display("前面。[whis", streaming: true) == "前面。")
        precondition(display("前面。[whis") == "前面。[whis")
        precondition(display("(普通括号) [whispers]你好...") == "(普通括号) 你好...")
        precondition(display("你好.", streaming: true) == "你好.")
        precondition(display("[whispers]你好。", .elevenLabs, "eleven_multilingual_v2") == "[whispers]你好。")
        precondition(display("[whispers]你好。", .elevenLabs, " ELEVEN_V4_TURBO ") == "你好。")
        precondition(display("(laughs)你好<#0.5#>接着说。(普通括号)", .miniMax, "speech-2.8-hd") == "你好接着说。(普通括号)")
        precondition(display("(laughs)你好。", .miniMax, "speech-02-hd") == "(laughs)你好。")
        precondition(display("你好<#broken#>接着说。", .miniMax, "speech-2.8-hd") == "你好<#broken#>接着说。")
        precondition(display("你好<#0.", .miniMax, "speech-2.8-hd", streaming: true) == "你好")
        precondition(display("你好<#0.", .miniMax, "speech-2.8-hd") == "你好<#0.")
        precondition(display("[whispers sweetly]你好。", .fishAudio, "s2.1-pro") == "你好。")
        precondition(display("[普通括号]你好。", .openAICompatible, "model", streaming: true) == "[普通括号]你好。")
        precondition(display("[sad]  你好") == "你好")
        precondition(display("Hello [sad] world") == "Hello world")
        precondition(display("Hello[sad] world") == "Hello world")
        precondition(display("Hello[sad]world") == "Helloworld")
        precondition(display("你好  [sad]  世界") == "你好 世界")
        precondition(display("  [sad]  你好\n\t  [whispers]  下一行\n\n结尾  [sad]  ") == "  你好\n\t  下一行\n\n结尾")
        precondition(display("普通  正文\n\t缩进  和空格") == "普通  正文\n\t缩进  和空格")
        precondition(display("Hello [sad] world", streaming: true) == "Hello world")
        precondition(display("[sad]  你好。", .elevenLabs, "eleven_multilingual_v2") == "[sad]  你好。")
        precondition(display("(laughs)  你好。", .miniMax, "speech-2.8-hd") == "你好。")
        precondition(display("[laughing]  你好。", .fishAudio, "s2.1-pro") == "你好。")
        precondition(display("[sad]\n你好。") == "你好。")
        precondition(display("第一行\n \t[sad] [whispers]\t \n第二行") == "第一行\n第二行")
        precondition(display("第一段\n\n[sad]\n第二段") == "第一段\n\n第二段")
        precondition(display("第一段\n[sad]\n\n第二段") == "第一段\n\n第二段")
        precondition(display("第一行\r\n[sad]\r\n第二行") == "第一行\r\n第二行")
        precondition(display("第一行\n  [sad]\t ") == "第一行\n")
        precondition(display(" \t[sad]\n[whispers]\n") == "")
        precondition(display("[sad]\n你好。", streaming: true) == "你好。")
        precondition(display("[sad]\n你好。", .elevenLabs, "eleven_multilingual_v2") == "[sad]\n你好。")
        precondition(display("[sad\n你好。") == "[sad\n你好。")
        precondition(display("第一行\n(laughs)\n第二行", .miniMax, "speech-2.8-hd") == "第一行\n第二行")
        precondition(display("[whispers]\n你好。", .fishAudio, "s2.1-pro") == "你好。")
        var segmenter = SpeechSegmenter(provider: .elevenLabs, model: "eleven_v4")
        let original = "[sad]  Hello [whispers] world."
        let segments = try! segmenter.append(original, final: true)
        precondition(segments.map(\.text).joined() == original)
        precondition(segments.map(\.caption).joined() == "Hello world.")
        print("PASS: transcript display shares provider/model controls, hides streaming partial tags, preserves final malformed tags and original punctuation")
    }
    private static func check(_ value: Bool) { precondition(value) }
    private static func rejects(file: StaticString = #file, line: UInt = #line, _ body: () throws -> Void) throws {
        do { try body(); preconditionFailure("Expected a rejected protocol input", file: file, line: line) }
        catch let error as TincallError { precondition(!error.message.contains("private detail")) }
    }
}
