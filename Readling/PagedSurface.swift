import SwiftUI
import UIKit

/// Page-by-page reading. Each page lays out the text from where the page
/// before it ended in a page-sized container; what fits is the page, and that
/// same layout is what it shows, so pagination and display can't disagree.
/// Selections are reported in the same chapter coordinates as the scrolling
/// surface. The neighbouring chapters are laid out too, so turning across a
/// chapter boundary is an ordinary page turn.
@MainActor
struct PagedSurface: UIViewControllerRepresentable {
    var chapter: ReaderChapter
    /// Zero-based, for the "chapter n of m" footer.
    var chapterIndex: Int
    var chapterCount: Int
    /// Every chapter of the book, so a page's neighbours never depend on SwiftUI catching up after a chapter turn.
    var chapters: [ReaderChapter]
    var layout: ReaderLayout
    var palette: ReaderPalette
    var backdrop: ReaderBackdrop
    var backdropVersion: Int
    var turn: PageTurn
    var initialOffset: Int
    var jump: JumpRequest?
    /// Words still being learned; every occurrence gets a dotted underline.
    var learningForms: Set<String>
    /// True while the lookup card is up; the looked-up text stays selected until it closes, and like the toolbars,
    /// the card turns taps into closing it.
    var lookingUp: Bool
    /// False while the toolbars are up: taps only dismiss them, and words can't be looked up or selected.
    var interactive: Bool
    /// Seconds per page while auto reading.
    var autoTurnInterval: Double?
    var onPosition: (_ offset: Int, _ fraction: Double) -> Void
    var onTapBlank: () -> Void
    var onTurn: () -> Void
    /// The selection settled on a word or phrase; long press and double tap both select.
    var onLookup: (ReadingSelection) -> Void
    /// The selection went away.
    var onDeselect: () -> Void
    var onSave: (ReadingSelection) -> Void
    /// A page turn carried reading into another chapter, which this surface now shows.
    var onChapterTurn: (_ index: Int) -> Void
    /// Tried to turn past the first or last page of the book.
    var onBoundary: (_ forward: Bool) -> Void
    /// Where the book's image files are; without it pictures are left out.
    var resources: URL?
    /// A link was tapped; the argument is its target as stored in the chapter.
    var onTapLink: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> PagerController { PagerController(self) }

    func updateUIViewController(_ controller: PagerController, context: Context) { controller.update(self) }

    static func dismantleUIViewController(_ controller: PagerController, coordinator: ()) { controller.stopAutoTurn() }
}

/// One chapter laid out page by page.
@MainActor
final class PagedChapter {
    let chapter: ReaderChapter
    let number: Int
    /// The chapter's text, shared by its pages for the sentences around selections.
    let text: NSString
    private(set) var layouts: [PageLayout] = []
    let wordRanges: [NSRange]
    let accent: UIColor
    var marked: [NSRange] = []
    var cache: [Int: PageController] = [:]

    var pages: [NSRange] { layouts.map(\.range) }

    init(_ chapter: ReaderChapter, number: Int, size: CGFloat, layout: ReaderLayout, ink: UIColor, accent: UIColor, pageSize: CGSize,
         forms: Set<String>, resources: URL?) {
        self.chapter = chapter
        self.number = number
        text = chapter.text as NSString
        self.accent = accent
        wordRanges = ReadingSurface.englishWordRanges(in: chapter.text)
        let full = NSTextStorage(attributedString: ReadingSurface.attributedText(for: chapter, size: size, layout: layout,
                                                                                             ink: ink, accent: accent, resources: resources,
                                                                                             width: pageSize.width))
        marked = ReaderTextTools.markedRanges(in: chapter.text, words: wordRanges, forms: forms)
        ReaderTextTools.applyMarks(marked, replacing: [], color: accent, in: full)
        // Each page is handed some text past what it can hold; a generous first guess saves laying out twice.
        let guess = max(500, Int(pageSize.width * pageSize.height / (size * size * 0.25)))
        var start = 0
        repeat {
            let page = PageLayout(text: full, from: start, guess: guess, size: pageSize)
            // A line taller than the page can never be placed; stop rather than loop.
            guard page.range.length > 0 || layouts.isEmpty else { break }
            layouts.append(page)
            start = NSMaxRange(page.range)
        } while start < full.length
    }

