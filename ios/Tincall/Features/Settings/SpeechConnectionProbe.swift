// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation
import AVFoundation

@MainActor @Observable
final class SpeechConnectionProbe {
    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var progress = ""
    private(set) var feedback: SettingsConnectionFeedback?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var playback: SpeechPlayback?
    private var recognizer: (any SpeechRecognizer)?
    private var generation = 0
    private var ownsAudio = false
    private var completedText = ""
    /// High-frequency correction rules from My Settings; applied the same way as in a call.
    var corrections: [SpeechRecognitionCorrection] = []

    func start(connection: ConnectionProfile, apiKey: String, apiSecret: String, isCallActive: Bool, sampleText: String = "") {
        cancel(deactivateAudio: !isCallActive)
        guard !isCallActive else { return }
        isRunning = true
        progress = connection.provider.isSpeechSynthesis ? String(localized: "正在生成并播放…") : String(localized: "正在准备麦克风…")
        let expected = generation
        operation = Task { [self] in
            do {
                try DataSharingConsent.require(connection)
                let credentials = CredentialStore()
                let key = try credential(apiKey, saved: {
                    guard connection.provider != .appleSpeech else { return nil }
                    return try credentials.read(connectionID: connection.id)
                })
                if connection.provider.isSpeechSynthesis {
                    let model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    let voice = connection.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { throw TincallError(message: String(localized: "请先填写 API Key")) }
                    guard !model.isEmpty else { throw TincallError(message: String(localized: "请先填写合成模型")) }
                    guard !voice.isEmpty else { throw TincallError(message: String(localized: "请先填写声音 ID")) }
                    let configuration: SpeechSynthesisConfiguration
                    switch connection.provider {
                    case .elevenLabs:
                        configuration = .elevenLabs(.init(elevenLabsAPIKey: key, elevenLabsVoiceID: voice, elevenLabsModel: model,
                            stability: connection.elevenLabsStability,
                            similarityBoost: connection.elevenLabsSimilarityBoost))
                    case .miniMax:
                        let host = connection.region == "international" ? "api.minimax.io" : "api.minimaxi.com"
                        configuration = .miniMax(.init(apiKey: key, model: model, voiceID: voice,
                                                      endpoint: URL(string: "https://\(host)/v1/t2a_v2")!))
                    case .fishAudio:
                        configuration = .fishAudio(try .init(apiKey: key, model: model, referenceID: voice))
                    default: throw TincallError(message: String(localized: "此服务暂不支持试听"))
                    }
                    let player = SpeechPlayback()
                    playback = player
                    ownsAudio = true
                    armTimeout(seconds: 60, generation: expected)
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                    try audioSession.setActive(true)
                    try player.begin(settings: configuration)
                    let trimmedSample = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    try player.appendText(trimmedSample.isEmpty ? String(localized: "你好，这是一次试听。") : trimmedSample, final: true)
                    do { try await player.waitUntilFinished() }
                    catch { throw player.synthesisError ?? error }
                    guard generation == expected, !Task.isCancelled else { return }
                    finish(message: String(localized: "已播放"))
                } else {
                    let recognizer: any SpeechRecognizer
                    switch connection.provider {
                    case .appleSpeech:
                        recognizer = AppleSpeechRecognizer(language: connection.language ?? "zh-CN")
                    case .xunfei:
                        let secret = try credential(apiSecret, saved: { try credentials.read(connectionID: connection.id, field: .apiSecret) })
                        let appID = connection.applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !appID.isEmpty, !key.isEmpty, !secret.isEmpty else {
                            throw TincallError(message: String(localized: "请填写讯飞 App ID、API Key 和 API Secret"))
                        }
                        recognizer = XunfeiSpeechRecognizer(credentials: .init(xunfeiAppID: appID, xunfeiAPIKey: key, xunfeiAPISecret: secret))
                    case .bailian:
                        guard !key.isEmpty else { throw TincallError(message: String(localized: "请先填写 API Key")) }
                        let model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !model.isEmpty else { throw TincallError(message: String(localized: "请先填写识别模型")) }
                        recognizer = BailianSpeechRecognizer(configuration: .init(apiKey: key, model: model))
                    case .whisperCompatible:
                        recognizer = WhisperSpeechRecognizer(configuration: try .init(endpoint: connection.endpoint, model: connection.model,
                                                                                     language: connection.language, apiKey: key))
                    default: throw TincallError(message: String(localized: "此服务暂不支持识别测试"))
                    }
                    guard await AVAudioApplication.requestRecordPermission() else {
                        throw TincallError(message: String(localized: "没有麦克风权限，请到系统设置允许 Tincall 使用麦克风"))
                    }
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    self.recognizer = recognizer
                    ownsAudio = true
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.playAndRecord, mode: .default,
                                                 options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
                    try audioSession.setActive(true)
                    try await recognizer.start(callback: { [weak self] text, isFinal, _ in
                        guard let self, self.generation == expected else { return }
                        let text = SpeechRecognitionCorrection.apply(to: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                     rules: self.corrections)
                        if isFinal, !text.isEmpty {
                            self.completedText += (self.completedText.isEmpty ? "" : "\n") + text
                        }
                        let display = isFinal ? self.completedText : [self.completedText, text].filter { !$0.isEmpty }.joined(separator: "\n")
                        if !display.isEmpty { self.feedback = SettingsConnectionFeedback(message: display) }
                        if isFinal, !self.isRecording {
                            if self.completedText.isEmpty { self.fail(TincallError(message: String(localized: "没有识别到文字，请靠近麦克风重试"))) }
                            else { self.finish(message: self.completedText) }
                        }
                    }, onError: { [weak self] error in
                        guard let self, self.generation == expected else { return }
                        self.fail(error)
                    }, onReset: {})
                    guard generation == expected, !Task.isCancelled else { return }
                    isRecording = true
                    progress = String(localized: "正在录音，说完后点停止录音")
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        guard let self, self.generation == expected else { return }
                        self.finishRecording()
                    }
                }
            } catch {
                guard generation == expected, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func finishRecording() {
        guard isRecording, let recognizer else { return }
        isRecording = false
        timeout?.cancel()
        progress = String(localized: "正在等待识别结果…")
        armTimeout(seconds: 30, generation: generation)
        do {
            if try !recognizer.finishRecording() {
                if completedText.isEmpty { fail(TincallError(message: String(localized: "没有听到说话声，请重试"))) }
                else { finish(message: completedText) }
            }
        } catch { fail(error) }
    }

    func cancel(deactivateAudio: Bool = true) {
        generation += 1
        operation?.cancel(); operation = nil
        timeout?.cancel(); timeout = nil
        playback?.stop(); playback = nil
        recognizer?.stop(); recognizer = nil
        if ownsAudio, deactivateAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        ownsAudio = false
        isRunning = false
        isRecording = false
        completedText = ""
        feedback = nil
    }

    private func credential(_ draft: String, saved: () throws -> String?) throws -> String {
        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = draft.isEmpty ? try saved() ?? "" : draft
        guard !value.contains("\r"), !value.contains("\n") else { throw TincallError(message: String(localized: "密钥格式不对，请重新粘贴")) }
        return value
    }

    private func armTimeout(seconds: Int, generation expected: Int) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.generation == expected else { return }
            self.fail(TincallError(message: String(localized: "等待服务结果超时，请检查网络后重试")))
        }
    }

