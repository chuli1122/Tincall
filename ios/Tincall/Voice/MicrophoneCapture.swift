// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

@preconcurrency import AVFoundation
import Foundation
import OSLog
import UIKit

/// The three recognizers share the existing 16 kHz VAD and media-volume route.
@MainActor
final class MicrophoneCapture {
    private let logger = Logger(subsystem: "com.tincall.app", category: "VoiceCallCapture")
    // All recognizers use this capture path; the call service owns reply policy.
    private static weak var activeCapture: MicrophoneCapture?
    static var outputRouteTransitionActive = false
    static func refreshForCurrentRoute() async {
        await activeCapture?.refreshForCurrentRoute(event: .captureRouteRestart)
    }
    static var requiresSustainedSpeech = false {
        didSet {
            guard requiresSustainedSpeech != oldValue else { return }
            // Drop queued frames from the previous policy as well as its VAD
            // history; they must not count as speech in a new reply.
            activeCapture?.reset()
        }
    }
    static var speechInterruptionReady: Bool { activeCapture?.speechGate.isOpen == true }
    var onSpeechActivityChange: ((Bool) -> Void)?
    private var speechActive = false

    static func needsEchoCancellation(outputPorts: [AVAudioSession.Port]) -> Bool {
        !outputPorts.isEmpty && outputPorts.allSatisfy { $0 == .builtInSpeaker || $0 == .builtInReceiver }
    }

    private var engine: AVAudioEngine?
    private var capturedInputFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var speechGate = SustainedSpeechGate(required: false)
    private let requiresSustainedSpeechForRecognizer: Bool
    private var hasTap = false
    private var generation = 0
    private var lifecycle = 0
    private var captureStartedAt: UInt64 = 0
    private var paused = false
    private var continuation: AsyncStream<(Data, Int)>.Continuation?
    private var processing: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var onAudio: (((audio: Data, hasSpeech: Bool)) async -> Void)?
    private var onError: ((Error) async -> Void)?

    init(requiresSustainedSpeech: Bool = false) {
        requiresSustainedSpeechForRecognizer = requiresSustainedSpeech
    }

