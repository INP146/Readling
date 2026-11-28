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
    private static let maximumDocumentBytes = 16 * 1_024 * 1_024
    private static let maximumDocumentsBytes = 64 * 1_024 * 1_024
    /// Room left on the device after unpacking.
    private static let spareBytes: Int64 = 64 << 20
    /// Font obfuscation is not DRM: the text itself stays readable.
    private static let obfuscationAlgorithms: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
    /// Formats ImageIO can decode; SVG is not among them.
    private static let drawableImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "ico"]

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
        let title = url.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let (parsed, content, package, cover) = ext == "txt"
            ? try importText(url, id: id, title: title, staging: staging)
            : try importEPUB(url, id: id, fallbackTitle: title, staging: staging)
        var book = parsed
        book.chapters = content.chapterInfo
        book.coverAspectRatio = cover?.aspectRatio
        book.hasPackage = true
        return ImportedBook(book: book, content: content, package: package, cover: cover?.jpeg, fingerprint: hash)
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

    private static func importText(_ url: URL, id: UUID, title: String, staging: URL) throws -> (ReaderBook, BookContent, BookPackage, Cover?) {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumTextBytes { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumTextBytes else { throw ImportError.tooLarge }
        guard var text = decodeText(data), !text.contains("\0") else {
            throw ImportError.corrupt("无法识别 TXT 的文字编码，请另存为 UTF-8 后再试。")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let chapters = try PlainTextLayout.chapters(from: text)
        guard !chapters.isEmpty else { throw ImportError.empty }
        // Chapter detection and the removal of license text change the text, so the file itself is kept for export.
        let resources = staging.appendingPathComponent("res", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try data.write(to: resources.appendingPathComponent("0"))
        let package = BookPackage(kind: .text, entries: [.init(path: url.lastPathComponent, file: "0", isDocument: false)])
        let book = ReaderBook(id: id, title: title.isEmpty ? "Untitled" : title, author: "", chapters: [])
        return (book, BookContent(chapters: chapters), package, nil)
    }

    // MARK: EPUB

    private static func importEPUB(_ url: URL, id: UUID, fallbackTitle: String, staging: URL) throws -> (ReaderBook, BookContent, BookPackage, Cover?) {
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
        // Only content encrypted with a real cipher is DRM; font obfuscation is ignored.
        var encrypted = Set<String>()
        if let encryptionPath = entries.keys.first(where: { $0.lowercased() == "meta-inf/encryption.xml" }) {
            guard let encryption = try? XMLTree.parse(resource(encryptionPath)) else { throw ImportError.encrypted }
            for item in encryption.descendants("EncryptedData") {
                let algorithm = item.descendants("EncryptionMethod").first?.attributes["Algorithm"] ?? ""
                guard !obfuscationAlgorithms.contains(algorithm) else { continue }
                for reference in item.descendants("CipherReference") {
                    guard let uri = reference.attributes["URI"] else { continue }
                    encrypted.insert((try? resolve(uri, relativeTo: "")) ?? uri)
                }
            }
        }
        let encryptedPaths = encrypted
        let container = try XMLTree.parse(resource("META-INF/container.xml"))
        guard let rootfile = container.descendants("rootfile").first(where: { $0.attributes["media-type"] == "application/oebps-package+xml" }),
              let packagePath = rootfile.attributes["full-path"] else {
            throw ImportError.corrupt("EPUB 缺少内容清单。")
        }
        let opfPath = try resolve(packagePath, relativeTo: "")
        let package = try XMLTree.parse(resource(opfPath, limit: 8 * 1_024 * 1_024))
        guard let metadata = package.descendants("metadata").first,
              let manifest = package.descendants("manifest").first,
              let spine = package.descendants("spine").first else {
            throw ImportError.corrupt("EPUB 缺少书籍信息或阅读顺序。")
        }
        for meta in metadata.descendants("meta") {
            if meta.attributes["property"] == "rendition:layout" && meta.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated" {
                throw ImportError.fixedLayout
            }
            if meta.attributes["name"]?.lowercased() == "fixed-layout" && meta.attributes["content"]?.lowercased() == "true" {
                throw ImportError.fixedLayout
            }
        }
        struct Item {
            let path: String
            let media: String
            let properties: Set<String>
        }
        var items: [String: Item] = [:]
        for node in manifest.children where node.name == "item" {
            guard let id = node.attributes["id"], let href = node.attributes["href"], items[id] == nil,
                  let path = try? resolve(href, relativeTo: opfPath) else { continue }
            items[id] = Item(path: path, media: node.attributes["media-type"] ?? "",
                             properties: Set((node.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)))
        }
        // Navigation only supplies titles; a broken table of contents must not block the book.
        var titles: [String: String] = [:]
        if let navigation = items.values.first(where: { $0.properties.contains("nav") }),
           let nav = try? XMLTree.parse(resource(navigation.path)) {
            let navigationNodes = nav.descendants("nav")
            let toc = navigationNodes.first(where: { ($0.attribute("type") ?? "").split(separator: " ").contains("toc") }) ?? navigationNodes.first
            for anchor in toc?.descendants("a") ?? [] {
                guard let href = anchor.attributes["href"], let path = try? resolve(href, relativeTo: navigation.path) else { continue }
                let title = PlainTextLayout.cleanLabel(anchor.plainText)
                if titles[path] == nil && !title.isEmpty { titles[path] = title }
            }
        } else if let tocID = spine.attributes["toc"], let ncx = items[tocID], let nav = try? XMLTree.parse(resource(ncx.path)) {
            for point in nav.descendants("navPoint") {
                guard let content = point.children.first(where: { $0.name == "content" }),
                      let href = content.attributes["src"], let label = point.children.first(where: { $0.name == "navLabel" }),
                      let path = try? resolve(href, relativeTo: ncx.path) else { continue }
                if titles[path] == nil { titles[path] = PlainTextLayout.cleanLabel(label.plainText) }
            }
        }

        // Every file gets a stored name up front, so chapters can refer to images before they are unpacked.
        var files: [String: String] = [:]
        for (index, entry) in order.enumerated() where entry.type == .file { files[entry.path] = String(index) }
        var mediaTypes: [String: String] = [:]
        for item in items.values { mediaTypes[item.path] = item.media }
        let storedFiles = files
        let media = mediaTypes
        func imageFile(_ path: String) -> String? {
            guard let file = storedFiles[path], !encryptedPaths.contains(path) else { return nil }
            let type = media[path] ?? ""
            let ext = (path as NSString).pathExtension.lowercased()
            guard ext != "svg", type != "image/svg+xml" else { return nil }
            return type.hasPrefix("image/") || drawableImageExtensions.contains(ext) ? file : nil
        }

        let documents = staging.appendingPathComponent("docs", isDirectory: true)
        var documentFiles: [String: String] = [:]
        var chapters: [ReaderChapter] = []
        var contentBytes = 0
        var visited = Set<String>()
        var readable = 0
        for reference in spine.children where reference.name == "itemref" {
            try Task.checkCancellation()
            if reference.attributes["linear"] == "no" { continue }
            guard let id = reference.attributes["idref"], let item = items[id] else { continue }
            guard ["application/xhtml+xml", "text/html", "application/xml", "text/xml"].contains(item.media) else { continue }
            guard visited.insert(item.path).inserted, entries[item.path] != nil else { continue }
            guard !encryptedPaths.contains(item.path) else { throw ImportError.encrypted }
            let bytes = try resource(item.path, limit: maximumDocumentBytes)
            contentBytes += bytes.count
            guard contentBytes <= maximumDocumentsBytes else { throw ImportError.tooLarge }
            let context = ChapterRenderer.Context(documentPath: item.path, imageFile: imageFile,
                                                  resolve: { try? resolve($0, relativeTo: $1) })
            guard let extracted = try chapterText(bytes, context: context) else { continue }
            readable += 1
            // A document that parsed as XML is stored as a tree; anything else stays as the bytes it came in.
            if let document = extracted.document {
                try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                let name = String(documentFiles.count)
                try JSONEncoder().encode(document).write(to: documents.appendingPathComponent(name))
                documentFiles[item.path] = name
            }
            if extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let imageOnly = extracted.text.allSatisfy { $0 == "\u{FFFC}" || $0.isWhitespace }
            let title = [titles[item.path], extracted.heading, extracted.documentTitle].compactMap { $0 }.first(where: { !$0.isEmpty })
                ?? (imageOnly ? "插图" : "Chapter \(chapters.count + 1)")
            chapters += ChapterLayout.split(ReaderChapter(id: item.path, title: title, text: extracted.text, styles: extracted.styles,
                                                          source: item.path, anchors: extracted.anchors))
            guard chapters.count <= 2_000 else { throw ImportError.tooLarge }
        }
        guard !chapters.isEmpty else { throw readable == 0 && !visited.isEmpty ? ImportError.corrupt("书中的章节都无法解析。") : ImportError.empty }

        // Everything else, in the container's own order, goes to disk as it is.
        let resources = staging.appendingPathComponent("res", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var packaged: [BookPackage.Entry] = []
        for entry in order where entry.type == .file && entry.path != "mimetype" {
            try Task.checkCancellation()
            if let document = documentFiles[entry.path] {
                packaged.append(.init(path: entry.path, file: document, isDocument: true))
            } else if let file = files[entry.path] {
                try unpack(entry, from: archive, to: resources.appendingPathComponent(file))
                packaged.append(.init(path: entry.path, file: file, isDocument: false))
            }
        }

        let title = metadata.descendants("title").first.map { PlainTextLayout.cleanLabel($0.plainText) } ?? ""
        let authors = metadata.descendants("creator").map { PlainTextLayout.cleanLabel($0.plainText) }.filter { !$0.isEmpty }
        let book = ReaderBook(id: id, title: title.isEmpty ? fallbackTitle : title, author: authors.joined(separator: ", "), chapters: [])
        // EPUB 3 marks the cover in the manifest; EPUB 2 names it in <meta name="cover">.
        // A missing or undecodable cover never blocks the book.
        let coverName = metadata.descendants("meta").first { $0.attributes["name"]?.lowercased() == "cover" }?.attributes["content"]
        let coverItem = items.values.first { $0.properties.contains("cover-image") }
            ?? coverName.flatMap { name in items[name] ?? (try? resolve(name, relativeTo: opfPath)).flatMap { path in items.values.first { $0.path == path } } }
        var cover: Cover?
        if let coverItem, coverItem.media.hasPrefix("image/"), !encryptedPaths.contains(coverItem.path),
           let bytes = try? resource(coverItem.path, limit: 16 * 1_024 * 1_024) {
            try Task.checkCancellation()
            cover = Cover(bytes)
        }
        return (book, BookContent(chapters: chapters), BookPackage(kind: .epub, entries: packaged), cover)
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

    // MARK: Chapter documents

    private struct Rendered {
        var text: String
        var styles: [TextStyleRun]
        var anchors: [String: Int]
        var heading: String?
        var documentTitle: String?
        /// The parsed tree, when the document was well-formed XML.
        var document: XMLDocumentFile?
    }

    /// Strict XHTML first; real-world tag soup falls back to the lenient scanner.
    /// Returns nil only when neither can read the chapter.
    private static func chapterText(_ bytes: Data, context: ChapterRenderer.Context) throws -> Rendered? {
        do {
            let document = try XMLTree.parse(bytes)
            let body = document.descendants("body").first ?? document
            var renderer = ChapterRenderer(context: context)
            try render(body, into: &renderer)
            let result = renderer.finish()
            let heading = body.first(where: { ["h1", "h2", "h3"].contains($0.name) }).map { PlainTextLayout.cleanLabel($0.plainText) }
            let documentTitle = document.first(where: { $0.name == "title" }).map { PlainTextLayout.cleanLabel($0.plainText) }
            return Rendered(text: result.text, styles: result.styles, anchors: result.anchors, heading: heading,
                            documentTitle: documentTitle, document: XMLDocumentFile(doctype: document.doctype, root: document))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as XMLTree.UnsafeDocument {
            throw ImportError.corrupt(error.reason)
        } catch {
            guard let source = decodeText(bytes) else { return nil }
            let result = try LenientHTML.extract(source, context: context)
            return Rendered(text: result.text, styles: result.styles, anchors: result.anchors, heading: nil, documentTitle: nil, document: nil)
        }
    }

    static func render(_ node: XMLTree.Node, into renderer: inout ChapterRenderer) throws {
        if Task.isCancelled { throw CancellationError() }
        let name = node.name.lowercased()
        if name == "svg" {
            // Cover pages often wrap their picture in an svg; the pictures inside are drawn, the vector artwork is not.
            for image in node.descendants("image") {
                if let reference = image.attribute("href") { renderer.image(reference: reference, alt: node.attribute("aria-label")) }
            }
            return
        }
        if name == "math" || name.hasSuffix(":math") {
            renderer.math(node)
            return
        }
        guard renderer.enter(name, node.attributes) else { return }
        for part in node.content {
            switch part {
            case .text(let value): renderer.text(value)
            case .node(let child): try render(child, into: &renderer)
            case .comment, .instruction: break
            }
        }
        renderer.leave(name)
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