    func applyMarks(_ forms: Set<String>) {
        let ranges = ReaderTextTools.markedRanges(in: chapter.text, words: wordRanges, forms: forms)
        guard ranges != marked else { return }
        for page in layouts { page.applyMarks(ranges, replacing: marked, color: accent) }
        marked = ranges
    }

    func pageIndex(containing offset: Int) -> Int {
        pages.firstIndex { offset < NSMaxRange($0) } ?? max(0, pages.count - 1)
    }
}

final class PagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UITextViewDelegate, UIGestureRecognizerDelegate {
    private var config: PagedSurface
    /// Chapters laid out so far, by number: the one being read and its neighbours.
    private var laidOut: [Int: PagedChapter] = [:]
    /// The chapter of the page on screen.
    private var book: PagedChapter?
    private var current = 0
    private var renderedKey: RenderKey?
    private var anchor: Int
    private var pendingJump: JumpRequest?
    private var lastJumpID: UUID?
    private var lastReported: Int?
    private var tapFilter = TapFilter()
    private let blankTap = DeferredTap()
    private let selectionLookup = SelectionLookup()
    private let flash = WordFlash()
    private var pager: UIPageViewController?
    /// Cover and no-animation modes show one page here and animate by hand.
    private let host = UIView()
    private var hosted: PageController?
    /// Cover mode's slide in flight; a new turn skips it to the end rather than waiting.
    private var hostedTurn: UIViewPropertyAnimator?
    /// Our own animated turn in the pager, until it lands.
    private var ownTurn: Int?
    private var turnSerial = 0
    /// Swiped curl turns in flight. Curl lets fast swipes overlap, pairing each start with a finish.
    private var swipesInFlight = 0
    private var lastSwipeEvent: CFTimeInterval = 0
    /// Turns asked for while the pager was busy: + forward, − back.
    private var queuedTurns = 0
    /// Runs queued turns once the pager lets them.
    private var drain: Task<Void, Never>?
    private var autoTurn: (interval: Double, task: Task<Void, Never>)?

    private struct RenderKey: Equatable {
        var chapterID: String
        var size: CGFloat
        var layout: ReaderLayout
        var palette: ReaderPalette
        var bounds: CGSize
        var insets: UIEdgeInsets
    }

    init(_ config: PagedSurface) {
        self.config = config
        anchor = max(0, config.initialOffset)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = config.palette.paper
        view.accessibilityIdentifier = "reading-pages"
        if config.turn == .curl || config.turn == .slide {
            let pager = UIPageViewController(transitionStyle: config.turn == .curl ? .pageCurl : .scroll,
                                             navigationOrientation: .horizontal,
                                             options: config.turn == .curl ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : nil)
            pager.isDoubleSided = false
            pager.dataSource = self
            pager.delegate = self
            // Taps are ours: edges turn pages, the middle shows the toolbars.
            pager.gestureRecognizers.filter { $0 is UITapGestureRecognizer }.forEach { $0.isEnabled = false }
            addChild(pager)
            pager.view.frame = view.bounds
            pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(pager.view)
            pager.didMove(toParent: self)
            self.pager = pager
        } else {
            host.frame = view.bounds
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.clipsToBounds = true
            view.addSubview(host)
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                host.addGestureRecognizer(swipe)
            }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        selectionLookup.look = { [weak self] value, text in
            guard let self else { return }
            // A page turned away meanwhile keeps no selection behind.
            guard text === self.currentTextView, !self.pagerBusy() else { self.selectionLookup.dismiss(); return }
            self.config.onLookup(value)
        }
        selectionLookup.clear = { [weak self] in self?.config.onDeselect() }
        view.addGestureRecognizer(selectionLookup.fingers)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        renderIfNeeded()
    }

