// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

@preconcurrency import ActivityKit
import AppIntents
import Foundation
import OSLog

struct TincallCallAttributes: ActivityAttributes {
    enum AudioActivity: String, Codable, Hashable {
        case idle, listening, speaking
    }

    struct ContentState: Codable, Hashable {
        var status: String
        var startedAt: Date
        var isMuted: Bool
        var microphoneAvailable: Bool? = nil
        var isSpeakerEnabled: Bool? = nil
        var audioActivity: AudioActivity? = nil
        // Remote starts may carry the display name; avatar images always stay local.
        var displayName: String? = nil
        var avatarContactID: UUID? = nil
    }

    var callID: UUID
    var name: String
    var avatarContactID: UUID? = nil
    var isPreview: Bool = false

    init(callID: UUID, name: String, avatarContactID: UUID? = nil, isPreview: Bool = false) {
        self.callID = callID
        self.name = name
        self.avatarContactID = avatarContactID
        self.isPreview = isPreview
    }

    private enum CodingKeys: String, CodingKey {
        case callID, name, avatarContactID, isPreview
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(UUID.self, forKey: .callID)
        name = try values.decode(String.self, forKey: .name)
        avatarContactID = try values.decodeIfPresent(UUID.self, forKey: .avatarContactID)
        isPreview = try values.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
    }
}

enum TincallCallAvatar {
    // Both targets receive this key from CallActivityAppGroup.xcconfig.
    static let appGroupIdentifier = Bundle.main.object(forInfoDictionaryKey: "TincallAppGroupIdentifier") as? String

    private static var sharedDefaults: UserDefaults? {
        appGroupIdentifier.flatMap(UserDefaults.init(suiteName:))
    }

    static func rememberName(_ name: String, for contactID: UUID) {
        sharedDefaults?.set(name, forKey: "tincall.contactName.\(contactID.uuidString)")
    }

    static func displayName(for contactID: UUID) -> String? {
        sharedDefaults?.string(forKey: "tincall.contactName.\(contactID.uuidString)")
    }

    // Prepared while ringing, before requesting the remote activity.
    static func rememberIncoming(callID: UUID, contactID: UUID?) {
        var identity = ["callID": callID.uuidString]
        identity["contactID"] = contactID?.uuidString
        sharedDefaults?.set(identity, forKey: "tincall.incomingActivityAvatar")
    }

    static func incomingContactID(for callID: UUID) -> UUID? {
        guard let identity = sharedDefaults?.dictionary(forKey: "tincall.incomingActivityAvatar"),
              identity["callID"] as? String == callID.uuidString,
              let contactID = identity["contactID"] as? String else { return nil }
        return UUID(uuidString: contactID)
    }

    static func forgetIncoming(callID: UUID) {
        guard let identity = sharedDefaults?.dictionary(forKey: "tincall.incomingActivityAvatar"),
              identity["callID"] as? String == callID.uuidString else { return }
        sharedDefaults?.removeObject(forKey: "tincall.incomingActivityAvatar")
    }

    static func fileURL(for contactID: UUID) -> URL? {
        guard let appGroupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        return container.appendingPathComponent("avatars", isDirectory: true)
            .appendingPathComponent(contactID.uuidString).appendingPathExtension("jpg")
    }
}

/// Only fixed execution stages are recorded; never include call identifiers or content.
enum TincallMicrophoneDiagnostics {
    enum Event: String {
        case handlerRegistered, intentEntered, invalidIdentifier, missingHandler
        case handlerEntered, missingCoordinator, inactiveCall, staleCall
        case muteRequested, muteChanged, muteUnchanged, intentCompleted
        case activityUnavailable, activityMuted, activityUnmuted
    }

