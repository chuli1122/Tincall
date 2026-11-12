// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFoundation
import Foundation

protocol CallAudioSessionRouting: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func overrideOutputAudioPort(_ portOverride: AVAudioSession.PortOverride) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
    func setAllowHapticsAndSystemSoundsDuringRecording(_ enabled: Bool) throws
}

extension AVAudioSession: CallAudioSessionRouting {}

/// Serializes session mutations away from the UI executor. Call identities keep
/// queued cleanup and volume updates from changing a newer call's session.
actor CallAudioRouting {
    struct SpeakerResult: Sendable {
        var categoryMilliseconds: Int?
        var outputMilliseconds: Int?
        var totalMilliseconds = 0
        var errorCode: Int?
        var rollbackErrorCode: Int?
        var ranOnMainThread = false
    }

    private let audio: any CallAudioSessionRouting
    private var session: VoiceSessionID?
    private var speakerOverride: Bool?
    private var duckingRevision = 0
    private var ducksOtherAudio = false

    init() { audio = AVAudioSession.sharedInstance() }
    init(audio: sending any CallAudioSessionRouting) { self.audio = audio }

    func prepare(session: VoiceSessionID) throws {
        self.session = session
        speakerOverride = nil
        duckingRevision = 0
        ducksOtherAudio = false
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .mixWithOthers]
        if audio.category != .playAndRecord || audio.mode != .default || audio.categoryOptions != options {
            try audio.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try audio.overrideOutputAudioPort(.none)
        try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audio.setActive(true, options: [])
    }

    func activate(session: VoiceSessionID) throws {
        guard self.session == session else { throw CancellationError() }
        _ = try refreshBluetooth(preferAutomatic: false, session: session)
        try audio.setActive(true, options: [])
    }

    func setSpeakerEnabled(_ enabled: Bool, restoreMediaMode: Bool = false,
                           session: VoiceSessionID) throws -> SpeakerResult {
        guard self.session == session else { throw CancellationError() }
        let start = ProcessInfo.processInfo.systemUptime
        let previousOptions = audio.categoryOptions
        let previousMode = audio.mode
        let previousOverride = speakerOverride
        let mode = restoreMediaMode ? AVAudioSession.Mode.default : previousMode
        var options = previousOptions.union(.allowBluetoothA2DP)
        // Once the default has been cleared, explicit overrides can switch both
        // ways without rebuilding the category on every tap.
        if !enabled { options.remove(.defaultToSpeaker) }
        var result = SpeakerResult()
        result.ranOnMainThread = Thread.isMainThread
        do {
            if audio.category != .playAndRecord || options != previousOptions || mode != previousMode {
                let categoryStart = ProcessInfo.processInfo.systemUptime
                try audio.setCategory(.playAndRecord, mode: mode, options: options)
                result.categoryMilliseconds = Int((ProcessInfo.processInfo.systemUptime - categoryStart) * 1000)
            } else { result.categoryMilliseconds = 0 }
            let outputStart = ProcessInfo.processInfo.systemUptime
            try audio.overrideOutputAudioPort(enabled ? .speaker : .none)
            result.outputMilliseconds = Int((ProcessInfo.processInfo.systemUptime - outputStart) * 1000)
            speakerOverride = enabled
        } catch {
            result.errorCode = (error as NSError).code
            do {
                try audio.setCategory(.playAndRecord, mode: previousMode, options: previousOptions)
                try audio.overrideOutputAudioPort(previousOverride == true ? .speaker : .none)
            } catch { result.rollbackErrorCode = (error as NSError).code }
        }
        result.totalMilliseconds = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        return result
    }

    func setDucking(_ enabled: Bool, revision: Int, session: VoiceSessionID) throws {
        guard self.session == session, revision >= duckingRevision else { return }
        duckingRevision = revision
        ducksOtherAudio = enabled
        var options = audio.categoryOptions.union([.allowBluetoothA2DP, .mixWithOthers])
        if enabled { options.insert(.duckOthers) }
        else { options.remove(.duckOthers) }
        guard options != audio.categoryOptions else { return }
        try audio.setCategory(.playAndRecord, mode: audio.mode, options: options)
        if speakerOverride == true { try audio.overrideOutputAudioPort(.speaker) }
    }

    func suspendDucking(revision: Int, session: VoiceSessionID) {
        guard self.session == session, revision >= duckingRevision else { return }
        duckingRevision = revision
        ducksOtherAudio = false
    }

    /// `restoreMediaMode` is only for a newly connected device after capture has
    /// released voice processing: VoiceChat mode keeps A2DP-only headsets from
    /// taking over, so the call returns to the media mode it started with.
    func refreshBluetooth(preferAutomatic: Bool, restoreMediaMode: Bool = false,
                          session: VoiceSessionID) throws -> Bool {
        guard self.session == session else { throw CancellationError() }
        let previousOverride = speakerOverride
        let clearOverride = preferAutomatic && speakerOverride != nil
        if preferAutomatic { speakerOverride = nil }
        var options = audio.categoryOptions.union([.allowBluetoothA2DP, .mixWithOthers])
        if ducksOtherAudio { options.insert(.duckOthers) }
        else { options.remove(.duckOthers) }
        let mode = restoreMediaMode ? AVAudioSession.Mode.default : audio.mode
        do {
            if options != audio.categoryOptions || mode != audio.mode {
                // System route changes can drop mixing/ducking as well as A2DP.
                // Restore the call policy without replacing its mode or output choice.
                try audio.setCategory(.playAndRecord, mode: mode, options: options)
                if speakerOverride == true { try audio.overrideOutputAudioPort(.speaker) }
            }
            if clearOverride { try audio.overrideOutputAudioPort(.none) }
        } catch {
            speakerOverride = previousOverride
            throw error
        }
        return audio.categoryOptions.contains(.allowBluetoothA2DP)
    }

    func stop(session: VoiceSessionID) -> Int? {
        guard self.session == session else { return nil }
        self.session = nil
        speakerOverride = nil
        ducksOtherAudio = false
        var errorCode: Int?
        do { try audio.overrideOutputAudioPort(.none) }
        catch { errorCode = (error as NSError).code }
        do { try audio.setActive(false, options: .notifyOthersOnDeactivation) }
        catch { if errorCode == nil { errorCode = (error as NSError).code } }
        return errorCode
    }
}