    func update(_ value: PagedSurface) {
        let old = config
        config = value
        if old.lookingUp && !value.lookingUp { selectionLookup.cardClosed() }
        if old.backdrop != value.backdrop || old.backdropVersion != value.backdropVersion {
            for page in laidOut.values.flatMap(\.cache.values) { page.backdrop.backdrop = value.backdrop; page.backdrop.refresh() }
        }
        if old.interactive != value.interactive {
            for page in laidOut.values.flatMap(\.cache.values) { page.textView?.isSelectable = value.interactive }
        }
        if let jump = value.jump, jump.id != lastJumpID {
            lastJumpID = jump.id
            pendingJump = jump
            queuedTurns = 0
        }
        renderIfNeeded()
        if old.learningForms != value.learningForms { laidOut.values.forEach { $0.applyMarks(value.learningForms) } }
        if let jump = pendingJump, let book {
            pendingJump = nil
            show(book.pageIndex(containing: jump.offset), of: book, forward: true, animated: false)
            if jump.highlight, let text = currentTextView as? PageTextView {
                let range = ReaderTextTools.wordRange(containing: jump.offset, in: book.wordRanges) ?? NSRange(location: jump.offset, length: 1)
                if let local = text.page.local(range) { flash.show(local, in: text.textStorage) }
            }
        }
        if value.autoTurnInterval != autoTurn?.interval { restartAutoTurn() }
    }

    // MARK: Pagination

    private var safeInsets: UIEdgeInsets { view.window?.safeAreaInsets ?? view.safeAreaInsets }

    /// Blank space under the footer labels.
    private var footerBottomSpace: CGFloat { max(safeInsets.bottom, 12) + 4 }

    /// Text keeps at least one line of 20 pt body text clear above the footer.
    private var footerGap: CGFloat {
        ReaderTypography.font(config.layout.typeface, size: 20).lineHeight * CGFloat(config.layout.lineSpacing)
    }

    /// Where text sits on every page; the header and footer use the bands outside it.
    fileprivate var textFrame: CGRect {
        let insets = safeInsets
        let margin = CGFloat(config.layout.margin)
        return CGRect(x: insets.left + margin, y: insets.top + 34,
                      width: max(1, view.bounds.width - insets.left - insets.right - margin * 2),
                      height: max(1, view.bounds.height - insets.top - 34 - footerBottomSpace - 16 - footerGap))
    }

    /// The page number and chapter progress, pinned above the bottom blank.
    fileprivate var footerFrame: CGRect {
        let text = textFrame
        return CGRect(x: text.minX, y: view.bounds.height - footerBottomSpace - 16, width: text.width, height: 16)
    }

    private func renderKey(for chapterID: String) -> RenderKey {
        RenderKey(chapterID: chapterID, size: ReaderTypography.pointSize(config.layout.fontSize), layout: config.layout,
                  palette: config.palette, bounds: view.bounds.size, insets: safeInsets)
    }

    private func renderIfNeeded() {
        guard isViewLoaded, view.bounds.width > 1, view.bounds.height > 1, view.window != nil else { return }
        let key = renderKey(for: config.chapter.id)
        guard key != renderedKey else { return }
        if let book, book.chapter.id == config.chapter.id, book.pages.indices.contains(current) {
            anchor = book.pages[current].location
        } else if renderedKey != nil {
            anchor = max(0, config.initialOffset) // Opened another chapter.
        }
        renderedKey = key
        view.backgroundColor = config.palette.paper
        flash.cancel()
        let book = makeLayout(for: config.chapter, number: config.chapterIndex)
        laidOut = [book.number: book]
        self.book = book
        current = -1
        lastReported = nil
        queuedTurns = 0
        show(book.pageIndex(containing: anchor), of: book, forward: true, animated: false)
    }

    private func makeLayout(for chapter: ReaderChapter, number: Int) -> PagedChapter {
        PagedChapter(chapter, number: number, size: ReaderTypography.pointSize(config.layout.fontSize), layout: config.layout,
                     ink: config.palette.ink, accent: config.palette.accent, pageSize: textFrame.size, forms: config.learningForms, resources: config.resources)
    }

