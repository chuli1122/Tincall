// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct RequestLogChecks {
    @MainActor static func main() async throws {
        try await checkCallFiltering()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallRequestChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RequestLogStore(directory: directory)
        try expect(store.storageIssue == nil, "store initializes")
        let call = UUID(), input = UUID(), turn = UUID()
        let started = Date(timeIntervalSince1970: 1_000)
        store.registerCall(id: call, startedAt: started, mode: .mcp)
        let transcription = store.begin(service: .xunfei, step: .transcription,
            context: RequestLogContext(callID: call, roundID: input))
        store.registerTurn(callID: call, inputID: input, turnID: turn)
        let context = store.context(for: VoiceTurnID(session: VoiceSessionID(callID: call, epoch: UUID()), turnID: turn, messageID: UUID()))
        try expect(context.roundID == input, "transcription and reply share a round")
        try expect(store.service(callID: call) == .mcp, "MCP attribution")
        let model = store.begin(service: .gemini, step: .model, context: context)
        model.response(HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429, httpVersion: nil, headerFields: nil))
        model.protect(["SYNTHETIC_SECRET_AND_BODY"])
        model.fail(TincallError(message: "SYNTHETIC_SECRET_AND_BODY", requestCode: "SYNTHETIC_SECRET_AND_BODY"))
        model.finish(); model.finish()
        transcription.succeed(); transcription.finish()
        let synthesis = store.begin(service: .miniMax, step: .synthesis, context: context, segment: 2)
        synthesis.fail(TincallError(message: "Synthetic provider error", requestCode: "1001")); synthesis.finish()
        let cancelled = store.begin(service: .whisper, step: .transcription, context: context)
        cancelled.fail(CancellationError()); cancelled.finish()
        let network = store.begin(service: .cloud, step: .sync)
        network.fail(URLError(.timedOut)); network.finish()
        _ = store.begin(service: .mcp, step: .roleRegistration)
        await store.flushPendingWrites()
        let reopened = RequestLogStore(directory: directory)
        await reopened.flushPendingWrites()
        try expect(reopened.entries.count == 6, "each request completes once")
        try expect(reopened.calls.first?.rounds.count == 1, "one ordered round")
        try expect(reopened.entries.first { $0.step == .model }?.httpStatus == 429, "HTTP failure retained")
        try expect(reopened.entries.first { $0.step == .model }?.errorCode == "provider_error_redacted", "unknown codes redacted")
        try expect(reopened.entries.first { $0.step == .synthesis }?.errorCode == "1001", "numeric supplier code retained")
        try expect(reopened.entries.contains { $0.outcome == .cancelled }, "cancellation distinct from errors")
        try expect(reopened.entries.contains { $0.errorCode == "network_-1001" }, "transport code retained")
        try expect(reopened.entries.contains { $0.errorCode == "process_ended" }, "unfinished request recovered honestly")
        try expect(reopened.entries.filter { $0.errorCode != "process_ended" }.allSatisfy { ($0.duration ?? -1) >= 0 }, "monotonic duration retained")
        let file = directory.appendingPathComponent("requests.json")
        let encoded = try String(contentsOf: file, encoding: .utf8)
        try expect(!encoded.contains("SYNTHETIC_SECRET_AND_BODY") && !encoded.contains("example.invalid"), "credentials and URL are redacted from retained errors")
        #if os(iOS)
        try expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "system backup excluded")
        #endif
        await reopened.flushPendingWrites()
        let late = reopened.begin(service: .elevenLabs, step: .synthesis, context: context)
        let lateID = reopened.entries.last!.id
        for index in 1...301 {
            let id = UUID()
            reopened.registerCall(id: id, startedAt: started.addingTimeInterval(Double(index)))
            let request = reopened.begin(service: .openAI, step: index.isMultiple(of: 5) ? .sync : .model,
                context: index.isMultiple(of: 5) ? nil : RequestLogContext(callID: id, roundID: UUID()))
            request.succeed(); request.finish()
        }
        late.succeed(); late.finish()
        await reopened.flushPendingWrites()
        let retained = RequestLogStore(directory: directory)
        try expect(retained.entries.count == 308 && retained.entries.contains { $0.id == lateID }, "all requests within seven days retained without a count cap")
        try expect(retained.entries.contains { $0.context == nil }, "standalone requests share retention period")
        let oldRetry = retained.begin(service: .gemini, step: .summary, context: RequestLogContext(callID: call))
        oldRetry.succeed(); oldRetry.finish()
        try expect(retained.entries.count == 309 && retained.entries.last?.step == .summary, "new retry for an old call is a new request")
        await retained.flushPendingWrites()
        // A malformed archive must not be overwritten by subsequent requests.
        let corruptDirectory = directory.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFile = corruptDirectory.appendingPathComponent("requests.json")
        try Data("invalid archive".utf8).write(to: corruptFile)
        let corrupt = RequestLogStore(directory: corruptDirectory)
        let request = corrupt.begin(service: .cloud, step: .sync)
        request.succeed(); request.finish()
        try expect(corrupt.storageIssue != nil && (try String(contentsOf: corruptFile, encoding: .utf8)) == "invalid archive", "read failure preserves original file and surfaces issue")
        // New metadata remains optional for old archives; only public names are added.
        let metadataDirectory = directory.appendingPathComponent("metadata")
        let metadata = RequestLogStore(directory: metadataDirectory)
        let named = metadata.begin(service: .openAI, step: .model, context: RequestLogContext(callID: call),
                                   connectionName: "我的模型连接", modelName: "gpt-example")
        let completed = metadata.begin(service: .xunfei, step: .transcription, context: RequestLogContext(callID: call))
        completed.succeed(); completed.finish()
        let summary = metadata.begin(service: .openAI, step: .summary, context: RequestLogContext(callID: call))
        metadata.markHangUp(callID: call)
        try expect(metadata.entries[2].outcome == .pending, "hangup does not label independent summary as stopped")
        summary.succeed(); summary.finish()
        named.fail(CancellationError()); named.finish()
        let timeout = metadata.begin(service: .bailian, step: .transcription)
        timeout.fail(TincallError(message: "Synthetic timeout", requestCode: "timeout")); timeout.finish()
        await metadata.flushPendingWrites()
        let saved = RequestLogStore(directory: metadataDirectory)
        try expect(saved.entries.first?.connectionName == "我的模型连接" && saved.entries.first?.modelName == "gpt-example", "public names survive reopen")
        try expect(saved.entries.first?.outcome == .cancelled && saved.entries.first?.errorCode == "call_hang_up", "hangup reason survives asynchronous cancellation")
        try expect(saved.entries[1].outcome == .succeeded, "hangup leaves completed requests intact")
        try expect(saved.entries.last?.errorCode == "timeout", "recognizer timeout code retained")
        let metadataFile = metadataDirectory.appendingPathComponent("requests.json")
        await saved.flushPendingWrites()
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataFile)) as! [String: Any]
        var legacyEntries = legacy["entries"] as! [[String: Any]]
        for index in legacyEntries.indices {
            legacyEntries[index].removeValue(forKey: "connectionName")
            legacyEntries[index].removeValue(forKey: "modelName")
            legacyEntries[index].removeValue(forKey: "requestText")
            legacyEntries[index].removeValue(forKey: "omittedTurnCount")
            legacyEntries[index].removeValue(forKey: "requestConversationOffset")
            legacyEntries[index].removeValue(forKey: "responseText")
            legacyEntries[index].removeValue(forKey: "reasoningText")
            legacyEntries[index].removeValue(forKey: "serverErrorText")
        }
        legacy["entries"] = legacyEntries
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadataFile, options: .atomic)
        let old = RequestLogStore(directory: metadataDirectory)
        try expect(old.entries.allSatisfy { ($0.omittedTurnCount ?? 0) == 0 && $0.requestConversationOffset == nil }, "old logs default to zero omitted turns")
        try expect(old.storageIssue == nil && old.entries.count == 4 && old.entries.allSatisfy { $0.connectionName == nil && $0.modelName == nil && $0.requestText == nil && $0.responseText == nil && $0.reasoningText == nil && $0.serverErrorText == nil }, "legacy archive without names decodes")
        await old.flushPendingWrites()
        let contentsDirectory = directory.appendingPathComponent("contents")
        let contents = RequestLogStore(directory: contentsDirectory)
        let textSpan = contents.begin(service: .openAI, step: .model)
        textSpan.protect(["short-secret"])
        let longInput = String(repeating: "你好🌷", count: 8000) + "输入末尾"
        textSpan.request(longInput)
        try expect(try contents.load([contents.entries.first!]).first?.requestText == longInput, "full request available while awaiting response")
        textSpan.reasoning("先考虑对方的意思 short-secret")
        textSpan.succeed("收到你的消息，今天也一起慢慢来。")
        textSpan.finish()
        let errorSpan = contents.begin(service: .cloud, step: .sync)
        errorSpan.protect(["short-secret"])
        errorSpan.request("上传通话备份 3 条")
        errorSpan.text("已经收到的部分回复")
        errorSpan.body(Data(#"{"error":{"code":"invalid_api_key","message":"denied short-secret sk-example1234567890123456 eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature","token":"short-token","api_key":"tiny-key"}}"#.utf8))
        errorSpan.fail(TincallError(message: "fallback"))
        errorSpan.finish()
        let redacted = contents.begin(service: .cloud, step: .connectionTest)
        redacted.request("检查连接")
        redacted.text("Authorization: Bearer tiny\nCookie: session=tiny\n服务端拒绝连接")
        redacted.fail(TincallError(message: "fallback")); redacted.finish()
        await contents.flushPendingWrites()
        let contentSavedStore = RequestLogStore(directory: contentsDirectory)
        let savedContents = try contentSavedStore.load(contentSavedStore.entries)
        try expect(savedContents[0].requestText == longInput, "full unicode request survives reopen")
        try expect(savedContents[0].responseText == "收到你的消息，今天也一起慢慢来。", "response persists")
        try expect(savedContents[0].reasoningText == "先考虑对方的意思 [已打码]", "reasoning is persisted and redacted")
        let failureText = savedContents[1].serverErrorText ?? ""
        try expect(savedContents[1].responseText == "已经收到的部分回复", "server failure does not replace received output")
        try expect(savedContents[1].errorCode == "invalid_api_key", "provider error code survives fallback failure")
        try expect(failureText.contains("denied") && failureText.contains("[已打码]") && !failureText.contains("short-secret") && !failureText.contains("sk-example") && !failureText.contains("eyJ") && !failureText.contains("short-token") && !failureText.contains("tiny-key"), "server error preserved with credentials redacted")
        try expect(savedContents[2].responseText?.contains("tiny") == false, "authorization and cookie excluded")
        await contentSavedStore.flushPendingWrites()
        let contextSpan = contents.begin(service: .openAI, step: .model)
        contextSpan.protect(["short-secret"])
        let system = ModelMessage(role: "system", content: "Synthetic persona short-secret\n\n[user]\nThis is still the persona")
        let conversation = [ModelMessage(role: "user", content: "完整输入"), ModelMessage(role: "assistant", content: "完整回复")]
        contextSpan.request([system] + conversation, omittedTurnCount: 3)
        let pendingContext = contents.entries.last!
        try expect(pendingContext.omittedTurnCount == 3 && pendingContext.outcome == .pending, "omitted turns saved before request completes")
        contextSpan.succeed(); contextSpan.finish()
        await contents.flushPendingWrites()
        let contextReopened = RequestLogStore(directory: contentsDirectory)
        let contextSaved = try contextReopened.load([contextReopened.entries.last!])[0]
        let systemText = RequestLogText.clean(ModelMessage.logText([system]))! + "\n\n"
        let safeSystemText = RequestLogText.clean(systemText, secrets: ["short-secret"])!
        try expect(contextSaved.omittedTurnCount == 3 && contextSaved.requestConversationOffset == safeSystemText.count, "turn count and redacted system boundary survive reopen")
        let loggedText = contextSaved.requestText!
        let boundary = loggedText.index(loggedText.startIndex, offsetBy: contextSaved.requestConversationOffset!)
        try expect(String(loggedText[boundary...]) == ModelMessage.logText(conversation) && !loggedText.contains("short-secret"), "separator starts at real conversation even if persona contains message markers")
        await contextReopened.flushPendingWrites()
        let noSystem = contents.begin(service: .openAI, step: .model)
        noSystem.request(conversation, omittedTurnCount: 1)
        try expect(contents.entries.last?.requestConversationOffset == 0, "without system messages separator precedes first input")
        noSystem.succeed(); noSystem.finish()
        let noOmission = contents.begin(service: .openAI, step: .model)
        noOmission.request(conversation, omittedTurnCount: 0)
        try expect((contents.entries.last?.omittedTurnCount ?? 0) == 0 && contents.entries.last?.requestConversationOffset == nil, "no omitted turns adds no separator metadata")
        noOmission.succeed(); noOmission.finish()
        let longOutput = String(repeating: "回", count: 21000) + "输出末尾"
        try expect(RequestLogText.clean(longOutput) == longOutput, "long output is not truncated")
        var exportModel = savedContents[0]
        exportModel.duration = 1.25
        exportModel.modelName = "示例模型"
        exportModel.requestText = longInput + "\nAuthorization: Bearer tiny-auth\nCookie: tiny-cookie"
        exportModel.responseText = longOutput
        exportModel.serverErrorText = #"{"token":"tiny-token","api_key":"tiny-key"}"#
        let exportSTT = RequestLogEntry(id: UUID(), time: started, service: .apple, step: .transcription,
            context: nil, segment: nil, outcome: .succeeded, responseText: "完整识别结果")
        let exportText = RequestLogText.export([exportModel, exportSTT])
        try expect(exportText.contains(longInput) && exportText.contains(longOutput)
            && exportText.contains("思考：\n先考虑对方的意思 [已打码]"), "export retains full input, reasoning and output")
        try expect(exportText.contains("类型：模型") && exportText.contains("服务商：OpenAI 兼容模型")
            && exportText.contains("模型：示例模型") && exportText.contains("耗时：1.25 秒")
            && exportText.contains("结果：成功") && exportText.contains("识别结果：\n完整识别结果"), "export includes metadata and recognition result")
        try expect(exportText.components(separatedBy: "----------------------------------------").count == 2
            && !exportText.contains("已经收到的部分回复"), "export contains only supplied filtered entries with separators")
        try expect(!exportText.contains("tiny-auth") && !exportText.contains("tiny-cookie")
            && !exportText.contains("tiny-token") && !exportText.contains("tiny-key")
            && !exportText.contains("Authorization") && !exportText.contains("Cookie"), "export redacts legacy credentials again")
        let exportTTS = RequestLogEntry(id: UUID(), time: started, service: .miniMax, step: .synthesis,
            context: nil, segment: 2, outcome: .cancelled, errorCode: "call_hang_up", requestText: "要朗读的完整文字")
        let ttsText = RequestLogText.export([exportTTS])
        try expect(ttsText.contains("合成文字：\n要朗读的完整文字") && ttsText.contains("结果：挂断时中止")
            && ttsText.contains("分段：2"), "export includes complete synthesis text and interruption outcome")
        await contents.flushPendingWrites()
        try await outOfOrderRetentionChecks(in: directory.appendingPathComponent("ordered-retention"))
        try await storageAndPaginationChecks(in: directory)
        try await originalRequestChecks(in: directory.appendingPathComponent("original-requests"))
        print("PASS: local persistence, round attribution, HTTP/provider/transport errors, redaction, cancellation, crash recovery, seven-day retention without count cap, paged bodies, safe legacy migration, late completion, standalone requests and failed-read preservation")
    }

    @MainActor private static func outOfOrderRetentionChecks(in directory: URL) async throws {
        let store = RequestLogStore(directory: directory)
        let now = Date()
        func entry(_ age: TimeInterval) -> RequestLogEntry {
            RequestLogEntry(id: UUID(), time: now.addingTimeInterval(-age), service: .mcp,
                step: .callControl, context: nil, segment: nil, outcome: .succeeded,
                requestText: "Synthetic retained request")
        }
        let recent = entry(1), delayed = entry(60), expired = entry(8 * 86400)
        store.append(recent)
        store.append(delayed)
        store.append(expired)
        try expect(store.entries.map(\.id) == [delayed.id, recent.id], "delayed append stays ordered and expired append is pruned immediately")
        await store.flushPendingWrites()
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Bodies/" + expired.id.uuidString + ".json").path), "expired unsaved body is not written")
        let reopened = RequestLogStore(directory: directory)
        let saved = try reopened.load(reopened.entries)
        try expect(saved.map(\.id) == [delayed.id, recent.id] && saved.allSatisfy { $0.requestText == "Synthetic retained request" }, "retained delayed entries and bodies survive restart")
        await reopened.flushPendingWrites()
    }

    @MainActor private static func storageAndPaginationChecks(in root: URL) async throws {
        struct Archive: Codable {
            var calls: [RequestLogCall] = []
            var entries: [RequestLogEntry]
        }
        let directory = root.appendingPathComponent("pagination")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var fixture: [RequestLogEntry] = (0..<205).map { index in
            RequestLogEntry(id: UUID(), time: now.addingTimeInterval(-Double(index)),
                service: .openAI, step: index.isMultiple(of: 2) ? .model : .summary,
                context: nil, segment: nil, outcome: index.isMultiple(of: 3) ? .failed : .succeeded,
                requestText: "Synthetic request \(index) 🌷", responseText: "Complete output \(index)")
        }
        let expired = RequestLogEntry(id: UUID(), time: now.addingTimeInterval(-7 * 86400 - 5),
            service: .apple, step: .transcription, context: nil, segment: nil, requestText: "Expired request")
        fixture.append(expired)
        let inside = RequestLogEntry(id: UUID(), time: now.addingTimeInterval(-7 * 86400 + 60),
            service: .apple, step: .transcription, context: nil, segment: nil, outcome: .succeeded, requestText: "Still in retention")
        fixture.append(inside)
        let file = directory.appendingPathComponent("requests.json")
        try JSONEncoder().encode(Archive(entries: fixture)).write(to: file)
        let store = RequestLogStore(directory: directory)
        try expect(store.storageIssue == nil && store.entries.count == 206, "seven-day boundary prunes expired entries only")
        try expect(store.entries.allSatisfy { $0.requestText == nil && $0.responseText == nil }, "metadata index does not preload bodies")
        await store.flushPendingWrites()
        let indexText = try String(contentsOf: file, encoding: .utf8)
        try expect(!indexText.contains("Synthetic request") && !indexText.contains("Complete output"), "migrated index excludes full text")
        let sorted = store.matching()
        try expect(sorted.first?.id == fixture[0].id && sorted.last?.id == inside.id, "metadata sorted newest first")
        let firstPage = try store.load(Array(sorted.prefix(100)))
        try expect(firstPage.count == 100 && firstPage[99].requestText == "Synthetic request 99 🌷", "initial page loads 100 complete bodies")
        let body = directory.appendingPathComponent("Bodies/" + sorted[100].id.uuidString + ".json")
        let original = try Data(contentsOf: body)
        try Data("invalid body".utf8).write(to: body)
        await store.flushPendingWrites()
        let reopened = RequestLogStore(directory: directory)
        await reopened.flushPendingWrites()
        try expect(reopened.storageIssue == nil && (try reopened.load(Array(reopened.matching().prefix(100)))).count == 100,
                   "opening and first page never read an off-page corrupt body")
        do {
            _ = try reopened.load(Array(reopened.matching().dropFirst(100).prefix(100)))
            throw NSError(domain: "ExpectedUnreadableBody", code: 1)
        } catch {
            try expect((error as NSError).domain != "ExpectedUnreadableBody", "next page reports unavailable body instead of blank content")
        }
        let failedChat = store.matching(category: .chat, failuresOnly: true)
        try expect(failedChat.allSatisfy { $0.category == .chat && $0.outcome == .failed }, "filters select metadata before body access")
        try expect((try reopened.load(Array(reopened.matching().prefix(50)))).count == 50, "limited export does not read unselected bodies")
        try original.write(to: body)
        for limit in [500, 300, 100, 50] {
            let selected = Array(store.matching().prefix(limit))
            let loaded = try store.load(selected)
            try expect(loaded.count == min(limit, 206) && loaded.first?.requestText == "Synthetic request 0 🌷", "export limits keep latest complete requests")
        }
        store.registerCall(id: UUID(), startedAt: now)
        let earlierCall = UUID()
        store.registerCall(id: earlierCall, startedAt: now.addingTimeInterval(-60), mode: .mcp)
        try expect(store.service(callID: earlierCall) == .mcp, "registration preserves an older resumed call before its first request")
        let streamURL = root.appendingPathComponent("stream-export.txt")
        try Data().write(to: streamURL)
        let stream = try FileHandle(forWritingTo: streamURL)
        let allMetadata = store.matching()
        for (index, metadata) in allMetadata.enumerated() {
            var entry = try store.load([metadata])[0]
            if index == 0 { entry.responseText = String(repeating: "Synthetic long output 🌷", count: 4000) }
            try RequestLogText.writeExportEntry(entry, to: stream, isFirst: index == 0)
        }
        try stream.write(contentsOf: Data("\n".utf8)); try stream.close()
        var allForComparison = try store.load(allMetadata)
        allForComparison[0].responseText = String(repeating: "Synthetic long output 🌷", count: 4000)
        try expect(try String(contentsOf: streamURL, encoding: .utf8) == RequestLogText.export(allForComparison), "streamed 206-request export exactly preserves complete long text and separators")
        let new = store.begin(service: .openAI, step: .model, requestText: "Fresh dynamic request")
        new.succeed(); new.finish()
        try expect(try store.load(Array(store.matching().prefix(100))).first?.requestText == "Fresh dynamic request", "new requests join the first page")
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Bodies/" + expired.id.uuidString + ".json").path), "expired bodies are removed after index save")

        // Failed migration must keep the complete old archive and retry safely later.
        let blocked = root.appendingPathComponent("blocked-migration")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let legacyFile = blocked.appendingPathComponent("requests.json")
        let legacyData = try JSONEncoder().encode(Archive(entries: [fixture[0]]))
        try legacyData.write(to: legacyFile)
        let blockedBody = blocked.appendingPathComponent("Bodies/" + fixture[0].id.uuidString + ".json")
        try FileManager.default.createDirectory(at: blockedBody, withIntermediateDirectories: true)
        let failed = RequestLogStore(directory: blocked)
        try expect(failed.storageIssue != nil && (try Data(contentsOf: legacyFile)) == legacyData, "migration failure preserves original archive")
        let attempt = failed.begin(service: .cloud, step: .sync)
        attempt.succeed(); attempt.finish()
        try expect((try Data(contentsOf: legacyFile)) == legacyData, "later writes cannot overwrite failed migration")
        try FileManager.default.removeItem(at: blockedBody)
        let recovered = RequestLogStore(directory: blocked)
        await recovered.flushPendingWrites()
        try expect(recovered.storageIssue == nil && (try recovered.load(recovered.entries))[0].requestText == fixture[0].requestText, "migration retries with complete original content")
        let recoveredFile = blocked.appendingPathComponent("Bodies/" + fixture[0].id.uuidString + ".json")
        try expect((try String(contentsOf: recoveredFile, encoding: .utf8)).contains("Complete output"), "migration persists full response")

        await store.flushPendingWrites()
        await reopened.flushPendingWrites()
        await recovered.flushPendingWrites()

        // A body write failure must not publish a reference to a missing body.
        let before = try Data(contentsOf: file)
        let bodies = directory.appendingPathComponent("Bodies")
        let moved = directory.appendingPathComponent("Bodies-saved")
        try FileManager.default.moveItem(at: bodies, to: moved)
        try Data("blocked directory".utf8).write(to: bodies)
        let pending = store.begin(service: .openAI, step: .model, requestText: "Full text awaiting disk recovery")
        pending.succeed("Full response awaiting disk recovery"); pending.finish()
        await store.flushPendingWrites()
        try expect(store.storageIssue != nil && (try Data(contentsOf: file)) == before, "body write failure leaves previous index intact")
        try expect(try store.load([store.entries.last!])[0].responseText == "Full response awaiting disk recovery", "failed write remains readable in memory")
        try FileManager.default.removeItem(at: bodies)
        try FileManager.default.moveItem(at: moved, to: bodies)
        let trigger = store.begin(service: .cloud, step: .sync)
        trigger.succeed(); trigger.finish()
        await store.flushPendingWrites()
        let retried = RequestLogStore(directory: directory)
        try expect((try retried.load(retried.entries)).contains { $0.requestText == "Full text awaiting disk recovery" && $0.responseText == "Full response awaiting disk recovery" }, "later persistence retries all unsaved full bodies")
        await retried.flushPendingWrites()
    }

    @MainActor private static func originalRequestChecks(in directory: URL) async throws {
        let store = RequestLogStore(directory: directory)
        let image = Data(repeating: 0xab, count: 256)
        let connection = ConnectionProfile(name: "Synthetic", provider: .openAICompatible, model: "synthetic-model")
        let body = try ModelRequestCodec.requestBody(connection: connection,
            messages: [ModelMessage(role: "user", content: "Synthetic input", images: [image])], maxOutputTokens: 123)
        let span = store.begin(service: .openAI, step: .model)
        span.requestBody(body)
        span.request("Synthetic readable only")
        span.succeed("Synthetic output"); span.finish()
        try expect(store.entries.allSatisfy { $0.requestBodyJSON == nil }, "metadata index excludes original JSON")
        await store.flushPendingWrites()
        let reopened = RequestLogStore(directory: directory)
        await reopened.flushPendingWrites()
        let saved = try reopened.load(reopened.entries)[0]
        try expect(saved.requestBodyJSON == String(decoding: body, as: UTF8.self), "exact original request body survives restart")
        let exported = RequestLogText.export([saved])
        try expect(exported.contains(String(decoding: body, as: UTF8.self)) && exported.contains(image.base64EncodedString()), "export preserves actual parameters and complete image data")
        try expect(!exported.contains("Synthetic readable only"), "export uses actual JSON rather than readable reconstruction")
        let raw = try JSONSerialization.data(withJSONObject: ["api_key": "synthetic-auth", "max_tokens": 123,
            "messages": [["content": "synthetic-auth", "image": image.base64EncodedString()]]])
        let protected = store.begin(service: .openAI, step: .model)
        protected.protect(["synthetic-auth"])
        protected.requestBody(raw); protected.succeed(); protected.finish()
        await reopened.flushPendingWrites()
        await store.flushPendingWrites()
        let protectedEntry = try store.load([store.entries.last!])[0]
        let protectedText = RequestLogText.export([protectedEntry])
        try expect(!protectedText.contains("synthetic-auth") && protectedText.contains(image.base64EncodedString()), "original JSON redacts credentials without stripping image bytes")
        let object = try JSONSerialization.jsonObject(with: Data(protectedEntry.requestBodyJSON!.utf8)) as! [String: Any]
        try expect(object["max_tokens"] as? Int == 123 && object["api_key"] as? String == "[已打码]", "credential keys are redacted without changing token limits")
        var legacy = saved
        legacy.requestBodyJSON = nil
        try expect(RequestLogText.export([legacy]).contains("Synthetic readable only"), "old logs retain their saved contents without inventing original JSON")
        try expect(RequestLogText.requestJSON(Data([0, 1, 2])) == nil, "binary audio is not recorded as original JSON")
    }

    @MainActor private static func checkCallFiltering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallCallFilterChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RequestLogStore(directory: directory)
        let callA = UUID(), callB = UUID()
        store.registerCall(id: callA, startedAt: Date().addingTimeInterval(-60))
        let chatA = store.begin(service: .openAI, step: .model, context: RequestLogContext(callID: callA))
        chatA.request("Synthetic call A chat"); chatA.succeed(); chatA.finish()
        let ttsA = store.begin(service: .elevenLabs, step: .synthesis, context: RequestLogContext(callID: callA))
        ttsA.fail(TincallError(message: "Synthetic failure", requestCode: "400")); ttsA.finish()
        store.registerCall(id: callB, startedAt: Date())
        let chatB = store.begin(service: .openAI, step: .model, context: RequestLogContext(callID: callB))
        chatB.request("Synthetic call B chat"); chatB.succeed(); chatB.finish()
        let connection = store.begin(service: .openAI, step: .connectionTest)
        connection.request("Synthetic standalone"); connection.succeed(); connection.finish()
        let summaryA = store.begin(service: .openAI, step: .summary, context: RequestLogContext(callID: callA))
        summaryA.request("Synthetic call A summary"); summaryA.succeed(); summaryA.finish()

        await store.flushPendingWrites()
        let reopened = RequestLogStore(directory: directory)
        await reopened.flushPendingWrites()
        let selection = reopened.matching(callID: callA)
        try expect(selection.count == 3 && selection.allSatisfy { $0.context?.callID == callA }, "call filter isolates its requests including a late summary")
        try expect(reopened.matching(category: .chat, callID: callA).count == 1, "category and call filters compose")
        try expect(reopened.matching(category: .tts, failuresOnly: true, callID: callA).count == 1, "failure and call filters compose")
        try expect(reopened.matching(failuresOnly: true, callID: callB).isEmpty, "another call's failure cannot leak in")
        try expect(reopened.matching().count == 5 && reopened.matching().contains { $0.context == nil }, "all logs retain independent requests")
        try expect(reopened.matching(callID: UUID()).isEmpty, "unknown call never falls back to all logs")
        let exported = RequestLogText.export(try reopened.load(selection))
        try expect(exported.contains("Synthetic call A chat") && exported.contains("Synthetic call A summary"), "export retains selected call contents")
        try expect(!exported.contains("Synthetic call B chat") && !exported.contains("Synthetic standalone"), "export excludes other calls and independent requests")
        await reopened.flushPendingWrites()
        print("Request log call filtering checks passed")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "RequestLogChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
