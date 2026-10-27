// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

extension RequestLogEntry {
    fileprivate var indexEntry: Self {
        var value = self
        value.requestText = nil; value.requestBodyJSON = nil; value.responseText = nil
        value.reasoningText = nil; value.serverErrorText = nil
        return value
    }
}

/// The index never contains request or response bodies. Only selected pages load them.
private struct RequestLogBody: Codable, Equatable, Sendable {
    var requestText: String?
    var requestBodyJSON: String?
    var responseText: String?
    var reasoningText: String?
    var serverErrorText: String?

    init(_ entry: RequestLogEntry) {
        requestText = entry.requestText; requestBodyJSON = entry.requestBodyJSON; responseText = entry.responseText
        reasoningText = entry.reasoningText; serverErrorText = entry.serverErrorText
    }

    func applying(to entry: RequestLogEntry) -> RequestLogEntry {
        var value = entry
        value.requestText = requestText; value.requestBodyJSON = requestBodyJSON; value.responseText = responseText
        value.reasoningText = reasoningText; value.serverErrorText = serverErrorText
        return value
    }
}

/// Local request text and JSON bodies; credentials and audio never enter the archive.
@MainActor @Observable
final class RequestLogStore {
    static let shared = RequestLogStore()
    private(set) var calls: [RequestLogCall] = []
    private(set) var entries: [RequestLogEntry] = []
    private(set) var storageIssue: String?
    private(set) var revision = 0
    @ObservationIgnored private var bodiesDirectory: URL?
    @ObservationIgnored private var dirtyBodies: [UUID: RequestLogBody] = [:]
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var canWrite = false
    @ObservationIgnored private var needsBodyCleanup = true
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var saveRequested = false
#if os(iOS)
    @ObservationIgnored private var backgroundObserver: NotificationCenter.ObservationToken?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
#endif

    private struct Archive: Codable, Sendable {
        var version: Int? = nil
        var calls: [RequestLogCall]
        var entries: [RequestLogEntry]
    }

    /// An immutable snapshot crosses to the writer; observable state stays on MainActor.
    private struct WriteSnapshot: Sendable {
        let archive: Archive
        let bodies: [UUID: RequestLogBody]
        let file: URL
        let directory: URL
        let cleanup: Bool