    /// Chapter `number`, laid out on first use; nil past either end of the book.
    private func chapterLayout(_ number: Int) -> PagedChapter? {
        if let layout = laidOut[number] { return layout }
        guard config.chapters.indices.contains(number) else { return nil }
        let layout = makeLayout(for: config.chapters[number], number: number)
        laidOut[number] = layout
        return layout
    }

    /// Lets go of chapters more than one away from the one being read, whose pages can't be on screen.
    private func trimLayouts() {
        guard let book else { return }
        laidOut = laidOut.filter { abs($0.key - book.number) <= 1 }
    }

    private func page(_ index: Int, of layout: PagedChapter) -> PageController {
        if let page = layout.cache[index] { return page }
        let page = PageController(index: index, layout: layout)
        page.textFrame = { [weak self] in self?.textFrame ?? .zero }
        page.footerFrame = { [weak self] in self?.footerFrame ?? .zero }
        page.backdrop.palette = config.palette
        page.backdrop.backdrop = config.backdrop
        let secondary = config.palette.secondaryInk
        page.header.textColor = secondary
        page.footer.textColor = secondary
        page.progress.textColor = secondary
        if layout.pages.indices.contains(index) {
            let text = PageTextView(page: layout.layouts[index], chapterText: layout.text, frame: textFrame)
            text.isEditable = false
            text.isSelectable = config.interactive
            text.isScrollEnabled = false
            text.backgroundColor = .clear
            text.textContainerInset = .zero
            text.tintColor = config.palette.accent
            text.dataDetectorTypes = []
            text.delegate = self
            text.accessibilityHint = "选中单词或词组即可查词；也可用辅助功能操作选择单词、查词或收藏。"
            // For UI tests: "page 2/3 4/12" is page 4 of 12 in chapter 2 of 3.
            text.accessibilityIdentifier = "page \(layout.number + 1)/\(max(config.chapterCount, 1)) \(index + 1)/\(layout.pages.count)"
            page.textView = text
            page.header.text = layout.chapter.title
            page.footer.text = "\(index + 1) / \(layout.pages.count)"
            let percent = Int(Double(index + 1) / Double(layout.pages.count) * 100)
            page.progress.text = String(localized: "第 \(layout.number + 1)/\(max(config.chapterCount, 1)) 章 · 本章 \(percent)%")
        }
        layout.cache[index] = page
        return page
    }

    // MARK: Turning

    /// Whether the pager mustn't be driven: a turn is moving or a finger is on it. Setting its pages then strands a
    /// page on top of all later ones (curl) or loses the turn's completion (scroll). `tapping` leaves out the finger
    /// whose tap is asking, which is lifting.
    private func pagerBusy(tapping: Bool = false) -> Bool {
        guard let pager else { return false }
        if ownTurn != nil { return true }
        if swipesInFlight > 0 {
            if CACurrentMediaTime() - lastSwipeEvent < 2 { return true }
            swipesInFlight = 0 // A finish UIKit never delivered must not freeze the pages.
        }
        if let scroll = pagerScroll {
            return scroll.isDragging || scroll.isDecelerating || (!tapping && scroll.isTracking)
        }
        return pager.gestureRecognizers.contains { $0.state == .began || $0.state == .changed }
    }

    /// A scroll-style pager's own scroll view. Its transition callbacks don't pair up the way curl's do, so whether
    /// a swipe is still moving is read from here instead.
    private var pagerScroll: UIScrollView? {
        pager?.view.subviews.first { $0 is UIScrollView } as? UIScrollView
    }

    /// After a turn, once nothing is moving: follows the pager to the page it shows, lets go of far chapters and runs
    /// turns asked for meanwhile. Never from inside the pager's own callbacks.
    private func settle() {
        Task { @MainActor [weak self] in
            guard let self, !self.pagerBusy() else { return }
            // Scroll-style pagers fold overlapping swipes together without reporting each one.
            if let shown = self.pager?.viewControllers?.first as? PageController, shown !== self.book?.cache[self.current] {
                self.arrive(at: shown)
            }
            self.trimLayouts()
            self.runQueuedTurns()
        }
    }

