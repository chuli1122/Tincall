// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// Local permission is tied to the connection and destination, never included in configuration backups.
enum DataSharingConsent {
    static var privacyURL: URL {
        let path = Locale.current.language.languageCode?.identifier == "zh" ? "zh/privacy/" : "privacy/"
        return URL(string: "https://tincall-site.tincall-app.workers.dev/" + path)!
    }

    static func destination(_ connection: ConnectionProfile) -> [String] {
        [connection.provider.rawValue, connection.endpoint?.absoluteString ?? "", connection.region ?? "", connection.applicationID]
    }

    static func recipient(_ connection: ConnectionProfile) -> String {
        if connection.provider.isLanguageModel { return connection.endpoint?.absoluteString ?? String(localized: "尚未填写服务地址") }
        switch connection.provider {
        case .openAICompatible, .whisperCompatible, .genericConnector:
            return connection.endpoint?.absoluteString ?? String(localized: "尚未填写服务地址")
        case .anthropic: return "Anthropic · api.anthropic.com"
        case .gemini: return "Google Gemini · generativelanguage.googleapis.com"
        case .xunfei: return "讯飞 · iat-api.xfyun.cn"
        case .bailian: return "阿里云百炼 · dashscope.aliyuncs.com"
        case .elevenLabs: return "ElevenLabs · api.elevenlabs.io"
        case .miniMax: return connection.region == "international" ? "MiniMax · api.minimax.io" : "MiniMax · api.minimax.cn / api.minimaxi.com"
        case .fishAudio: return "Fish Audio · api.fish.audio"
        case .appleSpeech: return String(localized: "Apple 本机识别")
        }
    }

    static func disclosure(_ connection: ConnectionProfile) -> String {
        if connection.provider.isLanguageModel {
            return String(localized: "此模型服务会接收你启用的角色设定、称呼、历史上下文、当前文字及主动发送的图片或原声音频，用于对话和摘要。内容可能包含个人信息，由该服务按其隐私政策处理。")
        }
        if connection.provider.isSpeechSynthesis {
            return String(localized: "此语音服务会接收待朗读的回复文字、声音 ID 和合成参数，文字可能包含个人信息，由该服务按其隐私政策处理。")
        }
        if connection.provider.isSpeechRecognition {
            return String(localized: "此识别服务会接收麦克风录到的语音并返回文字，语音可能包含个人信息，由该服务按其隐私政策处理。")
        }
        return String(localized: "此连接端及其接入的 AI 平台会按所用功能接收联系人设定、称呼、通话文字和图片。开启同步后还会接收记录、摘要及另行允许的录音；后台来电会传输设备标识与必要路由信息。请只连接你信任的服务，并了解其数据处理方式。")
    }

    static func canAuthorize(_ connection: ConnectionProfile) -> Bool {
        guard connection.provider.isLanguageModel || [.whisperCompatible, .genericConnector].contains(connection.provider) else { return true }
        guard let endpoint = connection.endpoint else { return false }
        return endpoint.scheme == "https" && endpoint.host?.isEmpty == false && endpoint.user == nil && endpoint.password == nil && endpoint.query == nil && endpoint.fragment == nil
    }

    static func isAllowed(_ connection: ConnectionProfile, defaults: UserDefaults = .standard) -> Bool {
        connection.provider == .appleSpeech || (canAuthorize(connection) && defaults.stringArray(forKey: key(connection)) == destination(connection) && !defaults.bool(forKey: key(connection) + ".revoked"))
    }

    static func needsReview(_ connection: ConnectionProfile, defaults: UserDefaults = .standard) -> Bool {
        connection.provider != .appleSpeech && defaults.object(forKey: key(connection)) == nil
            && defaults.object(forKey: key(connection) + ".revoked") == nil
    }

    static func isCleanupAllowed(_ connection: ConnectionProfile, defaults: UserDefaults = .standard) -> Bool {
        canAuthorize(connection) && [key(connection), key(connection) + ".deviceBinding"].contains { defaults.stringArray(forKey: $0) == destination(connection) }
    }

    static func rememberDeviceBinding(_ connection: ConnectionProfile, defaults: UserDefaults = .standard) {
        guard connection.provider == .genericConnector, canAuthorize(connection) else { return }
        defaults.set(destination(connection), forKey: key(connection) + ".deviceBinding")
    }

    static func permitsIncomingCall(role: CallRole, connector: ConnectionProfile, connections: [ConnectionProfile], defaultSTT: UUID?, defaults: UserDefaults = .standard) -> Bool {
        guard isAllowed(connector, defaults: defaults) else { return false }
        var needed = [defaultSTT ?? role.sttConnectionID, role.ttsConnectionID]
        if role.effectiveCallMode == .standalone { needed.append(role.modelConnectionID) }
        return needed.allSatisfy { id in
            guard let id, let connection = connections.first(where: { $0.id == id }) else { return false }
            return isAllowed(connection, defaults: defaults)
        }
    }

    static func setAllowed(_ allowed: Bool, for connection: ConnectionProfile, defaults: UserDefaults = .standard) {
        if allowed {
            guard canAuthorize(connection) else { return }
            defaults.set(destination(connection), forKey: key(connection))
            defaults.removeObject(forKey: key(connection) + ".revoked")
        }
        else { defaults.set(true, forKey: key(connection) + ".revoked") }
    }

    static func require(_ connection: ConnectionProfile) throws {
        guard isAllowed(connection) else {
            throw TincallError(message: String(localized: "请在「\(connection.name)」连接设置的页面底部勾选「已阅读隐私政策，同意上述数据发送。」"))
        }
    }

    private static func key(_ connection: ConnectionProfile) -> String { "tincall.dataSharing.v1.\(connection.id.uuidString)" }
}
