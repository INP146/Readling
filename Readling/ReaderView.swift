import AVFoundation
import SwiftUI
@preconcurrency import Translation
import UIKit

struct ReaderView: View {
    let store: LibraryStore
    let bookID: UUID
    var requestedChapter: Int?
    var requestedOffset: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(SettingsKeys.lastReadBookID) private var lastReadBookID = ""
    @AppStorage(SettingsKeys.readerFont) private var fontSize = ReaderTypography.defaultSize
    @AppStorage(SettingsKeys.readerTypeface) private var typeface = ReaderTypeface.newYork
    @AppStorage(SettingsKeys.readerLineSpacing) private var lineSpacing = ReaderLayout.defaultLineSpacing
    @AppStorage(SettingsKeys.readerParagraphSpacing) private var paragraphSpacing = ReaderLayout.defaultParagraphSpacing
    @AppStorage(SettingsKeys.readerMargin) private var margin = ReaderLayout.defaultMargin
    @AppStorage(SettingsKeys.readerAppearance) private var appearance = "system"
    @AppStorage(SettingsKeys.readerDayTheme) private var dayTheme = ReaderTheme.defaultDay
    @AppStorage(SettingsKeys.readerNightTheme) private var nightTheme = ReaderTheme.defaultNight
    @AppStorage(SettingsKeys.readerBackdrop) private var backdrop = ReaderBackdrop.plain
    @AppStorage(SettingsKeys.readerBackdropVersion) private var backdropVersion = 0
    @AppStorage(SettingsKeys.readerPageTurn) private var pageTurn = PageTurn.scroll
    @AppStorage(SettingsKeys.readerEyeCare) private var eyeCare = false
    @AppStorage(SettingsKeys.readerAutoSpeed) private var autoSpeed = 3
    @AppStorage(SettingsKeys.readerKeepAwake) private var keepAwake = false
    @AppStorage(SettingsKeys.readerTipSeen) private var tipSeen = false

    @State private var content: BookContent?
    @State private var loadError: String?
    @State private var chapter = 0
    @State private var offset = 0
    @State private var fraction = 0.0
    @State private var jump: JumpRequest?
    @State private var lookup: ReadingSelection?
    /// Where the lookup bubble may go, in global coordinates: inside the safe area and above the bottom bars.
    @State private var lookupArea: CGRect = .zero
    @State private var chromeVisible = false
    /// The floating menu button unfolded into its list of actions.
    @State private var menuOpen = false
    @Namespace private var glassSpace
    /// Where a drag along the progress row has got to, through the whole book; nil when not dragging.
    @State private var scrubFraction: Double?
    @State private var scrubStart = 0.0
    /// Each chapter's length in UTF-16 units, so progress through the book weighs chapters by their text.
    @State private var chapterLengths: [Int] = []
    @State private var autoReading = false
    @State private var sheet: ReaderSheet?
    @State private var toast: String?
    /// Set while visiting a saved word's source or a search result; the reader's own place is kept here.
    @State private var savedPlace: ReadingPosition?
    @State private var marks: [NSRange] = []

    private enum ReaderSheet: String, Identifiable {
        case contents, search, settings
        var id: String { rawValue }
    }

    private var book: ReaderBook? { store.books.first { $0.id == bookID } }
    private var current: ReaderChapter? {
        guard let content, content.chapters.indices.contains(chapter) else { return nil }
        return content.chapters[chapter]
    }
    private var chapterCount: Int { content?.chapters.count ?? book?.chapters.count ?? 0 }
    private var resources: URL? { book.flatMap { store.resourcesURL(for: $0) } }
    private var hasNext: Bool { chapter + 1 < chapterCount }
    private var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    private var isNight: Bool { appearance == "dark" || (appearance != "light" && systemScheme == .dark) }
    private var palette: ReaderPalette { ReaderPalette(day: dayTheme, night: nightTheme) }
    private var layout: ReaderLayout {
        ReaderLayout(fontSize: fontSize, typeface: typeface, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing, margin: margin)
    }
    /// Auto reading pauses while the toolbars or the lookup card are up.
    private var autoRunning: Bool { autoReading && !chromeVisible && lookup == nil && sheet == nil }

    /// Surface forms of words still being learned; every occurrence gets underlined.
    private var learningForms: Set<String> {
        Set(store.favorites.filter { !$0.mastered }.flatMap { [WordDictionary.normalize($0.selection), $0.key] })
    }

