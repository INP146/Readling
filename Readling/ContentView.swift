import SwiftUI
import UniformTypeIdentifiers

struct ReaderRoute: Identifiable {
    let id = UUID()
    var bookID: UUID
    var chapter: Int?
    var offset: Int?
}

struct ContentView: View {
    /// Made once by `ReadlingApp`: a store here would be made again each time the view is.
    let store: LibraryStore
    @State private var tab = 0
    @State private var route: ReaderRoute?
    @Environment(\.scenePhase) private var scenePhase
    private let downloads = DictionaryDownloads.shared

    var body: some View {
        if let version = store.newerDataVersion {
            NewerDataView(store: store, version: version)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("书架", systemImage: "books.vertical", value: 0) {
                LibraryView(store: store) { route = $0 }
            }
            Tab("生词本", systemImage: "bookmark", value: 1) {
                WordsView(store: store) { route = $0 }
            }
            .badge(store.favorites.filter { $0.isDue(at: .now) }.count)
            Tab("设置", systemImage: "gearshape", value: 2) {
                SettingsView(store: store)
            }
            .badge(downloads.updates.isEmpty ? 0 : 1)
        }
        .tint(.accent)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await downloads.refreshIfStale() } }
        }
        .fullScreenCover(item: $route) { value in
            ReaderView(store: store, bookID: value.bookID, requestedChapter: value.chapter, requestedOffset: value.offset)
        }
        .alert("没有保存成功", isPresented: Binding(get: { store.errorMessage != nil && route == nil },
                                              set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct LibraryView: View {
    let store: LibraryStore
    var open: (ReaderRoute) -> Void

    @AppStorage(SettingsKeys.lastReadBookID) private var lastReadBookID = ""
    @State private var choosingFile = false
    @State private var importTask: Task<Void, Never>?
    @State private var importingName: String?
    @State private var importError: String?
    @State private var exportError: String?
    @State private var duplicateID: UUID?
    @State private var removeID: UUID?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportingName: String?
    @State private var exported: ExportedFile?
    @State private var gridWidth: CGFloat = 0

    /// Started, unfinished books, the one read most recently first.
    private var reading: [ReaderBook] {
        let started = store.books.filter { $0.isStarted && !$0.isFinished }
        return started.filter { $0.id.uuidString == lastReadBookID } + started.filter { $0.id.uuidString != lastReadBookID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if let failure = store.readFailure { failureCard(failure).padding(.horizontal, 20) }
                    if !reading.isEmpty { continueShelf }
                    if !store.books.isEmpty {
                        grid
                    } else if store.readFailure == nil {
                        emptyState
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Color.paper)
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { choosingFile = true } label: { Label("导入书籍", systemImage: "plus") }
                        .disabled(importTask != nil || store.readFailure != nil)
                        .accessibilityIdentifier("import-book")
                }
            }
            .overlay(alignment: .bottom) {
                if let importingName {
                    progress("正在导入《\(importingName)》") { importTask?.cancel() }
                } else if let exportingName {
                    progress("正在导出《\(exportingName)》") { exportTask?.cancel() }
                }
            }
        }
        .sheet(isPresented: $choosingFile) {
            DocumentPicker { startImport($0) }.ignoresSafeArea()
        }
        .sheet(item: $exported, onDismiss: { exported = nil }) { file in
            ShareSheet(url: file.url).ignoresSafeArea().presentationDetents([.medium, .large])
                .onDisappear { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        }
        .alert("没有导入成功", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .alert("没有导出成功", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .alert("这本书已在书架上", isPresented: Binding(get: { duplicateID != nil }, set: { if !$0 { duplicateID = nil } })) {
            Button("打开") { if let duplicateID { open(ReaderRoute(bookID: duplicateID)) } }
            Button("取消", role: .cancel) {}
        }
        .alert("从书架移除这本书？", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } })) {
            Button("移除", role: .destructive) { if let removeID { store.removeBook(id: removeID) } }
            Button("取消", role: .cancel) {}
        } message: { Text("书和阅读进度会被删除。生词本里的词会保留。") }
    }

    // MARK: Pieces

    /// Like Apple Books' "Continue": large covers in a horizontal row, progress underneath.
    private var continueShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .bottom, spacing: 18) {
                ForEach(reading) { book in
                    VStack(alignment: .leading, spacing: 8) {
                        coverButton(book).frame(height: 210)
                        ProgressView(value: book.progress).tint(.accent)
                        HStack {
                            Text("\(book.percentRead)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            bookMenu(book)
                        }
                    }
                    .frame(width: 210 * book.coverAspect)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }

    /// Covers keep their own proportions at full column width; each column stacks independently and lazily.
    private var grid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("全部书籍").font(.title2.bold())
                Spacer()
                Text("\(store.books.count) 本").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, books in
                    LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(books) { gridItem($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        }
        .padding(.horizontal, 20)
    }

    private static let columnSpacing: CGFloat = 22
    private static let rowSpacing: CGFloat = 26
    /// The row under each cover (reading status + "⋯" menu) plus the 6pt gap above it.
    /// Its 28pt height is set by `bookMenu`'s tap target; keep the two in sync, or the columns balance less evenly.
    private static let footerHeight: CGFloat = 6 + 28

    /// Each book goes under the currently shortest column, so a book never sits higher than the one before it
    /// and any sort order reads top to bottom. Heights come from the stored cover proportions, so covers
    /// don't have to be loaded to lay the shelf out.
    private var columns: [[ReaderBook]] {
        let count = max(1, Int((gridWidth + Self.columnSpacing) / (140 + Self.columnSpacing)))
        let width = max(1, (gridWidth - Self.columnSpacing * CGFloat(count - 1)) / CGFloat(count))
        var columns = [[ReaderBook]](repeating: [], count: count)
        var heights = [CGFloat](repeating: 0, count: count)
        for book in store.books {
            let column = heights.indices.min { heights[$0] < heights[$1] }!
            columns[column].append(book)
            heights[column] += width / book.coverAspect + Self.footerHeight + Self.rowSpacing
        }
        return columns
    }

    private func gridItem(_ book: ReaderBook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            coverButton(book)
            HStack {
                status(book)
                Spacer(minLength: 0)
                bookMenu(book)
            }
        }
        .accessibilityIdentifier("book-\(book.id.uuidString)")
    }

    private func coverButton(_ book: ReaderBook) -> some View {
        Button { open(ReaderRoute(bookID: book.id)) } label: {
            BookCover(book: book, url: store.coverURL(for: book))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if book.canExport { exportButton(book) }
            Button("移除书籍", systemImage: "trash", role: .destructive) { removeID = book.id }
                .tint(.red)
        }
        .accessibilityLabel(book.author.isEmpty ? book.title : "\(book.title)，\(book.author)")
        .accessibilityValue(book.isStarted ? "已读 \(book.percentRead)%" : "未开始")
    }

    @ViewBuilder
    private func status(_ book: ReaderBook) -> some View {
        if book.isFinished {
            Text("已读完").font(.caption).foregroundStyle(.secondary)
        } else if book.isStarted {
            Text("\(book.percentRead)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(book.isSample ? "示例" : "新")
                .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.accent, in: Capsule())
        }
    }

    private func bookMenu(_ book: ReaderBook) -> some View {
        Menu {
            Button(book.isStarted ? "继续阅读" : "开始阅读", systemImage: "book") { open(ReaderRoute(bookID: book.id)) }
            if book.canExport { exportButton(book) }
            Button("移除书籍", systemImage: "trash", role: .destructive) { removeID = book.id }
                .tint(.red)
        } label: {
            Image(systemName: "ellipsis").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 32, height: 28).contentShape(Rectangle()) // Height is mirrored in `footerHeight`.
        }
        .accessibilityLabel("更多操作")
    }

    private func exportButton(_ book: ReaderBook) -> some View {
        Button("导出书籍", systemImage: "square.and.arrow.up") { startExport(book) }
            .disabled(exportTask != nil)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("把想读的英文书放进来", systemImage: "books.vertical")
        } description: {
            Text("支持没有 DRM 的 EPUB 和 TXT。读的时候点任何一个单词，就能看到中文释义。")
        } actions: {
            Button("导入书籍") { choosingFile = true }.buttonStyle(.borderedProminent)
            Button("读示例书") { store.addSample() }
        }
        .padding(.top, 40)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("书库读取失败", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text("\(message)可以重试；如果一直失败，可以把旧文件另存一份，然后从空书架重新开始。").font(.subheadline)
            HStack {
                Button("重试") { store.retryLoading() }.buttonStyle(.bordered)
                Button("另存旧文件并重新开始") { store.setAsideUnreadableLibrary() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func progress(_ message: String, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(message).lineLimit(1)
            Button("取消", action: cancel)
        }
        .font(.subheadline)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    private func startImport(_ url: URL) {
        importingName = url.deletingPathExtension().lastPathComponent
        importTask = Task {
            defer {
                importTask = nil; importingName = nil
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let id = try await store.importBook(url: url)
                lastReadBookID = id.uuidString
                open(ReaderRoute(bookID: id))
            } catch LibraryError.duplicate(let id) {
                duplicateID = id
            } catch is CancellationError {
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func startExport(_ book: ReaderBook) {
        exportingName = book.title
        exportTask = Task {
            defer { exportTask = nil; exportingName = nil }
            do {
                let url = try await store.exportFile(for: book)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                exported = ExportedFile(url: url)
            } catch is CancellationError {
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// A book written out for sharing; its folder is temporary and removed when the share sheet closes.
struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, which also offers "Save to Files".
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// The EPUB's own cover when it has one, otherwise a generated title cover.
/// Sizes itself to the book's proportions within whatever frame it is offered.
struct BookCover: View {
    let book: ReaderBook
    var url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? url.flatMap(CoverImages.cached) {
                // Overlaying a clear box keeps an out-of-range image cropped to the cover's frame.
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                generated
            }
        }
        .aspectRatio(book.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .task(id: url) { if let url { image = await CoverImages.load(url) } }
        .accessibilityHidden(true)
    }

    private var generated: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // Size the title so its longest word fits on one line instead of breaking mid-word.
            let longest = book.title.split(whereSeparator: \.isWhitespace).map(\.count).max() ?? 1
            let titleSize = max(7, min(width * 0.17, width * 0.76 / (CGFloat(longest) * 0.56)))
            VStack(spacing: width * 0.06) {
                if !book.author.isEmpty {
                    Text(book.author).font(.system(size: max(6, width * 0.09))).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                Text(book.title)
                    .font(.system(size: titleSize, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Rectangle().frame(width: width * 0.4, height: 1).opacity(0.45)
            }
            .padding(width * 0.12)
            .foregroundStyle(Color(uiColor: .readerPaper).opacity(0.95))
            .environment(\.colorScheme, .light)
            .frame(width: width, height: proxy.size.height)
            .background(Color.cover)
        }
    }
}

/// Covers are small JPEGs written at import; decode them off the main thread once.
@MainActor
enum CoverImages {
    private static let cache = NSCache<NSURL, UIImage>()

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Picks in copy mode: the system hands over a private copy instead of a security-scoped URL.
/// Open-in-place needs a sandbox extension issued to the app's identity, which fails when
/// a re-signed app's bundle ID doesn't match its application-identifier entitlement.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType(filenameExtension: "epub") ?? .data, .plainText], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
