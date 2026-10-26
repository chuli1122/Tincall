// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Contacts
import Intents
import SwiftUI
import UIKit

struct TincallRootView: View {
    private enum Page: Int, Hashable { case contacts, records, settings }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPage: Page = .contacts
    @State private var dockSelectionFeedback = 0
    @State private var dockPresentation = NavigationDockPresentation()
    @Namespace private var dockSelection
    @State private var runtime = TincallRuntime.shared
    private var configuration: LocalConfigurationStore? { runtime.configuration }
    private var records: CallRecordStore? { runtime.records }
    private var coordinator: CallCoordinator? { runtime.coordinator }
    @State private var selectedRoleID: UUID?
    @State private var showsCall = false
    @State private var minimizedCallID: UUID?
    @State private var isDialing = false
    @State private var dialingTask: Task<Void, Never>?
    @State private var opensCallDirectly = false
    @State private var showsConfiguration = false
    @State private var showsCallRecords = false
    @State private var showsCallPreview = false
    @State private var dismissContactEditorRequest: UUID?
    @State private var isRecordDetailVisible = false
    @State private var isSettingsSubpageVisible = false
    @State private var callDraft = ""
    @State private var dataSharingReviewConnections: [ConnectionProfile] = []
    @State private var showsDataSharingReview = false
    @State private var systemCallError: String?
    @State private var systemPhoneURL: URL?
    private var callActivity: CallActivityController { runtime.callActivity }
    @State private var configurationIssue: String? = String(localized: "请选择联系人并配置连接")

    private var activeCallID: UUID? {
        runtime.incoming.answeringCall?.id ?? (coordinator?.isCallActive == true ? coordinator?.record?.id : nil)
    }

    private var callPageIsVisible: Bool {
        showsCall || runtime.launchCall != nil || (activeCallID != nil && activeCallID != minimizedCallID)
    }

