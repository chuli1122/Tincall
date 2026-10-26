// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class ActivityRecoveryProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var attempts = 0
        var failures = 0
        var failureCode = URLError.Code.networkConnectionLost
        var status = 200
        var requestIDs: [String] = []
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "activity-check.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let requestID = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["request_id"] as? String
        let result: (Bool, URLError.Code, Int) = Self.state.lock.withLock {
            Self.state.attempts += 1
            Self.state.requestIDs.append(requestID ?? "missing")
            return (Self.state.attempts <= Self.state.failures, Self.state.failureCode, Self.state.status)
        }
        if result.0 {
            client?.urlProtocol(self, didFailWithError: URLError(result.1))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.2,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        let json = result.2 == 200 ? #"{"accepted_by_apns":true}"# : #"{"error":{"code":"activity_push_failed"}}"#
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct ActivityPushRecoveryChecks {
    struct CheckFailure: Error { let message: String }
    @MainActor static func main() async throws {
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector,
            endpoint: URL(string: "https://activity-check.invalid"))
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        let credentials = CredentialStore()
        try credentials.write("synthetic-only", connectionID: connection.id)
        defer { try? credentials.delete(connectionID: connection.id) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityRecoveryProtocol.self]
        let client = ExternalCallClient(credentials: credentials, configuration: configuration,
            logs: RequestLogStore(directory: directory), summaryUploadDirectory: directory.appendingPathComponent("summaries"))
        let state = ActivityRecoveryProtocol.state
        for (failures, code, status, expectedAttempts, expectedSuccess) in [
            (1, URLError.Code.networkConnectionLost, 200, 2, true),
            (2, .networkConnectionLost, 200, 2, false),
            (1, .timedOut, 200, 1, false),
            (0, .networkConnectionLost, 502, 1, false)
        ] {
            state.lock.withLock {
                state.attempts = 0; state.requestIDs = []
                state.failures = failures; state.failureCode = code; state.status = status
            }
            var succeeded = false
            do {
                try await client.startCallActivity(connection: connection, callID: UUID(), deviceID: UUID(),
                    avatarContactID: UUID(), displayName: "Synthetic")
                succeeded = true
            } catch { }
            let (attempts, ids) = state.lock.withLock { (state.attempts, state.requestIDs) }
            guard attempts == expectedAttempts, succeeded == expectedSuccess else {
                throw CheckFailure(message: "Expected \(expectedAttempts) attempts and success=\(expectedSuccess); got \(attempts), \(succeeded)")
            }
            guard ids.allSatisfy({ $0 != "missing" && $0 == ids.first }) else {
                throw CheckFailure(message: "Activity retry must reuse its request ID")
            }
        }
        state.lock.withLock {
            state.attempts = 0; state.requestIDs = []
            state.failures = 1; state.failureCode = .networkConnectionLost; state.status = 200
        }
        let cancelled = Task {
            try await client.startCallActivity(connection: connection, callID: UUID(), deviceID: UUID(),
                avatarContactID: UUID(), displayName: "Synthetic")
        }
        let deadline = Date().addingTimeInterval(2)
        while state.lock.withLock({ state.attempts == 0 }) {
            guard Date() < deadline else { throw CheckFailure(message: "Activity request did not begin") }
            try await Task.sleep(for: .milliseconds(5))
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            throw CheckFailure(message: "Cancelled activity start must fail")
        } catch is CancellationError { }
        guard state.lock.withLock({ state.attempts == 1 }) else {
            throw CheckFailure(message: "Cancellation must prevent the retry")
        }
        print("PASS: one retry reuses the request ID; repeat loss, timeout, HTTP rejection and cancellation do not keep retrying")
    }
}
