// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFoundation
import Foundation
import OSLog

@MainActor
final class SpeechPlayback {
    private(set) var isPlaying = false
    private(set) var isActive = false
    private(set) var synthesisError: Error?
    private(set) var failedCaption: String?
    var onPlaybackStateChange: ((Bool) -> Void)?
    var onActivityStateChange: ((Bool) -> Void)?
    var onCaptionChange: ((String?) -> Void)?
    var onAudioReady: ((Int, Data) -> Void)?
    var retainsAudio = false
    private let session: URLSession
    private let fishSession: URLSession
    private let logger = Logger(subsystem: "com.tincall.app", category: "VoiceCallTTS")
    private var logContext: RequestLogContext?
    private var connectionName: String?
    private var settings: SpeechSynthesisConfiguration?
    private var playbackEnabled = true
    private var segmenter = SpeechSegmenter()
    private var previousSegmentText = ""
    private var completedElevenLabsRequests: [(index: Int, id: String, completedAt: TimeInterval)] = []
    private var stitchingWaitTask: Task<Void, Never>?
    private var stitchingWaitIndex: Int?
    private var previousSourceEnd = 0
    private var segments: [Int: SpeechPlaybackSegment] = [:]
    private var pending: [Int] = []
    private var requests: [Int: Task<Void, Never>] = [:]
    private var nextIndex = 0
    private var playingIndex = 0
    private var generation = 0
    private var renderGeneration = 0
    private var failedSegments: [Int] = []
    private var playbackTimedOut = false
    private var playbackError: TincallError?
    private var drainTask: Task<Void, Never>?
    private var drainIndex: Int?
    private var segmentGapTask: Task<Void, Never>?
    private var nextPlaybackNotBefore: TimeInterval = 0
    private var finalReceived = false
    private var result: Result<Void, Error>?
    private var completion: CheckedContinuation<Void, Error>?
    private var engine: AVAudioEngine?
    private var engineObservationID = UUID()
    private var player: AVAudioPlayerNode?
    private var routeObserver: NSObjectProtocol?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var volumeObservation: NSKeyValueObservation?
    private var isAudioInterrupted = false
    private var outputConfigurationChanged = false
    private var caption: String?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var diagnosticTurn = UUID()

    init(session: URLSession = .shared) {
        self.session = session
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 30
        options.timeoutIntervalForResource = 120
        options.httpCookieStorage = nil
        options.urlCredentialStorage = nil
        fishSession = URLSession(configuration: options, delegate: SpeechHTTPNoRedirects(), delegateQueue: nil)
    }

    func begin(settings: SpeechSynthesisConfiguration, logContext: RequestLogContext? = nil, connectionName: String? = nil,
               diagnosticTurn: UUID? = nil, playbackEnabled: Bool = true) throws {
        stop()
        self.playbackEnabled = playbackEnabled
        guard !isAudioInterrupted else {
            throw TincallError(message: String(localized: "语音播放被系统音频中断，请重新打开麦克风后继续"))
        }
        self.diagnosticTurn = diagnosticTurn ?? UUID()
        synthesisError = nil
        failedCaption = nil
        self.logContext = logContext
        self.connectionName = connectionName
        self.settings = settings
        switch settings {
        case .elevenLabs(let value):
            segmenter = SpeechSegmenter(provider: .elevenLabs, model: value.elevenLabsModel)
        case .miniMax(let value):
            segmenter = SpeechSegmenter(provider: .miniMax, model: value.model)
        case .fishAudio(let value):
            segmenter = SpeechSegmenter(provider: .fishAudio, model: value.model)
        }
        nextIndex = 0
        playingIndex = 0
        failedSegments.removeAll()
        playbackTimedOut = false
        playbackError = nil
        finalReceived = false
        result = nil
        startedAt = ProcessInfo.processInfo.systemUptime
        setActive(true)
        log("turn_start", index: -1)
    }

