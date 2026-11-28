import Foundation
import Observation

/// Library metadata and saved words live in one small JSON file; each book has
/// its own directory under `books/` (see `BookDirectory`), written once at
/// import. Saving a position or a word therefore rewrites kilobytes, never books.
@MainActor @Observable
final class LibraryStore {
    private(set) var books: [ReaderBook] = []
    private(set) var favorites: [SavedPassage] = []
    var errorMessage: String?
    /// Set when the saved library exists but cannot be read. Nothing is written
    /// until the reader chooses to retry or to set the unreadable file aside.
    private(set) var readFailure: String?

    /// The newer app version the saved data belongs to. Nothing is read or written then: like iOS, the app doesn't
    /// go back a version with its data (see docs/data-versioning.md 3.6).
    private(set) var newerDataVersion: String?
    /// What bringing the data up to date did at launch.
    private(set) var migrationOutcome: Migrator.Outcome = .upToDate
    /// Reading text being rebuilt from the stored originals after a migration asked for it.
    private(set) var rebuild = RebuildStatus()

    struct RebuildStatus: Equatable {
        /// Books still to rebuild, in order.
        var pending: [UUID] = []
        /// How many books this round started with.
        var total = 0
        /// The book being rebuilt now.
        var current: UUID?
        var failures: [UUID: String] = [:]
        var isFinished: Bool { pending.isEmpty && current == nil }
        var done: Int { max(0, total - pending.count - (current == nil ? 0 : 1)) }
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored let settings: SettingsDomain
    @ObservationIgnored private var fingerprints: [String: UUID] = [:]
    @ObservationIgnored private var pendingPositionSave: Task<Void, Never>?
    @ObservationIgnored private var contentCache: (id: UUID, content: BookContent)?
    @ObservationIgnored private var rebuildTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rebuildWorker: Task<Void, Never>?

    static let reviewIntervals: [Double] = [1, 2, 4, 7, 15, 30] // days
    /// The `version` of `library.json` this app writes (see `V0_2_0.Library`).
    nonisolated static let libraryVersion = 3

    private struct Snapshot: Codable {
        var version: Int = LibraryStore.libraryVersion
        var books: [ReaderBook]
        var favorites: [SavedPassage]
        var fingerprints: [String: UUID]
    }

    /// `fileURL` is `library.json` inside the data directory, which also holds the books and the migration state.
    init(fileURL: URL? = nil, settings: SettingsDomain = .standard) {
        self.fileURL = fileURL ?? URL.appData.appendingPathComponent("library.json")
        self.settings = settings
        start()
    }

    private func start() {
        migrationOutcome = migrator.run()
        switch migrationOutcome {
        case .tooNew(let version):
            newerDataVersion = version
            return
        case .failed(_, let reason):
            readFailure = "无法升级已保存的数据，原文件没有被改动。\(reason)"
            return
        case .fresh, .upToDate, .migrated:
            break
        }
        load()
        // An import that was interrupted leaves its unpacked files behind.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)) ?? [] where name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent(name))
        }
        if readFailure == nil { resumeRebuilding() }
    }

    private var dataDirectory: URL { fileURL.deletingLastPathComponent() }

    private var booksDirectory: URL { dataDirectory.appendingPathComponent("books", isDirectory: true) }

    var migrator: Migrator { Migrator(directory: dataDirectory, settings: settings) }

    /// The version the data is at, for the 数据与升级 page.
    var dataVersionLabel: String {
        switch migrationOutcome {
        case .tooNew(let version): version
        case .failed(let from, _): "\(from)（未升级）"
        case .fresh, .upToDate, .migrated: DataVersion.current
        }
    }

    func directory(for id: UUID) -> BookDirectory { BookDirectory(url: booksDirectory.appendingPathComponent(id.uuidString, isDirectory: true)) }

    func coverURL(for book: ReaderBook) -> URL? {
        book.coverAspectRatio == nil ? nil : directory(for: book.id).cover
    }

    /// Where the book's images are, for drawing them; nil for the sample.
    func resourcesURL(for book: ReaderBook) -> URL? { book.isSample ? nil : directory(for: book.id).resources }

    /// Runs blocking work off the main thread, cancelling it when the caller is cancelled.
    private func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    // MARK: Loading and recovery

    func retryLoading() {
        rebuildWorker?.cancel()
        rebuildWorker = nil
        for task in rebuildTasks.values { task.cancel() }
        rebuildTasks = [:]
        readFailure = nil
        errorMessage = nil
        newerDataVersion = nil
        books = []
        favorites = []
        fingerprints = [:]
        contentCache = nil
        rebuild = RebuildStatus()
        start()
    }