    var body: some View {
        NavigationStack {
            readingArea
            // Chrome floats over the text instead of resizing it; the lookup bubble stays clear of the bottom bar.
            .overlay {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lookupArea = $0 }
                    .overlay { lookupOverlay }
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomInset }
                    .overlay(alignment: .top) { topBar }
                    .overlay(alignment: .top) {
                        if let toast { ToastLabel(text: toast).padding(.top, 8) }
                    }
            }
            .animation(.default, value: toast)
            .animation(.spring(duration: 0.25), value: lookup?.id)
            // Our own top bar: the system one slides in under the status bar and Dynamic Island.
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden(!chromeVisible)
        }
        .tint(.accent)
        .overlay {
            if eyeCare {
                // A warm multiply wash cuts blue light over the page and the toolbars alike.
                Color(red: 1, green: 0.72, blue: 0.38).opacity(0.22).blendMode(.multiply)
                    .ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .preferredColorScheme(colorScheme)
        .task { await open() }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
        .onChange(of: learningForms, initial: true) { updateMarks() }
        .onChange(of: current?.id) { updateMarks() }
        .onChange(of: pageTurn) { jump = nil } // A rebuilt surface must not replay an old jump.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.persist(); ScreenBrightness.restore() } else { ScreenBrightness.reapply() }
        }
        .onChange(of: keepAwake || autoReading, initial: true) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            ScreenBrightness.reset()
        }
        .sheet(item: $sheet) { sheetContent($0) }
        .alert("没有保存成功", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    // MARK: Pieces

    /// Sheets don't follow the reader's own day/night choice by themselves.
    private func sheetContent(_ item: ReaderSheet) -> some View {
        Group {
            switch item {
            case .contents: contents
            case .search: BookSearchView(chapters: content?.chapters ?? []) { visit(chapter: $0, offset: $1) }
            case .settings: ReaderSettingsSheet(isNight: isNight)
            }
        }
        .preferredColorScheme(colorScheme)
    }

    private var readingArea: some View {
        ZStack {
            Color(uiColor: palette.paper).ignoresSafeArea()
            if let current {
                surface(for: current)
                    // The pager turns into neighbouring chapters itself, so only scrolling rebuilds per chapter.
                    .id(pageTurn.isPaged ? pageTurn.rawValue : "\(current.id)|\(pageTurn.rawValue)")
                    .ignoresSafeArea()
            } else if let loadError {
                ContentUnavailableView("无法打开这本书", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                // A book whose text a migration asked to rebuild is rebuilt before it opens.
                ProgressView(store.rebuild.pending.contains(bookID) ? "正在按新版本更新这本书…" : "正在打开…")
            }
        }
    }

    @ViewBuilder private func surface(for current: ReaderChapter) -> some View {
        if pageTurn.isPaged {
            PagedSurface(
                chapter: current, chapterIndex: chapter, chapterCount: chapterCount,
                chapters: content?.chapters ?? [],
                layout: layout, palette: palette, backdrop: backdrop, backdropVersion: backdropVersion,
                turn: pageTurn, initialOffset: offset, jump: jump, learningForms: learningForms,
                lookingUp: lookup != nil,
                interactive: !chromeVisible,
                autoTurnInterval: autoRunning ? Double(34 - 3 * autoSpeed) : nil,
                onPosition: positionChanged,
                onTapBlank: { tappedBlank() },
                onTurn: { lookup = nil; hideChrome() },
                onLookup: { show($0) },
                onDeselect: { lookup = nil },
                onSave: { save($0) },
                onChapterTurn: { index in
                    // The surface already shows the new chapter; its position report follows.
                    chapter = index
                    jump = nil
                },
                onBoundary: { forward in
                    if forward { reachedChapterEnd() }
                },
                resources: resources,
                onTapLink: { openLink($0) })
        } else {
            ZStack {
                BackdropRepresentable(backdrop: backdrop, palette: palette, version: backdropVersion)
                ReadingSurface(
                    chapter: current, layout: layout, palette: palette, initialOffset: offset, jump: jump, markedRanges: marks,
                    autoScrollSpeed: autoRunning ? Double(8 + 8 * autoSpeed) : nil,
                    onPosition: positionChanged,
                    onTapBlank: { tappedBlank() },
                    onScroll: { lookup = nil },
                    onLookup: { show($0) },
                    onDeselect: { lookup = nil },
                    onSave: { save($0) },
                    lookingUp: lookup != nil,
                    interactive: !chromeVisible,
                    onReachEnd: { reachedChapterEnd() },
                    resources: resources,
                    onTapLink: { openLink($0) })
            }
        }
    }

    /// Just the way back to the shelf, floating in the corner above the menu button.
    private var topBar: some View {
        Button { close() } label: {
            Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 48, height: 48).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("书架")
        .accessibilityIdentifier("close-reader")
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        // Always in place and only slid away: inserting it anew sometimes animated from a stale frame.
        .visualEffect { [chromeVisible] content, proxy in
            content.offset(y: chromeVisible ? 0 : -proxy.frame(in: .global).maxY)
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .accessibilityHidden(!chromeVisible)
    }

    private var bottomInset: some View {
        VStack(spacing: 0) {
            if !tipSeen && content != nil && lookup == nil { tip.padding(.bottom, 8) }
            if savedPlace != nil { returnBar.padding(.bottom, 10) }
            if chromeVisible {
                Group {
                    if autoReading { autoReadingBar } else { menu }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if fraction >= 0.99 && hasNext && !pageTurn.isPaged && !autoReading {
                nextChapterButton.padding(.bottom, 8)
            }
        }
    }

    /// The card pops out of the looked-up word, so the eyes stay where they were reading.
    @ViewBuilder private var lookupOverlay: some View {
        if let lookup {
            // Without a known position (e.g. VoiceOver), the bubble hangs from the top edge.
            let anchor = lookup.anchor.map { $0.offsetBy(dx: -lookupArea.minX, dy: -lookupArea.minY) }
            let size = lookupArea.size
            let point = anchor.map { UnitPoint(x: size.width > 0 ? $0.midX / size.width : 0.5,
                                               y: size.height > 0 ? $0.midY / size.height : 0) } ?? .top
            LookupBubbleLayout(anchor: anchor) {
                Rectangle()
                    .fill(Color(uiColor: palette.chrome))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(45))
                    .opacity(anchor == nil ? 0 : 1)
                    .accessibilityHidden(true)
                LookupCard(selection: lookup, entry: WordDictionary.shared.lookup(lookup.text),
                           isSaved: store.favorite(matching: lookup.text) != nil,
                           palette: palette,
                           onToggleSaved: { toggleSaved(lookup, translation: $0) })
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.14), radius: 16, y: 4)
            .transition(.scale(scale: 0.85, anchor: point).combined(with: .opacity))
            .id(lookup.id)
        }
    }

    /// Where a place in a chapter falls through the whole book, from 0 to 1.
    private func bookFraction(chapter index: Int, fraction value: Double) -> Double {
        let total = chapterLengths.reduce(0, +)
        guard total > 0, chapterLengths.indices.contains(index) else { return 0 }
        let before = chapterLengths[..<index].reduce(0, +)
        return (Double(before) + min(max(value, 0), 1) * Double(chapterLengths[index])) / Double(total)
    }

    /// The chapter, and how far into it, at a fraction of the whole book.
    private func place(atBookFraction value: Double) -> (chapter: Int, fraction: Double) {
        let total = chapterLengths.reduce(0, +)
        guard total > 0 else { return (0, 0) }
        var remaining = min(max(value, 0), 1) * Double(total)
        for (index, length) in chapterLengths.enumerated() {
            if remaining < Double(length) || index == chapterLengths.count - 1 {
                return (index, length > 0 ? min(remaining / Double(length), 1) : 0)
            }
            remaining -= Double(length)
        }
        return (0, 0)
    }

    private var bookProgress: Double { bookFraction(chapter: chapter, fraction: fraction) }

    /// One glass button in the corner; it unfolds into the reader's actions and folds back into itself.
    private var menu: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .trailing, spacing: 10) {
                if menuOpen {
                    progressRow
                    // Dragging the progress row leaves it alone on the page, still where the finger found it.
                    if scrubFraction != nil {
                        Color.clear.frame(width: Self.menuWidth, height: Self.menuRowHeight * 3 + 10 * 2)
                    } else {
                    menuRow("书内搜索", systemImage: "magnifyingglass", id: "search-book") { present(.search) }
                    menuRow("主题与设置", systemImage: "paintpalette", id: "reading-settings") { present(.settings) }
                    HStack(spacing: 10) {
                        menuIcon(isNight ? "日间" : "夜间", systemImage: isNight ? "sun.max" : "moon", id: "toggle-night") {
                            appearance = isNight ? "light" : "dark"
                        }
                        menuIcon("护眼模式", systemImage: eyeCare ? "eye.fill" : "eye", id: "eye-care") { eyeCare.toggle() }
                            .accessibilityValue(eyeCare ? "开" : "关")
                        menuIcon("自动阅读", systemImage: "play", id: "auto-read") { startAutoReading() }
                        menuIcon("收起", systemImage: "xmark", id: "close-menu") { setMenu(open: false) }
                    }
                    }
                } else {
                    Button { setMenu(open: true) } label: {
                        Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold)).frame(width: 48, height: 48).contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("menu", in: glassSpace)
                    .accessibilityLabel("菜单")
                    .accessibilityIdentifier("reader-menu")
                }
            }
        }
        // Outside the glass container, which would otherwise draw the bubble into the bar's glass.
        .overlay(alignment: .topLeading) {
            if let scrubFraction { scrubBubble(at: scrubFraction, width: Self.progressWidth) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func menuRow(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).monospacedDigit().lineLimit(1)
                Spacer(minLength: 16)
                Image(systemName: systemImage).font(.title3)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 22)
            .frame(width: Self.menuWidth, height: Self.menuRowHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(id, in: glassSpace)
        .accessibilityIdentifier(id)
    }

    private func menuIcon(_ title: LocalizedStringKey, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title3).frame(width: (Self.menuWidth - 10 * 3) / 4, height: Self.menuRowHeight).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(id, in: glassSpace)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private func setMenu(open: Bool) {
        withAnimation(.bouncy(duration: 0.35)) { menuOpen = open }
    }

    /// The menu folds away behind a sheet; the buttons stay up for the next step.
    private func present(_ item: ReaderSheet) {
        sheet = item
        setMenu(open: false)
    }

    /// The first menu row is the book's progress: a tap opens the contents, a sideways drag turns it
    /// into a bar to skim through the whole book, landing where the finger lets go.
    /// The unfolded menu: rows this wide and tall; the four round buttons share the bottom row.
    private static let menuWidth: CGFloat = 260
    private static let menuRowHeight: CGFloat = 50
    private static var progressWidth: CGFloat { menuWidth }

    /// The row's look: the part read so far always under the label, so it shows progress at a glance.
    private var progressBar: some View {
        let width = Self.progressWidth
        let shown = CGFloat(scrubFraction ?? bookProgress)
        let fill = Color.primary.opacity(scrubFraction == nil ? 0.1 : 0.18)
        return ZStack(alignment: .leading) {
            Rectangle().fill(fill).frame(width: width * shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if scrubFraction == nil { progressLabel(Int(shown * 100)) }
        }
        .frame(width: width, height: Self.menuRowHeight)
        .clipShape(Capsule())
        .contentShape(Capsule())
        // Not interactive glass: its press squeezes the glass but not the progress drawn on it.
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("open-chapters", in: glassSpace)
    }

    private func progressLabel(_ percent: Int) -> some View {
        HStack {
            Text("目录 · \(percent)%").monospacedDigit().lineLimit(1)
            Spacer(minLength: 16)
            Image(systemName: "list.bullet").font(.title3)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 22)
    }

    private var progressRow: some View {
        progressBar
            // A tick on picking the bar up and at each chapter crossed; a firmer knock at either end of the book.
            .sensoryFeedback(trigger: scrubChapter, Self.chapterFeedback)
            .sensoryFeedback(trigger: scrubAtEnd, Self.endFeedback)
            .onTapGesture { present(.contents) }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { drag in
                    if scrubFraction == nil { scrubStart = bookProgress }
                    let value = min(max(scrubStart + drag.translation.width / Self.progressWidth, 0), 1)
                    withAnimation(.snappy(duration: 0.2)) { scrubFraction = value }
                }
                .onEnded { _ in
                    if let target = scrubFraction { moveTo(bookFraction: target) }
                    withAnimation(.snappy(duration: 0.25)) { scrubFraction = nil }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("目录")
        .accessibilityValue("全书 \(Int(bookProgress * 100))%")
        .accessibilityHint("左右滑动可跳转进度")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            moveTo(bookFraction: min(max(bookProgress + step, 0), 0.999))
        }
        .accessibilityIdentifier("open-chapters")
    }

    private static func chapterFeedback(from old: Int?, to new: Int?) -> SensoryFeedback? {
        guard new != nil else { return nil }
        return old == nil ? .impact(weight: .light) : .selection
    }

    private static func endFeedback(from _: Bool, to atEnd: Bool) -> SensoryFeedback? {
        atEnd ? .impact(flexibility: .rigid) : nil
    }

    /// The chapter under the finger while skimming.
    private var scrubChapter: Int? { scrubFraction.map { place(atBookFraction: $0).chapter } }
    private var scrubAtEnd: Bool { scrubFraction == 0 || scrubFraction == 1 }

    /// The bubble over the finger while skimming: which chapter, and how far through the book.
    private func scrubBubble(at value: Double, width: CGFloat) -> some View {
        let bubbleWidth: CGFloat = 220
        let target = place(atBookFraction: value)
        let title = content?.chapters.indices.contains(target.chapter) == true ? content!.chapters[target.chapter].title : ""
        return VStack(spacing: 2) {
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("第 \(target.chapter + 1)/\(chapterCount) 章 · \(Int(value * 100))%")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(width: bubbleWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        // Sits on the bar's top edge, centred over the finger but kept on screen at either end.
        .frame(height: 0, alignment: .bottom)
        .offset(x: min(max(width * CGFloat(value) - bubbleWidth / 2, -80), width - bubbleWidth), y: -10)
        .allowsHitTesting(false)
    }

    /// Opens the book at a fraction of the way through it, as the progress row was dragged to.
    private func moveTo(bookFraction value: Double) {
        let target = place(atBookFraction: value)
        guard chapterLengths.indices.contains(target.chapter) else { return }
        let length = chapterLengths[target.chapter]
        let position = min(Int(target.fraction * Double(length)), max(length - 1, 0))
        lookup = nil
        if target.chapter == chapter {
            jump = JumpRequest(offset: position, highlight: false)
        } else {
            chapter = target.chapter
            offset = position
            fraction = target.fraction
            jump = nil
        }
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: chapter, offset: position, fraction: target.fraction) }
    }

    private var autoReadingBar: some View {
        HStack(spacing: 8) {
            Label("自动阅读", systemImage: "play.circle").font(.subheadline.weight(.medium))
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Button { autoSpeed = max(1, autoSpeed - 1) } label: { Image(systemName: "minus").frame(width: 32, height: 32) }
                .disabled(autoSpeed <= 1).accessibilityLabel("减速")
            Text("速度 \(autoSpeed)").monospacedDigit().font(.subheadline).lineLimit(1).fixedSize()
            Button { autoSpeed = min(10, autoSpeed + 1) } label: { Image(systemName: "plus").frame(width: 32, height: 32) }
                .disabled(autoSpeed >= 10).accessibilityLabel("加速")
            Button { autoReading = false } label: { Text("退出").lineLimit(1).fixedSize() }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("stop-auto-read")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private var nextChapterButton: some View {
        Button { go(to: chapter + 1) } label: {
            Label("下一章", systemImage: "arrow.down.circle").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glassProminent).controlSize(.small)
        .accessibilityIdentifier("next-chapter")
    }

    private var returnBar: some View {
        HStack {
            Button { returnToSavedPlace() } label: { Label("回到我读到的地方", systemImage: "arrow.uturn.backward") }
            Spacer()
            Button("从这里继续读") {
                savedPlace = nil
                store.savePosition(bookID: bookID, chapter: chapter, offset: offset, fraction: fraction)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
    }

    private var tip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.point.up.left").foregroundStyle(Color.accent)
            Text("长按或双击单词看释义，拖动选区可查词组。轻点隐藏工具栏。").font(.footnote)
            Button { tipSeen = true } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                .accessibilityLabel("关闭提示")
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
    }

    private var contents: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array((content?.chapters ?? []).enumerated()), id: \.element.id) { index, item in
                    Button { go(to: index); sheet = nil } label: {
                        HStack {
                            Text(item.title).foregroundStyle(index == chapter ? Color.accent : .primary)
                            Spacer()
                            if index == chapter { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                        }
                        .frame(minHeight: 36)
                    }
                    .id(index)
                }
                .onAppear { proxy.scrollTo(chapter, anchor: .center) }
                .onChange(of: chapter) { _, index in withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { sheet = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    private func open() async {
        guard content == nil, let book else { return }
        lastReadBookID = book.id.uuidString
        do {
            let loaded = try await store.content(for: book)
            let last = max(loaded.chapters.count - 1, 0)
            if let requestedOffset {
                savedPlace = book.position
                chapter = min(max(requestedChapter ?? 0, 0), last)
                offset = max(0, requestedOffset)
                jump = JumpRequest(offset: offset, highlight: true)
            } else {
                chapter = min(max(book.position.chapter, 0), last)
                offset = book.position.offset
            }
            chapterLengths = loaded.chapters.map { $0.text.utf16.count }
            content = loaded
        } catch {
            loadError = "书籍文件丢失或已损坏。可以从书架移除后重新导入。"
        }
    }

    private func positionChanged(_ value: Int, _ fraction: Double) {
        offset = value
        self.fraction = fraction
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: chapter, offset: value, fraction: fraction) }
    }

    /// `atEnd` opens the chapter at its last page, for turning back across a chapter boundary.
    private func go(to index: Int, atEnd: Bool = false) {
        guard index >= 0, index < chapterCount, index != chapter else { return }
        lookup = nil
        chapter = index
        offset = atEnd ? max(0, (current?.text.utf16.count ?? 1) - 1) : 0
        fraction = atEnd ? 1 : 0
        jump = nil
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: index, offset: offset, fraction: fraction) }
    }

    /// Opens a search result, keeping the reader's own place to come back to.
    private func visit(chapter index: Int, offset value: Int) {
        guard content?.chapters.indices.contains(index) == true else { return }
        if savedPlace == nil { savedPlace = ReadingPosition(chapter: chapter, offset: offset, fraction: fraction) }
        lookup = nil
        chapter = index
        offset = value
        jump = JumpRequest(offset: value, highlight: true)
    }

    /// A tapped link: web addresses open in the browser, places in the book are visited like a search result,
    /// so "回到我读到的地方" brings the reader back from a footnote.
    private func openLink(_ target: String) {
        lookup = nil
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            UIApplication.shared.open(url)
            return
        }
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let place = content?.location(ofPath: parts[0], fragment: parts.count > 1 ? parts[1] : nil) else {
            toast = "这个链接指向的内容不在书里"
            return
        }
        visit(chapter: place.chapter, offset: place.offset)
    }

    private func reachedChapterEnd() {
        if hasNext {
            go(to: chapter + 1)
        } else if autoReading {
            autoReading = false
            toast = "已经读到最后了"
        }
    }

    private func startAutoReading() {
        lookup = nil
        autoReading = true
        withAnimation(.easeInOut(duration: 0.2)) {
            menuOpen = false
            chromeVisible = false
        }
    }

    private func returnToSavedPlace() {
        guard let place = savedPlace else { return }
        savedPlace = nil
        lookup = nil
        if place.chapter == chapter {
            jump = JumpRequest(offset: place.offset, highlight: false)
        } else {
            chapter = place.chapter
            offset = place.offset
            fraction = place.fraction ?? 0
            jump = nil
        }
    }

    private func tappedBlank() {
        if lookup != nil {
            lookup = nil
        } else if menuOpen {
            setMenu(open: false)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
    }

    /// Turning a page puts the toolbars away instead of leaving them over the new page.
    private func hideChrome() {
        guard chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible = false
            menuOpen = false
        }
    }

    private func show(_ selection: ReadingSelection) {
        tipSeen = true
        lookup = selection
    }

    /// The card's star: saves the word, or takes it back out when it's already in the word list.
    private func toggleSaved(_ selection: ReadingSelection, translation: (text: String, source: String)?) {
        if let saved = store.favorite(matching: selection.text) {
            store.deleteFavorite(id: saved.id)
            toast = "已从生词本移除"
        } else {
            save(selection, translation: translation)
        }
    }

    private func save(_ selection: ReadingSelection, translation: (text: String, source: String)? = nil) {
        let result = store.savePassage(bookID: bookID, chapter: chapter, offset: selection.offset,
                                       selection: selection.text, sentence: selection.sentence, translation: translation)
        switch result {
        case .saved: toast = "已加入生词本"
        case .alreadySaved: toast = "生词本里已经有这个词"
        case .failed: break // The store's error alert explains.
        }
    }

    private func close() {
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: chapter, offset: offset, fraction: fraction) }
        store.persist()
        dismiss()
    }

    private func updateMarks() {
        guard let current else { marks = []; return }
        let forms = learningForms
        guard !forms.isEmpty else { marks = []; return }
        marks = ReaderTextTools.markedRanges(in: current.text, words: ReadingSurface.englishWordRanges(in: current.text), forms: forms)
    }
}