    private func closeCallPage() {
        opensCallDirectly = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            minimizedCallID = activeCallID
            showsCall = false
        }
    }

    var body: some View {
        Group {
            if let configuration, let coordinator {
                ZStack {
                    TabView(selection: $selectedPage) {
                        NavigationStack {
                            ContactsScreen(store: configuration, isCallActive: coordinator.isCallActive,
                                           onSelectRole: startCall, records: records,
                                           dismissEditorRequest: dismissContactEditorRequest)
                            .background(dockNavigationObserver(for: .contacts))
                        }
                        .toolbar(.hidden, for: .tabBar)
                        .tabItem { Image(systemName: "person.crop.circle").accessibilityLabel("联系人") }
                        .tag(Page.contacts)

                        NavigationStack {
                            if let records {
                                RecordListScreen(store: records, isCallActive: coordinator.isCallActive,
                                                 onRequestSummary: summaryCallback(store: records, configuration: configuration, coordinator: coordinator),
                                                 canRequestSummary: summaryAvailability(store: records, configuration: configuration),
                                                 isDockPage: true, roles: configuration.roles, onResumeCall: resumeCall,
                                                 summaryConnections: configuration.connections,
                                                 onRequestSummaryUsing: summaryUsingCallback(store: records, configuration: configuration, coordinator: coordinator))
                                    .background(dockNavigationObserver(for: .records))
                            }
                        }
                        .toolbar(.hidden, for: .tabBar)
                        .tabItem { Image(systemName: "clock").accessibilityLabel("通话记录") }
                        .tag(Page.records)

                        NavigationStack {
                            ConfigurationScreen(store: configuration, records: records, isCallActive: coordinator.isCallActive,
                                                onRequestSummary: summaryCallback(store: records, configuration: configuration, coordinator: coordinator),
                                                canRequestSummary: summaryAvailability(store: records, configuration: configuration),
                                                isDockPage: true, incomingController: runtime.incoming,
                                                cloudSync: runtime.cloudSync, cloudSyncLoadingError: runtime.cloudSyncLoadingError)
                                .background(dockNavigationObserver(for: .settings))
                        }
                        .toolbar(.hidden, for: .tabBar)
                        .tabItem { Image(systemName: "gearshape").accessibilityLabel("设置") }
                        .tag(Page.settings)
                    }
                    .environment(\.navigationDockClearance, isRecordDetailVisible || isSettingsSubpageVisible ? 0 : 70)
                    .overlay(alignment: .bottom) {
                        dockInset.ignoresSafeArea(.keyboard, edges: .bottom)
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .onPreferenceChange(RecordDetailVisibilityKey.self) { isRecordDetailVisible = $0 }
                    .onPreferenceChange(SettingsSubpageVisibilityKey.self) { isSettingsSubpageVisible = $0 }
                    .overlay {
                        if coordinator.isCallActive && !callPageIsVisible {
                            FloatingCallView(name: coordinator.record?.roleName ?? "Tincall", status: statusTitle(coordinator),
                                             avatarData: configuration.roles.first { $0.id == coordinator.record?.roleID }?.displayAvatarData,
                                             activity: floatingActivity(coordinator),
                                             caption: coordinator.playback == .playing ? (coordinator.currentPlaybackCaption ?? "") : coordinator.floatingUserTranscript,
                                             captionIsOutgoing: coordinator.playback != .playing) {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                    showsCall = true
                                }
                            }
                            .padding(.bottom, dockPresentation.isDockShown ? 70 : 0)
                        }
                    }
                    .onChange(of: coordinator.isCallActive) { _, active in
                        if active {
                            presentActiveCall(animated: isDialing)
                            isDialing = false
                        }
                        if !active, coordinator.phase == .ended {
                            isDialing = false
                            showsCallRecords = false
                            showsConfiguration = false
                            showsCallPreview = false
                            if !coordinator.endedByRemote { closeCallPage() }
                            callDraft = ""
                        }
                    }
                    .onChange(of: coordinator.phase) { _, phase in
                        if phase == .active { runtime.donateActiveCallContact() }
                    }
                    .onChange(of: selectedRoleID) {
                        if !coordinator.isCallActive { callDraft = "" }
                        refreshConfiguration()
                    }
                    .onChange(of: configuration.roles) { refreshConfiguration() }
                    .onChange(of: configuration.connections) { refreshConfiguration() }
                    .onChange(of: configuration.defaultSTTConnectionID) { refreshConfiguration() }
                    .opacity(callPageIsVisible ? 0 : 1)
                    .allowsHitTesting(!callPageIsVisible)
                    .accessibilityHidden(callPageIsVisible)

                    // Render the call in the root hierarchy. A modal presentation
                    // necessarily renders its presenting page first on scene entry.
                    if callPageIsVisible {
                        NavigationStack {
                            callScreen(configuration: configuration, coordinator: coordinator)
                        }
                        .transition(opensCallDirectly || runtime.launchCall != nil ? .identity
                            : (reduceMotion ? .opacity : .move(edge: .bottom)))
                        .zIndex(1)
                    }
                }
                .animation(reduceMotion || opensCallDirectly || runtime.launchCall != nil || (callPageIsVisible && runtime.incoming.answeringCall != nil)
                    ? nil : .easeInOut(duration: 0.3), value: callPageIsVisible)
                .onChange(of: runtime.incoming.answeringCall?.id) { _, id in
                    if id != nil { presentActiveCall() }
                }
            } else if let loadError = runtime.loadError {
                ContentUnavailableView {
                    Label("本地数据未能打开", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(loadError) } actions: { Button("重试", action: load) }
            } else {
                ProgressView("打开本地记录…")
            }
        }
        .fullScreenCover(isPresented: Binding(get: { runtime.access.showsUnlock }, set: { runtime.access.showsUnlock = $0 })) {
            NavigationStack { CallAccessScreen(isModal: true) }
        }
        .onOpenURL(perform: handleOpenURL)
        .onContinueUserActivity("INStartCallIntent", perform: handleSystemCall)
        .onContinueUserActivity("INStartAudioCallIntent", perform: handleSystemCall)
        .alert("Tincall", isPresented: Binding(get: { systemCallError != nil }, set: { if !$0 { systemCallError = nil } })) {
            if let systemPhoneURL {
                Button("使用系统电话拨打") { UIApplication.shared.open(systemPhoneURL) }
            }
            Button("好", role: .cancel) { systemCallError = nil }
        } message: { Text(systemCallError ?? "") }
        .sheet(isPresented: $showsDataSharingReview, onDismiss: {
            runtime.refreshDataSharingConsent()
            refreshConfiguration()
        }) {
            NavigationStack { ConnectionDataSharingReview(connections: dataSharingReviewConnections) }
        }
        .alert("来电提示", isPresented: Binding(get: {
            !showsDataSharingReview && runtime.incoming.errorMessage != nil
        }, set: { if !$0 { runtime.incoming.dismissError() } })) {
            if configuration?.connections.contains(where: { !DataSharingConsent.isAllowed($0) }) == true {
                Button("检查连接授权") {
                    runtime.incoming.dismissError()
                    dataSharingReviewConnections = configuration?.connections.filter { !DataSharingConsent.isAllowed($0) } ?? []
                    showsDataSharingReview = !dataSharingReviewConnections.isEmpty
                }
            }
            Button("好", role: .cancel) { runtime.incoming.dismissError() }
        } message: { Text(runtime.incoming.errorMessage ?? "") }
        .task {
            if configuration == nil { load() }
            if selectedRoleID == nil {
                selectedRoleID = runtime.launchCall?.roleID
                    ?? (coordinator?.isCallActive == true ? coordinator?.record?.roleID : configuration?.roles.first?.id)
            }
            if let launchCall = runtime.launchCall {
                handleSystemCall(launchCall.intent)
                runtime.launchCall = nil
            }
            refreshConfiguration()
            presentActiveCall()
            dataSharingReviewConnections = configuration?.connections.filter { DataSharingConsent.needsReview($0) } ?? []
            showsDataSharingReview = !dataSharingReviewConnections.isEmpty
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-TincallOpenSettings") || arguments.contains("-TincallOpenRequestLogs") || arguments.contains("-TincallOpenRequestLogFailedCall") {
                selectedPage = .settings
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await configuration?.refreshLinkedContacts() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            Task { await configuration?.refreshLinkedContacts() }
        }
        .background(RootKeyboardDismissal())
    }

    private func presentActiveCall(animated: Bool = false) {
        let id = runtime.incoming.answeringCall?.role.id
            ?? (coordinator?.isCallActive == true ? coordinator?.record?.roleID : nil)
        guard let id, activeCallID != minimizedCallID else { return }
        var transaction = Transaction(animation: animated && !reduceMotion ? .easeInOut(duration: 0.3) : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            selectedRoleID = id
            dismissContactEditorRequest = UUID()
            showsConfiguration = false
            showsCallRecords = false
            showsCallPreview = false
            showsCall = true
        }
    }

    private func startCall(_ id: UUID) {
        guard let configuration, let coordinator, !coordinator.isCallActive, !isDialing else { return }
        selectedRoleID = id
        refreshConfiguration()
        guard configurationIssue == nil,
              let role = resolvedCallRole(configuration.roles.first { $0.id == id }, configuration: configuration) else {
            showsCall = true
            return
        }
        isDialing = true
        dialingTask = Task {
            await coordinator.start(role: role, connections: configuration.connections,
                                    retention: configuration.retention, historyRecords: records?.records ?? [])
            guard !Task.isCancelled else { return }
            if isDialing { showsCall = true; isDialing = false }
        }
    }

    private func handleOpenURL(_ url: URL) {
        if url.scheme?.lowercased() == "tel" {
            handleSystemCall(SystemCallContact.intent(for: url))
            return
        }
        guard url.scheme == "tincall", url.host == "call" else { return }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if queryItems?.contains(where: { $0.name == "preview" && $0.value == "1" }) == true {
            guard showsCallPreview,
                  queryItems?.contains(where: { $0.name == "compose" && $0.value == "1" }) == true,
                  let previewStartedAt = CallTextInputRequest.shared.previewStartedAt else { return }
            CallTextInputRequest.shared.previewRequestedAt = previewStartedAt
            return
        }
        guard let coordinator, coordinator.isCallActive || runtime.incoming.answeringCall != nil else { return }
        let compose = queryItems?.contains { $0.name == "compose" && $0.value == "1" } == true
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            CallTextInputRequest.shared.startedAt = compose ? coordinator.record?.startedAt : nil
            opensCallDirectly = true
            dismissContactEditorRequest = UUID()
            showsConfiguration = false
            showsCallRecords = false
            showsCallPreview = false
            showsCall = true
        }
    }

    private func handleSystemCall(_ activity: NSUserActivity) {
        handleSystemCall(activity.interaction?.intent)
    }

    private func handleSystemCall(_ intent: INIntent?) {
        systemPhoneURL = nil
        if configuration == nil { load() }
        guard let configuration, let coordinator else { return }
        do {
            let role = try SystemCallContact.role(for: intent, roles: configuration.roles, records: records?.records ?? [])
            if coordinator.isCallActive || runtime.incoming.answeringCall != nil || isDialing {
                let currentRoleID = runtime.incoming.answeringCall?.role.id
                    ?? (coordinator.isCallActive ? coordinator.record?.roleID : selectedRoleID)
                guard currentRoleID == role.id else {
                    systemCallError = String(localized: "已有通话正在进行")
                    return
                }
                // SwiftUI can also deliver the same URL/activity after scene connection.
                // Reopen the existing call without creating another call or busy alert.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    opensCallDirectly = true
                    dismissContactEditorRequest = UUID()
                    showsConfiguration = false
                    showsCallRecords = false
                    showsCallPreview = false
                    showsCall = true
                }
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                opensCallDirectly = true
                selectedRoleID = role.id
                dismissContactEditorRequest = UUID()
                showsConfiguration = false
                showsCallRecords = false
                showsCallPreview = false
                showsCall = true
                startCall(role.id)
            }
        } catch {
            systemPhoneURL = SystemCallContact.telephonyURL(for: intent)
            systemCallError = (error as? TincallError)?.message
                ?? String(localized: "无法确定要拨打的 Tincall 联系人，请在 App 中选择。")
        }
    }

    private var dockInset: some View {
        NavigationDockHost(presentation: dockPresentation) {
            DockSlideContainer(presentation: dockPresentation) {
                navigationDock
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedPage)
            }
        }
        .frame(height: 70)
    }

    private func dockNavigationObserver(for page: Page) -> some View {
        NavigationDockObserver(presentation: dockPresentation, isSelected: selectedPage == page,
                               reduceMotion: reduceMotion)
    }

    private var navigationDock: some View {
        HStack(spacing: 0) {
            dockButton(.contacts, symbol: "person.crop.circle", label: String(localized: "联系人"))
            dockButton(.records, symbol: "clock", label: String(localized: "通话记录"))
            dockButton(.settings, symbol: "gearshape", label: String(localized: "设置"))
        }
        .background(Color(white: 0.09))
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .padding(.horizontal, 24)
        .sensoryFeedback(.selection, trigger: dockSelectionFeedback)
    }

    private func dockButton(_ page: Page, symbol: String, label: String) -> some View {
        Button {
            guard selectedPage != page else { return }
            dockSelectionFeedback += 1
            dockPresentation.selectTab(at: page.rawValue, reduceMotion: reduceMotion) {
                selectedPage = page
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(selectedPage == page ? Color.white : Color(white: 0.63))
                .animation(nil, value: selectedPage)
                .frame(width: 84, height: 50)
                .overlay(alignment: .bottom) {
                    if selectedPage == page {
                        Circle().fill(Color.white).frame(width: 3, height: 3)
                            .matchedGeometryEffect(id: "dockSelection", in: dockSelection)
                            .padding(.bottom, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
    }

    private func summaryCallback(store: CallRecordStore?, configuration: LocalConfigurationStore, coordinator: CallCoordinator) -> ((UUID) -> Void)? {
        guard let store else { return nil }
        return { id in
            guard let value = store.records.first(where: { $0.id == id }) else { return }
            coordinator.requestSummary(for: value, connections: configuration.connections, roles: configuration.roles)
        }
    }

    private func summaryAvailability(store: CallRecordStore?, configuration: LocalConfigurationStore) -> ((UUID) -> Bool)? {
        guard let store else { return nil }
        return { recordID in
            guard let record = store.records.first(where: { $0.id == recordID }),
                  let role = configuration.roles.first(where: { $0.id == record.roleID }),
                  let summaryID = role.summaryConnectionID,
                  let summary = configuration.connections.first(where: { $0.id == summaryID }) else { return false }
            return summary.provider.isLanguageModel
        }
    }

    private func summaryUsingCallback(store: CallRecordStore, configuration: LocalConfigurationStore, coordinator: CallCoordinator) -> (UUID, UUID) -> Void {
        { recordID, connectionID in
            guard let value = store.records.first(where: { $0.id == recordID }) else { return }
            coordinator.requestSummary(for: value, connections: configuration.connections, roles: configuration.roles, using: connectionID)
        }
    }

    private func resumeCall(_ id: UUID) {
        guard let configuration, let coordinator, !coordinator.isCallActive, !isDialing,
              let record = records?.records.first(where: { $0.id == id }),
              let role = resolvedCallRole(configuration.roles.first(where: { $0.id == record.roleID }), configuration: configuration) else { return }
        selectedRoleID = role.id
        showsCallRecords = false
        isDialing = true
        dialingTask = Task {
            await coordinator.resumeExternal(record: record, role: role, connections: configuration.connections, retention: configuration.retention)
            guard !Task.isCancelled else { return }
            if isDialing { showsCall = true; isDialing = false }
        }
    }

    @ViewBuilder
    private func callScreen(configuration: LocalConfigurationStore, coordinator: CallCoordinator) -> some View {
        let answeringCall = runtime.incoming.answeringCall
        let isAnswering = answeringCall != nil && !coordinator.isCallActive
        let isStarting = isAnswering || runtime.launchCall != nil || (isDialing && !coordinator.isCallActive)
        let identity = coordinator.isCallActive ? coordinator.record?.roleID
            : (answeringCall?.role.id ?? runtime.launchCall?.roleID ?? selectedRoleID)
        let role = configuration.roles.first { $0.id == identity }
        let displayedRecord = (isStarting || coordinator.phase == .connecting) ? nil
            : coordinator.record.flatMap { $0.roleID == identity ? $0 : nil }
        let caption = voiceCaption(displayedRecord, partialTranscript: coordinator.partialTranscript,
                                   role: role, connections: configuration.connections)
        let interruptibleMessageID = coordinator.canInterrupt && !coordinator.speechInterruptionEnabled
            ? displayedRecord?.messages.last(where: { $0.role == .assistant })?.id : nil
        CallScreen(
            name: coordinator.isCallActive ? (coordinator.record?.roleName ?? "Tincall") : (role?.displayName ?? "Tincall"),
            statusTitle: isStarting ? String(localized: "正在连接") : statusTitle(coordinator),
            statusDetail: isStarting ? "" : (coordinator.isCallActive ? statusDetail(coordinator) : (configurationIssue ?? statusDetail(coordinator))),
            isConfigured: isStarting || coordinator.isCallActive || configurationIssue == nil,
            isCallActive: isStarting || coordinator.isCallActive,
            canStart: !isStarting && !coordinator.isCallActive,
            canSend: coordinator.canSend,
            microphoneAvailable: coordinator.phase == .active && !coordinator.isSwitchingSpeechRecognition,
            isMuted: coordinator.isMuted,
            canInterrupt: coordinator.canInterrupt,
            errorMessage: isStarting ? nil : (coordinator.errorMessage ?? callActivity.errorMessage),
            onRetrySaving: !coordinator.savingCallIDs.isEmpty ? { coordinator.retrySaving() } : nil,
            onConfigure: { showsConfiguration = true },
            onStart: {
                guard let role else { return }
                startCall(role.id)
            },
            onToggleMute: { Task { await coordinator.toggleMute() } },
            onTextInputActiveChange: { coordinator.setTextInputActive($0) },
            onInterrupt: { coordinator.interrupt() },
            onHangUp: {
                dialingTask?.cancel()
                isDialing = false
                if isAnswering { runtime.incoming.cancelAnsweringCall() }
                else { coordinator.hangUp() }
                if !coordinator.isCallActive { closeCallPage() }
            },
            onSend: { coordinator.sendText($0) },
            onSendImages: { coordinator.sendText($0, images: $1) },
            onClose: closeCallPage,
            isSpeakerEnabled: coordinator.isSpeakerEnabled,
            onToggleSpeaker: { Task { await coordinator.toggleSpeaker() } },
            backgroundData: role?.callBackgroundData,
            avatarData: role?.displayAvatarData,
            userAvatarData: configuration.userProfile.avatarData,
            userDisplayName: configuration.userProfile.name,
            startedAt: displayedRecord == nil ? nil : coordinator.connectedAt,
            endedAt: displayedRecord?.endedAt,
            isCallEnded: coordinator.phase == .ended && displayedRecord != nil,
            onReconnect: coordinator.externalConnectionLost ? { coordinator.reconnectExternal() } : nil,
            onShowRecords: records == nil ? nil : { showsCallRecords = true },
            onPreview: { showsCallPreview = true },
            textStatusTitle: isStarting ? String(localized: "正在连接") : textStatusTitle(coordinator),
            textStatusDetail: isStarting ? "" : (coordinator.isCallActive ? statusDetail(coordinator)
                : (configurationIssue ?? statusDetail(coordinator))),
            assistantSpeaking: coordinator.isCallActive && coordinator.playback == .playing,
            userSpeaking: coordinator.isUserSpeaking,
            animatesStatus: coordinator.phase == .active && coordinator.playback != .playing && coordinator.playback != .failed
                && (coordinator.generation == .generating || coordinator.playback == .synthesizing || coordinator.isUserSpeaking),
            captionText: caption.text,
            captionSpeaker: caption.isOutgoing ? configuration.userProfile.name : (role?.displayName ?? String(localized: "对方")),
            awaitingSpeechTranscript: coordinator.isAwaitingSpeechTranscript,
            speechInterruptionEnabled: coordinator.speechInterruptionEnabled,
            speechInterruptionAvailability: coordinator.speechInterruptionAvailability,
            onSetSpeechInterruptionEnabled: { coordinator.setSpeechInterruptionEnabled($0) },
            speechRecognitionConnections: configuration.connections.filter { $0.provider.isSpeechRecognition },
            speechRecognitionConnectionID: coordinator.speechRecognitionConnectionID,
            pendingSpeechRecognitionConnectionID: coordinator.pendingSpeechRecognitionConnection?.id,
            isSwitchingSpeechRecognition: coordinator.isSwitchingSpeechRecognition,
            speechRecognitionError: coordinator.speechRecognitionError,
            onSelectSpeechRecognition: coordinator.phase == .active && coordinator.speechRecognitionConnectionID != nil
                ? { coordinator.requestSpeechRecognitionConnection($0) } : nil,
            originalAudioInputEnabled: coordinator.originalAudioInputEnabled,
            pendingOriginalAudioInputEnabled: coordinator.pendingOriginalAudioInputEnabled,
            supportsOriginalAudioInput: coordinator.supportsOriginalAudioInput,
            onSetOriginalAudioInput: coordinator.phase == .active && coordinator.speechRecognitionConnectionID != nil
                ? { coordinator.requestOriginalAudioInput($0, connections: configuration.connections) } : nil,
            draft: $callDraft
        ) {
            CallTranscriptView(revision: coordinator.revision, isEmpty: displayedRecord?.messages.isEmpty != false,
                               partialTranscript: coordinator.partialTranscript,
                               awaitingSpeechTranscript: coordinator.isAwaitingSpeechTranscript,
                               userDisplayName: configuration.userProfile.name,
                               emptyPrompt: coordinator.isCallActive ? (coordinator.isMuted ? String(localized: "打字，或者打开麦克风") : String(localized: "在听你说")) : String(localized: "通话内容将在这里显示。")) {
                ForEach(displayedRecord?.messages ?? []) { message in
                    CallLiveTranscriptRow(speaker: message.role == .user ? configuration.userProfile.name : (coordinator.record?.roleName ?? String(localized: "对方")),
                                      text: liveTranscriptText(message, role: role, connections: configuration.connections), isOutgoing: message.role == .user,
                                      isStreaming: message.status == .generating, timestamp: message.createdAt,
                                      onInterrupt: message.id == interruptibleMessageID ? { coordinator.interrupt() } : nil,
                                      images: message.images ?? [], imageURL: { image in
                                          guard let records, let recordID = displayedRecord?.id else {
                                              throw TincallError(message: String(localized: "无法读取消息图片"))
                                          }
                                          return try records.imageURL(image, recordID: recordID, messageID: message.id)
                                      })
                }
            }
        }
        .sheet(isPresented: $showsCallRecords) {
            if let records {
                NavigationStack {
                    RecordListScreen(store: records, isCallActive: coordinator.isCallActive,
                        onRequestSummary: summaryCallback(store: records, configuration: configuration, coordinator: coordinator),
                        canRequestSummary: summaryAvailability(store: records, configuration: configuration),
                        roles: configuration.roles, onResumeCall: resumeCall,
                        summaryConnections: configuration.connections,
                        onRequestSummaryUsing: summaryUsingCallback(store: records, configuration: configuration, coordinator: coordinator))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showsCallRecords = false } } }
                }
            }
        }
        .sheet(isPresented: $showsConfiguration, onDismiss: refreshConfiguration) {
            NavigationStack {
                ConfigurationScreen(store: configuration, records: records, isCallActive: coordinator.isCallActive,
                                    onRequestSummary: summaryCallback(store: records, configuration: configuration, coordinator: coordinator),
                                    canRequestSummary: summaryAvailability(store: records, configuration: configuration), incomingController: runtime.incoming,
                                    cloudSync: runtime.cloudSync, cloudSyncLoadingError: runtime.cloudSyncLoadingError)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsConfiguration = false } } }
            }
        }
        .fullScreenCover(isPresented: $showsCallPreview) {
            CallPreviewScreen(callActivity: callActivity, contactID: role?.id,
                              name: role?.displayName ?? "Tincall",
                              avatarData: role?.displayAvatarData,
                              backgroundData: role?.callBackgroundData,
                              userAvatarData: configuration.userProfile.avatarData,
                              userDisplayName: configuration.userProfile.name)
        }
    }

    private func voiceCaption(_ record: CallRecord?, partialTranscript: String,
                              role: CallRole?, connections: [ConnectionProfile]) -> (text: String, isOutgoing: Bool) {
        if !partialTranscript.isEmpty { return (partialTranscript, true) }
        // Empty reply placeholders and playback lifecycle events must not erase the last words.
        for message in (record?.messages ?? []).reversed() {
            let text = liveTranscriptText(message, role: role, connections: connections)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (text, message.role == .user)
            }
        }
        return ("", false)
    }

    private func transcriptText(_ message: CallMessage, role: CallRole?, connections: [ConnectionProfile]) -> String {
        guard message.role == .assistant,
              let tts = connections.first(where: { $0.id == role?.ttsConnectionID }) else { return message.recordedText }
        return SpeechSegmenter.displayText(message.recordedText, provider: tts.provider, model: tts.model,
                                           isStreaming: message.status == .generating)
    }

    private func liveTranscriptText(_ message: CallMessage, role: CallRole?, connections: [ConnectionProfile]) -> String {
        guard message.role == .assistant,
              let tts = connections.first(where: { $0.id == role?.ttsConnectionID }) else { return message.text }
        return SpeechSegmenter.displayText(message.text, provider: tts.provider, model: tts.model,
                                           isStreaming: message.status == .generating)
    }

    private func load() {
        runtime.load()
        selectedRoleID = configuration?.roles.first?.id
        refreshConfiguration()
    }

    private func resolvedCallRole(_ role: CallRole?, configuration: LocalConfigurationStore) -> CallRole? {
        guard var role else { return nil }
        if let id = configuration.defaultSTTConnectionID { role.sttConnectionID = id }
        return role
    }

    private func refreshConfiguration() {
        guard let configuration, let coordinator else { return }
        if !configuration.roles.contains(where: { $0.id == selectedRoleID }) { selectedRoleID = configuration.roles.first?.id }
        configurationIssue = coordinator.configurationIssue(role: resolvedCallRole(configuration.roles.first { $0.id == selectedRoleID },
                                                                                 configuration: configuration),
                                                           connections: configuration.connections)
    }

    private func statusTitle(_ coordinator: CallCoordinator) -> String {
        CallActivityController.statusTitle(coordinator)
    }

    private func floatingActivity(_ coordinator: CallCoordinator) -> FloatingCallView.Activity {
        if coordinator.phase == .connecting { return .connecting }
        if coordinator.playback == .playing { return .speaking }
        if coordinator.playback == .failed || coordinator.generation == .failed { return .failed }
        if coordinator.generation == .generating || coordinator.playback == .synthesizing { return .replying }
        if coordinator.isMuted { return .muted }
        return coordinator.isUserSpeaking ? .listening : .idle
    }

    private func textStatusTitle(_ coordinator: CallCoordinator) -> String? {
        if coordinator.externalConnectionLost { return String(localized: "连接中断") }
        guard coordinator.phase == .active else { return statusTitle(coordinator) }
        if coordinator.pendingInputCount > 0 { return String(localized: "等待发送") }
        if coordinator.playback == .failed { return String(localized: "播放失败") }
        if coordinator.generation == .failed { return String(localized: "回复失败") }
        if coordinator.playback == .playing { return nil }
        // The streaming message row already shows the reply's waiting status.
        if coordinator.generation == .generating || coordinator.playback == .synthesizing { return nil }
        return nil
    }

    private func statusDetail(_ coordinator: CallCoordinator) -> String {
        if coordinator.pendingInputCount > 0 {
            if coordinator.externalConnectionLost { return String(localized: "文字已保存在本机，恢复连接后继续发送。") }
            if coordinator.record?.externalPendingControl != nil { return String(localized: "文字已保存，等待连接端确认打断。") }
            return String(localized: "文字已保存，等待发送。")
        }
        if coordinator.phase == .ended { return String(localized: "可在通话记录中查看已保存的内容。") }
        if coordinator.playback == .failed { return String(localized: "语音未完成，文字记录保留。") }
        return ""
    }
}
