// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

struct CloudSyncDocument: Codable, Equatable, Sendable {
    private static let maximumMediaCount = 50_000
    private static let maximumMediaBytes = 2 * 1024 * 1024 * 1024
    var format = "TincallRecord"
    var version = 1
    var call: CallRecord
    var media: [CloudSyncMedia] = []
    var imageReferences: [CloudSyncImageReference]?

    init(call: CallRecord, media: [CloudSyncMedia] = [], imageReferences: [CloudSyncImageReference]? = nil) {
        self.call = Self.textOnly(call)
        self.media = media
        let ids = Set(call.messages.flatMap { ($0.images ?? []).map(\.id) })
        self.imageReferences = imageReferences?.filter { ids.contains($0.id) }
    }

    static func textOnly(_ record: CallRecord) -> CallRecord {
        var value = record
        value.audioAssets = []
        value.externalConnectionID = nil
        if value.summaryStatus == .pending || value.summaryStatus == .generating { value.summaryStatus = .failed }
        value.externalCallID = nil; value.externalEventCursor = nil; value.externalEpoch = nil
        value.externalReplyID = nil; value.externalAnswerRequestID = nil; value.externalPendingInput = nil; value.externalPendingControl = nil
        return value
    }

    @MainActor func validated(recordID: UUID) throws -> CloudSyncDocument {
        guard format == "TincallRecord", version == 1, call.id == recordID,
              call.isFinished, call.audioAssets.isEmpty,
              Set(call.messages.map(\.id)).count == call.messages.count,
              Set(media.map(\.object_id)).count == media.count,
              Set(media.map { $0.asset.id }).count == media.count,
              media.count <= Self.maximumMediaCount else {
            throw TincallError(message: String(localized: "云端通话备份格式无效，未改动本机记录"))
        }
        let assets = call.messages.flatMap { $0.images ?? [] }
        let references = imageReferences ?? []
        guard Set(assets.map(\.id)).count == assets.count,
              Set(references.map(\.id)) == Set(assets.map(\.id)), references.count == assets.count,
              call.messages.allSatisfy({ ($0.images?.count ?? 0) <= 4 }) else {
            throw TincallError(message: String(localized: "云端消息图片引用不完整，未改动本机记录"))
        }
        for reference in references {
            guard ["image/jpeg", "image/png"].contains(reference.mime_type),
                  reference.bytes > 0, reference.bytes <= ConnectorMessageImage.maximumBytes else {
                throw TincallError(message: String(localized: "云端消息图片类型或大小无效"))
            }
        }
        var total = references.reduce(0) { $0 + $1.bytes }
        guard total <= Self.maximumMediaBytes else { throw TincallError(message: String(localized: "云端图片总量超过备份限制")) }
        var segments = Set<String>()
        for item in media {
            guard item.bytes > 0, item.bytes <= CloudSyncClient.maximumMediaBytes,
                  item.bytes <= Self.maximumMediaBytes - total,
                  item.asset.segmentIndex >= 0,
                  call.messages.contains(where: { $0.id == item.asset.messageID }),
                  segments.insert("\(item.asset.messageID):\(item.asset.segmentIndex)").inserted,
                  ["wav", "mp3", "m4a", "aac", "caf"].contains(item.fileExtension),
                  item.asset.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw TincallError(message: String(localized: "云端音频索引无效，未下载媒体"))
            }
            total += item.bytes
        }
        var clean = self
        clean.call = Self.textOnly(call)
        return clean
    }
}

struct CloudSyncMedia: Codable, Equatable, Identifiable, Sendable {
    let object_id: UUID
    let asset: CallAudioAsset
    let bytes: Int
    var id: UUID { object_id }
    var fileExtension: String { URL(fileURLWithPath: asset.relativePath).pathExtension.lowercased() }
}

struct CloudSyncRemote: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let revision: Int
    let deleted: Bool
    let updated_at: String
    var record: CloudSyncDocument?
    /// List-only facts from servers that provide them; the body still needs record.get.
    var summary: CloudSyncRemoteSummary? = nil
}

struct CloudSyncRemoteSummary: Codable, Equatable, Sendable {
    let role_name: String?
    /// Same encoding as CallRecord.startedAt in the stored document.
    let started_at: Date?
    let audio_count: Int
    let audio_bytes: Int64
    let image_count: Int
    let image_bytes: Int64
}

/// Bytes referenced by this owner's cloud backups, not the project's whole storage.
struct CloudSyncUsage: Codable, Equatable, Sendable {
    let records: Int
    let audio_count: Int
    let audio_bytes: Int64
    let image_count: Int
    let image_bytes: Int64
}

struct CloudSyncCursor: Codable, Equatable, Sendable {
    let after: String
    let after_id: UUID
}

struct CloudSyncCheckpoint: Codable, Sendable {
    var revision: Int
    var text: CallRecord?
    var deleted: Bool = false
    /// Local record/media removal never silently restores or overwrites a different cloud copy.
    var localRemoved: Bool = false
    /// Whether that cloud revision carried recordings. Losing them later means another phone removed them.
    var hadAudio: Bool?
}

/// A cloud media removal not yet confirmed; retried with the same request so the service finishes cleanup.
struct CloudMediaRemoval: Codable, Sendable {
    let requestID: UUID
    let revision: Int
    let audio: Bool
    let images: Bool
}

