// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFoundation
import Foundation
import Speech

/// SpeechAnalyzer is entirely on device. Its module finals are accumulated until
/// the local speech boundary, so a long utterance does not become several turns.
@MainActor
final class AppleSpeechRecognizer: SpeechRecognizer {
    private let language: String
    private let logContext: () -> RequestLogContext?
    private let connectionName: String?
    private var requestLog: RequestLogSpan?
    // Require a short sustained onset before creating a local recognition
    // utterance; the gate retains those onset frames for the analyzer.
    private let capture = MicrophoneCapture(requiresSustainedSpeech: true)
    var onSpeechActivityChange: ((Bool) -> Void)? {
        get { capture.onSpeechActivityChange }
        set { capture.onSpeechActivityChange = newValue }
    }
    private var locale: Locale?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var callback: ((String, Bool, Data?) async -> Void)?
    private var onError: ((Error) async -> Void)?
    private var onReset: (() -> Void)?
    private var generation = 0
    private var running = false
    private var paused = false
    private var finishing = false
    private var silenceBytes = 0
    private var audio = STTReplayBuffer(limitBytes: 16_000 * 2 * 600)
    private var pendingAudio = STTReplayBuffer(limitBytes: 16_000 * 2 * 600)
    private var transcript = TimedSpeechTranscript()

    init(language: String, logContext: @escaping () -> RequestLogContext? = { nil }, connectionName: String? = nil) {
        self.language = language
        self.logContext = logContext
        self.connectionName = connectionName
    }
    var currentInputAudio: Data { audio.audio }

    func start(callback: @escaping (String, Bool, Data?) async -> Void,
               onError: @escaping (Error) async -> Void, onReset: @escaping () -> Void) async throws {
        stop()
        let expected = generation
        guard SpeechTranscriber.isAvailable else { throw TincallError(message: String(localized: "这台设备不支持 Apple 本机语音识别")) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw TincallError(message: String(localized: "Apple 本机识别不支持所选语言，请更换语言或识别连接"))
        }
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installation.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw TincallError(message: String(localized: "Apple 语音模型尚未就绪，请联网后重试"))
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let source = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw TincallError(message: String(localized: "Apple 语音模型的音频格式不可用"))
        }
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        self.locale = locale; self.format = format; self.converter = converter
        self.callback = callback; self.onError = onError; self.onReset = onReset
        running = true
        onReset()
        try await capture.start(onAudio: { [weak self] value in await self?.accept(value) },
                          onError: { [weak self] error in await self?.fail(error) })
    }

    func setTranscriptionPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        capture.setPaused(paused)
        // A route change can update the pause while start() awaits system assets.
        // Keep the flag for capture, but don't invalidate the start in progress.
        guard running else { return }
        resetUtterance()
        onReset?()
    }

    func stopAndWait() async {
        stop()
        await capture.waitForStop()
    }

    func stop() {
        running = false; paused = false
        capture.stop()
        resetUtterance()
        callback = nil; onError = nil; onReset = nil
        locale = nil; format = nil; converter = nil
    }

    func finishRecording() throws -> Bool {
        capture.stop()
        guard analyzer != nil else { return false }
        try endUtterance()
        return true
    }

    private func endUtterance() throws {
        guard !finishing else { return }
        finishing = true
        try finishInput()
        input?.finish(); input = nil
        let expected = generation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.generation == expected else { return }
            await self.fail(TincallError(message: String(localized: "Apple 本机识别等待最终结果超时")))
        }
    }

    private func resetUtterance() {
        requestLog?.finish(); requestLog = nil
        generation += 1
        input?.finish(); input = nil
        analysisTask?.cancel(); analysisTask = nil
        resultsTask?.cancel(); resultsTask = nil
        timeout?.cancel(); timeout = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        converter?.reset()
        audio = STTReplayBuffer(limitBytes: 16_000 * 2 * 600); pendingAudio = STTReplayBuffer(limitBytes: 16_000 * 2 * 600)
        transcript = TimedSpeechTranscript(); silenceBytes = 0; finishing = false
        capture.reset()
    }

    private func accept(_ value: (audio: Data, hasSpeech: Bool)) async {
        guard running, !paused else { return }
        do {
            if finishing {
                try pendingAudio.append(value.audio)
                return
            }
            if analyzer == nil {
                guard value.hasSpeech else { return }
                try beginUtterance()
            }
            try audio.append(value.audio)
            try appendInput(value.audio)
            silenceBytes = value.hasSpeech ? 0 : silenceBytes + value.audio.count
            // Only a 2-second pause ends the utterance; keep listening while the user keeps talking.
            if silenceBytes >= 16_000 * 2 * 2 {
                try endUtterance()
            }
        } catch { await fail(error) }
    }

    private func beginUtterance() throws {
        guard let locale, let format else { throw CancellationError() }
        requestLog = RequestLogStore.shared.begin(service: .apple, step: .transcription, context: logContext(),
                                                  connectionName: connectionName, modelName: String(localized: "Apple 本机识别"))
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        let expected = generation
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingOldest(100)) { input = $0 }
        resultsTask = Task { [weak self] in
            for try await result in module.results {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.transcript.update(start: result.range.start.seconds, end: result.range.end.seconds,
                                       text: String(result.text.characters), isFinal: result.isFinal)
                self.requestLog?.text(self.transcript.text)
                await self.callback?(self.transcript.text, false, nil)
            }
        }
        analysisTask = Task { [weak self] in
            do {
                try await analyzer.prepareToAnalyze(in: format)
                _ = try await analyzer.analyzeSequence(stream)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                try await self.resultsTask?.value
                guard self.generation == expected, !Task.isCancelled else { return }
                let text = self.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let pcm = self.audio.audio
                let remainder = self.pendingAudio.audio
                self.requestLog?.succeed(text); self.requestLog?.finish()
                if !text.isEmpty { await self.callback?(text, true, pcm) }
                guard self.generation == expected, !Task.isCancelled else { return }
                self.resetUtterance()
                self.onReset?()
                if remainder.contains(where: { $0 != 0 }) {
                    await self.accept((audio: remainder, hasSpeech: true))
                }
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                await self.fail(error)
            }
        }
    }

    private func appendInput(_ pcm: Data) throws {
        guard !pcm.isEmpty, let converter, let format else { return }
        let frames = pcm.count / 2
        guard let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = source.floatChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(frames) * format.sampleRate / 16_000 + 32)) else {
            throw TincallError(message: String(localized: "Apple 本机识别音频转换失败"))
        }
        source.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for index in 0..<frames {
                samples[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard output.frameLength > 0 else { return }
        if case .dropped = input?.yield(AnalyzerInput(buffer: output)) {
            throw TincallError(message: String(localized: "Apple 本机识别处理过慢，请重新打开麦克风"))
        }
    }

    private func finishInput() throws {
        guard let converter, let format else { return }
        // Flush the resampler's remaining samples before ending the analyzer input.
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
                throw TincallError(message: String(localized: "Apple 本机识别无法准备句尾音频"))
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if output.frameLength > 0, case .dropped = input?.yield(AnalyzerInput(buffer: output)) {
                throw TincallError(message: String(localized: "Apple 本机识别处理过慢，请重新打开麦克风"))
            }
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }

    private func fail(_ error: Error) async {
        guard running else { return }
        requestLog?.fail(error); requestLog?.finish()
        let handler = onError
        stop()
        await handler?(error)
    }
}
