// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFoundation
import Foundation

private final class RoutingSession: CallAudioSessionRouting, @unchecked Sendable {
    struct State {
        var category = AVAudioSession.Category.playback
        var mode = AVAudioSession.Mode.default
        var options: AVAudioSession.CategoryOptions = []
        var port = AVAudioSession.Port.builtInReceiver
        var override = AVAudioSession.PortOverride.none
        var active = false
        var allowsHaptics = false
        var headset = true
        var categoryCalls = 0
        var overrideCalls = 0
        var mainThreadCalls = 0
        var delay: TimeInterval = 0
        var failOverride = false
    }
    private let lock = NSLock()
    private var state = State()
    func read() -> State { lock.withLock { state } }
    func change(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    var category: AVAudioSession.Category { read().category }
    var mode: AVAudioSession.Mode { read().mode }
    var categoryOptions: AVAudioSession.CategoryOptions { read().options }
    private func automaticPort(_ state: State) -> AVAudioSession.Port {
        state.headset && state.options.contains(.allowBluetoothA2DP) ? .bluetoothA2DP
            : (state.options.contains(.defaultToSpeaker) ? .builtInSpeaker : .builtInReceiver)
    }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        Thread.sleep(forTimeInterval: read().delay)
        change {
            $0.category = category; $0.mode = mode; $0.options = options
            $0.categoryCalls += 1
            if Thread.isMainThread { $0.mainThreadCalls += 1 }
            $0.override = .none; $0.port = automaticPort($0)
        }
    }
    func overrideOutputAudioPort(_ portOverride: AVAudioSession.PortOverride) throws {
        try lock.withLock {
            state.overrideCalls += 1
            if Thread.isMainThread { state.mainThreadCalls += 1 }
            if state.failOverride { state.failOverride = false; throw NSError(domain: "SyntheticRoute", code: 123) }
            state.override = portOverride
            state.port = portOverride == .speaker ? .builtInSpeaker : automaticPort(state)
        }
    }
    func setAllowHapticsAndSystemSoundsDuringRecording(_ enabled: Bool) throws {
        change { $0.allowsHaptics = enabled; if Thread.isMainThread { $0.mainThreadCalls += 1 } }
    }
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        change { $0.active = active; if Thread.isMainThread { $0.mainThreadCalls += 1 } }
    }
}

