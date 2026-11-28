import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

/// All parsing is synchronous and CPU/file-bound; LibraryStore calls it in a cancellable detached task.
///
/// A book is read straight from its file, never loaded whole. Small XML files are
/// read into bounded memory; everything else is unpacked to disk one chunk at a
/// time, so the size of a book is limited by storage, not by memory.
enum BookImporter {
    struct ImportedBook: Sendable {
        let book: ReaderBook
        let content: BookContent
        let package: BookPackage
        /// A downscaled JPEG of the EPUB's own cover, when it has one.
        let cover: Data?
        let fingerprint: String
    }

    enum ImportError: LocalizedError {
        case unsupported, fixedLayout, tooLarge, corrupt(String), encrypted, unsafePath, empty, noSpace
        var errorDescription: String? {
            switch self {
            case .unsupported: "只支持 EPUB 和 TXT 文件。PDF、MOBI 等格式可以先用 Calibre 等工具转换成 EPUB。"
            case .fixedLayout: "这是固定版式（图片或漫画类）的 EPUB，没有可以逐词阅读的文字。"
            case .tooLarge: "这本书太大了：文件最大 1 GB，解压后最大 2 GB。"
            case .corrupt(let reason): "无法打开这本书。\(reason)"
            case .encrypted: "这本书受 DRM 保护，正文被加密，无法读取。请使用无 DRM 的版本。"
            case .unsafePath: "这个 EPUB 包含不安全或无效的文件路径。"
            case .empty: "这本书中没有找到可阅读的文字。"
            case .noSpace: "这台设备的储存空间不够，放不下这本书。"
            }
        }
    }