    private func turn(forward: Bool, tapping: Bool = false) {
        guard let book else { return }
        finishHostedTurn()
        guard !pagerBusy(tapping: tapping) else { queueTurn(forward: forward); return }
        selectionLookup.dismiss()
        let target = current + (forward ? 1 : -1)
        if book.pages.indices.contains(target) {
            config.onTurn()
            show(target, of: book, forward: forward, animated: config.turn != .none)
        } else if let neighbour = chapterLayout(book.number + (forward ? 1 : -1)) {
            config.onTurn()
            show(forward ? 0 : neighbour.pages.count - 1, of: neighbour, forward: forward, animated: config.turn != .none)
        } else {
            queuedTurns = 0
            config.onBoundary(forward)
        }
    }

    private func queueTurn(forward: Bool) {
        queuedTurns = max(-2, min(2, queuedTurns + (forward ? 1 : -1)))
        guard drain == nil else { return }
        // Polled rather than left to pager callbacks, which don't all arrive when swipes overlap.
        drain = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                self.runQueuedTurns()
                if self.queuedTurns == 0 { self.drain = nil; return }
            }
        }
    }

    private func runQueuedTurns() {
        while queuedTurns != 0, !pagerBusy() {
            let forward = queuedTurns > 0
            queuedTurns += forward ? -1 : 1
            turn(forward: forward)
        }
    }

    private func show(_ index: Int, of layout: PagedChapter, forward: Bool, animated: Bool) {
        guard layout.pages.indices.contains(index) else { return }
        guard layout !== book || index != current else { reportPosition(); return }
        let next = page(index, of: layout)
        if let pager {
            turnSerial += 1
            let serial = turnSerial
            if animated {
                ownTurn = serial
                pager.view.isUserInteractionEnabled = false // No swipe may start until this turn lands; taps still reach us.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.landed(serial, on: next) // In case UIKit never reports back.
                }
            }
            pager.setViewControllers([next], direction: forward ? .forward : .reverse, animated: animated) { [weak self] _ in
                // Not from inside the pager's own completion.
                if animated { Task { @MainActor in self?.landed(serial, on: next) } }
            }
        } else {
            showHosted(next, forward: forward, animated: animated)
        }
        arrive(at: next)
    }

    /// Our own animated turn to `page` finished, or was given up on.
    private func landed(_ serial: Int, on page: PageController) {
        guard ownTurn == serial, let pager else { return }
        ownTurn = nil
        // Scroll-style pagers keep stale neighbours after an animated set.
        if config.turn == .slide, pager.viewControllers?.first === page {
            pager.setViewControllers([page], direction: .forward, animated: false)
        }
        pager.view.isUserInteractionEnabled = true
        settle()
    }

    /// Makes the page current, adopting its chapter when the turn crossed into a neighbour.
    private func arrive(at page: PageController) {
        guard let layout = page.layout else { return }
        if layout !== book {
            book = layout
            config.chapter = layout.chapter
            config.chapterIndex = layout.number
            renderedKey?.chapterID = layout.chapter.id
            lastReported = nil
            flash.cancel()
            if pager == nil { trimLayouts() } // The pager trims once its turns have landed.
            config.onChapterTurn(layout.number)
        }
        current = page.index
        reportPosition()
    }

    private func showHosted(_ next: PageController, forward: Bool, animated: Bool) {
        finishHostedTurn()
        let old = hosted
        guard old !== next else { return }
        addChild(next)
        next.view.frame = host.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosted = next
        let finish = {
            old?.willMove(toParent: nil)
            old?.view.removeFromSuperview()
            old?.removeFromParent()
            next.didMove(toParent: self)
        }
        guard animated, let old else {
            host.addSubview(next.view)
            finish()
            return
        }
        // Cover: the top page slides away to reveal the next, or slides back in over the current one.
        let width = host.bounds.width
        let moving = forward ? old.view! : next.view!
        if forward { host.insertSubview(next.view, belowSubview: old.view) } else { host.addSubview(next.view) }
        moving.layer.shadowColor = UIColor.black.cgColor
        moving.layer.shadowOpacity = 0.25
        moving.layer.shadowRadius = 8
        moving.layer.shadowOffset = CGSize(width: 2, height: 0)
        if !forward { moving.frame.origin.x = -width }
        let slide = UIViewPropertyAnimator(duration: 0.3, curve: .easeOut) { moving.frame.origin.x = forward ? -width : 0 }
        slide.addCompletion { [weak self] _ in
            moving.layer.shadowOpacity = 0
            moving.frame.origin.x = 0
            finish()
            if self?.hostedTurn === slide { self?.hostedTurn = nil }
        }
        hostedTurn = slide
        slide.startAnimation()
    }

    /// Jumps the cover slide in flight to its end; its completion runs before this returns.
    private func finishHostedTurn() {
        guard let slide = hostedTurn else { return }
        hostedTurn = nil
        guard slide.state == .active else { return }
        slide.stopAnimation(false)
        slide.finishAnimation(at: .end)
    }

    private func reportPosition() {
        guard let book, book.pages.indices.contains(current), lastReported != current else { return }
        lastReported = current
        let offset = book.pages[current].location
        let fraction = Double(current + 1) / Double(book.pages.count)
        // Never change SwiftUI state inside updateUIViewController.
        Task { @MainActor [weak self] in self?.config.onPosition(offset, fraction) }
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        turn(forward: gesture.direction == .left)
    }

    // MARK: UIPageViewController

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PageController, let layout = page.layout else { return nil }
        if page.index > 0 { return self.page(page.index - 1, of: layout) }
        guard let previous = chapterLayout(layout.number - 1) else { return nil }
        return self.page(previous.pages.count - 1, of: previous)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PageController, let layout = page.layout else { return nil }
        if page.index + 1 < layout.pages.count { return self.page(page.index + 1, of: layout) }
        guard let next = chapterLayout(layout.number + 1) else { return nil }
        return self.page(0, of: next)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        if config.turn == .curl {
            swipesInFlight += 1
            lastSwipeEvent = CACurrentMediaTime()
        }
        selectionLookup.dismiss()
        config.onTurn()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        if completed, let page = pageViewController.viewControllers?.first as? PageController { arrive(at: page) }
        if config.turn == .curl {
            swipesInFlight = max(0, swipesInFlight - 1)
            lastSwipeEvent = CACurrentMediaTime()
        }
        settle()
    }

    // MARK: Tapping

    private var currentTextView: UITextView? { book?.cache[current]?.textView }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let text = currentTextView else { return false }
        tapFilter.began(touch, in: text)
        blankTap.touchBegan()
        return !UIAccessibility.isVoiceOverRunning
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let text = currentTextView, tapFilter.isQuick else { return }
        let x = gesture.location(in: view).x / max(view.bounds.width, 1)
        let edge = x < 0.3 || x > 0.7
        if tapFilter.beganWithSelection || config.lookingUp {
            // Like the toolbars, the card (or a selection on its way to one) masks the page: a tap only closes it.
            selectionLookup.deselect()
            config.onDeselect()
            return
        } else if text.selectedRange.length > 0 {
            return // The second tap of a double tap selected a word.
        }
        guard config.interactive else { config.onTapBlank(); return }
        // Mid-turn the page under the finger is still moving: edges queue another turn, anything else is ignored.
        guard !pagerBusy(tapping: true) else {
            if edge { turn(forward: x > 0.7, tapping: true) }
            return
        }
        let location = gesture.location(in: text)
        if text.bounds.contains(location), let target = ReaderTextTools.link(at: location, in: text) {
            config.onTapLink(target)
        } else if edge {
            turn(forward: x > 0.7, tapping: true) // Turning also closes the lookup card.
        } else {
            blankTap.run { [weak self, weak text] in
                guard let self, let text, text.selectedRange.length == 0 else { return }
                self.config.onTapBlank()
            }
        }
    }

    // Selecting is looking up: long press or double tap a word, drag the handles to widen it to a phrase.
    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionLookup.changed(in: textView)
    }

    // The lookup card offers what the edit menu would.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        ReaderTextTools.noEditMenu
    }

    // MARK: Auto reading

    private func restartAutoTurn() {
        stopAutoTurn()
        guard let interval = config.autoTurnInterval else { return }
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.turn(forward: true)
            }
        }
        autoTurn = (interval, task)
    }

    func stopAutoTurn() {
        blankTap.cancel()
        selectionLookup.cancel()
        autoTurn?.task.cancel()
        autoTurn = nil
    }
}