struct CloudSyncPending: Codable, Sendable {
    let requestID: UUID
    let recordID: UUID
    let expectedRevision: Int
    let document: CloudSyncDocument?
    var uploads: [CloudSyncMedia] = []
    var uploadedCount = 0
    var manifestAttempted = false
    var revisionRejected = false
    var preserveCallMedia: Bool?
    var isDelete: Bool { document == nil }
}

struct CloudSyncLedger: Codable, Sendable {
    let connectionID: UUID
    let endpoint: String
    let ownerID: UUID
    var checkpoints: [UUID: CloudSyncCheckpoint] = [:]
    var mediaConsent = false
    var pending: CloudSyncPending?
    /// Keep intentionally cleared recordings off this device until an explicit media restore.
    var locallyClearedAudio: Set<UUID>?
    /// Recordings / images removed from the cloud copy only. Sync keeps them off the cloud
    /// until an explicit re-upload; the local record keeps them.
    var cloudClearedAudio: Set<UUID>?
    var cloudClearedImages: Set<UUID>?
    var mediaRemovals: [UUID: CloudMediaRemoval]?
}

/// Compares actual saved content, never a hash or fingerprint.
enum CloudSyncDecision: Equatable {
    case upload, download, unchanged, conflict, cloudDeleted, locallyRemoved

    static func decide(local: CallRecord?, remote: CloudSyncRemote?, checkpoint: CloudSyncCheckpoint?) -> Self {
        if remote?.deleted == true { return .cloudDeleted }
        guard let local else {
            if checkpoint != nil { return .locallyRemoved }
            return remote == nil ? .unchanged : .download
        }
        let text = CloudSyncDocument.textOnly(local)
        guard let remote else {
            return checkpoint == nil ? .upload : .conflict
        }
        guard let document = remote.record else { return .conflict }
        if text == document.call { return .unchanged }
        guard let checkpoint, checkpoint.deleted == false, checkpoint.localRemoved == false else { return .conflict }
        if remote.revision == checkpoint.revision { return .upload }
        if text == checkpoint.text { return .download }
        return .conflict
    }
}

struct CloudSyncImageReference: Codable, Equatable, Sendable {
    let id: UUID
    let mime_type: String
    let bytes: Int
}

/// Only this adapter crosses the connector boundary. Local journals keep local asset paths;
/// the wire document carries image references or inline files, never device paths.
struct CloudSyncWireDocument: Codable {
    let document: CloudSyncDocument
    var images: [UUID: ConnectorMessageImage] = [:]
    private enum Keys: String, CodingKey { case format, version, call, media, messages, images }

    init(_ document: CloudSyncDocument, images: [UUID: ConnectorMessageImage] = [:]) {
        self.document = document; self.images = images
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        var call = try values.decode(CallRecord.self, forKey: .call)
        let wireCall = try values.nestedContainer(keyedBy: Keys.self, forKey: .call)
        var messages = try wireCall.nestedUnkeyedContainer(forKey: .messages)
        var references: [CloudSyncImageReference] = []
        for index in call.messages.indices {
            let message = try messages.nestedContainer(keyedBy: Keys.self)
            let refs = try message.decodeIfPresent([CloudSyncImageReference].self, forKey: .images) ?? []
            references += refs
            call.messages[index].images = refs.isEmpty ? nil : try refs.map { ref in
                guard ["image/jpeg", "image/png"].contains(ref.mime_type) else {
                    throw TincallError(message: String(localized: "云端消息图片类型无效"))
                }
                let ext = ref.mime_type == "image/png" ? "png" : "jpg"
                return CallImageAsset(id: ref.id, relativePath: "\(call.id.uuidString)/\(call.messages[index].id.uuidString)/\(ref.id.uuidString).\(ext)")
            }
        }
        var result = CloudSyncDocument(call: call, media: try values.decodeIfPresent([CloudSyncMedia].self, forKey: .media) ?? [])
        result.format = try values.decode(String.self, forKey: .format)
        result.version = try values.decode(Int.self, forKey: .version)
        result.imageReferences = references.isEmpty ? nil : references
        document = result
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(document.format, forKey: .format)
        try values.encode(document.version, forKey: .version)
        try values.encode(document.media, forKey: .media)
        let callEncoder = values.superEncoder(forKey: .call)
        var metadata = document.call
        metadata.messages = []
        try metadata.encode(to: callEncoder)
        var call = callEncoder.container(keyedBy: Keys.self)
        var messages = call.nestedUnkeyedContainer(forKey: .messages)
        for message in document.call.messages {
            let messageEncoder = messages.superEncoder()
            var text = message
            text.images = nil
            try text.encode(to: messageEncoder)
            var entry = messageEncoder.container(keyedBy: Keys.self)
            if let assets = message.images, !assets.isEmpty {
                var output = entry.nestedUnkeyedContainer(forKey: .images)
                for asset in assets {
                    if let input = images[asset.id] { try output.encode(input) }
                    else if let reference = document.imageReferences?.first(where: { $0.id == asset.id }) {
                        try output.encode(reference)
                    } else { throw TincallError(message: String(localized: "待备份消息图片缺失，未上传本机路径")) }
                }
            }
        }
    }
}