    func appendText(_ text: String, final: Bool) throws {
        guard settings != nil, result == nil, !finalReceived else { return }
        if nextIndex == 0, !text.isEmpty { log("text_received", index: 0) }
        for value in try segmenter.append(text, final: final) {
            guard segments.count < 64 else { throw TincallError(message: String(localized: "待播语音过多，请打断后重试")) }
            segments[nextIndex] = SpeechPlaybackSegment(value, previousText: previousSegmentText, sourceStart: previousSourceEnd)
            previousSourceEnd = value.sourceEnd
            previousSegmentText = value.text
            pending.append(nextIndex)
            log("segment_ready", index: nextIndex)
            nextIndex += 1
        }
        if final, segmenter.droppedIncompleteTags > 0 { log("incomplete_tag_dropped", index: nextIndex) }
        finalReceived = final
        pumpRequests()
        do { try pumpPlayback() } catch { finish(.failure(error)) }
    }

    func enablePlayback() throws {
        playbackEnabled = true
        for index in segments.keys.sorted() where segments[index]?.received == true || segments[index]?.failed == true {
            archiveSegment(index)
        }
        try pumpPlayback()
    }

    static func waveData(pcm: Data, sampleRate: UInt32 = 24_000) -> Data {
        PCM16Wave.data(pcm: pcm, sampleRate: sampleRate)
    }

