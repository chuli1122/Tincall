// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct ConfigurationSettingsChecks {
    @MainActor private static func checkExternalIdentityMigration(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var connection = ConnectionProfile(name: "Legacy backend", provider: .genericConnector,
                                           endpoint: URL(string: "https://example.com"))
        connection.externalRoleID = "legacy-target"
        connection.externalRoleName = "Legacy name"
        let backend = CallRole(name: "Backend", callMode: .backend, externalConnectionID: connection.id)
        let mcp = CallRole(name: "Manual MCP", callMode: .mcp, externalConnectionID: connection.id)
        let explicit = CallRole(name: "Explicit", callMode: .backend, externalConnectionID: connection.id,
                                externalRoleID: "own-target", externalRoleName: "Own name")
        let standalone = CallRole(name: "Standalone", externalConnectionID: connection.id)
        let legacy = LocalConfigurationStore.Configuration(connections: [connection], roles: [backend, mcp, explicit, standalone],
                                                          retention: AudioRetention())
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("configuration.json"))
        let store = try LocalConfigurationStore(directory: directory)
        precondition(store.roles[0].externalRoleID == "legacy-target" && store.roles[0].externalRoleName == "Legacy name")
        precondition(store.roles[1].externalRoleID == "legacy-target")
        precondition(store.roles[2] == explicit && store.roles[3] == standalone)
        precondition(store.connections[0].externalRoleID == nil && store.connections[0].externalRoleName == nil)
        let newContact = CallRole(name: "New backend", callMode: .backend, externalConnectionID: connection.id)
        try store.saveRole(newContact)
        let reopened = try LocalConfigurationStore(directory: directory)
        precondition(reopened.roles.last?.externalRoleID == nil, "Migration cannot assign a default to later contacts")
        precondition(reopened.roles[0].externalRoleID == "legacy-target")
        var renamedService = reopened.connections[0]
        renamedService.name = "Local service"
        try reopened.saveConnection(renamedService)
        let plan = try reopened.prepareImport(legacy)
        precondition(plan.connectionIDs[connection.id] != connection.id, "Conflicting services must be remapped")
        try reopened.commitImport(plan)
        let importedID = plan.roleIDs[backend.id]!
        let imported = reopened.roles.first { $0.id == importedID }!
        precondition(imported.externalRoleID == "legacy-target" && imported.externalConnectionID == plan.connectionIDs[connection.id])
        precondition(reopened.roles.first { $0.id == newContact.id }?.externalRoleID == nil)
        precondition(reopened.connections.allSatisfy { $0.externalRoleID == nil })
    }

    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallConfigurationChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkConnectionDeletion(directory: directory.appendingPathComponent("connection-deletion"))
        if CommandLine.arguments.contains("--connection-deletion") { return }
        try checkExternalIdentityMigration(directory: directory.appendingPathComponent("external-identities"))
        try checkIndividualCorrectionEdits(directory: directory.appendingPathComponent("individual-rules"))
        // A configuration written before profiles existed must still open.
        let legacy = Data(#"{"connections":[],"roles":[],"retention":{"user":false,"assistant":false}}"#.utf8)
        try legacy.write(to: directory.appendingPathComponent("configuration.json"))
        let store = try LocalConfigurationStore(directory: directory)
        precondition(store.userProfile == LocalUserProfile())
        precondition(store.speechRecognitionCorrections.isEmpty)
        let correction = SpeechRecognitionCorrection(source: "帐户", replacement: "账户")
        let chain = SpeechRecognitionCorrection(source: "账户", replacement: "账号")
        precondition(SpeechRecognitionCorrection.apply(to: "帐户，今天找帐户。", rules: [correction, chain]) == "账户，今天找账户。")
        precondition(SpeechRecognitionCorrection.apply(to: "账户和帐户", rules: [correction, chain]) == "账号和账户")
        precondition(SpeechRecognitionCorrection.apply(to: "帐户名找帐户", rules: [correction,
            SpeechRecognitionCorrection(source: "帐户名", replacement: "账户名称")]) == "账户名称找账户")
        precondition(SpeechRecognitionCorrection.apply(to: "你好，🙂今天见。", rules: [correction]) == "你好，🙂今天见。")
        precondition(SpeechRecognitionCorrection.apply(to: "A+B AAB", rules: [
            SpeechRecognitionCorrection(source: "A+B", replacement: "C$1")]) == "C$1 AAB")
        precondition(SpeechRecognitionCorrection.apply(to: "帐户", rules: []) == "帐户")
        let inputID = UUID()
        for final in [false, true] {
            let result = TranscriptResult(inputID: inputID, text: "帐户", isFinal: final).corrected(using: [correction])
            precondition(result.inputID == inputID && result.isFinal == final && result.text == "账户")
        }
        var padded = correction
        padded.source = " 帐户\n"
        padded.replacement = " 账户 "
        try store.saveSpeechRecognitionCorrections([padded])
        precondition(store.speechRecognitionCorrections == [correction])
        for invalid in [
            [SpeechRecognitionCorrection(source: " ", replacement: "账户")],
            [SpeechRecognitionCorrection(source: "帐户", replacement: "\n")],
            [correction, SpeechRecognitionCorrection(source: " 帐户 ", replacement: "账号")]
        ] {
            do {
                try store.saveSpeechRecognitionCorrections(invalid)
                preconditionFailure("Invalid corrections must not overwrite saved rules")
            } catch is TincallError { }
            precondition(store.speechRecognitionCorrections == [correction])
        }
        let profile = LocalUserProfile(name: "Synthetic identity", avatarData: Data([1, 2, 3]))
        try store.saveUserProfile(profile)
        try store.selectSTTProvider(.appleSpeech)
        let appleID = store.defaultSTTConnectionID
        precondition(appleID != nil)
        try store.selectSTTProvider(.xunfei)
        let xunfeiID = store.defaultSTTConnectionID
        try store.selectSTTProvider(.appleSpeech)
        precondition(store.defaultSTTConnectionID == appleID && store.connections.count == 2)
        try store.selectSTTProvider(.xunfei)
        precondition(store.defaultSTTConnectionID == xunfeiID && store.connections.count == 2)
        try store.selectSTTProvider(.whisperCompatible)
        let whisperID = store.defaultSTTConnectionID!
        var whisper = store.connections.first { $0.id == whisperID }!
        precondition(whisper.model == "whisper-1")
        whisper.endpoint = URL(string: "https://speech.example.com/custom/audio/transcriptions")
        whisper.language = "zh"
        try store.saveConnection(whisper)
        try store.selectSTTProvider(.xunfei)
        try store.selectSTTProvider(.whisperCompatible)
        precondition(store.defaultSTTConnectionID == whisperID && store.connections.first { $0.id == whisperID } == whisper)
        var role = CallRole(name: "Synthetic contact")
        role.sttConnectionID = xunfeiID
        try store.saveRole(role)
        try store.selectSTTProvider(nil)
        precondition(store.defaultSTTConnectionID == nil && store.roles[0].sttConnectionID == nil)
        let first = ConnectionProfile(name: "Voice one", provider: .miniMax, model: "speech-02-hd", voiceID: "synthetic-one")
        let second = ConnectionProfile(name: "Voice two", provider: .elevenLabs, model: "eleven_multilingual_v2",
                                       voiceID: "synthetic-two", elevenLabsStability: 0.31, elevenLabsSimilarityBoost: 0.86)
        try store.saveConnection(first)
        try store.saveConnection(second)
        let fish = ConnectionProfile(name: "Fish voice", provider: .fishAudio, model: "s2.1-pro", voiceID: "synthetic-fish")
        try store.saveConnection(fish)
        var model = ConnectionProfile(name: "Thinking model", provider: .anthropic,
                                      endpoint: URL(string: "https://api.anthropic.com/v1"), model: "claude-sonnet-4-6")
        model.anthropicThinkingMode = .adaptive
        model.anthropicEffort = .low
        try store.saveConnection(model)
        role.ttsConnectionID = fish.id
        role.modelConnectionID = model.id
        role.sttConnectionID = whisperID
        try store.saveRole(role)
        let reopened = try LocalConfigurationStore(directory: directory)
        precondition(reopened.userProfile == profile)
        precondition(reopened.speechRecognitionCorrections == [correction])
        precondition(reopened.connections.filter { $0.provider.isSpeechSynthesis }.count == 3)
        precondition(reopened.connections.first { $0.id == second.id } == second,
                     "ElevenLabs voice settings must survive saving and reopening")
        let legacyVoice = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(first))
        precondition(legacyVoice.elevenLabsStability == nil && legacyVoice.elevenLabsSimilarityBoost == nil,
                     "Connections without advanced settings retain supplier defaults")
        precondition(reopened.connections.first { $0.id == whisperID } == whisper)
        precondition(reopened.connections.first { $0.id == model.id } == model)
        // Restore the identity to an empty installation; retain an existing identity on merge.
        let target = try LocalConfigurationStore(directory: directory.appendingPathComponent("restore"))
        let backup = try JSONDecoder().decode(LocalConfigurationStore.Configuration.self,
                                             from: JSONEncoder().encode(reopened.backupConfiguration()))
        try target.commitImport(target.prepareImport(backup))
        precondition(target.userProfile == profile)
        precondition(target.speechRecognitionCorrections == [correction])
        precondition(target.connections.first { $0.id == whisperID } == whisper)
        precondition(target.connections.first { $0.id == fish.id } == fish)
        precondition(target.connections.first { $0.id == second.id } == second,
                     "Backup restore must preserve ElevenLabs voice settings")
        precondition(target.connections.first { $0.id == model.id } == model)
        precondition(target.roles.first { $0.id == role.id }?.sttConnectionID == whisperID)
        var unsafeImport = reopened.backupConfiguration()
        let whisperIndex = unsafeImport.connections.firstIndex { $0.id == whisperID }!
        unsafeImport.connections[whisperIndex].endpoint = URL(string: "https://speech.example.com/v1?api_key=synthetic")
        do {
            _ = try target.prepareImport(unsafeImport)
            preconditionFailure("Whisper import must reject credentials in URL")
        } catch is TincallError { }
        try target.saveUserProfile(LocalUserProfile(name: "Keep my current identity"))
        try target.commitImport(target.prepareImport(reopened.backupConfiguration()))
        precondition(target.userProfile.name == "Keep my current identity")
        precondition(target.speechRecognitionCorrections == [correction], "Repeated imports must not duplicate rules")
        let local = SpeechRecognitionCorrection(source: "帐户", replacement: "用户账户")
        try target.saveSpeechRecognitionCorrections([local])
        var extraRules = backup
        // The same ID with a different phrase may come from an edited backup.
        var other = local
        other.source = "天气"
        other.replacement = "天启"
        extraRules.speechRecognitionCorrections = [correction, other]
        try target.commitImport(target.prepareImport(extraRules))
        let mergedRules = target.speechRecognitionCorrections
        precondition(mergedRules.count == 2 && mergedRules[0] == local && mergedRules[1].source == "天气" &&
                     mergedRules[1].replacement == "天启" && mergedRules[1].id != local.id,
                     "Local rules win conflicts; new phrases merge with unique IDs")
        try target.commitImport(target.prepareImport(extraRules))
        precondition(target.speechRecognitionCorrections == mergedRules)
        try target.commitImport(target.prepareImport(JSONDecoder().decode(LocalConfigurationStore.Configuration.self, from: legacy)))
        precondition(target.speechRecognitionCorrections == mergedRules, "Legacy imports preserve local corrections")
        try target.saveSpeechRecognitionCorrections([])
        let cleared = try LocalConfigurationStore(directory: directory.appendingPathComponent("restore"))
        precondition(cleared.speechRecognitionCorrections.isEmpty)
        print("PASS: legacy external identity migration/import and new-contact isolation, transcript corrections, correction validation/persistence/backup merge, legacy configuration, identity, STT switching/reuse, Fish presets, thinking persistence, safe Whisper import")
    }

    @MainActor private static func checkConnectionDeletion(directory: URL) throws {
        let store = try LocalConfigurationStore(directory: directory)
        let model = ConnectionProfile(name: "Synthetic model", provider: .openAICompatible)
        let speech = ConnectionProfile(name: "Synthetic speech", provider: .appleSpeech)
        let voice = ConnectionProfile(name: "Synthetic voice", provider: .miniMax)
        let service = ConnectionProfile(name: "Synthetic service", provider: .genericConnector)
        for connection in [model, speech, voice, service] { try store.saveConnection(connection) }
        try store.selectSTTProvider(.appleSpeech)
        let contact = CallRole(name: "Retained contact", modelConnectionID: model.id,
                               summaryConnectionID: model.id, sttConnectionID: speech.id,
                               ttsConnectionID: voice.id, callMode: .standalone,
                               externalConnectionID: service.id, externalRoleID: "retained-identity")
        try store.saveRole(contact)
        try store.deleteConnection(service.id)
        var expected = contact
        expected.externalConnectionID = nil
        precondition(store.roles == [expected], "Deleting a service clears its selection without deleting contacts or changing call mode")
        try store.deleteConnection(speech.id)
        expected.sttConnectionID = nil
        precondition(store.defaultSTTConnectionID == nil && store.roles == [expected])
        try store.deleteConnection(model.id)
        expected.modelConnectionID = nil
        expected.summaryConnectionID = nil
        precondition(store.roles == [expected] && store.connections == [voice])
        let reopened = try LocalConfigurationStore(directory: directory)
        precondition(reopened.roles == [expected] && reopened.defaultSTTConnectionID == nil && reopened.connections == [voice])
        // A failed atomic write must retain both the connection and its contact selection.
        let file = directory.appendingPathComponent("configuration.json")
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            try store.deleteConnection(voice.id)
            preconditionFailure("A failed write cannot delete the in-memory connection")
        } catch { }
        precondition(store.connections == [voice] && store.roles == [expected])
        try FileManager.default.removeItem(at: file)
        try original.write(to: file)
        try store.deleteConnection(voice.id)
        expected.ttsConnectionID = nil
        precondition(store.connections.isEmpty && store.roles == [expected])
        print("PASS: connection deletion clears only matching selections, persists atomically and preserves contacts and call mode")
    }

    @MainActor private static func checkIndividualCorrectionEdits(directory: URL) throws {
        let store = try LocalConfigurationStore(directory: directory)
        var first = SpeechRecognitionCorrection(source: "帐户", replacement: "账户")
        let second = SpeechRecognitionCorrection(source: "登陆", replacement: "登录")
        try store.saveSpeechRecognitionCorrection(first)
        try store.saveSpeechRecognitionCorrection(second)
        first.replacement = " 用户账户 "
        try store.saveSpeechRecognitionCorrection(first)
        first.replacement = "用户账户"
        precondition(store.speechRecognitionCorrections == [first, second], "Editing one rule must preserve the others")
        var duplicate = first
        duplicate.source = second.source
        do {
            try store.saveSpeechRecognitionCorrection(duplicate)
            preconditionFailure("Duplicate phrases must be rejected without replacing the saved rule")
        } catch is TincallError { }
        let reopened = try LocalConfigurationStore(directory: directory)
        precondition(reopened.speechRecognitionCorrections == [first, second])
        try reopened.deleteSpeechRecognitionCorrection(first.id)
        let afterDelete = try LocalConfigurationStore(directory: directory)
        precondition(afterDelete.speechRecognitionCorrections == [second], "Deleting one rule must preserve the others on disk")
        try afterDelete.deleteSpeechRecognitionCorrection(UUID())
        precondition(afterDelete.speechRecognitionCorrections == [second], "Discarding an unsaved draft must not alter saved rules")
    }
}