struct ToastLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("toast")
    }
}

/// The definition appears next to the text instead of in a modal sheet, so the
/// sentence stays visible while reading the meaning.
struct LookupCard: View {
    let selection: ReadingSelection
    let entry: DictionaryEntry?
    let isSaved: Bool
    /// The card takes the reading theme's toolbar shade and ink, like the bars around the page.
    var palette = ReaderPalette(day: ReaderTheme.defaultDay, night: ReaderTheme.defaultNight)
    /// Passes the machine translation shown in place of a dictionary entry, to keep with the saved word.
    var onToggleSaved: ((text: String, source: String)?) -> Void
    @AppStorage(SettingsKeys.dictionaryExpandByDefault) private var expandByDefault = false
    @AppStorage(TranslationService.automaticKey) private var automaticTranslation = true
    @State private var expanded: Bool?
    @State private var openPhrases: Set<String> = []
    @State private var copied = false
    @State private var translation: TranslationService.Result?
    @State private var translationError: TranslationFailure?
    @State private var translationAttempt = 0
    @State private var languagePack: TranslationSession.Configuration?

    private var isExpanded: Bool { expanded ?? expandByDefault }

    private var wordCount: Int { selection.text.split(whereSeparator: \.isWhitespace).count }
    /// A sentence or a longer run of words.
    private var isExpression: Bool { wordCount > 3 }
    /// Nothing in the dictionary for a sentence: the card is just its translation, without repeating the text.
    private var isTranslationOnly: Bool { entry == nil && isExpression }

