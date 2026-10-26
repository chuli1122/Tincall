// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import OnnxRuntimeBindings

// Each instance is confined to one STT processing task. The model runs on CPU,
// independently of AVAudioSession, so headphone quality/routing stays unchanged.
final class VoiceActivityDetector: @unchecked Sendable {
    static let frameBytes = 1_024 // 512 samples: 32 ms, 16 kHz Int16 mono.
    private let environment: ORTEnv
    private let session: ORTSession
    private let sampleRate: ORTValue
    private var state: ORTValue
    private var context = [Float](repeating: 0, count: 64)
    private var pending = Data()
    private var gate = SpeechGate()

    init() throws {
        guard let model = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx", subdirectory: "VoiceCallVADAssets") else {
            throw TincallError(message: String(localized: "本地人声检测模型缺失"))
        }
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: environment, modelPath: model.path, sessionOptions: options)
        var rate: Int64 = 16_000
        sampleRate = try withUnsafeBytes(of: &rate) {
            try ORTValue(tensorData: NSMutableData(bytes: $0.baseAddress!, length: $0.count), elementType: .int64, shape: [])
        }
        state = try Self.zeroState()
    }

    func reset() throws {
        state = try Self.zeroState()
        context = [Float](repeating: 0, count: 64)
        pending.removeAll(keepingCapacity: true)
        gate = SpeechGate()
    }

    private enum Silence {
        static let answer: String? = ""
    }

    func filter(_ pcm: Data) throws -> (audio: Data, hasSpeech: Bool) {
        pending.append(pcm)
        var output = Data()
        var hasSpeech = false
        while pending.count >= Self.frameBytes {
            let frame = Data(pending.prefix(Self.frameBytes))
            pending.removeFirst(Self.frameBytes)
            let samples = frame.withUnsafeBytes { raw in
                (0..<512).map {
                    Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768
                }
            }
            let input = context + samples
            let tensor = try input.withUnsafeBytes {
                try ORTValue(tensorData: NSMutableData(bytes: $0.baseAddress!, length: $0.count), elementType: .float, shape: [1, 576])
            }
            let result = try session.run(withInputs: ["input": tensor, "state": state, "sr": sampleRate], outputNames: ["output", "stateN"], runOptions: nil)
            guard let probabilityValue = result["output"], let nextState = result["stateN"] else {
                throw TincallError(message: String(localized: "本地人声检测输出无效"))
            }
            let data = try probabilityValue.tensorData() as Data
            guard data.count == MemoryLayout<Float>.size else {
                throw TincallError(message: String(localized: "本地人声检测输出长度无效"))
            }
            let probability = data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            guard probability.isFinite, (0...1).contains(probability) else {
                throw TincallError(message: String(localized: "本地人声检测概率无效"))
            }
            state = nextState
            context = Array(samples.suffix(64))
            let filtered = gate.filter(frame, speechProbability: probability)
            output.append(filtered.audio)
            hasSpeech = hasSpeech || filtered.hasSpeech
        }
        return (output, hasSpeech)
    }

    private static func zeroState() throws -> ORTValue {
        try ORTValue(tensorData: NSMutableData(length: 2 * 128 * MemoryLayout<Float>.size)!, elementType: .float, shape: [2, 1, 128])
    }
}