    static func record(_ event: Event) {
        Logger(subsystem: "com.tincall.app", category: "MicrophoneIntent")
            .notice("stage=\(event.rawValue, privacy: .public)")
        #if DEBUG
        guard let group = TincallCallAvatar.appGroupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let directory = container.appendingPathComponent("Library/Caches", isDirectory: true)
        let url = directory.appendingPathComponent("microphone-intent-diagnostics.txt")
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let row = "\(Date().timeIntervalSince1970) \(Bundle.main.bundleIdentifier ?? "unknown") \(event.rawValue)"
        // Keep only the latest published state so speech updates cannot erase a button's execution path.
        let activityEvents: Set<String> = [Event.activityUnavailable.rawValue, Event.activityMuted.rawValue, Event.activityUnmuted.rawValue]
        let retained = previous.split(separator: "\n").filter { line in
            !activityEvents.contains(String(line.split(separator: " ").last ?? ""))
        }
        let rows = (retained.suffix(19).map(String.init) + [row]).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(rows.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Logger(subsystem: "com.tincall.app", category: "MicrophoneIntent")
                .error("Diagnostic stage could not be saved")
        }
        #endif
    }
}

struct TincallToggleMicrophoneIntent: LiveActivityIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "开关麦克风"
    @MainActor static var microphoneAction: ((UUID) async throws -> Void)?

    @Parameter(title: "通话")
    var callID: String

    init() {}

    init(callID: UUID) {
        self.callID = callID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        TincallMicrophoneDiagnostics.record(.intentEntered)
        guard let id = UUID(uuidString: callID) else {
            TincallMicrophoneDiagnostics.record(.invalidIdentifier)
            throw NSError(domain: "TincallCall", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "请打开 Tincall 恢复通话后再操作麦克风")])
        }
        guard let action = Self.microphoneAction else {
            TincallMicrophoneDiagnostics.record(.missingHandler)
            throw NSError(domain: "TincallCall", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "请打开 Tincall 恢复通话后再操作麦克风")])
        }
        try await action(id)
        TincallMicrophoneDiagnostics.record(.intentCompleted)
        return .result()
    }
}

struct TincallTogglePreviewMicrophoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "开关麦克风"
    static let openAppWhenRun = false
    @MainActor static var microphoneAction: ((UUID) -> TincallCallAttributes.ContentState?)?

    @Parameter(title: "通话")
    var callID: String

    init() {}

    init(callID: UUID) {
        self.callID = callID.uuidString
    }

    @MainActor
    func perform() async -> some IntentResult {
        guard let id = UUID(uuidString: callID) else { return .result() }
        let previews = Activity<TincallCallAttributes>.activities.filter {
            $0.attributes.isPreview && $0.attributes.callID == id
        }
        guard !previews.isEmpty else { return .result() }
        if let state = Self.microphoneAction?(id) {
            let content = ActivityContent(state: state, staleDate: nil)
            for preview in previews {
                await preview.update(content)
            }
        } else {
            // The preview page is gone, including after the app process was restarted.
            for preview in previews {
                await preview.end(nil, dismissalPolicy: .immediate)
            }
        }
        return .result()
    }
}

struct TincallToggleSpeakerIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "切换扬声器"
    @MainActor static var speakerAction: ((UUID) async throws -> Void)?

    @Parameter(title: "通话")
    var callID: String

    init() {}

    init(callID: UUID) {
        self.callID = callID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: callID), let action = Self.speakerAction else {
            throw NSError(domain: "TincallCall", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "当前通话不可用，请打开 Tincall 查看")])
        }
        try await action(id)
        return .result()
    }
}

struct TincallTogglePreviewSpeakerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "切换扬声器"
    static let openAppWhenRun = false
    @MainActor static var speakerAction: ((UUID) -> TincallCallAttributes.ContentState?)?

    @Parameter(title: "通话")
    var callID: String

    init() {}

    init(callID: UUID) {
        self.callID = callID.uuidString
    }

    @MainActor
    func perform() async -> some IntentResult {
        guard let id = UUID(uuidString: callID) else { return .result() }
        let previews = Activity<TincallCallAttributes>.activities.filter {
            $0.attributes.isPreview && $0.attributes.callID == id
        }
        guard !previews.isEmpty else { return .result() }
        if let state = Self.speakerAction?(id) {
            let content = ActivityContent(state: state, staleDate: nil)
            for preview in previews { await preview.update(content) }
        } else {
            for preview in previews { await preview.end(nil, dismissalPolicy: .immediate) }
        }
        return .result()
    }
}
