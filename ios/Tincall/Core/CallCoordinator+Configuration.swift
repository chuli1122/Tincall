// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

extension CallCoordinator {
    func configurationIssue(role: CallRole?, connections: [ConnectionProfile]) -> String? {
        do { _ = try validatedConnections(role: role, connections: connections); return nil }
        catch { return safeMessage(error) }
    }

    func requestPreview(role: CallRole, connections: [ConnectionProfile], historyRecords: [CallRecord], input: String) throws -> CallRequestPreview {
        guard let connection = connections.first(where: { $0.id == role.modelConnectionID }) else {
            throw TincallError(message: String(localized: "此联系人缺少模型连接"))
        }
        return try CallContextBuilder.requestPreview(role: role, connection: connection, historyRecords: historyRecords,
            input: input, currentMessages: isCallActive && self.role?.id == role.id ? record?.messages ?? [] : [],
            ttsConnection: connections.first { $0.id == role.ttsConnectionID },
            userName: summaryUserName(),
            loadImages: { [self] message in try loadImages(message, callID: record?.id) })
    }

    func validatedSource(role: CallRole?, connections: [ConnectionProfile]) throws -> ConnectionProfile {
        guard let role else { throw TincallError(message: String(localized: "请选择通话联系人")) }
        let sourceID = role.effectiveCallMode == .standalone ? role.modelConnectionID : role.externalConnectionID
        guard let connection = connections.first(where: { $0.id == sourceID }) else {
            throw TincallError(message: role.effectiveCallMode == .standalone ? String(localized: "此联系人缺少模型连接") : String(localized: "此联系人缺少外部连接"))
        }
        if role.effectiveCallMode == .standalone { try model.validate(connection) }
        else { try external.validate(connection, role: role) }
        return connection
    }

    func validatedConnections(role: CallRole?, connections: [ConnectionProfile]) throws -> (ConnectionProfile, ConnectionProfile, ConnectionProfile) {
        let connection = try validatedSource(role: role, connections: connections)
        guard let role else { throw TincallError(message: String(localized: "请选择通话联系人")) }
        guard let stt = connections.first(where: { $0.id == role.sttConnectionID }), stt.provider.isSpeechRecognition else {
            throw TincallError(message: String(localized: "请选择 Apple、讯飞、百炼或 Whisper 兼容识别连接"))
        }
        if stt.provider == .whisperCompatible {
            guard let url = stt.endpoint, url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw TincallError(message: String(localized: "Whisper 兼容识别需要无内嵌凭据的 HTTPS 地址"))
            }
            guard !stt.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TincallError(message: String(localized: "请填写 Whisper 兼容识别的模型名称"))
            }
        } else {
            guard stt.endpoint == nil else { throw TincallError(message: String(localized: "此语音识别服务使用本机或固定供应商地址，请清除自定义地址")) }
        }
        let credentials = CredentialStore()
        if stt.provider == .xunfei {
            guard !stt.applicationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  try validVoiceSecret(credentials.read(connectionID: stt.id)),
                  try validVoiceSecret(credentials.read(connectionID: stt.id, field: .apiSecret)) else {
                throw TincallError(message: String(localized: "讯飞识别缺少 App ID、API Key 或 API Secret"))
            }
        } else if stt.provider == .bailian {
            guard stt.region == nil || stt.region == "beijing" else { throw TincallError(message: String(localized: "当前百炼 Paraformer 识别仅支持北京地域")) }
            guard stt.model.isEmpty || stt.model == "paraformer-realtime-v2" else { throw TincallError(message: String(localized: "当前百炼识别仅支持 paraformer-realtime-v2 模型")) }
            guard try validVoiceSecret(credentials.read(connectionID: stt.id)) else { throw TincallError(message: String(localized: "百炼识别缺少 API Key")) }
        }
        guard let tts = connections.first(where: { $0.id == role.ttsConnectionID }), tts.provider.isSpeechSynthesis else {
            throw TincallError(message: String(localized: "请选择 ElevenLabs、MiniMax 或 Fish Audio 语音连接"))
        }
        guard tts.endpoint == nil else { throw TincallError(message: String(localized: "语音合成使用固定供应商地址，请清除自定义地址")) }
        if tts.provider == .miniMax, let region = tts.region, region != "china" && region != "international" {
            throw TincallError(message: String(localized: "MiniMax 地域必须为中国或国际"))
        }
        let voiceOverride = role.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = voiceOverride.isEmpty ? tts.voiceID.trimmingCharacters(in: .whitespacesAndNewlines) : voiceOverride
        guard (tts.provider == .miniMax || !tts.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), !voiceID.isEmpty,
              try validVoiceSecret(credentials.read(connectionID: tts.id)) else {
            throw TincallError(message: String(localized: "语音连接缺少模型、音色或 API Key"))
        }
        return (connection, stt, tts)
    }

    func resolvedVoiceID(role: CallRole, tts: ConnectionProfile) -> String {
        let override = role.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? tts.voiceID.trimmingCharacters(in: .whitespacesAndNewlines) : override
    }

    private func validVoiceSecret(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && !value.contains("\r") && !value.contains("\n") && !value.contains("•") && !value.contains("*") && value != "已配置"
    }
}
