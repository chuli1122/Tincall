// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

// Isolated transport fixtures; the production controller owns subscriptions and cancellation.
import Foundation
import AVFAudio
import CallKit

struct ExternalCallFailure: LocalizedError {
    let status: Int
    var errorDescription: String? = "Synthetic connection guidance (HTTP 409)"
}
struct ExternalCallState: Sendable {
    let id = UUID()
    let contact_id = "synthetic-contact"
    let source = "mcp"
    var status = "ringing"
}
struct ExternalEventPage { let call: ExternalCallState }
@MainActor final class RequestLogStore {
    static let shared = RequestLogStore()
    func registerCall(id: UUID, startedAt: Date, mode: CallMode?) { }
}
@MainActor final class ExternalCallClient {
    var reads = 0
    var eventReads = 0
    var recoverRinging = false
    var activityStarts = 0
    var activityNames: [String] = []
    var streams = 0
    var cancellations = 0
    var fails = false
    var callbacks: [UUID: (ExternalCallState?) -> Void] = [:]
    var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var registrations: [(connection: UUID, device: UUID, token: String)] = []
    var removals: [(connection: UUID, device: UUID, request: UUID)] = []
    var registrationFailure: UUID?
    var removalFailure: UUID?
    var removalError = URLError(.notConnectedToInternet)
    var holdRegistration = false
    var registrationWaiter: CheckedContinuation<Void, Never>?
    func current(connection: ConnectionProfile) async throws -> ExternalCallState? {
        reads += 1
        preconditionFailure("Foreground discovery must never poll current")
    }
    func incomingCalls(connection: ConnectionProfile, onCall: @escaping (ExternalCallState?) -> Void) async throws {
        streams += 1
        callbacks[connection.id] = onCall
        if fails { throw URLError(.notConnectedToInternet) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[connection.id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancellations += 1
                self.waiters.removeValue(forKey: connection.id)?.resume(throwing: CancellationError())
            }
        }
    }
    func validate(_ connection: ConnectionProfile) throws { }
    func registerDevice(connection: ConnectionProfile, deviceID: UUID, token: String, environment: String,
                        liveActivityStartToken: String? = nil) async throws -> Bool {
        registrations.append((connection.id, deviceID, token))
        if holdRegistration { await withCheckedContinuation { registrationWaiter = $0 } }
        if connection.id == registrationFailure { throw URLError(.notConnectedToInternet) }
        return liveActivityStartToken != nil
    }
    func startCallActivity(connection: ConnectionProfile, callID: UUID, deviceID: UUID, avatarContactID: UUID, displayName: String) async throws {
        activityStarts += 1
        activityNames.append(displayName)
        if fails { throw URLError(.notConnectedToInternet) }
    }
    func prepareDeviceRemoval(connection: ConnectionProfile, deviceID: UUID, requestID: UUID) throws -> @MainActor () async throws -> Void {
        { try await self.removeDevice(connection: connection, deviceID: deviceID, requestID: requestID) }
    }
    func removeDevice(connection: ConnectionProfile, deviceID: UUID, requestID: UUID) async throws {
        removals.append((connection.id, deviceID, requestID))
        if connection.id == removalFailure { throw removalError }
    }
    func events(connection: ConnectionProfile, callID: UUID, after: Int) async throws -> ExternalEventPage {
        eventReads += 1
        if recoverRinging {
            if eventReads == 1 { throw URLError(.networkConnectionLost) }
            return ExternalEventPage(call: ExternalCallState(status: "ended"))
        }
        return ExternalEventPage(call: ExternalCallState())
    }
}

private final class AnswerProvider: CXProvider, @unchecked Sendable {
    var reportedID: UUID?
    var reportedUpdate: CXCallUpdate?
    var refreshedUpdate: CXCallUpdate?
    var ended = false
    var startedConnecting = false
    var connected = false
    override func reportOutgoingCall(with UUID: UUID, startedConnectingAt dateStartedConnecting: Date?) { startedConnecting = true }
    override func reportOutgoingCall(with UUID: UUID, connectedAt dateConnected: Date?) { connected = true }
    override func reportNewIncomingCall(with UUID: UUID, update: CXCallUpdate, completion: @escaping ((any Error)?) -> Void) {
        reportedID = UUID
        reportedUpdate = update
        completion(nil)
    }
    override func reportCall(with UUID: UUID, updated update: CXCallUpdate) { refreshedUpdate = update }
    override func reportCall(with UUID: UUID, endedAt dateEnded: Date?, reason endedReason: CXCallEndedReason) { ended = true }
}

private final class AnswerAction: CXAnswerCallAction, @unchecked Sendable {
    var answered = false
    var onFulfill: (() -> Void)?
    override func fulfill() { onFulfill?(); answered = true; super.fulfill() }
}

private final class AnswerCallController: CXCallController, @unchecked Sendable {
    var onRequest: ((CXTransaction) -> Void)?
    var failure: Error?
    override func request(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void) {
        if let failure { completion(failure); return }
        onRequest?(transaction)
        completion(nil)
    }
}