    func start(onAudio: @escaping ((audio: Data, hasSpeech: Bool)) async -> Void,
               onError: @escaping (Error) async -> Void) async throws {
        CallAudioDiagnostics.record(.captureStart, generation: generation)
        let wasPaused = paused
        stop()
        paused = wasPaused
        let expectedLifecycle = lifecycle
        await cleanupTask?.value
        try Task.checkCancellation()
        guard lifecycle == expectedLifecycle else { throw CancellationError() }
        cleanupTask = nil
        recordPreparation("vad_initialize")
        let detector: VoiceActivityDetector
        do {
            detector = try await Task.detached(priority: .userInitiated) { try VoiceActivityDetector() }.value
        } catch {
            Self.recordDiagnostic(.captureFailed, phase: "vad_initialize", generation: generation, error: error)
            throw error
        }
        try Task.checkCancellation()
        guard lifecycle == expectedLifecycle else { throw CancellationError() }
        self.onAudio = onAudio
        self.onError = onError
        let session = AVAudioSession.sharedInstance()
        logSession("capture_prepare", session: session)
        if session.currentRoute.outputs.contains(where: { $0.portType == .bluetoothA2DP }) {
            guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
                throw TincallError(message: String(localized: "高音质蓝牙播放需要手机麦克风"))
            }
            try prepare("preferred_input") { try session.setPreferredInput(microphone) }
        }
        guard session.isInputAvailable else { throw TincallError(message: String(localized: "没有可用的麦克风")) }
        let engine = AVAudioEngine()
        self.engine = engine
        recordPreparation("input_node")
        let input = engine.inputNode
        // Headphone output keeps ordinary media I/O and the phone microphone.
        // Speaker output needs echo cancellation before reading its I/O format.
        if Self.needsEchoCancellation(outputPorts: session.currentRoute.outputs.map(\.portType)) {
            logSession("capture_voice_processing_enable", session: session)
            try prepare("voice_processing") { try input.setVoiceProcessingEnabled(true) }
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            guard input.isVoiceProcessingEnabled, engine.outputNode.isVoiceProcessingEnabled else {
                throw TincallError(message: String(localized: "无法开启通话回声消除"))
            }
            logSession("capture_voice_processing_enabled", session: session)
            // The service owns the output choice. Keep the mode/options adopted
            // by voice processing instead of forcing media mode or speaker here.
        }
        recordPreparation("input_format")
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw TincallError(message: String(localized: "麦克风音频格式不可用"))
        }
        Self.activeCapture = self
        capturedInputFormat = format
        reset()
        recordPreparation("prepared")
        let stream = AsyncStream<(Data, Int)>(bufferingPolicy: .bufferingOldest(8)) { continuation = $0 }
        processing = Task.detached(priority: .userInitiated) { [weak self] in
            var activeGeneration: Int?
            var pending = Data()
            for await (pcm, generation) in stream {
                guard !Task.isCancelled else { return }
                do {
                    if activeGeneration != generation {
                        try detector.reset(); activeGeneration = generation
                        pending.removeAll(keepingCapacity: true)
                    }
                    pending.append(pcm)
                    var frames: [(audio: Data, hasSpeech: Bool)] = []
                    while pending.count >= VoiceActivityDetector.frameBytes {
                        let frame = Data(pending.prefix(VoiceActivityDetector.frameBytes))
                        pending.removeFirst(VoiceActivityDetector.frameBytes)
                        frames.append(try detector.filter(frame))
                    }
                    guard !Task.isCancelled else { return }
                    await self?.accept(frames, generation: generation)
                } catch {
                    await self?.fail(error, generation: generation)
                    return
                }
            }
        }
        // The tap runs on the realtime audio thread; it must not inherit MainActor isolation.
        nonisolated(unsafe) let tapConverter = converter
        nonisolated(unsafe) weak var captureEngine = engine
        input.installTap(onBus: 0, bufferSize: 3200, format: nil) { @Sendable [weak self] buffer, time in
            do {
                let pcm = try Self.convert(buffer, using: tapConverter, target: target)
                Task { @MainActor [weak self] in
                    guard let self, let engine = captureEngine, self.engine === engine, !self.paused,
                          !time.isHostTimeValid || time.hostTime >= self.captureStartedAt else { return }
                    if case .dropped = self.continuation?.yield((pcm, self.generation)) {
                        await self.fail(TincallError(message: String(localized: "语音处理过慢，请重新打开麦克风")), generation: self.generation)
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, let engine = captureEngine, self.engine === engine else { return }
                    await self.fail(error, generation: self.generation)
                }
            }
        }
        hasTap = true
        logSession("capture_engine_start", session: session)
        do { try prepare("engine_start") { try engine.start() } } catch { stop(); throw error }
        logSession("capture_engine_started", session: session)
        recordPreparation("engine_started")
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let engine = captureEngine, self.engine === engine else { return }
                await self.refreshForCurrentRoute(event: .captureConfigurationRestart)
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let engine = captureEngine, self.engine === engine else { return }
                await self.refreshForCurrentRoute(event: .captureRouteRestart)
            }
        }
    }

    private enum Received {
        static let packet: [UInt8] = [
            0xE5, 0x90, 0xAC,
            0xE8, 0xA7, 0x81,
            0xE4, 0xBA, 0x86
        ]
    }

    private func refreshForCurrentRoute(event: CallAudioDiagnostics.Event) async {
        guard !Self.outputRouteTransitionActive, let engine,
              let onAudio, let onError else { return }
        // Changing voice processing itself changes the output route. Rebuilding a
        // running engine to match that transient output creates an endless
        // receiver → A2DP → receiver cycle. Only rebuild unusable capture I/O.
        guard !engine.isRunning || engine.inputNode.outputFormat(forBus: 0) != capturedInputFormat else { return }
        CallAudioDiagnostics.record(event, generation: generation)
        do { try await start(onAudio: onAudio, onError: onError) }
        catch is CancellationError { }
        catch { stop(); await onError(error) }
    }

    func reset() {
        updateSpeechActivity(false)
        generation += 1
        captureStartedAt = mach_absolute_time()
        speechGate = SustainedSpeechGate(required: Self.requiresSustainedSpeech || requiresSustainedSpeechForRecognizer)
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        reset()
    }

    func stop() {
        if engine != nil { CallAudioDiagnostics.record(.captureStop, generation: generation) }
        lifecycle += 1
        reset()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        continuation?.finish(); continuation = nil
        processing?.cancel(); processing = nil
        if let engine {
            let hasTap = hasTap
            let previousCleanup = cleanupTask
            cleanupTask = Task.detached(priority: .userInitiated) {
                await previousCleanup?.value
                engine.stop()
                if hasTap { engine.inputNode.removeTap(onBus: 0) }
            }
        }
        hasTap = false; engine = nil; capturedInputFormat = nil; paused = false
        if Self.activeCapture === self { Self.activeCapture = nil }
        onAudio = nil; onError = nil
    }

    /// Finish dismantling this input graph before another recognizer starts one.
    func waitForStop() async {
        await cleanupTask?.value
    }

    private func accept(_ frames: [(audio: Data, hasSpeech: Bool)], generation: Int) async {
        guard self.generation == generation, !paused, engine != nil else { return }
        var audio = Data()
        var hasSpeech = false
        for frame in frames {
            let gateWasOpen = speechGate.isOpen
            let filtered = speechGate.filter(frame)
            if !gateWasOpen, speechGate.isOpen { CallAudioDiagnostics.record(.speechGateOpened, generation: generation) }
            audio.append(filtered.audio)
            hasSpeech = hasSpeech || filtered.hasSpeech
        }
        // UI/ducking must reflect the same confirmed speech sent to STT.
        // Rejected playback echoes must not start a pending transcript row.
        updateSpeechActivity(hasSpeech)
        if !audio.isEmpty { await onAudio?((audio, hasSpeech)) }
    }

    private func updateSpeechActivity(_ active: Bool) {
        guard speechActive != active else { return }
        CallAudioDiagnostics.record(.speechActive, generation: generation, flag: active)
        speechActive = active
        onSpeechActivityChange?(active)
    }

    private func logSession(_ phase: String, session: AVAudioSession) {
        logger.info("phase=\(phase, privacy: .public) category=\(session.category.rawValue, privacy: .public) mode=\(session.mode.rawValue, privacy: .public) options=\(session.categoryOptions.rawValue)")
    }

    private func recordPreparation(_ phase: String) {
        Self.recordDiagnostic(.captureStage, phase: phase, generation: generation)
    }

    private func prepare<T>(_ phase: String, operation: () throws -> T) rethrows -> T {
        recordPreparation(phase)
        do { return try operation() }
        catch {
            Self.recordDiagnostic(.captureFailed, phase: phase, generation: generation, error: error)
            throw error
        }
    }

    static func recordDiagnostic(_ event: CallAudioDiagnostics.Event, phase: String,
                                 turn: UUID? = nil, input: UUID? = nil, generation: Int? = nil,
                                 error: Error? = nil) {
        #if DEBUG
        let audio = AVAudioSession.sharedInstance()
        let failure = error.map { $0 as NSError }
        CallAudioDiagnostics.record(event, turn: turn, input: input, generation: generation,
            phase: phase, errorDomain: failure?.domain, errorCode: failure?.code,
            category: audio.category.rawValue, mode: audio.mode.rawValue, options: audio.categoryOptions.rawValue,
            inputPorts: audio.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ","),
            outputPorts: audio.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","),
            appState: UIApplication.shared.applicationState.rawValue)
        #endif
    }

    private func fail(_ error: Error, generation: Int) async {
        guard self.generation == generation, engine != nil else { return }
        Self.recordDiagnostic(.captureFailed, phase: "processing", generation: generation, error: error)
        let handler = onError
        stop()
        await handler?(error)
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                             target: AVAudioFormat) throws -> Data {
        guard let converted = AVAudioPCMBuffer(pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate + 32)) else {
            throw TincallError(message: String(localized: "无法转换麦克风音频"))
        }
        var error: NSError?
        var supplied = false
        converter.convert(to: converted, error: &error) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let samples = converted.floatChannelData?[0] else { throw TincallError(message: String(localized: "麦克风音频为空")) }
        var pcm = Data(capacity: Int(converted.frameLength) * 2)
        for index in 0..<Int(converted.frameLength) {
            var value = Int16(max(-1, min(1, samples[index])) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }
}

/// Receives one 32 ms Silero decision at a time, after system echo cancellation.
/// VAD pre-roll/tail bytes must not count toward the continuous-speech duration.
struct SustainedSpeechGate {
    private(set) var isOpen: Bool
    private var speechFrames = 0
    private var onset = Data()

    init(required: Bool) { isOpen = !required }

    mutating func filter(_ frame: (audio: Data, hasSpeech: Bool)) -> (audio: Data, hasSpeech: Bool) {
        guard !isOpen else { return frame }
        if frame.hasSpeech {
            speechFrames += 1
            onset.append(frame.audio)
            if speechFrames >= 10 { // 10 × 32 ms = 320 ms; never count callback/wall-clock delay.
                isOpen = true
                let audio = onset
                onset.removeAll(keepingCapacity: true)
                return (audio, true)
            }
        } else {
            speechFrames = 0
            onset.removeAll(keepingCapacity: true)
        }
        // Keep an existing recognition stream's clock alive without feeding it
        // a short echo/cough. Confirmed speech replays its buffered onset once.
        return (Data(repeating: 0, count: 1_024), false)
    }
}
