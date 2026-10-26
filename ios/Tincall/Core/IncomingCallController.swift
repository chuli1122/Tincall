// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFAudio
import CallKit
import Foundation
import Observation
import PushKit
import UIKit

enum IncomingPushEnvironment: String, Codable, CaseIterable, Sendable { case sandbox, production }
enum IncomingRegistrationState: String, Sendable { case disabled, registering, registered, failed }

struct IncomingDeviceBinding: Codable, Equatable, Identifiable {
    var connectionID: UUID
    var deviceID = UUID()
    var pendingRemovalID: UUID?
    var connection: ConnectionProfile?
    var id: UUID { connectionID }
}

struct IncomingCallConfiguration: Codable {
    var enabled = false
    var environment: IncomingPushEnvironment = .sandbox
    var bindings: [IncomingDeviceBinding] = []

    private enum CodingKeys: String, CodingKey {
        case enabled, environment, bindings, deviceID, connectionID, pendingRemovalID
    }

    init() { }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        environment = try values.decodeIfPresent(IncomingPushEnvironment.self, forKey: .environment) ?? .sandbox
        if let saved = try values.decodeIfPresent([IncomingDeviceBinding].self, forKey: .bindings) {
            bindings = saved
        } else if let id = try values.decodeIfPresent(UUID.self, forKey: .connectionID) {
            bindings = [IncomingDeviceBinding(connectionID: id,
                deviceID: try values.decodeIfPresent(UUID.self, forKey: .deviceID) ?? UUID(),
                pendingRemovalID: try values.decodeIfPresent(UUID.self, forKey: .pendingRemovalID))]
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(environment, forKey: .environment)
        try values.encode(bindings, forKey: .bindings)
    }

    func binding(for deviceID: UUID?) -> IncomingDeviceBinding? {
        guard enabled else { return nil }
        let active = bindings.filter { $0.pendingRemovalID == nil }
        if let deviceID { return active.first { $0.deviceID == deviceID } }
        // Old senders can only be resolved safely while exactly one service is bound.
        return active.count == 1 ? active.first : nil
    }
}