        func write() throws {
            // Publish the index only after every referenced body has been stored.
            for (id, body) in bodies {
                try JSONEncoder().encode(body).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            }
            try JSONEncoder().encode(archive).write(to: file, options: .atomic)
            if cleanup {
                let retained = Set(archive.entries.map { $0.id.uuidString + ".json" })
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where url.pathExtension == "json" && !retained.contains(url.lastPathComponent) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    init(directory: URL? = nil) {
        do {
            var root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Tincall/RequestLogs", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            let file = root.appendingPathComponent("requests.json")
            self.file = file
            let bodies = root.appendingPathComponent("Bodies", isDirectory: true)
            bodiesDirectory = bodies
            try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                calls = archive.calls
                entries = archive.entries.sorted { $0.time < $1.time }
                if let version = archive.version, version > 2 { throw CocoaError(.coderReadCorrupt) }
                if archive.version != 2 {
                    // Finish all body writes before replacing the legacy archive. A partial
                    // migration leaves its original contents intact and can retry next launch.
                    for entry in entries {
                        try JSONEncoder().encode(RequestLogBody(entry)).write(to: bodyURL(entry.id), options: .atomic)
                    }
                    try JSONEncoder().encode(Archive(version: 2, calls: calls, entries: entries.map(\.indexEntry)))
                        .write(to: file, options: .atomic)
                }
                entries = entries.map(\.indexEntry)
            }
            canWrite = true
            // A terminated process cannot still have a request in flight.
            for index in entries.indices where entries[index].outcome == .pending {
                entries[index].outcome = .failed
                entries[index].errorCode = "process_ended"
            }
            prune()
            persist()
        } catch {
            storageIssue = String(localized: "请求日志读取失败（\((error as NSError).code)），原文件已保留。")
        }
#if os(iOS)
        backgroundObserver = NotificationCenter.default.addObserver(of: UIApplication.self, for: .didEnterBackground) { [weak self] _ in
            self?.flushInBackground()
        }
#endif
    }

    deinit {
#if os(iOS)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
#endif
    }

    func registerCall(id: UUID, startedAt: Date, mode: CallMode? = nil) {
        if let index = calls.firstIndex(where: { $0.id == id }) {
            if let mode, calls[index].mode != mode { calls[index].mode = mode; persist() }
            return
        }
        calls.append(RequestLogCall(id: id, startedAt: startedAt, mode: mode))
        prune(keepingCall: id)
        persist()
    }

    func registerTurn(callID: UUID, inputID: UUID, turnID: UUID) {
        ensureRound(RequestLogContext(callID: callID, roundID: inputID))
        if let call = calls.firstIndex(where: { $0.id == callID }),
           let round = calls[call].rounds.firstIndex(where: { $0.id == inputID }) {
            calls[call].rounds[round].turnID = turnID
            persist()
        }
    }

    func context(for turn: VoiceTurnID) -> RequestLogContext {
        let round = calls.first { $0.id == turn.session.callID }?.rounds.first { $0.turnID == turn.turnID }
        return RequestLogContext(callID: turn.session.callID, roundID: round?.id ?? turn.turnID)
    }

    func service(callID: UUID) -> RequestLogService {
        calls.first { $0.id == callID }?.mode == .mcp ? .mcp : .backend
    }

    func begin(service: RequestLogService, step: RequestLogStep, context: RequestLogContext? = nil,
               segment: Int? = nil, connectionName: String? = nil, modelName: String? = nil, requestText: String? = nil,
               deferred: Bool = false) -> RequestLogSpan {
        let entry = RequestLogEntry(id: UUID(), time: Date(), service: service, step: step,
                                    context: context, segment: segment, connectionName: RequestLogText.clean(connectionName),
                                    modelName: RequestLogText.clean(modelName), requestText: RequestLogText.clean(requestText))
        if !deferred { append(entry) }
        return RequestLogSpan(store: self, entry: entry, deferred: deferred)
    }

    func append(_ entry: RequestLogEntry) {
        if let context = entry.context { ensureRound(context) }
        let arrivedOutOfOrder = entries.last.map { $0.time > entry.time } ?? false
        entries.append(entry.indexEntry)
        // Deferred requests can finish after newer entries; normal appends are already ordered.
        if arrivedOutOfOrder { entries.sort { $0.time < $1.time } }
        dirtyBodies[entry.id] = RequestLogBody(entry)
        prune()
        persist()
    }

    func recordRequest(id: UUID, text: String?, omittedTurnCount: Int? = nil, conversationOffset: Int? = nil,
                                   persistImmediately: Bool = true, bodyJSON: String? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        do {
            var body = try readBody(for: entries[index])
            body.requestText = text ?? body.requestText
            body.requestBodyJSON = bodyJSON ?? body.requestBodyJSON
            dirtyBodies[id] = body
        } catch {
            reportBodyReadError(error)
            return
        }
        entries[index].omittedTurnCount = omittedTurnCount
        entries[index].requestConversationOffset = conversationOffset
        if persistImmediately { persist() } else { revision &+= 1 }
    }

    func finish(_ entry: RequestLogEntry) {
        prune()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let stoppedOnHangUp = entries[index].errorCode == "call_hang_up"
        do {
            let previous = try readBody(for: entries[index])
            var body = RequestLogBody(entry)
            body.requestText = body.requestText ?? previous.requestText
            body.requestBodyJSON = body.requestBodyJSON ?? previous.requestBodyJSON
            body.responseText = body.responseText ?? previous.responseText
            body.reasoningText = body.reasoningText ?? previous.reasoningText
            body.serverErrorText = body.serverErrorText ?? previous.serverErrorText
            dirtyBodies[entry.id] = body
        } catch {
            reportBodyReadError(error)
            return
        }
        entries[index] = entry.indexEntry
        if stoppedOnHangUp {
            entries[index].outcome = .cancelled
            entries[index].errorCode = "call_hang_up"
        }
        persist()
    }

    /// Tag in-flight requests before their tasks and recognizers are stopped.
    func markHangUp(callID: UUID) {
        for index in entries.indices where entries[index].context?.callID == callID && entries[index].outcome == .pending
            && [.transcription, .model, .events, .synthesis].contains(entries[index].step) {
            entries[index].outcome = .cancelled
            entries[index].errorCode = "call_hang_up"
        }
        persist()
    }

    private func ensureRound(_ context: RequestLogContext) {
        if !calls.contains(where: { $0.id == context.callID }) {
            registerCall(id: context.callID, startedAt: Date())
        }
        guard let roundID = context.roundID, let index = calls.firstIndex(where: { $0.id == context.callID }),
              !calls[index].rounds.contains(where: { $0.id == roundID }) else { return }
        calls[index].rounds.append(RequestLogRound(id: roundID))
    }

    private func prune(keepingCall: UUID? = nil) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        // Entries stay ordered, so routine updates need not sort or rebuild retention sets.
        if let oldest = entries.first, oldest.time < cutoff {
            entries.removeAll { $0.time < cutoff }
            needsBodyCleanup = true
            let retainedIDs = Set(entries.map(\.id))
            dirtyBodies = dirtyBodies.filter { retainedIDs.contains($0.key) }
        }
        guard !calls.isEmpty else { return }
        let retained = Set(entries.compactMap { $0.context?.callID })
        // Preserve the latest call even before its first STT/model request arrives.
        let latestCall = calls.max { $0.startedAt < $1.startedAt }?.id
        calls.removeAll { !retained.contains($0.id) && $0.id != keepingCall && $0.id != latestCall }
    }

