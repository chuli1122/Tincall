// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct RequestLogResponsivenessChecks {
    @MainActor static func main() async throws {
        struct Archive: Encodable {
            let version = 2
            let calls: [RequestLogCall] = []
            let entries: [RequestLogEntry]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallLogResponsiveness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let fixture = (0..<15_000).map { index in
            RequestLogEntry(id: UUID(), time: now.addingTimeInterval(-Double(index)), service: .mcp,
                step: .callControl, context: nil, segment: nil, duration: 0.1, outcome: .succeeded,
                connectionName: "Synthetic connection")
        }
        try JSONEncoder().encode(Archive(entries: fixture)).write(to: directory.appendingPathComponent("requests.json"))
        let store = RequestLogStore(directory: directory)
        await store.flushPendingWrites()
        // Shared CI runners can pause a single sample. Keep the same 50 ms budget,
        // using the median of five complete updates to detect sustained blocking.
        var samples: [Double] = []
        for sample in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let span = store.begin(service: .mcp, step: .callControl)
            span.request("Synthetic current call check")
            span.succeed("Synthetic no incoming call \(sample)")
            span.finish()
            samples.append(ProcessInfo.processInfo.systemUptime - start)
            await store.flushPendingWrites()
        }
        let elapsed = samples.sorted()[samples.count / 2]
        let timings = samples.map { String(Int($0 * 1000)) }.joined(separator: ", ")
        try FileHandle.standardError.write(contentsOf: Data("Main-actor log updates: [\(timings)] ms; median \(Int(elapsed * 1000)) ms with \(fixture.count) retained requests\n".utf8))
        // A long index write overlaps further updates to the same request body.
        let callID = UUID()
        let updating = store.begin(service: .mcp, step: .events, context: RequestLogContext(callID: callID))
        for index in 0..<6 {
            updating.request("Synthetic update \(index)")
            await Task.yield()
        }
        store.markHangUp(callID: callID)
        updating.succeed("Synthetic late completion"); updating.finish()
        await store.flushPendingWrites()
        let reopened = RequestLogStore(directory: directory)
        let saved = try reopened.load(Array(reopened.entries.suffix(samples.count + 1)))
        guard reopened.entries.count == fixture.count + samples.count + 1,
              saved.dropLast().enumerated().allSatisfy({ index, entry in
                  entry.responseText == "Synthetic no incoming call \(index)"
              }),
              saved.last?.requestText == "Synthetic update 5",
              saved.last?.responseText == "Synthetic late completion",
              saved.last?.errorCode == "call_hang_up", saved.last?.outcome == .cancelled else {
            throw NSError(domain: "RequestLogResponsivenessChecks", code: 2)
        }
        await reopened.flushPendingWrites()
        guard elapsed < 0.05 else {
            throw NSError(domain: "RequestLogResponsivenessChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Routine incoming-call checks have a median UI blocking time over 50 ms"])
        }
        print("PASS: prompt incoming-call logging, updates during saves, hangup and complete restart recovery")
    }
}