/// One page: backdrop, chapter title, the page's text, chapter progress and page number.
final class PageController: UIViewController {
    let index: Int
    private(set) weak var layout: PagedChapter?
    let backdrop = BackdropView()
    let header = UILabel()
    let footer = UILabel()
    let progress = UILabel()
    var textView: UITextView?
    var textFrame: () -> CGRect = { .zero }
    var footerFrame: () -> CGRect = { .zero }

    init(index: Int, layout: PagedChapter) {
        self.index = index
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(backdrop)
        for label in [header, footer, progress] {
            label.font = .systemFont(ofSize: 11)
            label.isAccessibilityElement = false
            view.addSubview(label)
        }
        footer.textAlignment = .right
        footer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        if let textView { view.addSubview(textView) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        let frame = textFrame()
        textView?.frame = frame
        header.frame = CGRect(x: frame.minX, y: frame.minY - 26, width: frame.width, height: 16)
        footer.frame = footerFrame()
        progress.frame = footer.frame
    }
}

/// One page's text, laid out alone in a page-sized container: what fits is the page. It holds some text past the page
/// so the last line breaks as it would in the whole chapter; the container just never shows it.
@MainActor
final class PageLayout {
    /// The page's part of the chapter.
    let range: NSRange
    let container: NSTextContainer
    /// Containers don't keep their layout manager or its storage.
    private let storage: NSTextStorage

