import Foundation

/// Builds a book's reading text from its stored files (see `BookDirectory`), and nothing else.
///
/// Import unpacks a book (`BookImporter`) and then calls this; a migration that asks for the text to be rebuilt
/// calls it again on the same files. There is one way to turn a book into chapters, so a rebuilt book reads exactly
/// like a newly imported one.
enum BookBuilder {
    typealias ImportError = BookImporter.ImportError

    struct Built: Sendable {
        let content: BookContent
        /// The book's own title and author; nil or empty when it has none (the caller falls back to the file name).
        let title: String?
        let author: String
    }

    static let maximumChapters = 2_000

    static func build(from directory: BookDirectory, package: BookPackage) throws -> Built {
        switch package.kind {
        case .text: try buildText(directory, package)
        case .epub: try buildEPUB(PackageFiles(directory: directory, package: package))
        }
    }

    /// The EPUB's own cover as a downscaled JPEG, when it has one it can draw. A missing or broken cover is nil.
    static func cover(from directory: BookDirectory, package: BookPackage) -> BookImporter.Cover? {
        guard package.kind == .epub else { return nil }
        let files = PackageFiles(directory: directory, package: package)
        guard let opf = try? EPUBPackageDocument(files.data, encryptionPath: files.path(matching: "meta-inf/encryption.xml")), let path = opf.coverPath, !opf.encrypted.contains(path),
              let bytes = try? files.data(path, 16 * 1_024 * 1_024) else { return nil }
        return BookImporter.Cover(bytes)
    }

    // MARK: TXT