    // The limits keep a hostile archive from filling the disk or the memory; an honest book is nowhere near them.
    private static let maximumFileBytes: UInt64 = 1 << 30
    private static let maximumExpandedBytes: UInt64 = 2 << 30
    private static let maximumEntryBytes: UInt64 = 512 << 20
    private static let maximumEntries = 20_000
    private static let maximumTextBytes = 16 * 1_024 * 1_024
    /// One chapter document is parsed in memory.
    static let maximumDocumentBytes = 16 * 1_024 * 1_024
    private static let maximumDocumentsBytes = 64 * 1_024 * 1_024
    /// Room left on the device after unpacking.
    private static let spareBytes: Int64 = 64 << 20
    /// Formats ImageIO can decode; SVG is not among them.
    static let drawableImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "ico"]

    /// The SHA-256 of a file, read in chunks. Identical bytes are the same book under any name.
    static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            total += UInt64(chunk.count)
            guard total <= maximumFileBytes else { throw ImportError.tooLarge }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a book. Files that are not chapter text are written under `staging`, which
    /// the caller owns: it moves the directory into place on success and deletes it on failure.
    static func load(url: URL, id: UUID = UUID(), staging: URL, fingerprint: String? = nil) throws -> ImportedBook {
        do { return try loadFile(url: url, id: id, staging: staging, fingerprint: fingerprint) }
        catch is CancellationError { throw CancellationError() }
        catch let error as ImportError { throw error }
        catch let error as CocoaError where error.code == .fileWriteOutOfSpace { throw ImportError.noSpace }
        catch { throw ImportError.corrupt("无法读取所选文件，请确认文件已下载到本机。") }
    }

    private static func loadFile(url: URL, id: UUID, staging: URL, fingerprint: String?) throws -> ImportedBook {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        guard ext == "epub" || ext == "txt" else { throw ImportError.unsupported }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError.unsupported }
        if let size = values.fileSize, UInt64(size) > maximumFileBytes { throw ImportError.tooLarge }
        let hash = try fingerprint ?? Self.fingerprint(of: url)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let package = ext == "txt" ? try unpackText(url, staging: staging) : try unpackEPUB(url, staging: staging)
        // The text comes from the stored files, exactly as a rebuild would make it.
        let directory = BookDirectory(url: staging)
        let built = try BookBuilder.build(from: directory, package: package)
        let cover = BookBuilder.cover(from: directory, package: package)
        let fileTitle = url.deletingPathExtension().lastPathComponent
        let title = built.title.flatMap { $0.isEmpty ? nil : $0 } ?? (fileTitle.isEmpty ? "Untitled" : fileTitle)
        var book = ReaderBook(id: id, title: title, author: built.author, chapters: built.content.chapterInfo)
        book.coverAspectRatio = cover?.aspectRatio
        book.hasPackage = true
        book.contentFile = BookDirectory.firstContentFile
        return ImportedBook(book: book, content: built.content, package: package, cover: cover?.jpeg, fingerprint: hash)
    }

    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Older English texts are often Windows-1252 / Latin-1. Reject binaries.
        guard !data.prefix(4_096).contains(0) else { return nil }
        return String(data: data, encoding: .windowsCP1252)
    }

    // MARK: TXT

    /// The file itself is the whole book: chapter detection and the removal of license text change the text, so
    /// the original is kept for export and for building the text again.
    private static func unpackText(_ url: URL, staging: URL) throws -> BookPackage {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumTextBytes { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumTextBytes else { throw ImportError.tooLarge }
        let resources = staging.appendingPathComponent("res", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try data.write(to: resources.appendingPathComponent("0"))
        return BookPackage(kind: .text, entries: [.init(path: url.lastPathComponent, file: "0", isDocument: false)])
    }

    // MARK: EPUB

    /// Checks the archive and stores every file of it: chapter documents that are well-formed XML as trees
    /// (`docs/`), everything else byte for byte (`res/`), in the container's own order.
    private static func unpackEPUB(_ url: URL, staging: URL) throws -> BookPackage {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw ImportError.corrupt("文件不是有效的 EPUB（ZIP 压缩包损坏）。") }
        var entries: [String: Entry] = [:]
        var order: [Entry] = []
        var expanded: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            guard order.count < maximumEntries else { throw ImportError.tooLarge }
            guard validArchivePath(entry.path) else { throw ImportError.unsafePath }
            guard entry.type == .file || entry.type == .directory else { throw ImportError.unsafePath }
            guard entries[entry.path] == nil else { throw ImportError.corrupt("ZIP 压缩包包含重复的文件名。") }
            if entry.type == .file {
                guard entry.uncompressedSize <= maximumEntryBytes else { throw ImportError.tooLarge }
                // Deflate cannot honestly shrink a large file this much; that is how a zip bomb looks.
                if entry.uncompressedSize > 8 << 20, entry.compressedSize &* 100 < entry.uncompressedSize { throw ImportError.tooLarge }
                expanded += entry.uncompressedSize
                guard expanded <= maximumExpandedBytes else { throw ImportError.tooLarge }
            }
            entries[entry.path] = entry
            order.append(entry)
        }
        if let free = try? staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Int64(expanded) + spareBytes {
            throw ImportError.noSpace
        }

        func resource(_ path: String, limit: Int = 2 * 1_024 * 1_024) throws -> Data {
            try Task.checkCancellation()
            guard let entry = entries[path], entry.type == .file else {
                throw ImportError.corrupt("EPUB 缺少必要文件：\(path)")
            }
            guard entry.uncompressedSize <= UInt64(limit) else { throw ImportError.tooLarge }
            var output = Data()
            do {
                let checksum = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false) { chunk in
                    try Task.checkCancellation()
                    guard output.count + chunk.count <= limit else { throw ImportError.tooLarge }
                    output.append(chunk)
                }
                guard checksum == entry.checksum, UInt64(output.count) == entry.uncompressedSize else {
                    throw ImportError.corrupt("ZIP 文件完整性校验失败。")
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as ImportError { throw error }
            catch { throw ImportError.corrupt("ZIP 中的文件已损坏。") }
            return output
        }

        let mime = try resource("mimetype", limit: 128)
        guard String(data: mime, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw ImportError.corrupt("文件不是有效的 EPUB。")
        }
        let opf = try EPUBPackageDocument({ try resource($0, limit: $1) },
                                          encryptionPath: entries.keys.first { $0.lowercased() == "meta-inf/encryption.xml" })
        var chapterDocuments = Set<String>()
        for item in opf.spine where entries[item.path] != nil {
            guard !opf.encrypted.contains(item.path) else { throw ImportError.encrypted }
            chapterDocuments.insert(item.path)
        }

        let documents = staging.appendingPathComponent("docs", isDirectory: true)
        let resources = staging.appendingPathComponent("res", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var packaged: [BookPackage.Entry] = []
        var documentCount = 0
        var contentBytes = 0
        for (index, entry) in order.enumerated() where entry.type == .file && entry.path != "mimetype" {
            try Task.checkCancellation()
            let file = String(index)
            guard chapterDocuments.contains(entry.path) else {
                try unpack(entry, from: archive, to: resources.appendingPathComponent(file))
                packaged.append(.init(path: entry.path, file: file, isDocument: false))
                continue
            }
            let bytes = try resource(entry.path, limit: maximumDocumentBytes)
            contentBytes += bytes.count
            guard contentBytes <= maximumDocumentsBytes else { throw ImportError.tooLarge }
            // A document that parses as XML is stored as a tree; anything else stays as the bytes it came in.
            do {
                let document = try XMLTree.parse(bytes)
                try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                let name = String(documentCount)
                documentCount += 1
                try JSONEncoder().encode(XMLDocumentFile(doctype: document.doctype, root: document)).write(to: documents.appendingPathComponent(name))
                packaged.append(.init(path: entry.path, file: name, isDocument: true))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as XMLTree.UnsafeDocument {
                throw ImportError.corrupt(error.reason)
            } catch {
                try bytes.write(to: resources.appendingPathComponent(file))
                packaged.append(.init(path: entry.path, file: file, isDocument: false))
            }
        }
        return BookPackage(kind: .epub, entries: packaged)
    }

    /// Writes one archive entry to `destination` chunk by chunk, checking its size and CRC as it goes.
    private static func unpack(_ entry: Entry, from archive: Archive, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: UInt64 = 0
        do {
            let checksum = try archive.extract(entry, bufferSize: 256 * 1_024, skipCRC32: false) { chunk in
                try Task.checkCancellation()
                written += UInt64(chunk.count)
                // More data than the archive declared is a lie about the size, not a bigger file.
                guard written <= entry.uncompressedSize else { throw ImportError.corrupt("ZIP 文件完整性校验失败。") }
                try handle.write(contentsOf: chunk)
            }
            guard checksum == entry.checksum, written == entry.uncompressedSize else {
                throw ImportError.corrupt("ZIP 文件完整性校验失败。")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ImportError { throw error }
        catch let error as CocoaError where error.code == .fileWriteOutOfSpace { throw ImportError.noSpace }
        catch { throw ImportError.corrupt("ZIP 中的文件已损坏。") }
    }

    struct Cover {
        static let maximumPixelSize = 900
        let jpeg: Data
        /// Width over height, kept within ordinary book proportions.
        let aspectRatio: Double

        /// Decodes through a bounded thumbnail so a huge image never expands fully in memory.
        init?(_ data: Data) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width * height <= 100_000_000 else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            jpeg = output as Data
            aspectRatio = min(1, max(0.5, Double(image.width) / Double(image.height)))
        }
    }

    private static func validArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 2_048, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, part in
            part != "." && part != ".." && (!part.isEmpty || index == components.count - 1)
        }
    }

    /// Resolve URI references without ever trusting URL/file normalization or writing a ZIP path to disk.
    static func resolve(_ href: String, relativeTo base: String) throws -> String {
        guard href.utf8.count <= 4_096 else { throw ImportError.unsafePath }
        let raw = String(href.prefix { $0 != "#" && $0 != "?" })
        guard let decoded = raw.removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains(":"), !decoded.contains("\0") else { throw ImportError.unsafePath }
        if decoded.isEmpty { return base }
        var components = base.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { throw ImportError.unsafePath }
                components.removeLast()
            } else { components.append(String(part)) }
        }
        guard !components.isEmpty else { throw ImportError.unsafePath }
        return components.joined(separator: "/")
    }
}