    init(text: NSAttributedString, from start: Int, guess: Int, size: CGSize) {
        let string = text.string as NSString
        var length = guess
        while true {
            // End the excerpt at a space, so no word is cut short where a line might break.
            var end = min(string.length, start + length)
            if end < string.length {
                let space = string.rangeOfCharacter(from: .whitespacesAndNewlines, range: NSRange(location: end, length: string.length - end))
                end = space.location == NSNotFound ? string.length : space.location
            }
            let storage = NSTextStorage(attributedString: text.attributedSubstring(from: NSRange(location: start, length: end - start)))
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let fits = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil).length
            // Filling the whole excerpt means more might have fitted, unless it ran to the end of the chapter.
            if fits < storage.length || end == string.length {
                range = NSRange(location: start, length: fits)
                self.container = container
                self.storage = storage
                return
            }
            length *= 2
        }
    }

    /// The part of a chapter range on this page, in the page's own text; nil when none of it is.
    func local(_ range: NSRange) -> NSRange? {
        let part = NSIntersectionRange(range, self.range)
        return part.length > 0 ? NSRange(location: part.location - self.range.location, length: part.length) : nil
    }

    func applyMarks(_ ranges: [NSRange], replacing old: [NSRange], color: UIColor) {
        // The text held past the page too, should it ever be laid out.
        let held = NSRange(location: range.location, length: storage.length)
        func local(_ range: NSRange) -> NSRange? {
            let part = NSIntersectionRange(range, held)
            return part.length > 0 ? NSRange(location: part.location - held.location, length: part.length) : nil
        }
        ReaderTextTools.applyMarks(ranges.compactMap(local), replacing: old.compactMap(local), color: color, in: storage)
    }
}

/// Shows one page's own layout. UIKit lets only the first text container of a layout manager be selected, which is
/// why every page has a layout of its own.
final class PageTextView: UITextView {
    let page: PageLayout
    /// The whole chapter, so a selection's sentence can run on across pages.
    let chapterText: NSString

    @MainActor
    init(page: PageLayout, chapterText: NSString, frame: CGRect) {
        self.page = page
        self.chapterText = chapterText
        super.init(frame: frame, textContainer: page.container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        ReaderTextTools.tightSelectionRects(super.selectionRects(for: range), in: self)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        ReaderTextTools.tightRect(super.caretRect(for: position), in: self)
    }
}