    func waitUntilFinished() async throws {
        try Task.checkCancellation()
        let expectedGeneration = generation
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { try result.get(); return }
            try await withCheckedThrowingContinuation { completion = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.stop()
            }
        }
    }

    func stop() {
        if settings != nil { CallAudioDiagnostics.record(.ttsStop, turn: diagnosticTurn, generation: generation, segment: playingIndex) }
        failedCaption = nil
        generation += 1
        renderGeneration += 1
        cancelDrainWait()
        cancelSegmentGap()
        cancelStitchingWait()
        nextPlaybackNotBefore = 0
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        if let engineConfigurationObserver { NotificationCenter.default.removeObserver(engineConfigurationObserver) }
        engineConfigurationObserver = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        for request in requests.values { request.cancel() }
        requests.removeAll()
        pending.removeAll()
        player?.stop()
        engine?.stop()
        setCaption(nil)
        player = nil
        engine = nil
        outputConfigurationChanged = false
        if retainsAudio {
            for index in segments.keys.sorted() {
                guard let segment = segments[index] else { continue }
                let bytes = segment.archivePCM.count / 2 * 2
                if bytes > 0 {
                    onAudioReady?(index, Self.waveData(pcm: Data(segment.archivePCM.prefix(bytes))))
                }
                segment.archivePCM.removeAll()
            }
        }
        segments.removeAll()
        completedElevenLabsRequests.removeAll()
        previousSegmentText = ""
        previousSourceEnd = 0
        settings = nil
        setPlaying(false)
        setActive(false)
        result = .failure(CancellationError())
        let continuation = completion
        completion = nil
        continuation?.resume(throwing: CancellationError())
    }

    func setAudioInterrupted(_ interrupted: Bool) {
        guard isAudioInterrupted != interrupted else { return }
        isAudioInterrupted = interrupted
        if interrupted {
            guard isActive else { return }
            // The system may never send an ended notification. Resolve the
            // current reply instead of leaving the coordinator synthesizing.
            finish(.failure(TincallError(message: String(localized: "语音播放被系统音频中断，请重新打开麦克风后继续"))))
        } else {
            do {
                if outputConfigurationChanged { restoreOutputQueue() }
                if let engine, !engine.isRunning { try engine.start() }
                try pumpPlayback()
            } catch { finish(.failure(error)) }
        }
    }

    private func pumpRequests() {
        while requests.count < 2, let next = pending.first {
            // Prefer completed-audio context, but don't hold the next text for
            // more than 500 ms. An unfinished request's ID is never referenced.
            if case .elevenLabs(let configuration) = settings, configuration.supportsRequestStitching,
               !requests.isEmpty, let segment = segments[next] {
                let delay = segment.queuedAt + 0.5 - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    if stitchingWaitIndex != next {
                        cancelStitchingWait()
                        stitchingWaitIndex = next
                        let expectedGeneration = generation
                        stitchingWaitTask = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(delay)) }
                            catch { return }
                            guard let self, self.generation == expectedGeneration,
                                  !Task.isCancelled, self.result == nil, self.stitchingWaitIndex == next else { return }
                            self.stitchingWaitTask = nil
                            self.stitchingWaitIndex = nil
                            self.pumpRequests()
                        }
                    }
                    return
                }
            }
            cancelStitchingWait()
            let index = pending.removeFirst()
            let expectedGeneration = generation
            requests[index] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.receiveAudio(index: index, generation: expectedGeneration)
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    self.requests[index] = nil
                    self.segments[index]?.received = true
                    self.archiveSegment(index)
                    self.log("receive_end", index: index)
                    self.pumpRequests()
                    try self.pumpPlayback()
                } catch {
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    CallAudioDiagnostics.record(.ttsRequestFailed, turn: self.diagnosticTurn, generation: self.generation,
                                                segment: index, count: (error as NSError).code)
                    if self.synthesisError == nil { self.synthesisError = error }
                    self.requests[index] = nil
                    self.failSegment(index)
                    self.pumpRequests()
                    do { try self.pumpPlayback() } catch { self.finish(.failure(error)) }
                }
            }
        }
    }

    private func cancelStitchingWait() {
        stitchingWaitTask?.cancel()
        stitchingWaitTask = nil
        stitchingWaitIndex = nil
    }

    private indirect enum Echo {
        case yourVoice(String)
        case onceMore(Echo)
    }

    private func archiveSegment(_ index: Int) {
        guard retainsAudio, let onAudioReady, let segment = segments[index] else { return }
        let bytes = segment.archivePCM.count / 2 * 2
        if bytes > 0 { onAudioReady(index, Self.waveData(pcm: Data(segment.archivePCM.prefix(bytes)))) }
        segment.archivePCM.removeAll()
    }

    private func failSegment(_ index: Int) {
        guard let segment = segments[index], !segment.failed else { return }
        if failedCaption == nil, !segment.value.caption.isEmpty { failedCaption = segment.value.caption }
        segment.fail()
        requests[index]?.cancel()
        requests[index] = nil
        pending.removeAll { $0 == index }
        failedSegments.append(index)
        archiveSegment(index)
        log("segment_failed", index: index)
        if index == playingIndex {
            // Only the current segment is ever scheduled on the player.
            cancelDrainWait()
            cancelSegmentGap()
            player?.stop()
            segment.scheduled = 0
            segment.scheduledFrames = 0
            setCaption(nil)
            setPlaying(false)
        }
        pumpRequests()
    }

    private func receiveAudio(index: Int, generation expectedGeneration: Int) async throws {
        guard let settings, let segment = segments[index] else { throw CancellationError() }
        switch settings {
        case .miniMax(let configuration):
            try await SpeechHTTP.perform(service: .miniMax, step: .synthesis, context: logContext, segment: index,
                                         connectionName: connectionName, modelName: configuration.model) { log in
                try await receiveMiniMaxAudio(configuration, segment: segment, index: index, generation: expectedGeneration, log: log)
                log.text(audioResult(segment))
            }
        case .elevenLabs(let configuration):
            try await receiveElevenLabsAudio(configuration, segment: segment, index: index, generation: expectedGeneration)
        case .fishAudio(let configuration):
            try await SpeechHTTP.perform(service: .fish, step: .synthesis, context: logContext, segment: index,
                                         connectionName: connectionName, modelName: configuration.model) { log in
                try await receiveFishAudio(configuration, segment: segment, index: index, generation: expectedGeneration, log: log)
                log.text(audioResult(segment))
            }
        }
    }

    private func receiveFishAudio(_ settings: FishAudioConfiguration, segment: SpeechPlaybackSegment,
                                  index: Int, generation expectedGeneration: Int, log requestLog: RequestLogSpan) async throws {
        let request = try settings.request(text: segment.value.text)
        requestLog.protect(request)
        requestLog.requestBody(request.httpBody)
        requestLog.request(segment.value.text)
        log("request_start", index: index)
        let (bytes, response) = try await fishSession.bytes(for: request)
        requestLog.response(response)
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw TincallError(message: String(localized: "Fish Audio 返回了无效响应")) }
        log("http_response", index: index, status: response.statusCode)
        if !(200..<300).contains(response.statusCode) { try await requestLog.errorBody(bytes) }
        try FishPCMStream.validate(statusCode: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        var parser = FishPCMStream()
        var chunk = Data()
        chunk.reserveCapacity(4096)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            chunk.append(byte)
            if chunk.count >= 4096 {
                let pcm = parser.consume(chunk)
                if !pcm.isEmpty { try accept(pcm, for: segment, index: index, generation: expectedGeneration) }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            let pcm = parser.consume(chunk)
            if !pcm.isEmpty { try accept(pcm, for: segment, index: index, generation: expectedGeneration) }
        }
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
        try parser.finish()
    }

    private func receiveElevenLabsAudio(_ settings: ElevenLabsConfiguration, segment: SpeechPlaybackSegment,
                                       index: Int, generation expectedGeneration: Int) async throws {
        guard var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(settings.elevenLabsVoiceID)/stream") else {
            throw TincallError(message: String(localized: "ElevenLabs 音色配置无效"))
        }
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        guard let url = components.url else { throw TincallError(message: String(localized: "ElevenLabs 连接地址无效")) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(settings.elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        // Reference completed audio instead of resending preceding text, which
        // was repeated in the next segment's returned audio.
        var body: [String: Any] = ["text": segment.value.text, "model_id": settings.elevenLabsModel]
        let voiceSettings = try settings.voiceSettings()
        if !voiceSettings.isEmpty { body["voice_settings"] = voiceSettings }
        if settings.supportsRequestStitching {
            let now = ProcessInfo.processInfo.systemUptime
            completedElevenLabsRequests.removeAll { now - $0.completedAt >= 2 * 60 * 60 }
            let ids = completedElevenLabsRequests.filter { $0.index < index }.map(\.id)
            if !ids.isEmpty { body["previous_request_ids"] = ids }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            attempt += 1
            let requestLog = RequestLogStore.shared.begin(service: .elevenLabs, step: .synthesis, context: logContext, segment: index,
                                                         connectionName: connectionName, modelName: settings.elevenLabsModel)
            requestLog.protect(request)
            requestLog.requestBody(request.httpBody)
            requestLog.request(segment.value.text)
            let initialBytes = segment.receivedBytes
            defer { requestLog.finish() }
            do {
                log("request_start", index: index)
                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do { (bytes, response) = try await session.bytes(for: request, delegate: SpeechHTTPNoRedirects()) }
                catch {
                    requestLog.fail(error); requestLog.finish()
                    try Task.checkCancellation()
                    if attempt < 3, Self.isTemporaryNetworkError(error) {
                        log("transport_retry", index: index)
                        try await Task.sleep(for: .seconds(Double(attempt)))
                        continue
                    }
                    throw error
                }
                requestLog.response(response)
                guard let response = response as? HTTPURLResponse else {
                    throw TincallError(message: String(localized: "ElevenLabs 返回了无效响应"))
                }
                log("http_response", index: index, status: response.statusCode)
                if response.statusCode != 200 {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count >= 16_384 { break }
                    }
                    requestLog.body(body)
                    try Task.checkCancellation()
                    if response.statusCode == 429, attempt < 3 {
                        requestLog.fail(TincallError(message: "HTTP 429")); requestLog.finish()
                        let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? min(10, pow(2, Double(min(attempt, 4))))
                        log("rate_limit_retry", index: index, status: 429)
                        try await Task.sleep(for: .seconds(min(10, max(0.25, delay.isFinite ? delay : 1))))
                        continue
                    }
                    if attempt < 3, response.statusCode == 408 || (500...599).contains(response.statusCode) {
                        requestLog.fail(TincallError(message: "HTTP failure")); requestLog.finish()
                        log("server_retry", index: index, status: response.statusCode)
                        try await Task.sleep(for: .seconds(Double(attempt)))
                        continue
                    }
                    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let detail = object?["detail"] as? [String: Any]
                    let rawCode = detail?["status"] as? String ?? "request_failed"
                    let code = rawCode.prefix(80).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                    let error = TincallError(message: "ElevenLabs \(response.statusCode)（\(code)）", requestCode: rawCode)
                    let hasWords = segment.value.caption.contains { character in
                        guard character.isLetter || character.isNumber else { return false }
                        // Plain ASCII digits are words; keycaps and letter emoji are not.
                        return !character.unicodeScalars.contains {
                            $0.properties.isEmoji && ($0.value > 127 || character.unicodeScalars.count > 1)
                        }
                    }
                    if rawCode == "input_text_empty", !segment.firstAudio, !hasWords {
                        // A tag/emoji-only input rejected as empty has no words to lose.
                        // Keep the HTTP failure in logs, but let the queue skip it without
                        // marking the reply or its preserved transcript as interrupted.
                        requestLog.fail(error)
                        segment.fail()
                        log("non_speech_skipped", index: index, status: response.statusCode)
                        return
                    }
                    throw error
                }
                var chunk = Data()
                chunk.reserveCapacity(4096)
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count == 4096 {
                            try accept(chunk, for: segment, index: index, generation: expectedGeneration)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                } catch {
                    requestLog.fail(error); requestLog.finish()
                    try Task.checkCancellation()
                    if attempt < 3, Self.isTemporaryNetworkError(error), segment.resetUnplayedReception() {
                        log("transport_retry", index: index)
                        try await Task.sleep(for: .seconds(Double(attempt)))
                        continue
                    }
                    throw error
                }
                if !chunk.isEmpty { try accept(chunk, for: segment, index: index, generation: expectedGeneration) }
                try Task.checkCancellation()
                guard generation == expectedGeneration else { throw CancellationError() }
                guard segment.firstAudio else { throw TincallError(message: String(localized: "ElevenLabs 返回了空音频")) }
                guard segment.pcm.count.isMultiple(of: 2) else { throw TincallError(message: String(localized: "ElevenLabs PCM 音频不完整")) }
                if settings.supportsRequestStitching,
                   let id = response.value(forHTTPHeaderField: "request-id")?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                    completedElevenLabsRequests.append((index, id, ProcessInfo.processInfo.systemUptime))
                    completedElevenLabsRequests = Array(completedElevenLabsRequests.sorted { $0.index < $1.index }.suffix(3))
                }
                requestLog.succeed(audioResult(segment, subtracting: initialBytes))
                return
            } catch { requestLog.fail(error); throw error }
        }
    }

    private func receiveMiniMaxAudio(_ settings: MiniMaxConfiguration, segment: SpeechPlaybackSegment,
                                    index: Int, generation expectedGeneration: Int, log requestLog: RequestLogSpan) async throws {
        var request = URLRequest(url: settings.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.model, "text": segment.value.text, "stream": true,
            // Without this option MiniMax repeats all audio in its final event.
            "stream_options": ["exclude_aggregated_audio": true],
            "voice_setting": ["voice_id": settings.voiceID],
            "audio_setting": ["sample_rate": 24000, "format": "pcm", "channel": 1]
        ])
        requestLog.protect(request)
        requestLog.requestBody(request.httpBody)
        requestLog.request(segment.value.text)
        log("request_start", index: index)
        let (bytes, response) = try await session.bytes(for: request, delegate: SpeechHTTPNoRedirects())
        requestLog.response(response)
        guard let response = response as? HTTPURLResponse else { throw TincallError(message: String(localized: "MiniMax 返回了无效响应")) }
        log("http_response", index: index, status: response.statusCode)
        guard response.statusCode == 200 else {
            try await requestLog.errorBody(bytes)
            throw TincallError(message: String(localized: "MiniMax 合成失败（HTTP \(response.statusCode)）"))
        }
        var parser = MiniMaxAudioStream()
        var line = Data()
        // Byte parsing keeps both SSE lines and JSON error bodies bounded.
        for try await byte in bytes {
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            if byte == 10 {
                do {
                    if let data = try parser.consume(line: String(decoding: line, as: UTF8.self)), !data.isEmpty {
                        try accept(data, for: segment, index: index, generation: expectedGeneration)
                    }
                } catch { captureMiniMaxError(line, log: requestLog); throw error }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < 2 * 1024 * 1024 else { throw TincallError(message: String(localized: "MiniMax 音频响应过大")) }
                line.append(byte)
            }
        }
        do {
            if !line.isEmpty, let data = try parser.consume(line: String(decoding: line, as: UTF8.self)), !data.isEmpty {
                try accept(data, for: segment, index: index, generation: expectedGeneration)
            }
        } catch { captureMiniMaxError(line, log: requestLog); throw error }
        try Task.checkCancellation()
        try parser.finish()
        guard segment.firstAudio, segment.pcm.count.isMultiple(of: 2) else {
            throw TincallError(message: String(localized: "MiniMax 返回了空音频或不完整的 PCM"))
        }
    }

    private func audioResult(_ segment: SpeechPlaybackSegment, subtracting initialBytes: Int = 0) -> String {
        let bytes = max(0, segment.receivedBytes - initialBytes)
        return String(format: String(localized: "音频 %.2f 秒 · %d 字节"), Double(bytes) / 48000, bytes)
    }

    private func captureMiniMaxError(_ line: Data, log: RequestLogSpan) {
        let value = String(decoding: line, as: UTF8.self)
        let json = value.hasPrefix("data:") ? String(value.dropFirst(5)) : value
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["base_resp"] as? [String: Any],
              let code = error["status_code"] as? Int, code != 0,
              let body = try? JSONSerialization.data(withJSONObject: error) else { return }
        log.body(body)
    }

    private func accept(_ data: Data, for segment: SpeechPlaybackSegment, index: Int, generation expectedGeneration: Int) throws {
        try Task.checkCancellation()
        guard generation == expectedGeneration, !segment.failed else { throw CancellationError() }
        if !segment.firstAudio { segment.firstAudio = true; log("first_audio", index: index) }
        let bufferedBytes = segments.values.reduce(0) { $0 + $1.pcm.count + $1.archivePCM.count }
        guard bufferedBytes + data.count * (retainsAudio ? 2 : 1) <= 8 * 1024 * 1024 else {
            throw TincallError(message: String(localized: "待播音频超出缓存上限"))
        }
        segment.receivedBytes += data.count
        segment.pcm.append(data)
        if retainsAudio {
            guard segment.archivePCM.count + data.count <= 12 * 1024 * 1024 else {
                throw TincallError(message: String(localized: "单段语音过长，无法保存重播"))
            }
            segment.archivePCM.append(data)
        }
        try pumpPlayback()
    }

    private func pumpPlayback() throws {
        guard playbackEnabled, result == nil, !isAudioInterrupted else { return }
        playback: while let segment = segments[playingIndex] {
            if segment.failed {
                segments[playingIndex] = nil
                playingIndex += 1
                continue
            }
            if !segment.started {
                guard segment.canStart else { setPlaying(false); return }
                if waitForSegmentGap() { return }
                do { try preparePlayer() }
                catch {
                    let failure = error as NSError
                    CallAudioDiagnostics.record(.ttsPrepareFailed, turn: diagnosticTurn, generation: generation,
                                                segment: playingIndex, count: failure.code)
                    logger.error("phase=playback_start_failed error_domain=\(failure.domain, privacy: .public) error_code=\(failure.code)")
                    logAudioRoute("playback_start_failed_route")
                    if playbackError == nil {
                        let code = String(failure.code)
                        playbackError = TincallError(message: String(localized: "无法启动语音播放（错误码：\(code)）"))
                    }
                    failSegment(playingIndex)
                    continue
                }
                segment.started = true
                log("play_start", index: playingIndex)
            }
            while segment.scheduled < 3, segment.pcm.count >= 2 {
                let count = min(4096, segment.pcm.count / 2 * 2)
                let data = Data(segment.pcm.prefix(count))
                segment.pcm.removeFirst(count)
                let frames = count / 2
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let samples = buffer.floatChannelData?[0] else {
                    failSegment(playingIndex)
                    continue playback
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                data.withUnsafeBytes { raw in
                    for index in 0..<frames { samples[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768 }
                }
                segment.scheduled += 1
                segment.scheduledFrames += frames
                segment.scheduledPCM.append(data)
                let expectedGeneration = generation
                let expectedRenderGeneration = renderGeneration
                let index = playingIndex
                player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == expectedGeneration, self.renderGeneration == expectedRenderGeneration,
                              let current = self.segments[index], !current.failed else { return }
                        current.scheduled -= 1
                        current.scheduledFrames -= frames
                        current.scheduledPCM.removeFirst(min(count, current.scheduledPCM.count))
                        current.playedBytes += count
                        do { try self.pumpPlayback() } catch { self.finish(.failure(error)) }
                    }
                }
            }
            if segment.scheduled > 0 { setPlaying(true) }
            if player?.isPlaying == false { player?.play() }
            if segment.scheduled > 0, player?.isPlaying == true {
                setCaption(segment.value.caption.isEmpty ? nil : segment.value.caption)
            }
            guard segment.isDrained else {
                if segment.scheduled == 0 { setPlaying(false) }
                armDrainWait(segment, index: playingIndex)
                return
            }
            cancelDrainWait()
            log("play_end", index: playingIndex)
            setCaption(nil)
            segments[playingIndex] = nil
            playingIndex += 1
            nextPlaybackNotBefore = ProcessInfo.processInfo.systemUptime + 0.08
        }
        setPlaying(false)
        if finalReceived, playingIndex == nextIndex, requests.isEmpty {
            if let playbackError { finish(.failure(playbackError)); return }
            if failedSegments.isEmpty { finish(.success(())) }
            else {
                let numbers = failedSegments.sorted().map { String($0 + 1) }.joined(separator: "、")
                let reason = playbackTimedOut ? String(localized: "（播放异常结束）") : ""
                finish(.failure(TincallError(message: String(localized: "第 \(numbers) 段语音失败\(reason)，本轮未完整播放"))))
            }
        }
    }

    private func cancelSegmentGap() {
        segmentGapTask?.cancel()
        segmentGapTask = nil
    }

    private func waitForSegmentGap() -> Bool {
        let delay = nextPlaybackNotBefore - ProcessInfo.processInfo.systemUptime
        guard delay > 0 else { return false }
        guard segmentGapTask == nil else { return true }
        let expectedGeneration = generation
        let expectedRenderGeneration = renderGeneration
        segmentGapTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, self.generation == expectedGeneration,
                  self.renderGeneration == expectedRenderGeneration,
                  !Task.isCancelled, self.result == nil, !self.isAudioInterrupted else { return }
            self.segmentGapTask = nil
            do { try self.pumpPlayback() } catch { self.finish(.failure(error)) }
        }
        return true
    }

    private func cancelDrainWait() {
        drainTask?.cancel()
        drainTask = nil
        if let drainIndex { segments[drainIndex]?.cancelDrain() }
        drainIndex = nil
    }

    private func armDrainWait(_ segment: SpeechPlaybackSegment, index: Int) {
        guard drainTask == nil, !isAudioInterrupted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        segment.armDrain(now: now)
        guard let deadline = segment.drainDeadline else { return }
        drainIndex = index
        let expectedGeneration = generation
        log("drain_start", index: index)
        drainTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - now))) }
            catch { return }
            guard let self, self.generation == expectedGeneration, !Task.isCancelled,
                  !self.isAudioInterrupted, self.segments[index] === segment,
                  segment.drainExpired(now: ProcessInfo.processInfo.systemUptime) else { return }
            self.drainTask = nil
            self.drainIndex = nil
            self.playbackTimedOut = true
            self.log("drain_timeout", index: index)
            self.failSegment(index)
            do { try self.pumpPlayback() } catch { self.finish(.failure(error)) }
        }
    }

    private func preparePlayer() throws {
        guard engine == nil else { return }
        logAudioRoute("playback_prepare_route")
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        // Reply playback is output only. Echo cancellation belongs to the
        // speaker microphone engine; a second voice-processing I/O graph can
        // replace the user's high-quality Bluetooth media route.
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        logAudioRoute("playback_engine_start")
        try engine.start()
        logAudioRoute("playback_started_route")
        self.engine = engine
        self.player = player
        let expectedGeneration = generation
        let observationID = UUID()
        engineObservationID = observationID
        engineConfigurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.engineObservationID == observationID, let engine = self.engine, self.result == nil,
                      self.generation == expectedGeneration, !engine.isRunning else { return }
                self.outputConfigurationChanged = true
                guard !self.isAudioInterrupted else { return }
                do {
                    self.restoreOutputQueue()
                    try engine.start()
                    try self.pumpPlayback()
                } catch { self.finish(.failure(error)) }
            }
        }
        updateOutputVolume()
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logAudioRoute("playback_route_changed")
                self?.updateOutputVolume()
            }
        }
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateOutputVolume() }
        }
    }

    private func updateOutputVolume() {
        guard let player else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let usesReceiver = !outputs.isEmpty && outputs.allSatisfy { $0.portType == .builtInReceiver }
        player.volume = usesReceiver ? 1.0 : 0.8
    }

    private func restoreOutputQueue() {
        CallAudioDiagnostics.record(.ttsRestore, turn: diagnosticTurn, generation: generation,
                                    segment: playingIndex, count: segments.values.reduce(0) { $0 + $1.scheduledPCM.count })
        cancelDrainWait()
        cancelSegmentGap()
        renderGeneration += 1
        player?.stop()
        for segment in segments.values { segment.restoreScheduledAudio() }
        outputConfigurationChanged = false
    }

    private func logAudioRoute(_ phase: String) {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        logger.info("phase=\(phase, privacy: .public) category=\(session.category.rawValue, privacy: .public) mode=\(session.mode.rawValue, privacy: .public) options=\(session.categoryOptions.rawValue) inputs=\(inputs, privacy: .public) outputs=\(outputs, privacy: .public)")
    }

    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        if case .failure = result { CallAudioDiagnostics.record(.ttsFailed, turn: diagnosticTurn, generation: generation, segment: playingIndex) }
        else { CallAudioDiagnostics.record(.ttsFinished, turn: diagnosticTurn, generation: generation, segment: playingIndex) }
        let continuation = completion
        completion = nil
        let failedCaption = self.failedCaption
        stop()
        if case .failure = result { self.failedCaption = failedCaption }
        self.result = result
        continuation?.resume(with: result)
    }

    private static func isTemporaryNetworkError(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        onPlaybackStateChange?(playing)
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onActivityStateChange?(active)
    }

    private func setCaption(_ caption: String?) {
        guard self.caption != caption else { return }
        self.caption = caption
        onCaptionChange?(caption)
    }

    private func log(_ phase: String, index: Int, status: Int = 0) {
        let event: CallAudioDiagnostics.Event?
        switch phase {
        case "turn_start": event = .ttsBegin
        case "segment_ready": event = .ttsSegment
        case "request_start": event = .ttsRequest
        case "first_audio": event = .ttsFirstAudio
        case "receive_end": event = .ttsReceiveEnd
        case "play_start": event = .ttsPlayStart
        case "play_end": event = .ttsPlayEnd
        case "http_response": event = .ttsHTTPResponse
        case "drain_timeout": event = .ttsDrainTimeout
        default: event = nil
        }
        if let event {
            let segment = segments[index]
            let reportSource = event == .ttsSegment
            let reportBytes = event == .ttsReceiveEnd || event == .ttsPlayEnd
            CallAudioDiagnostics.record(event, turn: diagnosticTurn, generation: generation, segment: index,
                                        count: event == .ttsHTTPResponse ? status : nil,
                                        sourceStart: reportSource ? segment?.sourceStart : nil,
                                        sourceEnd: reportSource ? segment?.value.sourceEnd : nil,
                                        receivedBytes: reportBytes ? segment?.receivedBytes : nil,
                                        playedBytes: reportBytes ? segment?.playedBytes : nil)
        }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        logger.info("phase=\(phase, privacy: .public) segment=\(index) elapsed_ms=\(milliseconds) http_status=\(status)")
    }
}