    /// Moves the whole data directory aside (never deletes it) and starts afresh. The way out when the data belongs
    /// to a newer version of the app.
    func setAsideNewerData() {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let aside = dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(dataDirectory.lastPathComponent)-\(newerDataVersion ?? "newer")-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: dataDirectory, to: aside)
        } catch {
            errorMessage = "无法移动这些数据，请检查储存空间后重试。"
            return
        }
        retryLoading()
    }

    /// Moves the unreadable file aside (never deletes it) and starts a fresh library.
    func setAsideUnreadableLibrary() {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("library-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
        } catch {
            errorMessage = "无法移动旧的书库文件，请检查储存空间后重试。"
            return
        }
        retryLoading()
    }

    private func load() {
        do {
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                addSample() // Seed only a genuinely new library; a saved empty library stays empty.
                return
            }
            // Migrations ran before this, so only the current format is read.
            struct Version: Decodable { var version: Int }
            guard try JSONDecoder().decode(Version.self, from: data).version == Self.libraryVersion else { throw LibraryError.invalidLibrary }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard Set(snapshot.books.map(\.id)).count == snapshot.books.count else { throw LibraryError.invalidLibrary }
            books = snapshot.books
            favorites = snapshot.favorites
            fingerprints = snapshot.fingerprints
        } catch {
            readFailure = "无法读取已保存的书库。原文件没有被改动。"
        }
    }

    // MARK: Book content

    func content(for book: ReaderBook) async throws -> BookContent {
        if book.isSample { return SampleBook.content() }
        // A book waiting for its text to be rebuilt is rebuilt first, so it opens as it now reads.
        if rebuild.pending.contains(book.id) || rebuildTasks[book.id] != nil { await rebuildNow(book.id) }
        let book = books.first { $0.id == book.id } ?? book
        if let contentCache, contentCache.id == book.id { return contentCache.content }
        let url = directory(for: book.id).content(book.contentFile ?? BookDirectory.firstContentFile)
        let content = try await detached { try JSONDecoder().decode(BookContent.self, from: Data(contentsOf: url)) }
        contentCache = (book.id, content)
        return content
    }

    func importBook(url: URL) async throws -> UUID {
        try ensureReadable()
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        // The same bytes are the same book under any name, so look before unpacking anything.
        let fingerprint = try await detached { try BookImporter.fingerprint(of: url) }
        try Task.checkCancellation()
        if let existingID = fingerprints[fingerprint], books.contains(where: { $0.id == existingID }) {
            throw LibraryError.duplicate(existingID)
        }
        let id = UUID()
        let staging = booksDirectory.appendingPathComponent("\(id.uuidString).partial", isDirectory: true)
        let destination = directory(for: id)
        defer { try? FileManager.default.removeItem(at: staging) }
        let imported = try await detached { try BookImporter.load(url: url, id: id, staging: staging, fingerprint: fingerprint) }
        try Task.checkCancellation()
        do {
            try await detached {
                let files = BookDirectory(url: staging)
                let encoder = JSONEncoder()
                let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                try encoder.encode(imported.content).write(to: files.content(imported.book.contentFile ?? BookDirectory.firstContentFile), options: options)
                try encoder.encode(imported.package).write(to: files.package, options: options)
                try imported.cover?.write(to: files.cover, options: options)
                // The book appears all at once or not at all.
                try FileManager.default.moveItem(at: staging, to: destination.url)
            }
            try commit(books: [imported.book] + books, favorites: favorites,
                       fingerprints: fingerprints.merging([imported.fingerprint: imported.book.id]) { _, new in new })
        } catch {
            try? FileManager.default.removeItem(at: destination.url)
            throw error
        }
        contentCache = (imported.book.id, imported.content)
        return imported.book.id
    }

    /// Writes the book to a temporary file, an EPUB for an EPUB import, and returns it.
    /// The caller removes the file's folder when it is done with it.
    func exportFile(for book: ReaderBook) async throws -> URL {
        guard book.canExport else { throw BookExporter.ExportError.incomplete }
        let files = directory(for: book.id)
        let title = book.title
        return try await detached {
            let package = try JSONDecoder().decode(BookPackage.self, from: Data(contentsOf: files.package))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let file = folder.appendingPathComponent(BookExporter.fileName(for: title, kind: package.kind))
                try BookExporter.export(files, package: package, to: file)
                return file
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }

    func addSample() {
        guard !books.contains(where: \.isSample) else { return }
        perform { try commit(books: books + [SampleBook.make()], favorites: favorites, fingerprints: fingerprints) }
    }

    /// Saved words keep their book and chapter labels after the book is removed.
    func removeBook(id: UUID) {
        perform {
            try commit(books: books.filter { $0.id != id }, favorites: favorites, fingerprints: fingerprints.filter { $0.value != id })
            try? FileManager.default.removeItem(at: directory(for: id).url)
            if contentCache?.id == id { contentCache = nil }
            rebuild.pending.removeAll { $0 == id }
            updateQueue { $0.books.removeAll { $0 == id }; $0.failures[id] = nil }
        }
    }

    // MARK: Reading position

    func savePosition(bookID: UUID, chapter: Int, offset: Int, fraction: Double? = nil) {
        guard let index = books.firstIndex(where: { $0.id == bookID }), books[index].chapters.indices.contains(chapter) else { return }
        let position = ReadingPosition(chapter: chapter, offset: max(0, min(offset, books[index].chapters[chapter].length)),
                                       fraction: fraction.map { min(1, max(0, $0)) })
        guard books[index].position != position else { return }
        books[index].position = position
        pendingPositionSave?.cancel()
        pendingPositionSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.persist()
        }
    }

    /// Flushes pending position changes at reader exit or when the scene leaves the foreground.
    func persist() {
        pendingPositionSave?.cancel()
        pendingPositionSave = nil
        perform { try commit(books: books, favorites: favorites, fingerprints: fingerprints) }
    }

    // MARK: Saved words

    enum SaveResult: Equatable { case saved, alreadySaved, failed }

    func favorite(matching text: String) -> SavedPassage? {
        let key = WordDictionary.normalize(WordDictionary.shared.headword(for: text))
        return favorites.first { $0.key == key }
    }

    /// One card per headword: "peeped" and "peep" are the same word to learn. Without a
    /// dictionary entry, `translation` (with where it came from) stands in for the definition.
    @discardableResult
    func savePassage(bookID: UUID, chapter: Int, offset: Int, selection: String, sentence: String,
                     translation: (text: String, source: String)? = nil) -> SaveResult {
        guard let book = books.first(where: { $0.id == bookID }), book.chapters.indices.contains(chapter) else { return .failed }
        let selection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return .failed }
        if favorite(matching: selection) != nil { return .alreadySaved }
        let entry = WordDictionary.shared.lookup(selection)
        // Without an entry the key still follows the form table, so "peeped" is found again as "peep".
        let key = WordDictionary.shared.headword(for: selection)
        let passage = SavedPassage(
            bookID: bookID, bookTitle: book.title, chapterTitle: book.chapters[chapter].title, chapterIndex: chapter,
            offset: max(0, min(offset, book.chapters[chapter].length)),
            selection: String(selection.prefix(500)), sentence: String(sentence.prefix(2_000)),
            headword: entry?.headword ?? (key == WordDictionary.normalize(selection) ? nil : key), phonetic: entry?.phonetic, definition: entry?.definition ?? translation?.text,
            createdAt: .now, reviewStage: 0, dueAt: .now, definitionSource: entry == nil ? translation?.source : nil)
        do {
            try commit(books: books, favorites: [passage] + favorites, fingerprints: fingerprints)
            return .saved
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    func setMastered(id: UUID, _ mastered: Bool) {
        update(id) { $0.mastered = mastered }
    }

    /// Simple spaced repetition: each "remembered" doubles roughly the gap; the
    /// last interval marks the word mastered. "Not yet" brings it back tomorrow.
    func review(id: UUID, remembered: Bool) {
        update(id) { item in
            let stage = remembered ? (item.reviewStage ?? 0) + 1 : 0
            item.reviewStage = stage
            if stage >= Self.reviewIntervals.count {
                item.mastered = true
                item.dueAt = nil
            } else {
                let days = remembered ? Self.reviewIntervals[stage - 1] : 0
                item.dueAt = Calendar.current.startOfDay(for: .now).addingTimeInterval(days * 86_400 + (remembered ? 0 : 86_400))
            }
        }
    }

    func deleteFavorite(id: UUID) {
        perform { try commit(books: books, favorites: favorites.filter { $0.id != id }, fingerprints: fingerprints) }
    }

    func restoreFavorite(_ passage: SavedPassage) {
        guard !favorites.contains(where: { $0.id == passage.id }) else { return }
        perform { try commit(books: books, favorites: (favorites + [passage]).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) },
                             fingerprints: fingerprints) }
    }

    private func update(_ id: UUID, _ change: (inout SavedPassage) -> Void) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        var updated = favorites
        change(&updated[index])
        perform { try commit(books: books, favorites: updated, fingerprints: fingerprints) }
    }

    // MARK: Rebuilding reading text

    /// Picks up what migrations asked for and what an earlier launch left unfinished.
    private func resumeRebuilding() {
        var queue = RebuildQueue.load(from: dataDirectory)
        if queue.requested.contains(.content) {
            let rebuildable = books.filter(\.canRebuild).map(\.id)
            queue.books += rebuildable.filter { !queue.books.contains($0) }
            queue.requested.remove(.content)
            queue.failures = [:]
            queue.total = queue.books.count
        }
        // Books removed since they were queued.
        queue.books.removeAll { id in !books.contains { $0.id == id && $0.canRebuild } }
        queue.total = max(queue.total, queue.books.count)
        try? queue.save(to: dataDirectory)
        rebuild = RebuildStatus(pending: queue.books, total: queue.total, current: nil, failures: queue.failures)
        startRebuildWorker()
    }

    private func updateQueue(_ change: (inout RebuildQueue) -> Void) {
        var queue = RebuildQueue.load(from: dataDirectory)
        change(&queue)
        if queue.books.isEmpty { queue.total = 0 }
        try? queue.save(to: dataDirectory)
    }

    /// Rebuilds the queued books one at a time, in the background.
    private func startRebuildWorker() {
        guard rebuildWorker == nil, !rebuild.pending.isEmpty else { return }
        rebuildWorker = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Failed books wait for the next launch or a retry.
                guard let next = self.rebuild.pending.first(where: { self.rebuild.failures[$0] == nil }) else { break }
                await self.rebuildNow(next)
            }
            self?.rebuildWorker = nil
        }
    }

    /// Rebuilds one book now, or waits for the rebuild already under way.
    func rebuildNow(_ id: UUID) async {
        if let running = rebuildTasks[id] { return await running.value }
        guard rebuild.pending.contains(id) else { return }
        let task = Task { await self.rebuildBook(id) }
        rebuildTasks[id] = task
        await task.value
        rebuildTasks[id] = nil
    }

    /// Tries the books that failed again.
    func retryFailedRebuilds() {
        rebuild.failures = [:]
        updateQueue { $0.failures = [:] }
        startRebuildWorker()
    }

    private func rebuildBook(_ id: UUID) async {
        guard let book = books.first(where: { $0.id == id }), book.canRebuild else {
            finishRebuild(id, failure: nil)
            return
        }
        rebuild.current = id
        let files = directory(for: id)
        let oldFile = book.contentFile ?? BookDirectory.firstContentFile
        do {
            let result = try await detached { () throws -> (BookContent, String, TextRemap) in
                let package = try JSONDecoder().decode(BookPackage.self, from: Data(contentsOf: files.package))
                let built = try BookBuilder.build(from: files, package: package)
                let old = try JSONDecoder().decode(BookContent.self, from: Data(contentsOf: files.content(oldFile)))
                let remap = TextRemap(old: old.chapters, new: built.content.chapters)
                let name = files.nextContentFile()
                try JSONEncoder().encode(built.content).write(to: files.content(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return (built.content, name, remap)
            }
            try apply(rebuilt: result.0, file: result.1, remap: result.2, to: id)
            finishRebuild(id, failure: nil)
        } catch is CancellationError {
            rebuild.current = nil
        } catch {
            finishRebuild(id, failure: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Switches a book to its rebuilt text and carries its position and saved words over, in one library write;
    /// positions saved while the text was being built are carried over too, since they are read here.
    private func apply(rebuilt content: BookContent, file: String, remap: TextRemap, to id: UUID) throws {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        var updated = books
        var book = updated[index]
        let position = remap.map(chapter: book.position.chapter, offset: book.position.offset)
        book.position.chapter = position.chapter
        book.position.offset = position.offset
        book.chapters = content.chapterInfo
        book.contentFile = file
        updated[index] = book
        let favorites = favorites.map { item -> SavedPassage in
            guard item.bookID == id else { return item }
            var item = item
            let mapped = remap.map(chapter: item.chapterIndex, offset: item.offset)
            let chapter = content.chapters[mapped.chapter]
            item.chapterIndex = mapped.chapter
            item.offset = Self.locate(item, in: chapter.text, near: mapped.offset)
            item.chapterTitle = chapter.title
            return item
        }
        try commit(books: updated, favorites: favorites, fingerprints: fingerprints)
        contentCache = (id, content)
        pruneContentFiles(of: id)
    }

    /// Where a saved word is in its chapter: the mapped offset when the word is there, else the nearest place it
    /// occurs, else where its sentence is.
    nonisolated static func locate(_ item: SavedPassage, in text: String, near offset: Int) -> Int {
        let text = text as NSString
        let selection = item.selection
        let length = (selection as NSString).length
        func matches(at location: Int) -> Bool {
            location >= 0 && location + length <= text.length
                && text.substring(with: NSRange(location: location, length: length)).compare(selection, options: .caseInsensitive) == .orderedSame
        }
        if length == 0 || matches(at: offset) { return min(offset, text.length) }
        let window = 400
        let start = max(0, offset - window), end = min(text.length, offset + window)
        var best: Int?
        var search = NSRange(location: start, length: end - start)
        while true {
            let found = text.range(of: selection, options: .caseInsensitive, range: search)
            guard found.location != NSNotFound else { break }
            if best.map({ abs(found.location - offset) < abs($0 - offset) }) ?? true { best = found.location }
            search = NSRange(location: found.location + 1, length: end - found.location - 1)
            if search.length <= 0 { break }
        }
        if let best { return best }
        if !item.sentence.isEmpty {
            let sentence = text.range(of: item.sentence)
            if sentence.location != NSNotFound {
                let inside = text.range(of: selection, options: .caseInsensitive, range: sentence)
                return inside.location != NSNotFound ? inside.location : sentence.location
            }
        }
        return min(offset, text.length)
    }

    private func finishRebuild(_ id: UUID, failure: String?) {
        if rebuild.current == id { rebuild.current = nil }
        if let failure {
            rebuild.failures[id] = failure
            updateQueue { $0.failures[id] = failure }
        } else {
            rebuild.pending.removeAll { $0 == id }
            rebuild.failures[id] = nil
            updateQueue { $0.books.removeAll { $0 == id }; $0.failures[id] = nil }
            if rebuild.pending.isEmpty { rebuild.total = 0 }
        }
    }

    /// Deletes reading-text files nothing points to: neither the library nor a backup of it kept for going back.
    private func pruneContentFiles(of id: UUID) {
        let files = directory(for: id)
        var keep = Set(books.filter { $0.id == id }.map { $0.contentFile ?? BookDirectory.firstContentFile })
        keep.formUnion(backedUpContentFiles(of: id))
        for file in files.contentFiles() where !keep.contains(file) {
            try? FileManager.default.removeItem(at: files.content(file))
        }
    }

    /// Reading-text files that the libraries set aside by the last migration point to. A library from before
    /// v0.2.0 names none; its books read `content.json`.
    private func backedUpContentFiles(of id: UUID) -> Set<String> {
        struct Saved: Decodable {
            struct Book: Decodable { var id: UUID; var contentFile: String? }
            var books: [Book]
        }
        var files = Set<String>()
        for backup in migrator.history().flatMap(\.backups) where backup.hasPrefix("library.json.") {
            guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent(backup)),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data) else { continue }
            for book in saved.books where book.id == id { files.insert(book.contentFile ?? BookDirectory.firstContentFile) }
        }
        return files
    }

    /// Deletes what the last migration set aside, and the reading text only those backups pointed to.
    func removeMigrationBackups() {
        migrator.removeBackups()
        for book in books { pruneContentFiles(of: book.id) }
    }

    /// For development builds: puts the data back as it was before the last migration and runs it again.
    func remigrateFromBackups() {
        do {
            try migrator.restoreLatestBackups()
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(RebuildQueue.name))
        } catch {
            errorMessage = "无法从备份恢复：\(error.localizedDescription)"
            return
        }
        retryLoading()
    }

    // MARK: Persistence

    private func ensureReadable() throws {
        if newerDataVersion != nil { throw LibraryError.newerData }
        if let readFailure { throw LibraryError.unreadable(readFailure) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    /// Writes the entire candidate state atomically before publishing it, so a
    /// failed write never shows the reader a change that wasn't saved.
    private func commit(books: [ReaderBook], favorites: [SavedPassage], fingerprints: [String: UUID]) throws {
        try ensureReadable()
        do {
            let data = try JSONEncoder().encode(Snapshot(books: books, favorites: favorites, fingerprints: fingerprints))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw LibraryError.saveFailed
        }
        self.books = books
        self.favorites = favorites
        self.fingerprints = fingerprints
    }
}

enum LibraryError: LocalizedError {
    case duplicate(UUID)
    case invalidLibrary
    case saveFailed
    case unreadable(String)
    case newerData

    var errorDescription: String? {
        switch self {
        case .duplicate: "这本书已在书架中。"
        case .invalidLibrary: "书库文件已损坏，或来自更新版本的应用。"
        case .saveFailed: "无法保存到这台设备，原有数据没有被改动。请检查储存空间后重试。"
        case .unreadable(let message): message
        case .newerData: "这些数据来自更新版本的 Readling，请先安装新版本。"
        }
    }
}