@main struct IncomingForegroundChecks {
    @MainActor static func until(timeout: TimeInterval = 2, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            precondition(Date() < deadline, "Timed out waiting for incoming subscription")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--caller-handle") { try await checkInitialCallerHandle(); return }
        if CommandLine.arguments.contains("--connection-removal") { try await checkConnectionRemoval(); return }
        if CommandLine.arguments.contains("--bindings") { try await checkBindings(); return }
        if CommandLine.arguments.contains("--foreground-handoff") { try await checkForegroundHandoff(); return }
        if CommandLine.arguments.contains("--activity-after-answer") { try await checkIncomingActivitySuppression(); return }
        if CommandLine.arguments.contains("--ring-recovery") { try await checkRingRecovery(); return }
        if CommandLine.arguments.contains("--missed-call") { try await checkMissedCaller(); return }
        if CommandLine.arguments.contains("--answer") { try await checkAnswer(); return }
        if CommandLine.arguments.contains("--outgoing") { try await checkOutgoing(); return }
        if CommandLine.arguments.contains("--consent") { try await checkIncomingConsent(); return }
        if CommandLine.arguments.contains("--failure-guidance") { try await checkIncomingFailureGuidance(); return }
        var role = CallRole(name: "Synthetic")
        role.linkedContact = LinkedContact(identifier: "synthetic-id", name: "Synthetic", phoneNumber: " +12025550123 ", emailAddress: "fixture@example.invalid")
        precondition(IncomingCallController.callerHandle(for: role).type == .phoneNumber)
        precondition(IncomingCallController.callerHandle(for: role).value == "+12025550123")
        role.linkedContact?.phoneNumber = " "
        precondition(IncomingCallController.callerHandle(for: role).type == .emailAddress)
        role.unlinkContact()
        precondition(IncomingCallController.callerHandle(for: role).type == .generic)
        precondition(IncomingCallController.callerHandle(for: role).value == role.id.uuidString)
        let legacy = try JSONDecoder().decode(LinkedContact.self, from: Data(#"{"identifier":"legacy","name":"Synthetic"}"#.utf8))
        precondition(legacy.phoneNumber == nil && legacy.emailAddress == nil)
        print("PASS: selected contact phone/email matching, unlink fallback and legacy decoding")
        let suite = "TincallIncomingChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ExternalCallClient()
        let controller = IncomingCallController(client: client, defaults: defaults)
        var resolved = 0
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector, endpoint: URL(string: "https://synthetic.invalid"))
        controller.canAcceptCall = { true }
        controller.onResolveRole = { identifier, mode, connectionID in
            precondition(identifier == "synthetic-contact" && mode == .mcp && connectionID == connection.id)
            resolved += 1
            return nil
        }
        controller.monitorForeground(connections: [connection], active: true)
        try await until { client.waiters[connection.id] != nil }
        client.callbacks[connection.id]?(ExternalCallState())
        precondition(resolved == 1 && !controller.isEnabled && controller.state == .disabled)
        try await Task.sleep(for: .milliseconds(2100))
        precondition(client.streams == 1 && client.reads == 0, "An idle foreground must keep one stream without periodic queries")
        var activeCall = ExternalCallState(); activeCall.status = "active"
        client.callbacks[connection.id]?(activeCall)
        precondition(resolved == 1, "Active calls must not ring again")
        let lateCallback = client.callbacks[connection.id]!
        controller.monitorForeground(connections: [connection], active: false)
        try await until { client.cancellations == 1 }
        // Simulate a transport delivering a late result in its cancelled task.
        let lateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            lateCallback(ExternalCallState())
        }
        lateTask.cancel(); await lateTask.value
        precondition(resolved == 1 && client.reads == 0)
        print("PASS: foreground receives events without push or polling; active calls are ignored; background cancels and ignores late events")

        client.fails = true
        controller.monitorForeground(connections: [connection], active: true)
        try await until { controller.foregroundErrorMessage != nil }
        let attempts = client.streams
        try await Task.sleep(for: .milliseconds(150))
        precondition(client.streams == attempts, "Failures must back off instead of reconnecting in a tight loop")
        controller.monitorForeground(connections: [], active: false)
        precondition(controller.foregroundErrorMessage == nil)
        print("PASS: subscription failures are visible, reconnects back off and stopping clears the error")
        try await checkBindings()
        try await checkAnswer()
    }