@main struct CallAudioRoutingChecks {
    @MainActor static func main() async throws {
        let native = RoutingSession()
        native.change { $0.headset = false }
        let routing = CallAudioRouting(audio: native)
        let identity = VoiceSessionID(callID: UUID(), epoch: UUID())
        try await routing.prepare(session: identity)
        precondition(native.read().port == .builtInReceiver && !native.read().options.contains(.defaultToSpeaker),
                     "a call without headphones must start on the receiver, not speaker")
        _ = try await routing.setSpeakerEnabled(true, session: identity)
        precondition(native.read().port == .builtInSpeaker, "speaker remains available by explicit choice")
        try await routing.prepare(session: identity)
        precondition(native.read().port == .builtInReceiver, "a fresh call must clear the previous speaker choice")
        precondition(native.read().allowsHaptics, "call capture must allow system haptics")
        native.change { $0.headset = true; $0.options.remove(.allowBluetoothA2DP); $0.delay = 0.24 }
        let start = ProcessInfo.processInfo.systemUptime
        let change = Task { try await routing.setSpeakerEnabled(false, session: identity) }
        try await Task.sleep(for: .milliseconds(30))
        precondition(ProcessInfo.processInfo.systemUptime - start < 0.16, "slow native configuration must not block the UI executor")
        let first = try await change.value
        precondition(first.errorCode == nil && native.read().port == .bluetoothA2DP)
        precondition(native.read().mainThreadCalls == 0, "all session writes run off the UI thread")
        native.change { $0.delay = 0 }
        let categoryCalls = native.read().categoryCalls
        _ = try await routing.setSpeakerEnabled(true, session: identity)
        precondition(native.read().port == .builtInSpeaker)
        _ = try await routing.setSpeakerEnabled(false, session: identity)
        precondition(native.read().port == .bluetoothA2DP && native.read().categoryCalls == categoryCalls,
                     "repeat speaker toggles should only change the output override")

        _ = try await routing.setSpeakerEnabled(true, session: identity)
        native.change { $0.mode = .voiceChat; $0.options = [.mixWithOthers, .defaultToSpeaker] }
        let restored = try await routing.refreshBluetooth(preferAutomatic: false, session: identity)
        precondition(restored && native.read().mode == .voiceChat && native.read().port == .builtInSpeaker,
                     "repair the missing A2DP option without changing mode or an explicit speaker choice")
        _ = try await routing.refreshBluetooth(preferAutomatic: true, session: identity)
        precondition(native.read().port == .bluetoothA2DP, "a newly connected headset must release the old speaker override")
        native.change { $0.mode = .voiceChat }
        _ = try await routing.refreshBluetooth(preferAutomatic: true, session: identity)
        precondition(native.read().mode == .voiceChat, "ordinary route repair keeps the capture-owned mode")
        _ = try await routing.refreshBluetooth(preferAutomatic: true, restoreMediaMode: true, session: identity)
        precondition(native.read().mode == .default && native.read().options.contains([.allowBluetoothA2DP, .mixWithOthers]),
                     "a mid-call headset returns VoiceChat to media mode with the call policy intact")
        let overrides = native.read().overrideCalls
        _ = try await routing.refreshBluetooth(preferAutomatic: true, session: identity)
        precondition(native.read().overrideCalls == overrides, "an automatic route report must not trigger a notification loop")
        _ = try await routing.setSpeakerEnabled(true, session: identity)
        native.change { $0.mode = .voiceChat }
        _ = try await routing.setSpeakerEnabled(false, restoreMediaMode: true, session: identity)
        precondition(native.read().mode == .default && native.read().port == .bluetoothA2DP,
                     "turning the speaker off returns VoiceChat to media mode so the headset can take over")
        try await routing.setDucking(true, revision: 2, session: identity)
        try await routing.setDucking(false, revision: 1, session: identity)
        precondition(native.read().options.contains(.duckOthers), "stale ducking work must not override newer playback state")
        native.change { $0.options = [.allowBluetoothA2DP] }
        _ = try await routing.refreshBluetooth(preferAutomatic: false, session: identity)
        precondition(native.read().options.contains([.duckOthers, .mixWithOthers]),
                     "route changes must restore active playback ducking and media mixing, even when A2DP survived")
        let repairedCalls = native.read().categoryCalls
        _ = try await routing.refreshBluetooth(preferAutomatic: false, session: identity)
        precondition(native.read().categoryCalls == repairedCalls, "stable ducking repair must not loop")
        try await routing.setDucking(false, revision: 3, session: identity)
        precondition(!native.read().options.contains(.duckOthers) && native.read().port == .bluetoothA2DP)
        native.change { $0.options = [.allowBluetoothA2DP]; $0.active = false }
        try await routing.activate(session: identity)
        precondition(native.read().active && native.read().options.contains(.mixWithOthers)
                     && !native.read().options.contains(.duckOthers),
                     "explicit reactivation restores mixing before resuming capture")

        try await routing.setDucking(true, revision: 4, session: identity)
        let callsBeforeInterruption = native.read().categoryCalls
        await routing.suspendDucking(revision: 5, session: identity)
        try await routing.setDucking(true, revision: 4, session: identity)
        precondition(native.read().categoryCalls == callsBeforeInterruption,
                     "interruption only updates desired ducking; stale requests cannot reconfigure an inactive session")
        try await routing.activate(session: identity)
        precondition(!native.read().options.contains(.duckOthers),
                     "recovery must not restore ducking for the reply already terminated by interruption")

        native.change { $0.failOverride = true }
        let failed = try await routing.setSpeakerEnabled(true, session: identity)
        precondition(failed.errorCode == 123 && native.read().port == .bluetoothA2DP, "a failed switch restores the previous route")
        let next = VoiceSessionID(callID: UUID(), epoch: UUID())
        try await routing.prepare(session: next)
        _ = await routing.stop(session: identity)
        precondition(native.read().active, "old cleanup must not deactivate a newer call")
        do { _ = try await routing.setSpeakerEnabled(true, session: identity); preconditionFailure("old call changed the route") }
        catch is CancellationError { }
        _ = await routing.stop(session: next)
        precondition(!native.read().active && native.read().mainThreadCalls == 0)
        print("PASS: slow routing leaves UI responsive; A2DP repair, headset takeover, no redundant category changes, ducking order, rollback and old-call isolation")
    }
}