/// VoiceService owns media. Acquire recording under CallKit's background grant
/// before handing the connected call to independent audio.
@MainActor @Observable
final class IncomingCallController: NSObject, @preconcurrency PKPushRegistryDelegate,
    @preconcurrency CXProviderDelegate, @preconcurrency CXCallObserverDelegate {
    struct AnsweringCall {
        let id: UUID
        let role: CallRole
    }
    private(set) var answeringCall: AnsweringCall?
    private(set) var registrationStates: [UUID: IncomingRegistrationState] = [:]
    private(set) var registrationErrors: [UUID: String] = [:]
    private(set) var errorMessage: String?
    private(set) var foregroundErrorMessage: String?
    private(set) var connectionRemovalNotice: String?
    private(set) var environment: IncomingPushEnvironment = .sandbox

    @ObservationIgnored var onResolveRole: ((String, CallMode, UUID) -> CallRole?)?
    @ObservationIgnored var canAcceptCall: (() -> Bool)?
    @ObservationIgnored var canUseConnections: ((CallRole, ConnectionProfile) -> Bool)?
    @ObservationIgnored var onValidateCallAccess: (() async throws -> Void)?
    @ObservationIgnored var onRing: ((UUID, CallRole, ConnectionProfile) throws -> Void)?
    @ObservationIgnored var onIncoming: ((UUID, CallRole) -> Void)?
    /// Publishes the app-owned destination before CallKit answers.
    @ObservationIgnored var onAnswering: ((UUID, CallRole) -> Void)?
    /// Restores the connected-call presentation after CallKit releases the call.
    @ObservationIgnored var onPreparePresentation: (@MainActor (UUID, CallRole, ConnectionProfile) async throws -> Void)?
    @ObservationIgnored var onNeedsRemoteActivity: ((UUID) -> Bool)?
    @ObservationIgnored var onCancelRinging: ((UUID) -> Void)?
    @ObservationIgnored var onPrepare: (@MainActor (UUID, CallRole, ConnectionProfile) async throws -> Void)?
    @ObservationIgnored var onAccept: (@MainActor (UUID, CallRole, ConnectionProfile) async throws -> Void)?
    @ObservationIgnored var onBeginMedia: ((UUID, CallRole, ConnectionProfile) async throws -> Void)?
    @ObservationIgnored var onReleaseMedia: ((UUID) async throws -> Void)?
    @ObservationIgnored var onConnected: (@MainActor (UUID) async throws -> Void)?
    @ObservationIgnored var onSetMuted: ((UUID, Bool) async throws -> Void)?
    @ObservationIgnored var onEnd: ((UUID, CallRole?, ConnectionProfile) async -> Void)?
    @ObservationIgnored var onEndOutgoing: ((UUID) -> Void)?
    @ObservationIgnored private let client: ExternalCallClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settingsKey = "tincall.incoming.configuration"
    @ObservationIgnored private let provider: CXProvider
    @ObservationIgnored private let callController: CXCallController
    @ObservationIgnored private let observer = CXCallObserver()
    @ObservationIgnored private var registry: PKPushRegistry?
    @ObservationIgnored private var connections: [UUID: ConnectionProfile] = [:]
    @ObservationIgnored private var configuredConnections: [ConnectionProfile] = []
    private var settings: IncomingCallConfiguration
    @ObservationIgnored private var registrationID = UUID()
    @ObservationIgnored private var registrationTimeout: Task<Void, Never>?
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var registrationWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var activityStartToken: String?
    @ObservationIgnored private var activityPushConnections: Set<UUID> = []
    @ObservationIgnored private var invitations: [UUID: Invitation] = [:]
    @ObservationIgnored private var systemAudioActive = false
    @ObservationIgnored private var appIsActive = false
    @ObservationIgnored private var reportedCallIDs: [UUID] = []
    @ObservationIgnored private var foregroundTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var foregroundErrors: [UUID: String] = [:]
    @ObservationIgnored private var foregroundConnections: [ConnectionProfile] = []

    private struct Invitation {
        var role: CallRole?
        let connection: ConnectionProfile?
        var isAnswering = false
        var isAccepting = false
        var isHandingOff = false
        var systemCallEnded = false
        var releaseWaiter: CheckedContinuation<Void, Error>?
        var releaseTimeout: Task<Void, Never>?
        var activationWaiter: CheckedContinuation<Void, Error>?
        var activationTimeout: Task<Void, Never>?
        var ringMonitor: Task<Void, Never>?
        var mediaStarted = false
        var isOutgoing = false
        var startWaiter: CheckedContinuation<Void, Error>?
        var startTimeout: Task<Void, Never>?
    }

    @MainActor private final class PushCompletion {
        private var completion: (() -> Void)?
        init(_ completion: @escaping () -> Void) { self.completion = completion }
        func call() { let value = completion; completion = nil; value?() }
    }

    init(client: ExternalCallClient = ExternalCallClient(), defaults: UserDefaults = .standard,
         provider: CXProvider? = nil, callController: CXCallController = CXCallController()) {
        self.client = client
        self.defaults = defaults
        self.callController = callController
        if let data = defaults.data(forKey: "tincall.incoming.configuration"),
           let saved = try? JSONDecoder().decode(IncomingCallConfiguration.self, from: data) { settings = saved }
        else { settings = IncomingCallConfiguration() }
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic, .phoneNumber, .emailAddress]
        configuration.includesCallsInRecents = true
        self.provider = provider ?? CXProvider(configuration: configuration)
        super.init()
        self.provider.setDelegate(self, queue: .main)
        observer.setDelegate(self, queue: .main)
        environment = settings.environment
        for binding in settings.bindings {
            if let connection = binding.connection { DataSharingConsent.rememberDeviceBinding(connection, defaults: defaults) }
        }
    }

    var isEnabled: Bool { settings.enabled }
    var connectionIDs: Set<UUID> { Set(settings.bindings.map(\.connectionID)) }
    var needsDeviceRemoval: Bool { settings.bindings.contains { $0.pendingRemovalID != nil } }
    var state: IncomingRegistrationState {
        guard isEnabled else { return .disabled }
        if registrationStates.values.contains(.registering) { return .registering }
        if settings.bindings.isEmpty || settings.bindings.contains(where: { registrationStates[$0.connectionID] != .registered }) { return .failed }
        return .registered
    }
    func isRegistered(_ id: UUID) -> Bool { isEnabled && registrationStates[id] == .registered }

    func updateConnections(_ values: [ConnectionProfile]) {
        let eligible = values.filter { $0.provider == .genericConnector }
        guard configuredConnections != eligible else { return }
        configuredConnections = eligible
        Task { await restore(with: eligible) }
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if answeringCall != nil {
            CallAudioDiagnostics.record(.independentAudioStage, flag: active, phase: "incoming_app_active")
        }
    }

    func refreshCallAccess() {
        guard settings.enabled else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.onValidateCallAccess?() }
            catch {
                self.registry?.desiredPushTypes = []
                let message = self.safeMessage(error)
                for binding in self.settings.bindings where binding.pendingRemovalID == nil {
                    self.registrationStates[binding.connectionID] = .failed
                    self.registrationErrors[binding.connectionID] = message
                }
                self.report(error)
                return
            }
            await self.restore(with: self.configuredConnections)
        }
    }

    func updateActivityStartToken(_ token: Data) {
        let text = token.map { String(format: "%02x", $0) }.joined()
        guard text != activityStartToken else { return }
        activityStartToken = text
        if settings.enabled, let voip = registry?.pushToken(for: .voIP) { registerDeviceToken(voip) }
    }

    /// Re-apply contact-backed caller details to a ringing system call after
    /// the asynchronous Contacts refresh completes.
    func refreshReportedCallDetails(roles: [CallRole]) {
        for (callID, invitation) in invitations {
            guard !invitation.isAnswering, let role = invitation.role,
                  let refreshed = roles.first(where: { $0.id == role.id }) else { continue }
            invitations[callID]?.role = refreshed
            provider.reportCall(with: callID, updated: Self.callUpdate(for: refreshed))
        }
    }

    func startCallActivity(callID: UUID, contactID: UUID, connection: ConnectionProfile) async throws {
        // A remote activity start includes a system alert. Never send it while
        // CallKit is still ringing; the user must have answered first.
        guard let invitation = invitations[callID], invitation.isAnswering, !invitation.isAccepting,
              invitation.mediaStarted, invitation.systemCallEnded, !systemAudioActive, !appIsActive else { throw CancellationError() }
        guard settings.enabled, activityPushConnections.contains(connection.id),
              let binding = settings.bindings.first(where: { $0.connectionID == connection.id && $0.pendingRemovalID == nil }) else {
            throw TincallError(message: String(localized: "后台通话卡片尚未完成推送绑定，请更新云端服务"))
        }
        try await client.startCallActivity(connection: connection, callID: callID, deviceID: binding.deviceID,
                                           avatarContactID: contactID, displayName: invitation.role?.displayName ?? "Tincall")
    }

    private enum Somewhere {
        static let word = "somewhere"
    }

    func endAcceptedCall(_ id: UUID) {
        guard invitations[id]?.mediaStarted == true || invitations[id]?.isOutgoing == true else { return }
        finishInvitation(id, error: nil)
    }

    /// Register a real outgoing call, acquire media under the system grant, then
    /// use the same independent-audio handoff as incoming calls. System Recents
    /// describes this system-managed segment; the app records the full duration.
    func startOutgoingCall(callID: UUID, role: CallRole,
                           beginMedia: @MainActor () async throws -> Void,
                           releaseMedia: @MainActor () async throws -> Void) async throws {
        guard invitations.isEmpty, !Task.isCancelled else { throw CancellationError() }
        invitations[callID] = Invitation(role: role, connection: nil, isOutgoing: true)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Outgoing call handoff")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                    invitations[callID]?.startWaiter = waiter
                    invitations[callID]?.startTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        self?.finishInvitation(callID, error: TincallError(message: String(localized: "系统通话操作超时")))
                    }
                    let action = CXStartCallAction(call: callID, handle: SystemCallContact.handle(for: role))
                    action.contactIdentifier = role.linkedContact?.identifier
                    callController.request(CXTransaction(action: action)) { [weak self] error in
                        guard let error else { return }
                        Task { @MainActor in self?.finishInvitation(callID, error: error) }
                    }
                }
                try Task.checkCancellation()
                try await waitForSystemAudioActivation(callID: callID)
                try await beginMedia()
                guard invitations[callID] != nil, !Task.isCancelled else { throw CancellationError() }
                invitations[callID]?.mediaStarted = true
                provider.reportOutgoingCall(with: callID, connectedAt: Date())
                try await requestSystemAudioRelease(callID: callID)
                try await waitForSystemAudioRelease(callID: callID)
                try Task.checkCancellation()
                try await releaseMedia()
                guard invitations[callID] != nil, !Task.isCancelled else { throw CancellationError() }
                invitations.removeValue(forKey: callID)
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishInvitation(callID, error: CancellationError()) }
            }
        } catch {
            finishInvitation(callID, error: error)
            throw error
        }
    }

    func cancelAnsweringCall() {
        guard let call = answeringCall, let connection = invitations[call.id]?.connection else { return }
        finishInvitation(call.id, error: nil)
        Task { await onEnd?(call.id, call.role, connection) }
    }

    /// PushKit delivers in foreground too. Only services without registered push
    /// need a foreground stream and its recovery snapshot on reconnect.
    func monitorForeground(connections: [ConnectionProfile], active: Bool) {
        let connections = active ? connections.filter { $0.provider == .genericConnector && !isRegistered($0.id) } : []
        guard foregroundConnections != connections else { return }
        for task in foregroundTasks.values { task.cancel() }
        foregroundTasks.removeAll()
        foregroundConnections = connections
        foregroundErrors.removeAll()
        foregroundErrorMessage = nil
        for connection in connections {
            foregroundTasks[connection.id] = Task { [weak self, client] in
                var delay = 1
                while !Task.isCancelled {
                    do {
                        try await client.incomingCalls(connection: connection) { [weak self] call in
                            guard !Task.isCancelled, let self else { return }
                            delay = 1
                            self.foregroundErrors.removeValue(forKey: connection.id)
                            self.foregroundErrorMessage = self.foregroundErrors.values.first
                            guard let call, call.status == "ringing", !self.reportedCallIDs.contains(call.id),
                                  self.invitations.isEmpty, self.canAcceptCall?() == true else { return }
                            let mode = call.source == "independent" ? CallMode.standalone : CallMode(rawValue: call.source)
                            if let mode, let role = self.onResolveRole?(call.contact_id, mode, connection.id) {
                                self.reportIncoming(callID: call.id, role: role, connection: connection, allowed: true) { }
                            }
                        }
                        try Task.checkCancellation()
                    } catch {
                        guard !Task.isCancelled, let self else { return }
                        self.foregroundErrors[connection.id] = (error as? TincallError)?.message
                            ?? String(localized: "来电订阅连接中断，正在重连")
                        self.foregroundErrorMessage = self.foregroundErrors.values.first
                    }
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    delay = min(delay * 2, 60)
                }
            }
        }
    }

    /// Restore every saved binding and add configured services when background calls are enabled.
    func restore(with values: [ConnectionProfile]) async {
        let eligible = values.filter { $0.provider == .genericConnector }
        configuredConnections = eligible
        connections = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        if needsDeviceRemoval && !settings.enabled {
            do { try await disable() }
            catch { report(error) }
        } else if settings.enabled {
            do { try await enable(connections: eligible, environment: settings.environment) }
            catch { if !(error is CancellationError) { report(error) } }
        }
    }

    func enable(connections values: [ConnectionProfile], environment: IncomingPushEnvironment) async throws {
        try await onValidateCallAccess?()
        if needsDeviceRemoval && !settings.enabled { try await disable() }
        // Retain pending removals from saved settings without re-registering them.
        let pendingIDs = Set(settings.bindings.filter { $0.pendingRemovalID != nil }.map(\.connectionID))
        let eligible = values.filter { $0.provider == .genericConnector && !pendingIDs.contains($0.id) }
        if eligible.isEmpty && !pendingIDs.isEmpty { registry?.desiredPushTypes = []; return }
        guard !eligible.isEmpty else { throw TincallError(message: String(localized: "请先添加 Tincall 云端连接")) }
        guard Self.canRegisterPush else { throw TincallError(message: String(localized: "VoIP 来电需真机及支持推送的签名，模拟器不能完成设备绑定")) }
        guard onAccept != nil, onBeginMedia != nil, onEnd != nil, onResolveRole != nil else {
            throw TincallError(message: String(localized: "来电接听回调尚未接线"))
        }
        registrationWaiter?.resume(throwing: CancellationError())
        registrationWaiter = nil
        registrationTimeout?.cancel()
        registrationID = UUID()
        configuredConnections = eligible
        for connection in eligible {
            connections[connection.id] = connection
            if let index = settings.bindings.firstIndex(where: { $0.connectionID == connection.id }) {
                if settings.bindings[index].connection == nil { settings.bindings[index].connection = connection }
            } else {
                settings.bindings.append(IncomingDeviceBinding(connectionID: connection.id, connection: connection))
            }
        }
        self.environment = environment
        settings.enabled = true
        settings.environment = environment
        try saveSettings()
        registrationStates = Dictionary(uniqueKeysWithValues: settings.bindings.map { ($0.connectionID, $0.pendingRemovalID == nil ? .registering : .disabled) })
        activityPushConnections = []
        registrationErrors = [:]
        errorMessage = nil
        let identity = registrationID
        try await withCheckedThrowingContinuation { continuation in
            registrationWaiter = continuation
            if registry == nil {
                let registry = PKPushRegistry(queue: .main)
                registry.delegate = self
                self.registry = registry
            }
            registry?.desiredPushTypes = [.voIP]
            if let token = registry?.pushToken(for: .voIP) { registerDeviceToken(token) }
            registrationTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.registrationID == identity, self.registrationWaiter != nil else { return }
                self.finishRegistration(error: TincallError(message: String(localized: "系统尚未完成 VoIP 设备绑定，请检查真机、推送签名与连接端配置")))
            }
        }
    }

    /// Local deletion is immediate; remote cleanup runs after any in-flight registration.
    func removeConnectionBinding(_ id: UUID) throws {
        guard let binding = settings.bindings.first(where: { $0.connectionID == id }) else { return }
        let connection = binding.connection ?? connections[id]
        let previous = settings
        settings.bindings.removeAll { $0.connectionID == id }
        if settings.bindings.isEmpty { settings.enabled = false }
        do { try saveSettings() }
        catch { settings = previous; throw error }
        if !settings.enabled {
            registry?.desiredPushTypes = []
            finishRegistration(error: nil)
        }
        configuredConnections.removeAll { $0.id == id }
        connections.removeValue(forKey: id)
        registrationStates.removeValue(forKey: id)
        registrationErrors.removeValue(forKey: id)
        activityPushConnections.remove(id)
        errorMessage = nil
        connectionRemovalNotice = nil
        let notice = String(localized: "远端设备绑定未能自动清除，可在服务端另行移除。本机连接的删除不受影响。")
        do {
            guard let connection else { throw TincallError(message: notice) }
            let removal = try client.prepareDeviceRemoval(connection: connection, deviceID: binding.deviceID,
                                                         requestID: binding.pendingRemovalID ?? UUID())
            let registration = registrationTask
            Task { [weak self] in
                await registration?.value
                do { try await removal() }
                catch { self?.connectionRemovalNotice = notice }
            }
        } catch { connectionRemovalNotice = notice }
    }

    func disable() async throws {
        registrationID = UUID()
        registrationTimeout?.cancel()
        registrationWaiter?.resume(throwing: CancellationError())
        registrationWaiter = nil
        registry?.desiredPushTypes = []
        settings.enabled = false
        for index in settings.bindings.indices where settings.bindings[index].pendingRemovalID == nil {
            settings.bindings[index].pendingRemovalID = UUID()
        }
        try saveSettings()
        for (id, invitation) in Array(invitations) where !invitation.isHandingOff {
            finishInvitation(id, error: nil)
            if let source = invitation.connection { Task { await onEnd?(id, invitation.role, source) } }
        }
        await registrationTask?.value
        var failure: Error?
        for binding in settings.bindings {
            do {
                guard let connection = binding.connection ?? connections[binding.connectionID], let requestID = binding.pendingRemovalID else {
                    throw TincallError(message: String(localized: "原连接不可用，设备解绑待重试"))
                }
                try await client.removeDevice(connection: connection, deviceID: binding.deviceID, requestID: requestID)
                settings.bindings.removeAll { $0.connectionID == binding.connectionID }
                registrationStates.removeValue(forKey: binding.connectionID)
                registrationErrors.removeValue(forKey: binding.connectionID)
                try saveSettings()
            } catch {
                registrationErrors[binding.connectionID] = safeMessage(error)
                if failure == nil { failure = error }
            }
        }
        if let failure { report(failure); throw failure }
        errorMessage = nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP, settings.enabled else { return }
        registerDeviceToken(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP, settings.enabled else { return }
        for binding in settings.bindings { registrationStates[binding.connectionID] = .registering }
        finishRegistration(error: TincallError(message: String(localized: "系统已失效此 VoIP 令牌，请重新启用来电绑定")))
    }

    @discardableResult
    func registerDeviceToken(_ token: Data) -> Task<Void, Never> {
        let prior = registrationTask
        let identity = registrationID
        registrationTask = Task { [weak self] in
            await prior?.value
            guard let self, self.registrationID == identity, self.settings.enabled else { return }
            await self.performDeviceRegistration(token, identity: identity)
        }
        return registrationTask!
    }

    /// Fan out the same PushKit token using a distinct, persisted device ID per service.
    private func performDeviceRegistration(_ token: Data, identity: UUID) async {
        let tokenText = token.map { String(format: "%02x", $0) }.joined()
        var failure: Error?
        for binding in settings.bindings where binding.pendingRemovalID == nil {
            guard registrationID == identity, settings.enabled else { return }
            guard settings.bindings.contains(where: { $0.connectionID == binding.connectionID && $0.pendingRemovalID == nil }) else { continue }
            do {
                try await onValidateCallAccess?()
                guard settings.bindings.contains(where: { $0.connectionID == binding.connectionID && $0.pendingRemovalID == nil }) else { continue }
                guard let connection = connections[binding.connectionID],
                      binding.connection == nil || binding.connection?.endpoint == connection.endpoint else {
                    throw TincallError(message: String(localized: "来电连接已更改或不存在，请关闭后台来电并完成旧绑定解除后重试"))
                }
                let supportsActivity = try await client.registerDevice(connection: connection, deviceID: binding.deviceID,
                                                token: tokenText, environment: settings.environment.rawValue,
                                                liveActivityStartToken: activityStartToken)
                guard registrationID == identity, settings.enabled else { return }
                guard settings.bindings.contains(where: { $0.connectionID == binding.connectionID && $0.pendingRemovalID == nil }) else { continue }
                if supportsActivity { activityPushConnections.insert(binding.connectionID) }
                else { activityPushConnections.remove(binding.connectionID) }
                registrationStates[binding.connectionID] = .registered
                registrationErrors.removeValue(forKey: binding.connectionID)
            } catch {
                guard registrationID == identity, settings.enabled else { return }
                guard settings.bindings.contains(where: { $0.connectionID == binding.connectionID && $0.pendingRemovalID == nil }) else { continue }
                registrationStates[binding.connectionID] = .failed
                registrationErrors[binding.connectionID] = safeMessage(error)
                if failure == nil { failure = error }
            }
        }
        guard registrationID == identity, settings.enabled else { return }
        finishRegistration(error: failure)
    }

    private func finishRegistration(error: Error?) {
        registrationTimeout?.cancel()
        registrationTimeout = nil
        let waiter = registrationWaiter
        registrationWaiter = nil
        if let error {
            for binding in settings.bindings where registrationStates[binding.connectionID] == .registering || registrationStates[binding.connectionID] == nil {
                registrationStates[binding.connectionID] = .failed
                registrationErrors[binding.connectionID] = safeMessage(error)
            }
            waiter?.resume(throwing: error)
        } else { errorMessage = nil; waiter?.resume() }
    }

    func connectionForPush(deviceID: UUID?) -> ConnectionProfile? {
        guard let binding = settings.binding(for: deviceID), let connection = connections[binding.connectionID],
              binding.connection == nil || binding.connection?.endpoint == connection.endpoint else { return nil }
        return connection
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        let values = payload.dictionaryPayload
        let receivedID = (values["call_id"] as? String).flatMap(UUID.init(uuidString:))
        let callID = receivedID ?? UUID()
        let contactID = values["contact_id"] as? String ?? ""
        let source = values["source"] as? String
        let mode = source == "independent" ? CallMode.standalone : source.flatMap(CallMode.init(rawValue:))
        // Malformed explicit routing identifiers must never fall back to another service.
        let deviceID = (values["device_id"] as? String).flatMap(UUID.init(uuidString:))
        let connection = values["device_id"] != nil && deviceID == nil ? nil : connectionForPush(deviceID: deviceID)
        let role = connection.flatMap { connection in mode.flatMap { onResolveRole?(contactID, $0, connection.id) } }
        reportIncoming(callID: callID, role: role, connection: receivedID == nil ? nil : connection,
                       allowed: type == .voIP && receivedID != nil && settings.enabled, completion: completion)
    }

    private func reportIncoming(callID: UUID, role: CallRole?, connection: ConnectionProfile?,
                                allowed: Bool, completion: @escaping () -> Void) {
        let connectionsAllowed = role.flatMap { role in connection.map { canUseConnections?(role, $0) ?? true } } ?? false
        let mayAccept = allowed && connection != nil && role != nil && connectionsAllowed && (canAcceptCall?() ?? false)
        let update = Self.callUpdate(for: role)
        let handleType: String
        switch update.remoteHandle?.type {
        case .phoneNumber: handleType = "phoneNumber"
        case .emailAddress: handleType = "emailAddress"
        default: handleType = "generic"
        }
        NSLog("incoming_handle_type=%@", handleType)
        // Report every VoIP payload immediately, including unknown roles; never wait for a network lookup.
        let alreadyReported = reportedCallIDs.contains(callID)
        if !alreadyReported {
            reportedCallIDs.append(callID)
            if reportedCallIDs.count > 128 { reportedCallIDs.removeFirst() }
            invitations[callID] = Invitation(role: mayAccept ? role : nil, connection: connection)
        }
        let finish = PushCompletion(completion)
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            Task { @MainActor in
                finish.call()
                guard let self else { return }
                if alreadyReported {
                    // Duplicate pushes must still be reported, but cannot terminate an accepted business call.
                    if self.invitations[callID] == nil { self.provider.reportCall(with: callID, endedAt: Date(), reason: .remoteEnded) }
                    return
                }
                if error != nil || !mayAccept {
                    self.provider.reportCall(with: callID, endedAt: Date(), reason: .failed)
                    self.invitations.removeValue(forKey: callID)
                    if let connection { await self.onEnd?(callID, role, connection) }
                    if let error { self.report(error) }
                    else if role != nil && connection != nil && !connectionsAllowed {
                        self.errorMessage = String(localized: "此来电所需连接尚未授权，请打开 App 确认数据发送授权。")
                    } else { self.errorMessage = String(localized: "来电联系人未绑定或当前无法接听，已结束系统来电") }
                } else {
                    do { try await self.onValidateCallAccess?() }
                    catch {
                        self.finishInvitation(callID, error: error)
                        if let connection { await self.onEnd?(callID, role, connection) }
                        return
                    }
                    guard self.invitations[callID]?.isAnswering == false else { return }
                    if let role, let connection {
                        self.onIncoming?(callID, role)
                        do { try self.onRing?(callID, role, connection) }
                        catch { self.report(error) }
                    }
                    self.monitorRinging(callID)
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let invitation = invitations[action.callUUID], invitation.isOutgoing,
              !invitation.isAnswering, let role = invitation.role else { action.fail(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                options: [.allowBluetoothA2DP, .mixWithOthers])
        } catch {
            action.fail()
            finishInvitation(action.callUUID, error: error)
            return
        }
        invitations[action.callUUID]?.isAnswering = true
        provider.reportCall(with: action.callUUID, updated: Self.callUpdate(for: role))
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
        invitations[action.callUUID]?.startTimeout?.cancel()
        invitations[action.callUUID]?.startTimeout = nil
        let waiter = invitations[action.callUUID]?.startWaiter
        invitations[action.callUUID]?.startWaiter = nil
        waiter?.resume()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let invitation = invitations[action.callUUID], let role = invitation.role, let connection = invitation.connection,
              let onPrepare, let onAccept, let onBeginMedia, let onReleaseMedia, let onConnected else { action.fail(); return }
        guard !invitation.isAnswering else { action.fulfill(); return }
        invitations[action.callUUID]?.isAnswering = true
        invitations[action.callUUID]?.isAccepting = true
        CallAudioDiagnostics.record(.independentAudioStage, flag: appIsActive, phase: "incoming_answer_received")
        // Prepare the destination before fulfilling: iOS may show our scene as
        // soon as the system answer completes, before cloud preparation runs.
        answeringCall = AnsweringCall(id: action.callUUID, role: role)
        onAnswering?(action.callUUID, role)
        invitations[action.callUUID]?.ringMonitor?.cancel()
        invitations[action.callUUID]?.ringMonitor = nil
        // Configure before fulfilling so CallKit can activate recording. Cloud
        // confirmation must not hold the system answer action open.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                options: [.allowBluetoothA2DP, .mixWithOthers])
        } catch {
            action.fail()
            finishInvitation(action.callUUID, error: error)
            Task { await onEnd?(action.callUUID, role, connection) }
            return
        }
        action.fulfill()
        let callID = action.callUUID
        Task { [weak self] in
            guard let self, self.invitations[callID] != nil else { return }
            // Covers the short system-to-independent handoff, not the call's
            // lifetime. The active audio pipeline supplies ongoing background time.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Incoming call handoff")
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            do {
                try await onPrepare(callID, role, connection)
                guard self.invitations[callID] != nil else { throw CancellationError() }
                // The remote response may take seconds. Prepare real recording
                // concurrently, retaining CallKit until the microphone is ready.
                async let acceptance: Void = { @MainActor in
                    CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_accept_begin")
                    try await onAccept(callID, role, connection)
                    CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_accept_ready")
                }()
                try await self.waitForSystemAudioActivation(callID: callID)
                // Tincall's voice-processing input graph must acquire recording
                // while the system grants it. An output-only graph does not
                // preserve that grant after ending a locked-screen call.
                try await onBeginMedia(callID, role, connection)
                guard self.invitations[callID] != nil else { throw CancellationError() }
                self.invitations[callID]?.mediaStarted = true
                CallAudioDiagnostics.record(.independentAudioStage, flag: self.appIsActive, phase: "incoming_media_ready")
                try await self.requestSystemAudioRelease(callID: callID)
                try await self.waitForSystemAudioRelease(callID: callID)
                CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_system_audio_released")
                try await onReleaseMedia(callID)
                guard self.invitations[callID] != nil else { throw CancellationError() }
                CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_independent_media_ready")
                try await acceptance
                guard self.invitations[callID] != nil else { throw CancellationError() }
                self.invitations[callID]?.isAccepting = false
                try await onConnected(callID)
                guard self.invitations[callID] != nil else { throw CancellationError() }
                try await self.onPreparePresentation?(callID, role, connection)
                if !self.appIsActive, self.onNeedsRemoteActivity?(callID) == true {
                    do {
                        try await self.startCallActivity(callID: callID, contactID: role.id, connection: connection)
                        CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_activity_push_accepted")
                    } catch {
                        let failure = error as NSError
                        CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_activity_push_failed",
                            errorDomain: failure.domain, errorCode: failure.code)
                        // Presentation failure must never disconnect a real call.
                    }
                }
                self.invitations.removeValue(forKey: callID)
                if self.answeringCall?.id == callID { self.answeringCall = nil }
            } catch {
                let failure = error as NSError
                CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_answer_failed",
                    errorDomain: failure.domain, errorCode: failure.code)
                let needsEnd = self.invitations[callID] != nil
                self.finishInvitation(callID, error: error)
                if needsEnd { await self.onEnd?(callID, role, connection) }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let invitation = invitations[action.callUUID]
        action.fulfill()
        if invitation?.isHandingOff == true { return }
        // An end action outside handoff is a user hangup.
        finishInvitation(action.callUUID, error: nil)
        if invitation?.isOutgoing == true { onEndOutgoing?(action.callUUID) }
        if let connection = invitation?.connection { Task { await onEnd?(action.callUUID, invitation?.role, connection) } }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard invitations[action.callUUID]?.mediaStarted == true, let onSetMuted else { action.fail(); return }
        Task {
            do {
                try await onSetMuted(action.callUUID, action.isMuted)
                action.fulfill()
            } catch {
                action.fail()
                report(error)
            }
        }
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        if let callAction = action as? CXCallAction {
            let invitation = invitations[callAction.callUUID]
            finishInvitation(callAction.callUUID, error: TincallError(message: String(localized: "系统来电操作超时")))
            if invitation?.isOutgoing == true { onEndOutgoing?(callAction.callUUID) }
            if let connection = invitation?.connection { Task { await onEnd?(callAction.callUUID, invitation?.role, connection) } }
        }
        action.fail()
    }

    func providerDidReset(_ provider: CXProvider) {
        for (id, invitation) in invitations {
            finishInvitation(id, error: TincallError(message: String(localized: "系统来电服务已重置")))
            if invitation.isOutgoing { onEndOutgoing?(id) }
            if let connection = invitation.connection { Task { await onEnd?(id, invitation.role, connection) } }
        }
        systemAudioActive = false
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        systemAudioActive = true
        if answeringCall != nil {
            CallAudioDiagnostics.record(.independentAudioStage, phase: "incoming_system_audio_activated")
        }
        for id in Array(invitations.keys) {
            invitations[id]?.activationTimeout?.cancel()
            invitations[id]?.activationTimeout = nil
            let waiter = invitations[id]?.activationWaiter
            invitations[id]?.activationWaiter = nil
            waiter?.resume()
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        systemAudioActive = false
        for id in Array(invitations.keys) { completeHandoffIfReleased(id) }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded { systemCallDidEnd(call.uuid) }
    }

    func systemCallDidEnd(_ id: UUID) {
        guard let invitation = invitations[id] else { return }
        invitations[id]?.systemCallEnded = true
        if invitation.isOutgoing, !invitation.isHandingOff {
            finishInvitation(id, error: CancellationError())
            onEndOutgoing?(id)
            return
        }
        completeHandoffIfReleased(id)
    }

    private func requestSystemAudioRelease(callID: UUID) async throws {
        guard invitations[callID] != nil else { throw CancellationError() }
        invitations[callID]?.isHandingOff = true
        CallAudioDiagnostics.record(.independentAudioStage, flag: appIsActive, phase: "incoming_system_release_requested")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(CXTransaction(action: CXEndCallAction(call: callID))) { [weak self] error in
                Task { @MainActor in
                    if error != nil {
                        // Keep the provider report as a fallback for devices where
                        // the transaction is unavailable.
                        self?.provider.reportCall(with: callID, endedAt: Date(), reason: .remoteEnded)
                        continuation.resume()
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func waitForSystemAudioActivation(callID: UUID) async throws {
        guard invitations[callID] != nil else { throw CancellationError() }
        if systemAudioActive { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            invitations[callID]?.activationWaiter = continuation
            invitations[callID]?.activationTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.finishInvitation(callID, error: TincallError(message: String(localized: "系统未激活来电音频，请重新拨号")))
            }
        }
    }

    private func waitForSystemAudioRelease(callID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard invitations[callID] != nil else { continuation.resume(throwing: CancellationError()); return }
            invitations[callID]?.releaseWaiter = continuation
            invitations[callID]?.releaseTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.invitations[callID]?.releaseWaiter != nil else { return }
                self.finishInvitation(callID, error: TincallError(message: String(localized: "系统尚未释放来电音频，未启动独立收音，请重新拨号")))
            }
            completeHandoffIfReleased(callID)
        }
    }

    private func completeHandoffIfReleased(_ id: UUID) {
        guard let invitation = invitations[id], invitation.isHandingOff, invitation.systemCallEnded,
              !systemAudioActive, let waiter = invitation.releaseWaiter else { return }
        invitations[id]?.releaseWaiter = nil
        invitations[id]?.releaseTimeout?.cancel()
        invitations[id]?.releaseTimeout = nil
        waiter.resume()
    }

    private func finishInvitation(_ id: UUID, error: Error?) {
        guard let invitation = invitations.removeValue(forKey: id) else { return }
        if answeringCall?.id == id { answeringCall = nil }
        if !invitation.isOutgoing { onCancelRinging?(id) }
        invitation.startTimeout?.cancel()
        invitation.startWaiter?.resume(throwing: error ?? CancellationError())
        invitation.releaseTimeout?.cancel()
        invitation.activationTimeout?.cancel()
        invitation.activationWaiter?.resume(throwing: error ?? CancellationError())
        invitation.ringMonitor?.cancel()
        invitation.releaseWaiter?.resume(throwing: error ?? CancellationError())
        if !invitation.systemCallEnded {
            provider.reportCall(with: id, endedAt: Date(), reason: error == nil
                ? (invitation.isOutgoing ? .remoteEnded : .declinedElsewhere) : .failed)
        }
        if let error, !invitation.isOutgoing { report(error) }
    }

    private func monitorRinging(_ id: UUID) {
        guard let invitation = invitations[id], let connection = invitation.connection else { return }
        RequestLogStore.shared.registerCall(id: id, startedAt: Date(), mode: invitations[id]?.role?.effectiveCallMode)
        invitations[id]?.ringMonitor = Task { [weak self, client] in
            for _ in 0..<15 {
                guard !Task.isCancelled, let self, self.invitations[id] != nil else { return }
                do {
                    let page = try await client.events(connection: connection, callID: id, after: 0)
                    guard !Task.isCancelled, self.invitations[id] != nil else { return }
                    if page.call.status == "ended" || page.call.status == "active" {
                        self.provider.reportCall(with: id, endedAt: Date(), reason: page.call.status == "active" ? .answeredElsewhere : .remoteEnded)
                        self.invitations.removeValue(forKey: id)
                        self.onCancelRinging?(id)
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = String(localized: "来电状态暂时无法更新，接听时会重新确认")
                    return
                }
            }
            guard let self, !Task.isCancelled, self.invitations[id] != nil else { return }
            self.provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
            self.invitations.removeValue(forKey: id)
            self.onCancelRinging?(id)
            await self.onEnd?(id, invitation.role, connection)
        }
    }

    private func saveSettings() throws { defaults.set(try JSONEncoder().encode(settings), forKey: settingsKey) }

    static func callerHandle(for role: CallRole?) -> CXHandle {
        SystemCallContact.handle(for: role)
    }

    private static func callUpdate(for role: CallRole?) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.hasVideo = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.localizedCallerName = role?.displayName ?? String(localized: "Tincall 来电")
        update.remoteHandle = callerHandle(for: role)
        return update
    }

    func dismissError() { errorMessage = nil }

    private func report(_ error: Error) { errorMessage = safeMessage(error) }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? TincallError { return error.message }
        if let error = error as? ExternalCallFailure { return error.localizedDescription }
        return String(localized: "系统来电操作失败（\((error as NSError).code)）")
    }

    /// Store builds have no profile; self-signed builds must explicitly include push entitlement.
    static func signedPushEnvironment(bundle: Bundle = .main) -> IncomingPushEnvironment? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .production
        }
        // The provisioning profile is a CMS envelope containing an XML property list.
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return nil }
        switch environment {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }

    private static var canRegisterPush: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}