    private func finish(message: String) {
        cancel()
        feedback = SettingsConnectionFeedback(message: message)
    }

    private func fail(_ error: Error) {
        cancel()
        let detail = error.localizedDescription.lowercased()
        let code = (error as? TincallError)?.requestCode?.lowercased() ?? ""
        let reason = code + " " + detail
        let message: String
        if ["quota", "balance", "credit"].contains(where: reason.contains) || code == "1008" {
            message = String(localized: "额度已用完或余额不足，请到服务商处检查并充值")
        } else if ["invalid_api_key", "invalidapikey", "authentication", "unauthorized"].contains(where: reason.contains)
                    || code == "1004" || detail.contains("elevenlabs 401") {
            message = String(localized: "密钥不对或已失效，请检查 API Key 和所需凭据")
        } else if reason.contains("permission") || reason.contains("forbidden") || detail.contains("elevenlabs 403") {
            message = String(localized: "没有访问权限，请检查密钥及所选模型、声音的权限")
        } else if reason.contains("voice") || reason.contains("reference_id") {
            message = String(localized: "声音 ID 不对或无权使用，请检查声音 ID 和访问权限")
        } else if reason.contains("model") {
            message = String(localized: "模型名称不对或无权使用，请检查模型和服务权限")
        } else if reason.contains("timeout") || detail.contains("超时") {
            message = String(localized: "连接或识别超时，请检查网络后重试")
        } else if reason.contains("rate_limit") || code == "1002" {
            message = String(localized: "请求太频繁，请稍后重试")
        } else if detail.contains("讯飞识别失败") {
            message = String(localized: "讯飞拒绝了识别请求，请检查 App ID、密钥、服务权限和额度")
        } else if reason.contains("invalidparameter") || reason.contains("invalid_parameter") {
            message = String(localized: "服务参数不对，请检查模型名称和声音 ID")
        } else if detail.contains("elevenlabs 429") {
            message = String(localized: "请求太频繁或额度不足，请稍后重试或检查余额")
        } else {
            message = SettingsConnectionFeedback(error: error).message
        }
        feedback = SettingsConnectionFeedback(message: message)
        feedback?.isFailure = true
    }
}
