// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct ScheduledCallSettings: View {
    let configuration: LocalConfigurationStore
    let incoming: IncomingCallController
    let isCallActive: Bool
    let refreshID: UUID
    let onEdit: (ScheduleEditorSelection) -> Void
    @State private var schedules: [CloudScheduledCall] = []
    @State private var statusRequests: [String: (id: UUID, enabled: Bool)] = [:]
    @State private var isWorking = false
    @State private var needsRefresh = false
    @State private var hasLoaded = false
    @State private var message: String?
    private let client = ExternalCallClient()

    private var connections: [ConnectionProfile] {
        configuration.connections.filter { $0.provider == .genericConnector && incoming.connectionIDs.contains($0.id) }
    }
    private var canAddSchedule: Bool { connections.contains { incoming.isRegistered($0.id) } }

    var body: some View {
        Section {
            Text("仅适用于独立模式联系人。MCP 与后端联系人的来电时间由对应平台安排。")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            Group {
                Button { onEdit(ScheduleEditorSelection()) } label: {
                    SettingsActionLabel(title: String(localized: "添加来电计划"), symbol: "plus")
                }
                .buttonStyle(.plain)
                .disabled(!canAddSchedule || isCallActive)
                Button { Task { await refresh() } } label: {
                    SettingsActionLabel(title: String(localized: "刷新云端计划"), symbol: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(connections.isEmpty || isWorking)
                if isWorking || schedules.isEmpty || !canAddSchedule || message != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if isWorking {
                            ProgressView("正在更新云端计划…")
                        } else if schedules.isEmpty {
                            Text(hasLoaded ? String(localized: "暂无计划，可添加独立模式联系人的定时来电。") : String(localized: "尚未加载云端计划。"))
                        }
                        if !canAddSchedule {
                            Text("完成上方设备绑定后，才能添加或编辑计划。")
                        }
                        if let message { Text(message) }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            ForEach(schedules) { item in
                let schedule = item.schedule
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Button { onEdit(ScheduleEditorSelection(schedule: schedule, connectionID: item.connectionID)) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                if connections.count > 1 {
                                    Text(connections.first { $0.id == item.connectionID }?.name ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                scheduleLabel(schedule)
                            }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle("启用计划", isOn: Binding(get: { schedule.enabled }, set: { setEnabled($0, for: item) }))
                            .labelsHidden()
                            .tint(Color.accentColor)
                    }
                    .disabled(isWorking || isCallActive)
                }
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(item.id == schedules.last?.id ? .hidden : .visible, edges: .bottom)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
        } header: {
            SettingsSectionHeading(number: "02", title: String(localized: "定时来电"), caption: "\(schedules.count) PLANS")
        } footer: {
            Text("需云端定时任务与推送服务可用，忙线会跳过。关闭 App 不会取消计划，可用右侧开关暂停。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: "\(refreshID)-\(connections.map { $0.id.uuidString }.joined(separator: ","))") {
            if incoming.isEnabled { await refresh() }
            else { schedules = []; hasLoaded = false; message = nil }
        }

    }

    private func scheduleLabel(_ schedule: ScheduledCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(configuration.roles.first(where: { $0.id.uuidString.lowercased() == schedule.contact_id.lowercased() })?.displayName ?? schedule.contact_id)
                .font(.subheadline.weight(.medium))
            if let time = schedule.daily_time {
                Text("\(scheduleRepeatTitle(schedule.week_day)) \(String(time.prefix(5))) · \(schedule.time_zone ?? "")").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("下次来电：\(nextCallTime(schedule.next_at))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func nextCallTime(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refresh() async {
        guard !connections.isEmpty else { return }
        guard !isWorking else { needsRefresh = true; return }
        isWorking = true
        defer { finishWork() }
        schedules.removeAll { item in !connections.contains { $0.id == item.connectionID } }
        var failures: [String] = []
        for connection in connections {
            do {
                let loaded = try await client.schedules(connection: connection)
                guard !Task.isCancelled else { return }
                schedules.removeAll { $0.connectionID == connection.id }
                schedules += loaded.map { CloudScheduledCall(connectionID: connection.id, schedule: $0) }
            } catch {
                guard !Task.isCancelled else { return }
                failures.append("\(connection.name)：\(scheduleErrorDescription(error))")
            }
        }
        schedules.sort { $0.schedule.next_at < $1.schedule.next_at }
        hasLoaded = true
        message = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func setEnabled(_ enabled: Bool, for item: CloudScheduledCall) {
        guard let connection = connections.first(where: { $0.id == item.connectionID }), !isWorking, !isCallActive else { return }
        let requestID = statusRequests[item.id].flatMap { $0.enabled == enabled ? $0.id : nil } ?? UUID()
        statusRequests[item.id] = (requestID, enabled)
        if let index = schedules.firstIndex(where: { $0.id == item.id }) { schedules[index].schedule.enabled = enabled }
        isWorking = true
        message = nil
        Task {
            defer { finishWork() }
            do {
                try await client.setScheduleEnabled(connection: connection, requestID: requestID, id: item.schedule.id, enabled: enabled)
                statusRequests.removeValue(forKey: item.id)
                needsRefresh = true
            } catch {
                if let index = schedules.firstIndex(where: { $0.id == item.id }) { schedules[index].schedule.enabled = item.schedule.enabled }
                message = scheduleErrorDescription(error)
            }
        }
    }

    private func finishWork() {
        isWorking = false
        if needsRefresh {
            needsRefresh = false
            Task { await refresh() }
        }
    }
}

private struct CloudScheduledCall: Identifiable {
    let connectionID: UUID
    var schedule: ScheduledCall
    var id: String { "\(connectionID)-\(schedule.id)" }
}

struct ScheduleEditorSelection: Identifiable {
    let id: UUID
    let schedule: ScheduledCall?
    let connectionID: UUID?

    init(schedule: ScheduledCall? = nil, connectionID: UUID? = nil) {
        id = schedule?.id ?? UUID()
        self.schedule = schedule
        self.connectionID = connectionID
    }
}

struct ScheduledCallEditor: View {
    let configuration: LocalConfigurationStore
    let incoming: IncomingCallController
    let isCallActive: Bool
    let selection: ScheduleEditorSelection
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var connectionID: UUID?
    @State private var roleID: UUID?
    @State private var time: Date
    @State private var timeZoneID: String
    @State private var repeatDay: Int
    @State private var showingRemovalConfirmation = false
    @State private var removalRequestID = UUID()
    @State private var showingTimePicker = false
    @State private var requestID = UUID()
    @State private var isWorking = false
    @State private var isSaved = false
    @State private var message: String?
    private let client = ExternalCallClient()

    init(configuration: LocalConfigurationStore, incoming: IncomingCallController, isCallActive: Bool,
         selection: ScheduleEditorSelection, onSaved: @escaping () -> Void) {
        self.configuration = configuration
        self.incoming = incoming
        self.isCallActive = isCallActive
        self.selection = selection
        self.onSaved = onSaved
        let zoneID = selection.schedule?.time_zone ?? TimeZone.current.identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID) ?? .current
        let clock = selection.schedule?.daily_time?.split(separator: ":").compactMap { Int($0) } ?? []
        let initialTime = clock.count >= 2
            ? calendar.date(bySettingHour: clock[0], minute: clock[1], second: 0, of: Date()) ?? Date()
            : Date()
        let registered = configuration.connections.filter { $0.provider == .genericConnector && incoming.isRegistered($0.id) }
        _connectionID = State(initialValue: selection.connectionID ?? (registered.count == 1 ? registered.first?.id : nil))
        _roleID = State(initialValue: selection.schedule.flatMap { UUID(uuidString: $0.contact_id) })
        _time = State(initialValue: initialTime)
        _timeZoneID = State(initialValue: zoneID)
        _repeatDay = State(initialValue: selection.schedule?.week_day ?? 0)
    }

    private var connections: [ConnectionProfile] {
        configuration.connections.filter { $0.provider == .genericConnector && incoming.connectionIDs.contains($0.id) }
    }
    private var connection: ConnectionProfile? { connections.first { $0.id == connectionID } }
    private var isRegistered: Bool { connectionID.map { incoming.isRegistered($0) } ?? false }

    private var hasValidRole: Bool {
        configuration.roles.contains { $0.id == roleID && $0.effectiveCallMode == .standalone }
    }

    var body: some View {
        List {
            Section {
                SettingsPickerRow(title: String(localized: "云端"), value: connection?.name ?? String(localized: "请选择"), selection: $connectionID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(connections) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(selection.schedule != nil)
                SettingsPickerRow(title: String(localized: "联系人"), value: configuration.roles.first { $0.id == roleID }?.displayName ?? String(localized: "请选择"), selection: $roleID) {
                    Text("选择独立模式联系人").tag(nil as UUID?)
                    ForEach(configuration.roles.filter { $0.effectiveCallMode == .standalone }) {
                        Text($0.displayName).tag(Optional($0.id))
                    }
                }
                SettingsPickerRow(title: String(localized: "重复"), value: scheduleRepeatTitle(repeatDay == 0 ? nil : repeatDay), selection: $repeatDay) {
                    ForEach(0...7, id: \.self) { day in
                        Text(scheduleRepeatTitle(day == 0 ? nil : day)).tag(day)
                    }
                }
                Button { showingTimePicker = true } label: {
                    HStack(spacing: 16) {
                        Text("时间").foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        SettingsSelectionLabel(value: time.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: timeZoneID) ?? .current)))
                            .monospacedDigit()
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                NavigationLink {
                    ScheduleTimeZonePicker(selection: $timeZoneID)
                } label: {
                    HStack(spacing: 16) {
                        Text("时区").foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        SettingsSelectionLabel(value: TimeZone(identifier: timeZoneID)?.localizedName(for: .generic, locale: Locale(identifier: String(localized: "zh_Hans_CN", comment: "Locale used only to display time zone names. Keep zh_Hans_CN for Chinese; use en_US for English."))) ?? timeZoneID)
                    }
                    .frame(minHeight: 44)
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                if !isRegistered || connection == nil {
                    Text("请选择已完成后台来电绑定的云端，才能保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !configuration.roles.contains(where: { $0.effectiveCallMode == .standalone }) {
                    Text("请先添加一位独立模式联系人。").font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    Button { save() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 18, weight: .regular))
                                .frame(width: 38, height: 38)
                                .background(Color.settingsSurface(lightOpacity: 0.12), in: RoundedRectangle(cornerRadius: 3))
                            Text(isSaved ? String(localized: "已保存到云端") : String(localized: "保存到云端"))
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                    .disabled(isWorking || isSaved || isCallActive || !hasValidRole || connection == nil || !isRegistered || TimeZone(identifier: timeZoneID) == nil)
                    if selection.schedule != nil {
                        Divider().frame(height: 38)
                        Button(role: .destructive) { showingRemovalConfirmation = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash")
                                    .font(.system(size: 18, weight: .regular))
                                    .frame(width: 38, height: 38)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                                Text("删除此计划").font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                        .disabled(isWorking || isCallActive || connection == nil)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                if isWorking { ProgressView("正在保存…") }
                if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            } header: { SettingsSectionHeading(title: String(localized: "来电时间"), caption: "SCHEDULE") }
            .listRowBackground(Color.clear)
        }
        .alert("删除此来电计划？", isPresented: $showingRemovalConfirmation) {
            Button("删除", role: .destructive) { remove() }
            Button("取消", role: .cancel) { }
        } message: { Text("云端不再按这条计划发起来电，已有通话记录会保留。") }
        .modifier(SettingsPageStyle(title: selection.schedule == nil ? String(localized: "添加来电计划") : String(localized: "编辑来电计划"),
                                   subtitle: String(localized: "独立模式联系人的定时来电"), symbol: "clock", index: "SCHEDULED CALLS",
                                   isModal: true, dismissDisabled: isWorking))
        .interactiveDismissDisabled(isWorking)
        .sheet(isPresented: $showingTimePicker) {
            VStack(spacing: 12) {
                HStack {
                    Text("来电时间").font(.headline)
                    Spacer()
                    Button("完成") { showingTimePicker = false }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: timeZoneID) ?? .current)
            }
            .padding(24)
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: connectionID) { requestID = UUID() }
        .onChange(of: roleID) { requestID = UUID() }
        .onChange(of: time) { requestID = UUID() }
        .onChange(of: repeatDay) { requestID = UUID() }
        .onChange(of: timeZoneID) { oldValue, newValue in
            var oldCalendar = Calendar(identifier: .gregorian)
            oldCalendar.timeZone = TimeZone(identifier: oldValue) ?? .current
            let clock = oldCalendar.dateComponents([.hour, .minute], from: time)
            var newCalendar = oldCalendar
            newCalendar.timeZone = TimeZone(identifier: newValue) ?? .current
            time = newCalendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: time) ?? time
            requestID = UUID()
        }
    }

    private func remove() {
        guard !isWorking, !isCallActive, let schedule = selection.schedule, let connection else { return }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await client.removeSchedule(connection: connection, requestID: removalRequestID, id: schedule.id)
                onSaved()
                dismiss()
            } catch { message = scheduleErrorDescription(error) }
        }
    }

    private func save() {
        guard !isWorking, !isSaved, !isCallActive, isRegistered,
              let connection, let roleID, hasValidRole, let zone = TimeZone(identifier: timeZoneID) else {
            message = String(localized: "请先完成设备绑定，并选择独立模式联系人和有效时区。")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let clock = String(format: "%02d:%02d", calendar.component(.hour, from: time), calendar.component(.minute, from: time))
        let savingRequestID = requestID
        let savingTimeZone = timeZoneID
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try await client.saveSchedule(connection: connection, requestID: savingRequestID, id: selection.id,
                                              roleID: roleID, time: clock, timeZone: savingTimeZone,
                                              enabled: selection.schedule?.enabled ?? true, weekDay: repeatDay == 0 ? nil : repeatDay)
                isSaved = true
                onSaved()
                dismiss()
            } catch { message = scheduleErrorDescription(error) }
        }
    }
}

private struct ScheduleTimeZonePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matchingIdentifiers: [String] {
        TimeZone.knownTimeZoneIdentifiers.filter { identifier in
            search.isEmpty || identifier.localizedStandardContains(search)
                || (TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: Locale(identifier: String(localized: "zh_Hans_CN", comment: "Locale used only to display time zone names. Keep zh_Hans_CN for Chinese; use en_US for English.")))?.localizedStandardContains(search) == true)
        }
    }

    var body: some View {
        SettingsList {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索地区或时区", text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if search.isEmpty {
                Section {
                    zoneRow(TimeZone.current.identifier, title: String(localized: "本机时区"))
                } footer: {
                    Text("计划按选定时区执行，之后旅行或更改手机时区不会改变它。切换时区会保留所选钟点。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("所有时区") {
                ForEach(matchingIdentifiers, id: \.self) { identifier in
                    zoneRow(identifier)
                }
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "选择时区"), subtitle: String(localized: "计划来电使用的时区"), symbol: "globe", index: "TIME ZONE"))
    }

    private func zoneRow(_ identifier: String, title: String? = nil) -> some View {
        Button {
            selection = identifier
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title ?? TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: Locale(identifier: String(localized: "zh_Hans_CN", comment: "Locale used only to display time zone names. Keep zh_Hans_CN for Chinese; use en_US for English."))) ?? identifier)
                        .font(.subheadline).foregroundStyle(.primary)
                    Text(identifier).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selection == identifier {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private func scheduleErrorDescription(_ error: Error) -> String {
    if let failure = error as? ExternalCallFailure {
        if failure.code == "route_not_found" || failure.code == "schedule_update_required" {
            return String(localized: "此云端尚未支持新的定时来电设置，请先按原部署方式更新云端服务，再重试。")
        }
        return String(localized: "云端计划未完成（HTTP \(failure.status)），请检查连接端权限和定时任务配置，再刷新确认结果。")
    }
    return error.localizedDescription
}

private func scheduleRepeatTitle(_ day: Int?) -> String {
    switch day {
    case 1: String(localized: "每周一")
    case 2: String(localized: "每周二")
    case 3: String(localized: "每周三")
    case 4: String(localized: "每周四")
    case 5: String(localized: "每周五")
    case 6: String(localized: "每周六")
    case 7: String(localized: "每周日")
    default: String(localized: "每天")
    }
}
