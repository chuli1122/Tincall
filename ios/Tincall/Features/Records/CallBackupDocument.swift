// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UniformTypeIdentifiers

struct CallBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.folder] }
    let manifest: Data
    let media: [String: URL]

    init(manifest: Data, media: [String: URL]) {
        self.manifest = manifest
        self.media = media
    }

    init(configuration: ReadConfiguration) throws {
        // Imports use the validated, file-by-file CallRecordStore importer.
        throw TincallError(message: String(localized: "请使用通话记录页的导入按钮选择文件夹备份"))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var audio: [String: FileWrapper] = [:]
        for (name, url) in media {
            let file = try FileWrapper(url: url, options: [])
            file.preferredFilename = name
            audio[name] = file
        }
        return FileWrapper(directoryWithFileWrappers: [
            "record.json": FileWrapper(regularFileWithContents: manifest),
            "media": FileWrapper(directoryWithFileWrappers: audio)
        ])
    }
}