    private static func buildText(_ directory: BookDirectory, _ package: BookPackage) throws -> Built {
        guard let entry = package.entries.first else { throw ImportError.empty }
        let data = try Data(contentsOf: directory.resource(entry.file))
        guard var text = BookImporter.decodeText(data), !text.contains("\0") else {
            throw ImportError.corrupt("无法识别 TXT 的文字编码，请另存为 UTF-8 后再试。")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let chapters = try PlainTextLayout.chapters(from: text)
        guard !chapters.isEmpty else { throw ImportError.empty }
        let title = ((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return Built(content: BookContent(chapters: chapters), title: title, author: "")
    }

    // MARK: EPUB

    private static func buildEPUB(_ files: PackageFiles) throws -> Built {
        let opf = try EPUBPackageDocument(files.data, encryptionPath: files.path(matching: "meta-inf/encryption.xml"))
        let titles = navigationTitles(opf, files)
        func imageFile(_ path: String) -> String? {
            guard let entry = files.entry(path), !entry.isDocument, !opf.encrypted.contains(path) else { return nil }
            let type = opf.mediaType(of: path) ?? ""
            let ext = (path as NSString).pathExtension.lowercased()
            guard ext != "svg", type != "image/svg+xml" else { return nil }
            return type.hasPrefix("image/") || BookImporter.drawableImageExtensions.contains(ext) ? entry.file : nil
        }

        var chapters: [ReaderChapter] = []
        var readable = 0
        for item in opf.spine {
            try Task.checkCancellation()
            guard files.entry(item.path) != nil else { continue }
            guard !opf.encrypted.contains(item.path) else { throw ImportError.encrypted }
            let context = ChapterRenderer.Context(documentPath: item.path, imageFile: imageFile,
                                                  resolve: { try? BookImporter.resolve($0, relativeTo: $1) })
            guard let extracted = try chapterText(files, item.path, context: context) else { continue }
            readable += 1
            if extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let imageOnly = extracted.text.allSatisfy { $0 == "\u{FFFC}" || $0.isWhitespace }
            let title = [titles[item.path], extracted.heading, extracted.documentTitle].compactMap { $0 }.first(where: { !$0.isEmpty })
                ?? (imageOnly ? "插图" : "Chapter \(chapters.count + 1)")
            chapters += ChapterLayout.split(ReaderChapter(id: item.path, title: title, text: extracted.text, styles: extracted.styles,
                                                          source: item.path, anchors: extracted.anchors))
            guard chapters.count <= maximumChapters else { throw ImportError.tooLarge }
        }
        guard !chapters.isEmpty else {
            throw readable == 0 && !opf.spine.isEmpty ? ImportError.corrupt("书中的章节都无法解析。") : ImportError.empty
        }
        let title = opf.metadata.descendants("title").first.map { PlainTextLayout.cleanLabel($0.plainText) }
        let authors = opf.metadata.descendants("creator").map { PlainTextLayout.cleanLabel($0.plainText) }.filter { !$0.isEmpty }
        return Built(content: BookContent(chapters: chapters), title: title, author: authors.joined(separator: ", "))
    }

    /// Chapter titles from the table of contents. Navigation only supplies titles; a broken one must not block the book.
    private static func navigationTitles(_ opf: EPUBPackageDocument, _ files: PackageFiles) -> [String: String] {
        var titles: [String: String] = [:]
        if let navigation = opf.navigationPath, let nav = try? files.tree(navigation) {
            let navigationNodes = nav.descendants("nav")
            let toc = navigationNodes.first(where: { ($0.attribute("type") ?? "").split(separator: " ").contains("toc") }) ?? navigationNodes.first
            for anchor in toc?.descendants("a") ?? [] {
                guard let href = anchor.attributes["href"], let path = try? BookImporter.resolve(href, relativeTo: navigation) else { continue }
                let title = PlainTextLayout.cleanLabel(anchor.plainText)
                if titles[path] == nil && !title.isEmpty { titles[path] = title }
            }
        } else if let ncx = opf.ncxPath, let nav = try? files.tree(ncx) {
            for point in nav.descendants("navPoint") {
                guard let content = point.children.first(where: { $0.name == "content" }),
                      let href = content.attributes["src"], let label = point.children.first(where: { $0.name == "navLabel" }),
                      let path = try? BookImporter.resolve(href, relativeTo: ncx) else { continue }
                if titles[path] == nil { titles[path] = PlainTextLayout.cleanLabel(label.plainText) }
            }
        }
        return titles
    }

    // MARK: Chapter documents

    struct Rendered {
        var text: String
        var styles: [TextStyleRun]
        var anchors: [String: Int]
        var heading: String?
        var documentTitle: String?
    }

    /// A stored tree is rendered as it is; stored bytes are tag soup the strict parser refused at import, but are
    /// still tried as XML first, then read by the lenient scanner. Nil only when neither can read the chapter.
    private static func chapterText(_ files: PackageFiles, _ path: String, context: ChapterRenderer.Context) throws -> Rendered? {
        if files.entry(path)?.isDocument == true { return try render(document: files.tree(path), context: context) }
        let bytes = try files.data(path, BookImporter.maximumDocumentBytes)
        if let document = try? XMLTree.parse(bytes) { return try render(document: document, context: context) }
        guard let source = BookImporter.decodeText(bytes) else { return nil }
        let result = try LenientHTML.extract(source, context: context)
        return Rendered(text: result.text, styles: result.styles, anchors: result.anchors, heading: nil, documentTitle: nil)
    }

    static func render(document: XMLTree.Node, context: ChapterRenderer.Context) throws -> Rendered {
        let body = document.descendants("body").first ?? document
        var renderer = ChapterRenderer(context: context)
        try render(body, into: &renderer)
        let result = renderer.finish()
        let heading = body.first(where: { ["h1", "h2", "h3"].contains($0.name) }).map { PlainTextLayout.cleanLabel($0.plainText) }
        let documentTitle = document.first(where: { $0.name == "title" }).map { PlainTextLayout.cleanLabel($0.plainText) }
        return Rendered(text: result.text, styles: result.styles, anchors: result.anchors, heading: heading, documentTitle: documentTitle)
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
}

/// A stored book's files by their path inside the original container.
struct PackageFiles {
    let directory: BookDirectory
    private let entries: [String: BookPackage.Entry]

    init(directory: BookDirectory, package: BookPackage) {
        self.directory = directory
        entries = Dictionary(package.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func entry(_ path: String) -> BookPackage.Entry? { entries[path] }

    /// The stored path that matches regardless of case, such as an archive's `META-INF/Encryption.xml`.
    func path(matching lowercased: String) -> String? { entries.keys.first { $0.lowercased() == lowercased } }

    /// The bytes of a file kept as it came; documents kept as trees are serialized.
    func data(_ path: String, _ limit: Int) throws -> Data {
        guard let entry = entries[path] else { throw BookImporter.ImportError.corrupt("EPUB 缺少必要文件：\(path)") }
        if entry.isDocument { return XMLTree.serialize(try storedTree(entry)) }
        let url = directory.resource(entry.file)
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { throw BookImporter.ImportError.tooLarge }
        return try Data(contentsOf: url)
    }

    /// A file as an XML tree: the stored tree for a document, else its bytes parsed.
    func tree(_ path: String) throws -> XMLTree.Node {
        if let entry = entries[path], entry.isDocument { return try storedTree(entry).root }
        return try XMLTree.parse(data(path, 2 * 1_024 * 1_024))
    }

    private func storedTree(_ entry: BookPackage.Entry) throws -> XMLDocumentFile {
        try JSONDecoder().decode(XMLDocumentFile.self, from: Data(contentsOf: directory.document(entry.file)))
    }
}

/// What an EPUB's package document says: where things are and in what order. Read at import, from the archive,
/// and when building text, from the stored files; `read` returns a file's bytes, refusing any above the limit.
struct EPUBPackageDocument {
    struct Item {
        let path: String
        let media: String
        let properties: Set<String>
    }

    let path: String
    let metadata: XMLTree.Node
    let items: [String: Item]
    /// The documents read in order: linear, of a type that holds text, each once.
    let spine: [Item]
    /// Files encrypted with a real cipher (DRM); font obfuscation is not.
    let encrypted: Set<String>
    let navigationPath: String?
    let ncxPath: String?
    let coverPath: String?

    static let textTypes: Set<String> = ["application/xhtml+xml", "text/html", "application/xml", "text/xml"]
    private static let obfuscationAlgorithms: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]

    init(_ read: (_ path: String, _ limit: Int) throws -> Data, encryptionPath: String?) throws {
        typealias ImportError = BookImporter.ImportError
        var encrypted = Set<String>()
        if let encryptionPath, let bytes = try? read(encryptionPath, 2 * 1_024 * 1_024) {
            guard let encryption = try? XMLTree.parse(bytes) else { throw ImportError.encrypted }
            for item in encryption.descendants("EncryptedData") {
                let algorithm = item.descendants("EncryptionMethod").first?.attributes["Algorithm"] ?? ""
                guard !Self.obfuscationAlgorithms.contains(algorithm) else { continue }
                for reference in item.descendants("CipherReference") {
                    guard let uri = reference.attributes["URI"] else { continue }
                    encrypted.insert((try? BookImporter.resolve(uri, relativeTo: "")) ?? uri)
                }
            }
        }
        self.encrypted = encrypted
        let container = try XMLTree.parse(read("META-INF/container.xml", 2 * 1_024 * 1_024))
        guard let rootfile = container.descendants("rootfile").first(where: { $0.attributes["media-type"] == "application/oebps-package+xml" }),
              let packagePath = rootfile.attributes["full-path"] else {
            throw ImportError.corrupt("EPUB 缺少内容清单。")
        }
        let opfPath = try BookImporter.resolve(packagePath, relativeTo: "")
        path = opfPath
        let package = try XMLTree.parse(read(opfPath, 8 * 1_024 * 1_024))
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
        self.metadata = metadata
        var items: [String: Item] = [:]
        for node in manifest.children where node.name == "item" {
            guard let id = node.attributes["id"], let href = node.attributes["href"], items[id] == nil,
                  let path = try? BookImporter.resolve(href, relativeTo: opfPath) else { continue }
            items[id] = Item(path: path, media: node.attributes["media-type"] ?? "",
                             properties: Set((node.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)))
        }
        self.items = items
        mediaTypes = Dictionary(items.values.map { ($0.path, $0.media) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<String>()
        self.spine = spine.children.compactMap { reference -> Item? in
            guard reference.name == "itemref", reference.attributes["linear"] != "no",
                  let id = reference.attributes["idref"], let item = items[id], Self.textTypes.contains(item.media),
                  visited.insert(item.path).inserted else { return nil }
            return item
        }
        navigationPath = items.values.first(where: { $0.properties.contains("nav") })?.path
        ncxPath = spine.attributes["toc"].flatMap { items[$0]?.path }
        // EPUB 3 marks the cover in the manifest; EPUB 2 names it in <meta name="cover">.
        let coverName = metadata.descendants("meta").first { $0.attributes["name"]?.lowercased() == "cover" }?.attributes["content"]
        let coverItem = items.values.first { $0.properties.contains("cover-image") }
            ?? coverName.flatMap { name in items[name] ?? (try? BookImporter.resolve(name, relativeTo: opfPath)).flatMap { path in items.values.first { $0.path == path } } }
        coverPath = coverItem.flatMap { $0.media.hasPrefix("image/") ? $0.path : nil }
    }

    private let mediaTypes: [String: String]

    func mediaType(of path: String) -> String? { mediaTypes[path] }
}