    private var translationRequest: TranslationRequest {
        if wordCount == 1 { return .explain(word: selection.text, sentence: selection.sentence) }
        let context = selection.sentence.isEmpty || selection.sentence == selection.text ? nil : selection.sentence
        return .translate(selection.text, context: context)
    }

    private var savedTranslation: (text: String, source: String)? {
        guard let translation, translation.isFinal else { return nil }
        return (translation.text, "机器翻译 · \(translation.providerTitle)")
    }

    private var isLikelyName: Bool {
        guard let first = selection.text.first, first.isUppercase else { return false }
        return !selection.sentence.hasPrefix(selection.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: isTranslationOnly ? .top : .firstTextBaseline, spacing: 8) {
                    if isTranslationOnly {
                        // The sentence stays in view on the page above, so the translation takes its place.
                        translationView.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(entry?.headword ?? selection.text)
                            .font(.system(.title2, design: .serif).weight(.semibold))
                            .lineLimit(2).minimumScaleFactor(0.7)
                        if let phonetic = entry?.phonetic, !phonetic.isEmpty {
                            Text("/\(phonetic)/").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Button { Pronunciation.speak(entry?.headword ?? selection.text) } label: {
                        Image(systemName: "speaker.wave.2").font(.subheadline)
                    }
                    .accessibilityLabel("朗读")
                    .accessibilityIdentifier("speak-selection")
                    Spacer(minLength: 0)
                    Button { onToggleSaved(savedTranslation) } label: {
                        Image(systemName: isSaved ? "star.fill" : "star").font(.body).foregroundStyle(Color.accent)
                    }
                    .accessibilityLabel(isSaved ? "已在生词本" : "加入生词本")
                    .accessibilityIdentifier("save-selection")
                }
                if let entry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            summary(entry)
                            if isExpanded { details(entry) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: isExpanded ? 340 : 160)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !isTranslationOnly {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selection.text.contains(" ") ? "离线词典里没有这个词组。"
                                 : isLikelyName ? "离线词典里没有这个词，它可能是人名或地名。" : "离线词典里没有这个词。")
                                .font(.callout)
                            if DictionaryDownloads.shared.hasMoreToDownload {
                                Text("可在“设置 › 词典”下载更多词库。").font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                        translationView
                    }
                }
            }
            .foregroundStyle(Color(uiColor: palette.ink))
            // What the edit menu offered, which the card replaces.
            HStack(spacing: 0) {
                Button {
                    UIPasteboard.general.string = selection.text
                    copied = true
                } label: {
                    Label(copied ? "已拷贝" : "拷贝", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("copy-selection")
                ShareLink(item: selection.text) {
                    Label("分享", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("share-selection")
                if entry != nil {
                    Button { withAnimation(.snappy(duration: 0.25)) { expanded = !isExpanded } } label: {
                        Label(isExpanded ? "收起" : "展开", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("expand-lookup")
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .task(id: translationAttempt) { await translate() }
        .translationTask(languagePack) { session in
            // The system asks before downloading; once it's in, try again.
            if (try? await session.prepareTranslation()) != nil { translationAttempt += 1 }
        }
        .padding(16)
        .background(Color(uiColor: palette.chrome), in: RoundedRectangle(cornerRadius: 20))
        .tint(.accent)
        .accessibilityIdentifier("lookup-card")
    }

    /// Fills in for a missing dictionary entry: the engine's answer, or why there is none.
    @ViewBuilder private var translationView: some View {
        if let translation {
            // A word translated on its own, out of context, is a guess; keep it quieter than a definition.
            let isGuess = !isExpression && !translation.canExplain
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(translation.text).font(.callout)
                        .foregroundStyle(isGuess ? .secondary : .primary)
                        .accessibilityIdentifier("translation")
                    Text("机器翻译 · \(translation.providerTitle)").font(.caption2).foregroundStyle(.secondary)
                    if let notice = translation.notice {
                        Text(notice).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
        } else if let translationError {
            HStack(alignment: .firstTextBaseline) {
                Text(translationError.localizedDescription).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                switch translationError {
                case .needsLanguagePack:
                    Button("下载") { languagePack = .init(source: TranslationService.source, target: TranslationService.target) }
                        .font(.subheadline)
                case .unsupported, .notConfigured: EmptyView()
                case .offline, .failed: Button("重试") { translationAttempt += 1 }.font(.subheadline)
                }
            }
        } else if automaticTranslation || translationAttempt > 0 {
            ProgressView().controlSize(.small)
        } else {
            Button("显示译文") { translationAttempt += 1 }
                .font(.subheadline)
                .accessibilityIdentifier("show-translation")
        }
    }

    private func translate() async {
        guard entry == nil, automaticTranslation || translationAttempt > 0 else { return }
        translation = nil
        translationError = nil
        do {
            for try await result in TranslationService.shared.run(translationRequest) { translation = result }
        } catch is CancellationError {
        } catch {
            translation = nil
            translationError = error as? TranslationFailure ?? .failed(error.localizedDescription)
        }
    }

    /// What the card always shows: the short definition and how the tapped form relates to it.
    @ViewBuilder private func summary(_ entry: DictionaryEntry) -> some View {
        if let inflected = entry.inflectedFrom, inflected.lowercased() != entry.headword.lowercased() {
            let kinds = entry.forms.filter { $0.word.lowercased() == inflected.lowercased() }.map { DictionaryEntry.Form.title($0.kind) }
            Text(kinds.isEmpty ? "\(inflected) 是 \(entry.headword) 的变形" : "\(inflected) 是 \(entry.headword) 的\(kinds.joined(separator: "、"))")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text(entry.definition).font(.callout)
        if let own = entry.ownSense, let inflected = entry.inflectedFrom {
            (Text("\(inflected) 本身：").foregroundStyle(.secondary) + Text(own.replacingOccurrences(of: "\n", with: "  ")))
                .font(.footnote)
        }
    }

    @ViewBuilder private func details(_ entry: DictionaryEntry) -> some View {
        let more = entry.moreTranslation
        if !more.isEmpty { Text(more).font(.callout) }
        if !entry.englishDefinition.isEmpty {
            section("英文释义") { Text(entry.englishDefinition).font(.callout) }
        }
        let forms = entry.formLabels
        if !forms.isEmpty {
            section("词形") { Text(forms.joined(separator: " · ")).font(.callout) }
        }
        let labels = entry.levelLabels
        if !labels.isEmpty {
            section("等级") { Text(labels.joined(separator: " · ")).font(.callout) }
        }
        let phrases = WordDictionary.shared.phrases(startingWith: entry.headword)
        if !phrases.isEmpty {
            section("短语") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(phrases, id: \.headword) { phrase in phraseRow(phrase) }
                }
            }
        }
        Text("来源：ECDICT · \(entry.source)").font(.caption2).foregroundStyle(.secondary)
    }

    private func phraseRow(_ phrase: DictionaryEntry) -> some View {
        let open = openPhrases.contains(phrase.headword)
        return Button {
            if open { openPhrases.remove(phrase.headword) } else { openPhrases.insert(phrase.headword) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(phrase.headword).font(.callout.weight(.medium))
                Text(open ? phrase.definition : phrase.definition.replacingOccurrences(of: "\n", with: "  "))
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(open ? nil : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

extension DictionaryEntry.Form {
    static func title(_ kind: String) -> String {
        switch kind {
        case "p": String(localized: "过去式")
        case "d": String(localized: "过去分词")
        case "i": String(localized: "现在分词")
        case "3": String(localized: "第三人称单数")
        case "r": String(localized: "比较级")
        case "t": String(localized: "最高级")
        case "s": String(localized: "复数")
        default: kind
        }
    }
}

extension DictionaryEntry {
    /// "过去式/过去分词 peeped", one item per distinct form.
    var formLabels: [String] {
        var order: [String] = []
        var kinds: [String: [String]] = [:]
        for form in forms {
            if kinds[form.word] == nil { order.append(form.word) }
            kinds[form.word, default: []].append(Form.title(form.kind))
        }
        return order.map { "\(kinds[$0]!.joined(separator: "/")) \($0)" }
    }

    /// Exam lists the word is on, Collins stars and the Oxford 3000 mark.
    var levelLabels: [String] {
        let exams: [(String, String)] = [("zk", "中考"), ("gk", "高考"), ("cet4", "四级"), ("cet6", "六级"), ("ky", "考研"),
                                         ("ielts", "雅思"), ("toefl", "托福"), ("gre", "GRE")]
        var labels = exams.filter { tags.contains($0.0) }.map { String(localized: String.LocalizationValue($0.1)) }
        if collins > 0 { labels.append(String(localized: "柯林斯") + " " + String(repeating: "★", count: collins)) }
        if isOxford3000 { labels.append(String(localized: "牛津 3000")) }
        return labels
    }
}

/// Reads a word aloud with the system's offline voices.
@MainActor
enum Pronunciation {
    private static let synthesizer = AVSpeechSynthesizer()
    private static let session = SessionRelease()

    static func speak(_ text: String) {
        // The default session category is silenced by the ring/silent switch, so a tap on the
        // speaker button would do nothing on a muted phone. Play as spoken audio instead, ducking
        // whatever else is playing and handing it back when done.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        let accent = UserDefaults.standard.string(forKey: SettingsKeys.dictionaryAccent) ?? "en-US"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: accent)
        synthesizer.delegate = session
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    /// Deactivates the audio session once nothing is left to say, so ducked audio comes back.
    private final class SessionRelease: NSObject, AVSpeechSynthesizerDelegate {
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            release()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            release()
        }

        private func release() {
            // A cancel from stopSpeaking arrives while the next word is already queued.
            Task { @MainActor in
                guard !Pronunciation.synthesizer.isSpeaking else { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

/// Places the lookup card just below the word, or above it when there's no room below,
/// with the pointer (the first subview, drawn behind the card) poking out at the word.
struct LookupBubbleLayout: Layout {
    /// The word's frame in the layout's coordinates; nil puts the card at the top.
    var anchor: CGRect?
    var margin: CGFloat = 12
    var gap: CGFloat = 10
    var maxWidth: CGFloat = 440

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let pointer = subviews[0], card = subviews[1]
        let width = max(0, min(bounds.width - 2 * margin, maxWidth))
        let height = card.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let top = bounds.minY + margin, bottom = bounds.maxY - margin

        guard let anchor = anchor?.offsetBy(dx: bounds.minX, dy: bounds.minY) else {
            card.place(at: CGPoint(x: bounds.midX - width / 2, y: top), proposal: ProposedViewSize(width: width, height: height))
            pointer.place(at: CGPoint(x: bounds.midX, y: top), anchor: .center, proposal: .unspecified)
            return
        }
        let roomBelow = bottom - (anchor.maxY + gap), roomAbove = (anchor.minY - gap) - top
        let below = roomBelow >= height || roomBelow >= roomAbove
        let y = min(max(below ? anchor.maxY + gap : anchor.minY - gap - height, top), max(top, bottom - height))
        let x = min(max(anchor.midX - width / 2, bounds.minX + margin), bounds.maxX - margin - width)
        card.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
        // Kept clear of the rounded corners.
        let pointerX = min(max(anchor.midX, x + 28), x + width - 28)
        pointer.place(at: CGPoint(x: pointerX, y: below ? y : y + height), anchor: .center, proposal: .unspecified)
    }
}
