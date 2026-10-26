// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

// Compile only with the two production cloud recognizers, their transcript parsers,
// SpeechRecognizer.swift and Core/CallModels.swift. The microphone, sockets and log
// sink below are test-only boundaries; no microphone, provider or user files are used.
import Foundation

@main
struct CloudSTTLifecycleChecks {
    @MainActor static func main() async throws {
        try await xunfeiOnsetAndPacing()
        try await xunfeiPacingWithSendLatency()
        for action in ["continue", "finish", "pause", "stop"] {
            try await xunfeiNextOnsetDuringFinalization(action: action)
        }
        try await xunfei()
        try await bailianEmptyRecognitionTimeout()
        try await bailian()
        try await expiryAndRaces()
        print("PASS: Xunfei onset keeps capture/gate, 40ms pacing, ordered onset PCM, live partial corrections and next-onset isolation during finalization/manual finish/pause/stop; cloud STT preconnect/no idle PCM/quiet expiry/cold fallback, Bailian overlapping close/upload and per-task text/PCM/log isolation, pause/stop late-event isolation")
    }

    @MainActor private static func xunfeiOnsetAndPacing() async throws {
        URLSession.shared.sockets = []; RequestLogStore.shared.spans = []
        let client = XunfeiSpeechRecognizer(credentials: .init(xunfeiAppID: "test", xunfeiAPIKey: "test", xunfeiAPISecret: "test"))
        var partials: [String] = []
        try await client.start(callback: { text, final, _ in if !final { partials.append(text) } })
        let idle = URLSession.shared.sockets[0]
        idle.expire()
        await settle()
        let capture = MicrophoneCapture.active!
        let resets = capture.resetCount
        // Onset/pre-roll can arrive in a single callback after a cold connection.
        let onset = (1...5).reduce(into: Data()) { $0.append(Data(repeating: UInt8($1), count: 1280)) }
        await capture.emit(onset, speech: true)
        try expect(capture.resetCount == resets, "opening Xunfei on speech onset must not reset capture and invalidate queued onset frames")
        try await until { URLSession.shared.sockets.count == 2 && !URLSession.shared.sockets[1].sent.isEmpty }
        let socket = URLSession.shared.sockets[1]
        socket.push(#"{"code":0,"data":{"status":1,"result":{"sn":0,"pgs":"apd","ws":[{"cw":[{"w":"前半句"}]}]}}}"#)
        try await until { partials == ["前半句"] }
        try expect(socket.sent.count < 5, "Xunfei partial must reach captions while PCM upload is still in progress")
        socket.push(#"{"code":0,"data":{"status":1,"result":{"sn":1,"pgs":"rpl","rg":[0,0],"ws":[{"cw":[{"w":"前半句修正"}]}]}}}"#)
        try await until { partials == ["前半句", "前半句修正"] }
        try expect(!socket.closed, "Xunfei forwards partials and corrections before the final result")
        try await until { socket.sent.count >= 5 }
        let frames = try socket.sent.compactMap { message -> [String: Any]? in
            guard case .string(let text) = message else { return nil }
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        let uploaded = frames.reduce(into: Data()) { bytes, frame in
            if let payload = frame["data"] as? [String: Any], let encoded = payload["audio"] as? String,
               let pcm = Data(base64Encoded: encoded) { bytes.append(pcm) }
        }
        try expect(uploaded == onset, "Xunfei sends all buffered onset audio exactly once and in order")
        let times = socket.sentAt
        for index in 1..<times.count {
            try expect(times[index - 1].duration(to: times[index]) >= .milliseconds(35),
                       "Xunfei buffered PCM must be paced at 40 ms per 1280 bytes, not uploaded in a burst")
        }
        client.stop()
    }

    @MainActor private static func xunfei() async throws {
        URLSession.shared.sockets = []; RequestLogStore.shared.spans = []
        let client = XunfeiSpeechRecognizer(credentials: .init(xunfeiAppID: "test", xunfeiAPIKey: "test", xunfeiAPISecret: "test"))
        var errors = 0
        var finals: [(String, Data?)] = []
        try await client.start(callback: { text, final, pcm in if final { finals.append((text, pcm)) } }, onError: { _ in errors += 1 })
        try expect(URLSession.shared.sockets.count == 1, "Xunfei must connect at call start")
        let first = URLSession.shared.sockets[0]
        await MicrophoneCapture.active?.emit(Data(repeating: 0, count: 1280), speech: false)
        await settle()
        try expect(first.sent.isEmpty && RequestLogStore.shared.spans.isEmpty, "Xunfei preconnect must not send silence or create a recognition log")
        first.expire()
        await settle()
        try expect(errors == 0 && RequestLogStore.shared.spans.isEmpty && URLSession.shared.sockets.count == 1, "Xunfei idle expiry is quiet and does not loop")
        let pcm = Data(repeating: 1, count: 1280)
        await MicrophoneCapture.active?.emit(pcm, speech: true)
        try await until { URLSession.shared.sockets.count == 2 && !URLSession.shared.sockets[1].sent.isEmpty }
        let second = URLSession.shared.sockets[1]
        let captureResets = MicrophoneCapture.active!.resetCount
        second.push(#"{"code":0,"data":{"status":2,"result":{"sn":1,"ws":[{"cw":[{"w":"第一句"}]}]}}}"#)
        try await until { finals.count == 1 && URLSession.shared.sockets.count == 3 }
        try expect(finals[0].0 == "第一句" && finals[0].1 == pcm, "Xunfei final keeps its own PCM")
        try expect(MicrophoneCapture.active!.resetCount == captureResets,
                   "a normal Xunfei final must not reset capture and discard queued onset/pre-roll")
        let prepared = URLSession.shared.sockets[2]
        await settle()
        try expect(prepared.sent.isEmpty, "Xunfei prepares after final without PCM")
        await MicrophoneCapture.active?.emit(pcm, speech: true)
        try await until { !prepared.sent.isEmpty }
        try expect(URLSession.shared.sockets.count == 3, "Xunfei speech reuses a live preconnection")
        client.setTranscriptionPaused(true)
        let count = URLSession.shared.sockets.count
        prepared.push(#"{"code":0,"data":{"status":2}}"#)
        await settle()
        try expect(finals.count == 1 && URLSession.shared.sockets.count == count, "Xunfei paused late final is isolated")
        client.setTranscriptionPaused(false)
        try expect(URLSession.shared.sockets.count == count + 1, "Xunfei resume prepares once")
        client.stop()
        try expect(URLSession.shared.sockets.allSatisfy(\.closed), "Xunfei stop closes all sockets")
    }

    @MainActor private static func xunfeiPacingWithSendLatency() async throws {
        URLSession.shared.sockets = []; RequestLogStore.shared.spans = []
        let client = XunfeiSpeechRecognizer(credentials: .init(xunfeiAppID: "test", xunfeiAPIKey: "test", xunfeiAPISecret: "test"))
        try await client.start(callback: { _, _, _ in })
        let socket = URLSession.shared.sockets[0]
        socket.sendLatency = .milliseconds(25)
        // The first send outlasts one frame; later sends complete faster.
        socket.sendLatencies = [.milliseconds(80)]
        await MicrophoneCapture.active?.emit(Data(repeating: 1, count: 1280 * 8), speech: true)
        try await until { socket.sent.count >= 8 }
        let elapsed = socket.sentAt[0].duration(to: socket.sentAt[7])
        try expect(elapsed < .milliseconds(420), "Xunfei real-time pacing must include socket-send time, not add 40 ms after every send")
        for index in 1..<socket.sentAt.count {
            try expect(socket.sentAt[index - 1].duration(to: socket.sentAt[index]) >= .milliseconds(35),
                       "Xunfei must not burst queued audio to catch up after socket latency")
        }
        client.stop()
    }

    @MainActor private static func xunfeiNextOnsetDuringFinalization(action: String) async throws {
        URLSession.shared.sockets = []; RequestLogStore.shared.spans = []
        let client = XunfeiSpeechRecognizer(credentials: .init(xunfeiAppID: "test", xunfeiAPIKey: "test", xunfeiAPISecret: "test"))
        var finals: [Data] = []
        try await client.start(callback: { _, final, audio in if final, let audio { finals.append(audio) } })
        let first = URLSession.shared.sockets[0]
        let speech = Data(repeating: 1, count: 1280)
        let silence = Data(repeating: 0, count: 64_000)
        let nextOnset = Data(repeating: 2, count: 1280)
        await MicrophoneCapture.active?.emit(speech, speech: true)
        try await until { !first.sent.isEmpty }
        await MicrophoneCapture.active?.emit(silence, speech: false)
        await MicrophoneCapture.active?.emit(nextOnset, speech: true)
        // Model the provider's EOS decision before its final response arrives.
        // The old implementation sends nextOnset into this closing connection.
        for _ in 0..<4000 {
            if first.xunfeiEndSent || first.xunfeiAudio.count >= speech.count + silence.count + nextOnset.count { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        if action == "finish" {
            try expect(try client.finishRecording(), "manual finish must await captured speech")
        } else if action == "pause" { client.setTranscriptionPaused(true) }
        else if action == "stop" { client.stop() }
        first.push(#"{"code":0,"data":{"status":2,"result":{"sn":0,"ws":[{"cw":[{"w":"第一句"}]}]}}}"#)
        if action == "pause" || action == "stop" {
            await settle()
            try expect(finals.isEmpty && URLSession.shared.sockets.count == 1 && first.closed,
                       "pause/stop must discard pending onset and ignore the old final")
            if action == "pause" {
                client.setTranscriptionPaused(false)
                await settle()
                try expect(URLSession.shared.sockets.count == 2 && URLSession.shared.sockets[1].sent.isEmpty,
                           "resume must not upload discarded pending onset")
            }
            client.stop()
            return
        }
        try await until { finals.count == 1 && URLSession.shared.sockets.count >= 2 }
        try expect(finals[0] == speech + silence,
                   "Xunfei must keep speech that starts while the previous final is pending out of the previous utterance audio")
        let next = URLSession.shared.sockets.last!
        try await until { next.xunfeiAudio == nextOnset }
        try expect(first.xunfeiAudio == speech + silence, "closing Xunfei input must not consume the next utterance onset")
        next.push(#"{"code":0,"data":{"status":2,"result":{"sn":0,"ws":[{"cw":[{"w":"第二句"}]}]}}}"#)
        try await until { finals.count == 2 }
        try expect(finals[1] == nextOnset, "next utterance must retain exactly its own onset, including after manual finish")
        client.stop()
    }

    @MainActor private static func bailian() async throws {
        URLSession.shared.sockets = []; RequestLogStore.shared.spans = []
        let client = BailianSpeechRecognizer(configuration: .init(apiKey: "test", model: "paraformer-realtime-v2"))
        var errors = 0
        var finals: [(String, Data?)] = []
        var resets = 0
        try await client.start(callback: { text, final, pcm in if final { finals.append((text, pcm)) } }, onError: { _ in errors += 1 }, onReset: { resets += 1 })
        try expect(URLSession.shared.sockets.count == 1, "Bailian must connect at call start")
        let idle = URLSession.shared.sockets[0]
        try await until { idle.action("run-task") }
        idle.event("task-started")
        await MicrophoneCapture.active?.emit(Data(repeating: 0, count: 1280), speech: false)
        await settle()
        try expect(idle.pcm.isEmpty && RequestLogStore.shared.spans.isEmpty, "Bailian idle task must send no PCM or recognition log")
        idle.expire()
        await settle()
        try expect(errors == 0 && URLSession.shared.sockets.count == 1 && RequestLogStore.shared.spans.isEmpty, "Bailian idle expiry stays quiet without retries")
        let a = Data(repeating: 1, count: 1280), b = Data(repeating: 2, count: 1280)
        await MicrophoneCapture.active?.emit(a, speech: true)
        try await until { URLSession.shared.sockets.count == 2 && URLSession.shared.sockets[1].action("run-task") }
        let old = URLSession.shared.sockets[1]
        try expect(old.pcm.isEmpty, "Bailian buffers only for its own task-started")
        old.event("task-started")
        try await until { old.pcm == a }
        await MicrophoneCapture.active?.emit(Data(repeating: 0, count: 1280), speech: false)
        old.sentence("第一句", end: 40)
        try await until { finals.count == 1 && URLSession.shared.sockets.count == 3 && old.action("finish-task") }
        let next = URLSession.shared.sockets[2]
        try await until { next.action("run-task") }
        next.event("task-started")
        await settle()
        try expect(next.pcm.isEmpty && !old.closed, "Bailian next task is prepared while old task drains")
        await MicrophoneCapture.active?.emit(b, speech: true)
        try await until { next.pcm == b }
        try expect(!old.closed && !old.pcm.contains(2), "next speech uploads before task-finished and never enters old socket")
        let resetCount = resets
        old.event("task-finished")
        await settle()
        try expect(old.closed && !next.closed && resets == resetCount && client.currentInputAudio == b, "old completion cannot reset next PCM/caption/socket")
        await MicrophoneCapture.active?.emit(Data(repeating: 0, count: 1280), speech: false)
        next.sentence("第二句", end: 40)
        try await until { finals.count == 2 && URLSession.shared.sockets.count == 4 }
        try expect(finals[0].0 == "第一句" && finals[0].1 == a && finals[1].0 == "第二句" && finals[1].1 == b, "Bailian texts and PCM remain per-task")
        try expect(RequestLogStore.shared.spans.count == 2 && RequestLogStore.shared.spans[0].text == "第一句" && RequestLogStore.shared.spans[1].text == "第二句", "Bailian logs stay per-task and exclude idle task")
        client.setTranscriptionPaused(true)
        let count = URLSession.shared.sockets.count
        next.event("task-finished")
        await settle()
        try expect(finals.count == 2 && URLSession.shared.sockets.count == count && URLSession.shared.sockets.allSatisfy(\.closed), "Bailian pause closes prepared/active/draining and rejects late events")
        client.setTranscriptionPaused(false)
        try expect(URLSession.shared.sockets.count == count + 1, "Bailian resume prepares once")
        client.stop()
        try expect(URLSession.shared.sockets.allSatisfy(\.closed) && errors == 0, "Bailian stop closes everything")
    }

    @MainActor private static func bailianEmptyRecognitionTimeout() async throws {
        URLSession.shared.sockets = []; RequestLogStore.shared.spans = []
        let client = BailianSpeechRecognizer(configuration: .init(apiKey: "test", model: "paraformer-realtime-v2"))
        var errors = 0
        var resets = 0
        var callbacks = 0
        try await client.start(callback: { _, _, _ in callbacks += 1 },
                               onError: { _ in errors += 1 }, onReset: { resets += 1 })
        let socket = URLSession.shared.sockets[0]
        try await until { socket.action("run-task") }
        socket.event("task-started")
        await MicrophoneCapture.active?.emit(Data(repeating: 7, count: 1280), speech: true)
        try await until { socket.action("run-task") && socket.sent.contains(where: { message in
            if case .data(let value) = message { return !value.isEmpty }
            return false
        }) }
        // A cough can pass VAD and upload PCM without producing a transcript.
        socket.push("{\"header\":{\"task_id\":\"\(socket.taskIDForTest)\",\"event\":\"task-failed\",\"error_code\":\"response_timeout\",\"error_message\":\"Response timeout\"}}")
        try await until { socket.closed }
        try expect(errors == 0 && callbacks == 0 && !RequestLogStore.shared.spans[0].failed,
                   "Bailian empty recognition timeout must quietly end the turn")
        try expect(resets > 0, "Bailian empty recognition timeout must clear the listening caption")
        client.stop()
    }

    @MainActor private static func expiryAndRaces() async throws {
        URLSession.shared.sockets = []; RequestLogStore.shared.spans = []
        var errors = 0
        let pcm = Data(repeating: 3, count: 1280)
        let xunfei = XunfeiSpeechRecognizer(credentials: .init(xunfeiAppID: "test", xunfeiAPIKey: "test", xunfeiAPISecret: "test"))
        try await xunfei.start(callback: { _, _, _ in }, onError: { _ in errors += 1 })
        let expiredSignature = URLSession.shared.sockets[0]
        ProcessInfo.processInfo.systemUptime += 241
        await MicrophoneCapture.active?.emit(pcm, speech: true)
        try await until { URLSession.shared.sockets.count == 2 && !URLSession.shared.sockets[1].sent.isEmpty }
        try expect(expiredSignature.closed && expiredSignature.sent.isEmpty, "Xunfei stale signature must be replaced before first audio")
        let freshFrame = try JSONSerialization.jsonObject(with: Data(URLSession.shared.sockets[1].firstString.utf8)) as! [String: Any]
        try expect((freshFrame["business"] as? [String: Any])?["eos"] as? Int == 2000, "Xunfei eos remains 2000")
        xunfei.stop()
        try await xunfei.start(callback: { _, _, _ in }, onError: { _ in errors += 1 })
        let raced = URLSession.shared.sockets.last!
        raced.failNextAudio = true
        let count = URLSession.shared.sockets.count
        await MicrophoneCapture.active?.emit(pcm, speech: true)
        try await until { URLSession.shared.sockets.count == count + 1 && !URLSession.shared.sockets.last!.sent.isEmpty }
        try expect(raced.closed && errors == 0, "Xunfei idle-close/onset race retries once without onError")
        xunfei.stop()
        try await xunfei.start(callback: { _, _, _ in }, onError: { _ in errors += 1 })
        let idle = URLSession.shared.sockets.last!
        let pending = try xunfei.finishRecording()
        try expect(!pending, "Xunfei idle finish is not a pending recognition")
        await settle()
        try expect(idle.sent.isEmpty && idle.closed, "Xunfei idle finish sends no empty audio frame")
        xunfei.stop()

        let bailian = BailianSpeechRecognizer(configuration: .init(apiKey: "test", model: "paraformer-realtime-v2"))
        try await bailian.start(callback: { _, _, _ in }, onError: { _ in errors += 1 }, onReset: {})
        let warm = URLSession.shared.sockets.last!
        try await until { warm.action("run-task") }
        let run = try JSONSerialization.jsonObject(with: Data(warm.firstString.utf8)) as! [String: Any]
        let parameters = (run["payload"] as? [String: Any])?["parameters"] as? [String: Any]
        try expect(parameters?["max_sentence_silence"] as? Int == 2000, "Bailian silence threshold remains 2000")
        warm.event("task-started")
        await settle()
        warm.failNextAudio = true
        let before = URLSession.shared.sockets.count
        await MicrophoneCapture.active?.emit(pcm, speech: true)
        try await until { URLSession.shared.sockets.count == before + 1 && URLSession.shared.sockets.last!.action("run-task") }
        let cold = URLSession.shared.sockets.last!
        cold.event("task-started")
        try await until { cold.pcm == pcm }
        try expect(warm.closed && errors == 0 && bailian.currentInputAudio == pcm, "Bailian idle-close/onset race preserves new speech for a fresh task")
        // Once real PCM has been uploaded, a network failure is a real active
        // recognition error, not an idle-preparation failure to silently hide.
        cold.expire()
        try await until { errors == 1 }
        try expect(URLSession.shared.sockets.allSatisfy(\.closed), "Bailian active failure is reported and stops all tasks")
        bailian.stop()
    }

    @MainActor static func until(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw TincallError(message: "Timed out waiting for STT lifecycle assertion at line \(line)")
    }
    static func settle() async { for _ in 0..<30 { await Task.yield() } }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw TincallError(message: message) }
    }
}

@MainActor final class MicrophoneCapture {
    static weak var active: MicrophoneCapture?
    var onSpeechActivityChange: ((Bool) -> Void)?
    private var callback: (((audio: Data, hasSpeech: Bool)) async -> Void)?
    func start(onAudio: @escaping ((audio: Data, hasSpeech: Bool)) async -> Void, onError: @escaping (Error) async -> Void) throws { Self.active = self; callback = onAudio }
    func emit(_ pcm: Data, speech: Bool) async { await callback?((pcm, speech)) }
    var resetCount = 0
    init(requiresSustainedSpeech: Bool = false) {}
    func reset() { resetCount += 1 }
    func waitForStop() async {}
    func stop() { callback = nil }
    func setPaused(_ paused: Bool) {}
}

@MainActor final class URLSession {
    static let shared = URLSession()
    var sockets: [URLSessionWebSocketTask] = []
    func webSocketTask(with url: URL) -> URLSessionWebSocketTask { make() }
    func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask { make() }
    private func make() -> URLSessionWebSocketTask { let value = URLSessionWebSocketTask(); sockets.append(value); return value }
}

@MainActor final class URLSessionWebSocketTask {
    enum Message { case string(String), data(Data) }
    enum CloseCode { case invalid, normalClosure, goingAway }
    var closeCode: CloseCode = .invalid
    var state: Foundation.URLSessionTask.State = .suspended
    var error: Error?
    var response: URLResponse? { nil }
    var closed = false
    var failNextAudio = false
    var sent: [Message] = []
    var sentAt: [ContinuousClock.Instant] = []
    var sendLatency: Duration = .zero
    var sendLatencies: [Duration] = []
    private var messages: [Message] = []
    private var waiter: CheckedContinuation<Message, Error>?
    func resume() { state = .running }
    func send(_ message: Message) async throws {
        if closed { throw URLError(.networkConnectionLost) }
        // Record entry before parsing the fixture's message.
        let startedAt = ContinuousClock.now
        let isAudio: Bool
        switch message {
        case .data: isAudio = true
        case .string(let value):
            let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
            isAudio = object?["data"] != nil
        }
        if failNextAudio && isAudio { failNextAudio = false; throw URLError(.networkConnectionLost) }
        let latency = sendLatencies.isEmpty ? sendLatency : sendLatencies.removeFirst()
        if latency > .zero { try await Task.sleep(for: latency) }
        sent.append(message)
        sentAt.append(startedAt)
    }
    func receive() async throws -> Message {
        if !messages.isEmpty { return messages.removeFirst() }
        if closed { throw URLError(.networkConnectionLost) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel(with closeCode: CloseCode, reason: Data?) {
        closed = true; state = .completed; self.closeCode = closeCode
        let pending = waiter; waiter = nil; pending?.resume(throwing: URLError(.cancelled))
    }
    func expire() { error = URLError(.networkConnectionLost); cancel(with: .goingAway, reason: nil) }
    func push(_ text: String) {
        let message = Message.string(text)
        if let pending = waiter { waiter = nil; pending.resume(returning: message) } else { messages.append(message) }
    }
    var firstString: String { sent.compactMap { if case .string(let value) = $0 { value } else { nil } }.first ?? "" }
    var pcm: Data { sent.reduce(into: Data()) { result, message in if case .data(let value) = message { result.append(value) } } }
    var xunfeiAudio: Data { sent.reduce(into: Data()) { result, message in
        guard case .string(let text) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let payload = object["data"] as? [String: Any], let encoded = payload["audio"] as? String,
              let audio = Data(base64Encoded: encoded) else { return }
        result.append(audio)
    } }
    var xunfeiEndSent: Bool { sent.contains { message in
        guard case .string(let text) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let payload = object["data"] as? [String: Any] else { return false }
        return payload["status"] as? Int == 2
    } }
    func action(_ action: String) -> Bool { sent.contains { message in
        guard case .string(let value) = message else { return false }
        let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        return (object?["header"] as? [String: Any])?["action"] as? String == action
    } }
    var taskIDForTest: String {
        for message in sent {
            guard case .string(let value) = message,
                  let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                  let header = object["header"] as? [String: Any], let id = header["task_id"] as? String else { continue }
            return id
        }
        return "missing-task"
    }
    private var taskID: String { taskIDForTest }
    func event(_ event: String) { push("{\"header\":{\"task_id\":\"\(taskID)\",\"event\":\"\(event)\"}}") }
    func sentence(_ text: String, end: Int) {
        push("{\"header\":{\"task_id\":\"\(taskID)\",\"event\":\"result-generated\"},\"payload\":{\"output\":{\"sentence\":{\"begin_time\":0,\"end_time\":\(end),\"sentence_end\":true,\"text\":\"\(text)\"}}}}")
    }
}

@MainActor final class RequestLogStore {
    static let shared = RequestLogStore()
    enum Service { case xunfei, bailian }
    enum Step { case transcription }
    var spans: [RequestLogSpan] = []
    func begin(service: Service, step: Step, context: RequestLogContext?, connectionName: String?, modelName: String? = nil) -> RequestLogSpan {
        let span = RequestLogSpan(); spans.append(span); return span
    }
}
struct RequestLogContext {}
@MainActor final class RequestLogSpan {
    var text = ""
    var failed = false
    func response(_ value: URLResponse?) {}
    func protect(_ value: [String]) {}
    func protect(_ value: URLRequest) {}
    func request(_ value: String, persistImmediately: Bool = true) {}
    func body(_ value: Data) {}
    func text(_ value: String) { text = value }
    func succeed(_ value: String? = nil) { if let value { text = value } }
    func fail(_ error: Error) { failed = true }
    func finish() {}
    func flush() {}
}

// Advance signature age without sleeping or altering production clock APIs.
@MainActor final class ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime: TimeInterval = 1000
}
