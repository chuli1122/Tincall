// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct ElevenLabsConfiguration {
    let elevenLabsAPIKey: String
    let elevenLabsVoiceID: String
    let elevenLabsModel: String
    var stability: Double? = nil
    var similarityBoost: Double? = nil

    func voiceSettings() throws -> [String: Double] {
        var settings: [String: Double] = [:]
        for (key, value) in [("stability", stability), ("similarity_boost", similarityBoost)] {
            if let value {
                guard value.isFinite, (0...1).contains(value) else {
                    throw TincallError(message: String(localized: "ElevenLabs 稳定性和相似度须在 0–1 之间。"))
                }
                settings[key] = value
            }
        }
        return settings
    }

    var supportsRequestStitching: Bool {
        ["eleven_v4", "eleven_v4_turbo"].contains(elevenLabsModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct MiniMaxConfiguration {
    let apiKey: String
    let model: String
    let voiceID: String
    let endpoint: URL
}

enum SpeechSynthesisConfiguration {
    case elevenLabs(ElevenLabsConfiguration)
    case miniMax(MiniMaxConfiguration)
    case fishAudio(FishAudioConfiguration)
}