    @MainActor static func checkIncomingFailureGuidance() async throws {
        let suite = "TincallIncomingFailureGuidance-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ExternalCallClient(), provider = AnswerProvider(configuration: CXProviderConfiguration())
        let controller = IncomingCallController(client: client, defaults: defaults, provider: provider)
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector,
                                           endpoint: URL(string: "https://synthetic.invalid"))
        let role = CallRole(name: "Synthetic")
        let failure = ExternalCallFailure(status: 409)
        controller.canAcceptCall = { true }
        controller.onResolveRole = { _, _, _ in role }
        controller.onPrepare = { _, _, _ in throw failure }
        controller.onAccept = { _, _, _ in preconditionFailure("Preparation failure must not accept the call") }
        controller.onBeginMedia = { _, _, _ in preconditionFailure("Preparation failure must not start media") }
        controller.onReleaseMedia = { _ in preconditionFailure("Preparation failure must not hand off media") }
        controller.onConnected = { _ in preconditionFailure("Preparation failure must not connect the call") }
        controller.monitorForeground(connections: [connection], active: true)
        try await until { client.callbacks[connection.id] != nil }
        client.callbacks[connection.id]?(ExternalCallState())
        try await until { provider.reportedID != nil }
        controller.provider(provider, perform: AnswerAction(call: provider.reportedID!))
        try await until { controller.errorMessage != nil }
        precondition(controller.errorMessage == failure.localizedDescription,
                     "Incoming failures must preserve the error's complete action guidance and HTTP status")
        precondition(controller.answeringCall == nil && provider.ended)
        controller.monitorForeground(connections: [], active: false)
        print("PASS: incoming preparation failures preserve full connection guidance and clean up the call")
    }

    @MainActor static func checkIncomingConsent() async throws {
        let suite = "TincallIncomingConsent-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ExternalCallClient(), provider = AnswerProvider(configuration: CXProviderConfiguration())
        let controller = IncomingCallController(client: client, defaults: defaults, provider: provider)
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector, endpoint: URL(string: "https://synthetic.invalid"))
        let speech = ConnectionProfile(name: "On-device", provider: .appleSpeech)
        let voice = ConnectionProfile(name: "Synthetic voice", provider: .elevenLabs)
        var role = CallRole(name: "Synthetic")
        role.callMode = .mcp; role.sttConnectionID = speech.id; role.ttsConnectionID = voice.id
        DataSharingConsent.rememberDeviceBinding(connection, defaults: defaults)
        var ringing = 0
        controller.canAcceptCall = { true }
        controller.canUseConnections = { role, connector in
            DataSharingConsent.permitsIncomingCall(role: role, connector: connector,
                connections: [connection, speech, voice], defaultSTT: nil, defaults: defaults)
        }
        controller.onResolveRole = { _, _, _ in role }
        controller.onRing = { _, _, _ in ringing += 1 }
        controller.monitorForeground(connections: [connection], active: true)
        try await until { client.callbacks[connection.id] != nil }
        client.callbacks[connection.id]?(ExternalCallState())
        try await until { provider.ended }
        precondition(ringing == 0 && controller.answeringCall == nil)
        precondition(controller.errorMessage?.contains("尚未授权") == true)
        precondition(DataSharingConsent.needsReview(connection, defaults: defaults)
            && DataSharingConsent.needsReview(voice, defaults: defaults), "An upgraded configuration must be offered consent review")
        controller.dismissError()
        precondition(controller.errorMessage == nil)
        DataSharingConsent.setAllowed(true, for: connection, defaults: defaults)
        DataSharingConsent.setAllowed(true, for: voice, defaults: defaults)
        provider.ended = false
        client.callbacks[connection.id]?(ExternalCallState())
        try await until { ringing == 1 }
        precondition(!provider.ended, "Explicit consent must restore incoming preparation without changing the existing binding")
        controller.providerDidReset(provider)
        controller.monitorForeground(connections: [], active: false)
        print("PASS: legacy binding without grants is blocked with an error and needs review; explicit consent restores ringing preparation")
    }

    @MainActor static func checkInitialCallerHandle() async throws {
        for (phone, email, expectedType, expectedValue, hasCallNumber) in [
            (" +12025550123 ", "fixture@example.invalid", CXHandle.HandleType.phoneNumber, "+12025550123", false),
            (" ", " fixture@example.invalid ", .emailAddress, "fixture@example.invalid", false),
            (" ", " ", .generic, "", false),
            (" +12025550123 ", "fixture@example.invalid", .phoneNumber, "", true)
        ] {
            var savedRole = CallRole(name: "Synthetic")
            savedRole.linkedContact = LinkedContact(identifier: "synthetic-id", name: "Synthetic",
                                                    phoneNumber: phone, emailAddress: email)
            let callNumber = "000123456789"
            savedRole.systemCallPhoneNumber = callNumber
            if hasCallNumber { savedRole.linkedContact?.phoneNumbers = [phone, callNumber] }
            let expectedValue = hasCallNumber ? callNumber : expectedValue
            savedRole.syncSystemContactDetails = false
            let role = try JSONDecoder().decode(CallRole.self, from: JSONEncoder().encode(savedRole))
            let suite = "TincallInitialHandle-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = ExternalCallClient()
            let provider = AnswerProvider(configuration: CXProviderConfiguration())
            let controller = IncomingCallController(client: client, defaults: defaults, provider: provider)
            let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector,
                                               endpoint: URL(string: "https://synthetic.invalid"))
            controller.canAcceptCall = { true }
            controller.onResolveRole = { _, _, _ in role }
            controller.monitorForeground(connections: [connection], active: true)
            try await until { client.callbacks[connection.id] != nil }
            client.callbacks[connection.id]?(ExternalCallState())
            precondition(provider.reportedUpdate?.remoteHandle?.type == expectedType,
                         "The initial report must use the persisted phone or email without refreshing Contacts")
            precondition(provider.reportedUpdate?.remoteHandle?.value == (expectedType == .generic ? role.id.uuidString : expectedValue))
            precondition(provider.refreshedUpdate == nil, "The initial handle must not depend on a supplemental report")
            var refreshed = role
            refreshed.linkedContact?.phoneNumber = nil
            refreshed.linkedContact?.emailAddress = "refreshed@example.invalid"
            controller.refreshReportedCallDetails(roles: [refreshed])
            precondition(provider.refreshedUpdate?.remoteHandle?.type == (hasCallNumber ? .phoneNumber : .emailAddress))
            precondition(provider.refreshedUpdate?.remoteHandle?.value == (hasCallNumber ? callNumber : "refreshed@example.invalid"))
            controller.providerDidReset(provider)
            controller.monitorForeground(connections: [], active: false)
        }
        print("PASS: initial and refreshed incoming reports prefer the saved Tincall number; legacy phone, email and generic remain available")
    }

    @MainActor static func checkConnectionRemoval() async throws {
        let suite = "TincallConnectionRemoval-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ConnectionProfile(name: "Deleted service", provider: .genericConnector, endpoint: URL(string: "https://first.invalid"))
        let second = ConnectionProfile(name: "Retained service", provider: .genericConnector, endpoint: URL(string: "https://second.invalid"))
        var saved = IncomingCallConfiguration()
        saved.enabled = true
        saved.bindings = [IncomingDeviceBinding(connectionID: first.id, connection: first),
                          IncomingDeviceBinding(connectionID: second.id, connection: second)]
        defaults.set(try JSONEncoder().encode(saved), forKey: "tincall.incoming.configuration")
        let client = ExternalCallClient()
        let controller = IncomingCallController(client: client, defaults: defaults)
        await controller.restore(with: [first, second])
        client.holdRegistration = true
        let registering = controller.registerDeviceToken(Data([1]))
        try await until { client.registrationWaiter != nil }
        // Local deletion must finish while registration/network requests are still suspended.
        try controller.removeConnectionBinding(first.id)
        precondition(controller.connectionIDs == [second.id] && controller.isEnabled && !controller.needsDeviceRemoval)
        precondition(client.removals.isEmpty, "Remote cleanup must wait for in-flight registration")
        let persisted = try JSONDecoder().decode(IncomingCallConfiguration.self, from: defaults.data(forKey: "tincall.incoming.configuration")!)
        precondition(persisted.bindings.map(\.connectionID) == [second.id])
        let queued = controller.registerDeviceToken(Data([2]))
        client.holdRegistration = false
        client.registrationWaiter?.resume(); client.registrationWaiter = nil
        await registering.value
        await queued.value
        try await until { client.removals.count == 1 }
        precondition(client.removals[0].connection == first.id)
        precondition(controller.isRegistered(second.id) && !controller.isRegistered(first.id))
        precondition(client.registrations.filter { $0.connection == first.id }.count == 1,
                     "Queued tokens must not register the deleted service")
        precondition(controller.errorMessage == nil && controller.connectionRemovalNotice == nil)
        print("PASS: immediate local deletion persists before network cleanup, drains in-flight registration and preserves other services")

        client.removalFailure = second.id
        client.removalError = URLError(.secureConnectionFailed)
        try controller.removeConnectionBinding(second.id)
        precondition(controller.connectionIDs.isEmpty && !controller.isEnabled && !controller.needsDeviceRemoval)
        try await until { controller.connectionRemovalNotice != nil }
        precondition(controller.errorMessage == nil, "Remote cleanup failure must not become a blocking deletion error")
        precondition(controller.connectionForPush(deviceID: saved.bindings[1].deviceID) == nil)
        let reopened = IncomingCallController(client: client, defaults: defaults)
        await reopened.restore(with: [])
        precondition(reopened.connectionIDs.isEmpty && !reopened.isEnabled && !reopened.needsDeviceRemoval)
        precondition(client.removals.count == 2, "Reopening must not retry a deleted connection or require another confirmation")
        print("PASS: HTTPS cleanup failure needs no second action, leaves only an informational notice and never restores the deleted binding")
    }

    @MainActor static func checkForegroundHandoff() async throws {
        try await checkAnswer()
    }

    @MainActor static func checkIncomingActivitySuppression() async throws {
        let suite = "TincallActivityTimingChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector, endpoint: URL(string: "https://synthetic.invalid"))
        var settings = IncomingCallConfiguration()
        settings.enabled = true
        settings.bindings = [IncomingDeviceBinding(connectionID: connection.id, connection: connection)]
        defaults.set(try JSONEncoder().encode(settings), forKey: "tincall.incoming.configuration")
        let client = ExternalCallClient()
        let provider = AnswerProvider(configuration: CXProviderConfiguration())
        let controller = IncomingCallController(client: client, defaults: defaults, provider: provider)
        let role = CallRole(name: "Synthetic caller")
        controller.canAcceptCall = { true }
        controller.onResolveRole = { _, _, _ in role }
        await controller.restore(with: [connection])
        controller.monitorForeground(connections: [connection], active: true)
        try await until { client.callbacks[connection.id] != nil }
        controller.updateActivityStartToken(Data([1]))
        await controller.registerDeviceToken(Data([2])).value
        var ringed = false, accepted = false
        controller.onRing = { _, _, _ in ringed = true }
        controller.onPrepare = { _, _, _ in }
        controller.onAccept = { _, _, _ in accepted = true }
        controller.onConnected = { _ in }
        controller.onBeginMedia = { _, _, _ in }
        controller.onReleaseMedia = { _ in }
        client.callbacks[connection.id]?(ExternalCallState())
        try await until { ringed }
        precondition(client.activityStarts == 0, "Ringing must not send an additional Live Activity alert")
        controller.provider(provider, perform: AnswerAction(call: provider.reportedID!))
        try await until { accepted }
        precondition(client.activityStarts == 0, "Answering must not send an additional Live Activity alert")
        controller.cancelAnsweringCall()
        controller.monitorForeground(connections: [], active: false)
        print("PASS: incoming ringing and answering send no additional Live Activity alert")
    }

    @MainActor static func checkRingRecovery() async throws {
        let suite = "TincallRingRecoveryChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ExternalCallClient()
        client.recoverRinging = true
        let provider = AnswerProvider(configuration: CXProviderConfiguration())
        let controller = IncomingCallController(client: client, defaults: defaults, provider: provider)
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector, endpoint: URL(string: "https://synthetic.invalid"))
        let role = CallRole(name: "Synthetic caller")
        var cancelled = 0
        controller.canAcceptCall = { true }
        controller.onResolveRole = { _, _, _ in role }
        controller.onCancelRinging = { _ in cancelled += 1 }
        controller.monitorForeground(connections: [connection], active: true)
        try await until { client.callbacks[connection.id] != nil }
        client.callbacks[connection.id]?(ExternalCallState())
        try await until(timeout: 5) { provider.ended }
        precondition(client.eventReads == 2 && cancelled == 1,
                     "A transient status failure must not strand a ringing invitation")
        controller.monitorForeground(connections: [], active: false)
        print("PASS: ringing monitor recovers after a transient read failure and observes remote hangup")
    }

    @MainActor static func checkMissedCaller() async throws {
        let suite = "TincallMissedChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ExternalCallClient()
        let provider = AnswerProvider(configuration: CXProviderConfiguration())
        let controller = IncomingCallController(client: client, defaults: defaults, provider: provider)
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector, endpoint: URL(string: "https://synthetic.invalid"))
        let role = CallRole(name: "Synthetic caller")
        var ended = 0
        controller.canAcceptCall = { true }
        controller.onResolveRole = { _, _, _ in role }
        controller.onEnd = { id, caller, source in
            precondition(id == provider.reportedID && caller?.id == role.id && caller?.displayName == role.displayName)
            precondition(source.id == connection.id)
            ended += 1
        }
        controller.monitorForeground(connections: [connection], active: true)
        try await until { client.callbacks[connection.id] != nil }
        for index in 0..<3 {
            provider.reportedID = nil
            client.callbacks[connection.id]?(ExternalCallState())
            try await until { provider.reportedID != nil }
            // Let the asynchronous report completion install its ring monitor first.
            await Task.yield()
            let action = CXEndCallAction(call: provider.reportedID!)
            if index == 0 { controller.provider(provider, perform: action) }
            else if index == 1 { controller.provider(provider, timedOutPerforming: action) }
            else { controller.providerDidReset(provider) }
            try await until { ended == index + 1 }
        }
        controller.monitorForeground(connections: [], active: false)
        print("PASS: declined, timed-out and reset invitations retain caller identity after removal")
    }

    @MainActor static func checkOutgoing() async throws {
        for scenario in ["connected", "cancelled", "rejected", "media-failed", "cancel-during-media", "system-ended", "reset"] {
            let suite = "TincallOutgoingChecks-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let provider = AnswerProvider(configuration: CXProviderConfiguration())
            let system = AnswerCallController()
            let controller = IncomingCallController(defaults: defaults, provider: provider, callController: system)
            let callID = UUID()
            let role = CallRole(name: "Synthetic outgoing")
            var start: CXStartCallAction?
            var end: CXEndCallAction?
            var begins = 0, releases = 0, hangups = 0
            var mediaWaiter: CheckedContinuation<Void, Never>?
            controller.onEndOutgoing = { id in precondition(id == callID); hangups += 1 }
            if scenario == "rejected" { system.failure = URLError(.cannotConnectToHost) }
            system.onRequest = { transaction in
                if let action = transaction.actions.first as? CXStartCallAction { start = action }
                else if let action = transaction.actions.first as? CXEndCallAction {
                    precondition(begins == 1 && provider.connected)
                    end = action
                    controller.provider(provider, perform: action)
                } else { preconditionFailure("Unexpected system transaction") }
            }
            let task = Task {
                try await controller.startOutgoingCall(callID: callID, role: role, beginMedia: {
                    begins += 1
                    if scenario == "cancel-during-media" { await withCheckedContinuation { mediaWaiter = $0 } }
                    if scenario == "media-failed" { throw URLError(.cannotOpenFile) }
                }, releaseMedia: { releases += 1 })
            }
            if scenario != "rejected" {
                try await until { start != nil }
                precondition(begins == 0, "Do not start recording before system audio activation")
                if scenario == "cancelled" { task.cancel() }
                else {
                    controller.provider(provider, perform: start!)
                    precondition(provider.startedConnecting && !provider.connected && begins == 0)
                    if scenario == "system-ended" {
                        controller.provider(provider, perform: CXEndCallAction(call: callID))
                    } else if scenario == "reset" {
                        controller.providerDidReset(provider)
                    } else {
                        controller.provider(provider, didActivate: AVAudioSession.sharedInstance())
                        if scenario == "cancel-during-media" {
                            try await until { mediaWaiter != nil }
                            task.cancel()
                            mediaWaiter?.resume()
                        }
                        if scenario == "connected" {
                            try await until { end != nil }
                            precondition(releases == 0 && hangups == 0)
                            controller.systemCallDidEnd(callID)
                            await Task.yield()
                            precondition(releases == 0, "An end event alone must not release system audio")
                            controller.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
                        }
                    }
                }
            }
            do {
                try await task.value
                precondition(scenario == "connected" && releases == 1 && hangups == 0)
            } catch {
                precondition(scenario != "connected" && releases == 0)
                precondition((scenario != "system-ended" && scenario != "reset") || hangups == 1)
            }
            if scenario == "cancelled" || scenario == "rejected" || scenario == "system-ended" || scenario == "reset" {
                precondition(begins == 0 && !provider.connected)
            }
        }
        print("PASS: outgoing call registration, activation-before-recording, independent handoff, cancellation, rejection and media failure")
    }

    @MainActor static func checkAnswer() async throws {
        for (initialActive, finalActive, missingActivity, pushFailure) in [(false, false, true, false), (true, true, true, false), (false, true, true, false), (true, false, true, false), (false, false, false, false), (false, false, true, true)] {
            let suite = "TincallAnswerChecks-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let client = ExternalCallClient()
            let provider = AnswerProvider(configuration: CXProviderConfiguration())
            let systemController = AnswerCallController()
            let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector,
                                               endpoint: URL(string: "https://synthetic.invalid"))
            var role = CallRole(name: "")
            role.linkedContact = LinkedContact(identifier: "synthetic-linked", name: "Synthetic linked caller")
            var settings = IncomingCallConfiguration()
            settings.enabled = true
            settings.bindings = [IncomingDeviceBinding(connectionID: connection.id, connection: connection)]
            defaults.set(try JSONEncoder().encode(settings), forKey: "tincall.incoming.configuration")
            let controller = IncomingCallController(client: client, defaults: defaults, provider: provider, callController: systemController)
            await controller.restore(with: [connection])
            controller.onNeedsRemoteActivity = { _ in missingActivity }
            var acceptWaiter: CheckedContinuation<Void, Never>?
            var microphoneWaiter: CheckedContinuation<Void, Never>?
            var handoffWaiter: CheckedContinuation<Void, Never>?
            var presentationWaiter: CheckedContinuation<Void, Never>?
            var accepted = false, microphoneReady = false, audioReleased = false, callEnded = false
            var preparations = 0, mediaStarts = 0, mediaResumes = 0, releaseRequests = 0, cancellations = 0
            controller.canAcceptCall = { true }
            controller.onResolveRole = { _, _, _ in role }
            controller.onPrepare = { _, _, _ in }
            controller.onConnected = { _ in precondition(accepted && mediaResumes == 1) }
            controller.onAccept = { _, _, _ in
                preparations += 1
                await withCheckedContinuation { acceptWaiter = $0 }
                accepted = true
            }
            controller.onPreparePresentation = { _, _, _ in
                precondition(accepted && audioReleased && callEnded && microphoneReady && mediaResumes == 1,
                             "Present the connected activity only after media readiness and actual system release")
                await withCheckedContinuation { presentationWaiter = $0 }
            }
            systemController.onRequest = { transaction in
                precondition(microphoneReady,
                             "Do not relinquish the background recording grant before the microphone has started")
                releaseRequests += 1
                for action in transaction.actions {
                    if let end = action as? CXEndCallAction { controller.provider(provider, perform: end) }
                }
                provider.ended = true
            }
            controller.onBeginMedia = { _, _, _ in
                precondition(!audioReleased && !callEnded,
                             "Acquire background recording while CallKit still grants audio")
                mediaStarts += 1
                await withCheckedContinuation { microphoneWaiter = $0 }
                microphoneReady = true
            }
            controller.onReleaseMedia = { resumedID in
                precondition(resumedID == provider.reportedID && audioReleased && callEnded,
                             "Reacquire independent audio after both system release callbacks")
                mediaResumes += 1
                await withCheckedContinuation { handoffWaiter = $0 }
            }
            controller.onEnd = { _, endedRole, source in
                precondition(endedRole?.id == role.id && source.id == connection.id)
                cancellations += 1
            }
            controller.setAppActive(initialActive)
            controller.monitorForeground(connections: [connection], active: true)
            try await until { client.callbacks[connection.id] != nil }
            client.callbacks[connection.id]?(ExternalCallState())
            try await until { provider.reportedID != nil }
            let id = provider.reportedID!
            controller.updateActivityStartToken(Data([1]))
            await controller.registerDeviceToken(Data([2])).value
            let action = AnswerAction(call: id)
            action.onFulfill = {
                precondition(controller.answeringCall?.id == id,
                             "Publish the app destination before fulfilling the answer")
            }
            controller.provider(provider, perform: action)
            precondition(action.answered)
            try await until { acceptWaiter != nil }
            controller.setAppActive(finalActive)
            controller.provider(provider, didActivate: AVAudioSession.sharedInstance())
            await Task.yield()
            precondition(releaseRequests == 0)
            try await until { microphoneWaiter != nil }
            precondition(!accepted && releaseRequests == 0, "Prepare microphone while remote acceptance remains pending")
            if initialActive {
                acceptWaiter?.resume(); acceptWaiter = nil
                try await until { accepted }
            }
            let duplicate = AnswerAction(call: id)
            controller.provider(provider, perform: duplicate)
            precondition(duplicate.answered && preparations == 1 && mediaStarts == 1)
            microphoneWaiter?.resume(); microphoneWaiter = nil
            try await until { releaseRequests == 1 }
            if initialActive {
                audioReleased = true
                controller.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
                precondition(presentationWaiter == nil)
                callEnded = true
                controller.systemCallDidEnd(id)
            } else {
                callEnded = true
                controller.systemCallDidEnd(id)
                precondition(presentationWaiter == nil)
                audioReleased = true
                controller.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
            }
            try await until { handoffWaiter != nil }
            precondition(presentationWaiter == nil, "An in-flight audio handoff is not yet a connected activity")
            handoffWaiter?.resume(); handoffWaiter = nil
            await Task.yield()
            if !accepted {
                precondition(presentationWaiter == nil, "Media handoff must not mark remote acceptance complete")
                acceptWaiter?.resume(); acceptWaiter = nil
            }
            try await until { presentationWaiter != nil }
            precondition(client.activityStarts == 0, "No remote activity before connected presentation is ready")
            client.fails = pushFailure
            presentationWaiter?.resume(); presentationWaiter = nil
            try await until { controller.answeringCall == nil }
            precondition(client.activityStarts == ((!finalActive && missingActivity) ? 1 : 0),
                         "Push only when connected in background with no existing activity")
            precondition(client.activityNames.allSatisfy { $0 == role.displayName },
                         "The background card must use the linked display name even when the manual name is empty")
            client.fails = false
            precondition(cancellations == 0 && controller.errorMessage == nil)
            controller.onAccept = { _, _, _ in
                preconditionFailure("Immediate cancellation must not start a late answer")
            }
            provider.reportedID = nil
            client.callbacks[connection.id]?(ExternalCallState())
            try await until { provider.reportedID != nil }
            controller.provider(provider, perform: AnswerAction(call: provider.reportedID!))
            controller.cancelAnsweringCall()
            try await until { cancellations == 1 }
            var localPreparationWaiter: CheckedContinuation<Void, Never>?
            controller.onPrepare = { _, _, _ in
                await withCheckedContinuation { localPreparationWaiter = $0 }
            }
            provider.reportedID = nil
            client.callbacks[connection.id]?(ExternalCallState())
            try await until { provider.reportedID != nil }
            controller.provider(provider, perform: AnswerAction(call: provider.reportedID!))
            try await until { localPreparationWaiter != nil }
            controller.cancelAnsweringCall()
            try await until { cancellations == 2 }
            localPreparationWaiter?.resume()
            try await Task.sleep(for: .milliseconds(20))
            precondition(cancellations == 2, "Cancellation during local preparation must not start acceptance or end twice")
            controller.monitorForeground(connections: [], active: false)
        }
        print("PASS: real microphone preparation and system release do not wait for remote acceptance; connected presentation waits for cloud and media; foreground transitions, duplicate answers and cancellation")
    }

    @MainActor static func checkBindings() async throws {
        let first = ConnectionProfile(name: "First", provider: .genericConnector, endpoint: URL(string: "https://first.invalid"))
        let second = ConnectionProfile(name: "Second", provider: .genericConnector, endpoint: URL(string: "https://second.invalid"))
        let oldDevice = UUID(), oldRemoval = UUID()
        let legacyData = try JSONSerialization.data(withJSONObject: ["enabled": true, "environment": "sandbox",
            "connectionID": first.id.uuidString, "deviceID": oldDevice.uuidString, "pendingRemovalID": oldRemoval.uuidString])
        let migrated = try JSONDecoder().decode(IncomingCallConfiguration.self, from: legacyData)
        precondition(migrated.bindings.count == 1 && migrated.bindings[0].deviceID == oldDevice && migrated.bindings[0].pendingRemovalID == oldRemoval)
        precondition(migrated.binding(for: oldDevice) == nil, "Unbinding devices must not accept pushes")
        let roundTrip = try JSONDecoder().decode(IncomingCallConfiguration.self, from: JSONEncoder().encode(migrated))
        precondition(roundTrip.bindings == migrated.bindings)
        print("PASS: legacy binding migration retains device ID and pending removal request")

        let suite = "TincallBindingChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = IncomingCallConfiguration()
        settings.enabled = true
        settings.bindings = [IncomingDeviceBinding(connectionID: first.id, deviceID: oldDevice, connection: first),
                             IncomingDeviceBinding(connectionID: second.id, connection: second)]
        precondition(settings.bindings[0].deviceID != settings.bindings[1].deviceID)
        defaults.set(try JSONEncoder().encode(settings), forKey: "tincall.incoming.configuration")
        let client = ExternalCallClient()
        let controller = IncomingCallController(client: client, defaults: defaults)
        // Simulator restore loads persisted production configuration; PushKit remains unavailable.
        await controller.restore(with: [first, second])
        precondition(controller.connectionForPush(deviceID: oldDevice)?.id == first.id)
        precondition(controller.connectionForPush(deviceID: settings.bindings[1].deviceID)?.id == second.id)
        precondition(controller.connectionForPush(deviceID: nil) == nil && controller.connectionForPush(deviceID: UUID()) == nil)
        client.registrationFailure = first.id
        await controller.registerDeviceToken(Data([1, 2])).value
        precondition(client.registrations.count == 2 && client.registrations.allSatisfy { $0.token == "0102" })
        precondition(!controller.isRegistered(first.id) && controller.isRegistered(second.id) && controller.state == .failed)
        controller.monitorForeground(connections: [first, second], active: true)
        try await until { client.waiters[first.id] != nil }
        precondition(client.waiters[second.id] == nil && client.streams == 1,
                     "A service with registered system push must not also open a Realtime subscription")
        client.registrationFailure = nil
        await controller.registerDeviceToken(Data([3, 4])).value
        precondition(controller.state == .registered)
        controller.monitorForeground(connections: [first, second], active: true)
        try await until { client.cancellations == 1 }
        precondition(client.streams == 1 && controller.foregroundErrorMessage == nil,
                     "Finishing push registration must stop the old foreground subscription")
        precondition(client.registrations[0].device == client.registrations[2].device && client.registrations[1].device == client.registrations[3].device)
        precondition(client.registrations.suffix(2).allSatisfy { $0.token == "0304" })
        print("PASS: per-service push routing, registration failure isolation and stable IDs on token rotation")

        client.holdRegistration = true
        let active = controller.registerDeviceToken(Data([5]))
        try await until { client.registrationWaiter != nil }
        let queued = controller.registerDeviceToken(Data([6]))
        client.removalFailure = first.id
        let disabling = Task { try await controller.disable() }
        try await until { !controller.isEnabled }
        precondition(client.removals.isEmpty, "Unbinding must wait for the in-flight registration")
        client.holdRegistration = false
        client.registrationWaiter?.resume(); client.registrationWaiter = nil
        await active.value; await queued.value
        do { try await disabling.value; preconditionFailure("Expected one failed removal") }
        catch { }
        precondition(client.registrations.count == 5, "Queued stale tokens must not register after disable")
        precondition(client.removals.count == 2 && controller.connectionIDs == [first.id] && controller.needsDeviceRemoval)
        let failedRequest = client.removals.first { $0.connection == first.id }!.request
        client.removalFailure = nil
        try await controller.disable()
        precondition(client.removals.last?.request == failedRequest && controller.connectionIDs.isEmpty && !controller.needsDeviceRemoval)
        precondition(controller.connectionForPush(deviceID: oldDevice) == nil)
        print("PASS: disable waits for registration, skips stale tokens, isolates removal failures and retries the original request")

        settings.bindings.removeLast()
        precondition(settings.binding(for: nil)?.deviceID == oldDevice, "Single legacy service remains routable")
    }
}