    /// Filter and sort metadata before loading any full text.
    func matching(category: RequestLogCategory = .all, failuresOnly: Bool = false, callID: UUID? = nil) -> [RequestLogEntry] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return entries.filter {
            $0.time >= cutoff && (category == .all || $0.category == category)
                && (!failuresOnly || $0.outcome == .failed)
                && (callID == nil || $0.context?.callID == callID)
        }.sorted { $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time > $1.time }
    }

    func load(_ metadata: [RequestLogEntry]) throws -> [RequestLogEntry] {
        try metadata.map { try readBody(for: $0).applying(to: $0) }
    }

    private func bodyURL(_ id: UUID) throws -> URL {
        guard let bodiesDirectory else { throw CocoaError(.fileNoSuchFile) }
        return bodiesDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    private func readBody(for entry: RequestLogEntry) throws -> RequestLogBody {
        if let body = dirtyBodies[entry.id] { return body }
        // If a legacy migration failed, the untouched archive remains readable in memory.
        if entry.requestText != nil || entry.requestBodyJSON != nil || entry.responseText != nil || entry.reasoningText != nil || entry.serverErrorText != nil {
            return RequestLogBody(entry)
        }
        return try JSONDecoder().decode(RequestLogBody.self, from: Data(contentsOf: bodyURL(entry.id)))
    }

    private func reportBodyReadError(_ error: Error) {
        storageIssue = String(localized: "请求日志正文读取失败（\((error as NSError).code)），原文件已保留。")
    }

    func persist() {
        revision &+= 1
        guard canWrite else { return }
        saveRequested = true
        guard writeTask == nil else { return }
        writeTask = Task { await writePendingSnapshots() }
    }

    /// Wait for queued saves without blocking the UI thread.
    func flushPendingWrites() async {
        await writeTask?.value
    }

    private func writePendingSnapshots() async {
        defer { writeTask = nil }
        while saveRequested, let file, let bodiesDirectory {
            saveRequested = false
            let savedRevision = revision
            let snapshot = WriteSnapshot(archive: Archive(version: 2, calls: calls, entries: entries),
                bodies: dirtyBodies, file: file, directory: bodiesDirectory, cleanup: needsBodyCleanup)
            do {
                // Await one writer at a time. Updates during this write coalesce into
                // the next snapshot, so an older save can never overwrite a newer one.
                try await Task.detached(priority: .utility) { try snapshot.write() }.value
                for (id, body) in snapshot.bodies where dirtyBodies[id] == body {
                    dirtyBodies.removeValue(forKey: id)
                }
                if revision == savedRevision { needsBodyCleanup = false }
                storageIssue = nil
            } catch {
                // Keep all unsaved bodies readable and retry on the next save request.
                storageIssue = String(localized: "请求日志未能保存（\((error as NSError).code)），当前日志仍可查看。")
                return
            }
        }
    }

#if os(iOS)
    private func flushInBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Request logs") { [weak self] in
            Task { @MainActor in self?.endBackgroundWrite() }
        }
        persist()
        Task {
            await flushPendingWrites()
            endBackgroundWrite()
        }
    }

    private func endBackgroundWrite() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
#endif

}
