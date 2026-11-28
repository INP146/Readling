import SwiftUI
import UIKit

/// What the reader picked: a selected word or phrase, with its sentence.
/// Offsets use UTF-16 positions in ReaderChapter.text.
struct ReadingSelection: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var sentence: String
    var offset: Int
    var length: Int
    /// Where the text sits on screen (window coordinates) when it was picked; the lookup bubble points at it.
    var anchor: CGRect?
}

extension ReadingSelection {
    var range: NSRange { NSRange(location: offset, length: length) }
}

struct JumpRequest: Equatable {
    let id = UUID()
    var offset: Int
    var highlight: Bool
}

@MainActor
struct ReadingSurface: UIViewRepresentable {
    var chapter: ReaderChapter
    var layout: ReaderLayout
    var palette: ReaderPalette
    var initialOffset: Int
    var jump: JumpRequest?
    /// Saved words in this chapter, drawn with a dotted underline.
    var markedRanges: [NSRange]
    /// Points per second while auto reading; nil when not scrolling by itself.
    var autoScrollSpeed: Double?
    var onPosition: (_ offset: Int, _ fraction: Double) -> Void
    var onTapBlank: () -> Void
    var onScroll: () -> Void
    /// The selection settled on a word or phrase; long press and double tap both select.
    var onLookup: (ReadingSelection) -> Void
    /// The selection went away.
    var onDeselect: () -> Void
    var onSave: (ReadingSelection) -> Void
    /// True while the lookup card is up; the looked-up text stays selected until it closes, and like the toolbars,
    /// the card turns taps into closing it.
    var lookingUp = false
    /// False while the toolbars are up: taps only dismiss them, and words can't be looked up or selected.
    var interactive = true
    /// Auto reading reached the end of the chapter.
    var onReachEnd: () -> Void = {}
    /// Where the book's image files are; without it pictures are left out.
    var resources: URL?
    /// A link was tapped; the argument is its target as stored in the chapter.
    var onTapLink: (String) -> Void = { _ in }

    nonisolated private static let wordPattern = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:['’‐‑-][A-Za-z]+)*"#)

    nonisolated static func englishWordRanges(in string: String) -> [NSRange] {
        wordPattern.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)).map(\.range)
    }

    /// The exact string the view displays is chapter.text, so stored offsets never drift.
    /// `width` is the width the text is laid out in; tables choose their layout by it, and without it are stacked.
    static func attributedText(for chapter: ReaderChapter, size: CGFloat, layout: ReaderLayout = ReaderLayout(),
                               ink: UIColor = .readerInk, accent: UIColor = .readerAccent, resources: URL? = nil,
                               width: CGFloat? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: chapter.text)
        let full = NSRange(location: 0, length: result.length)
        let face = layout.typeface
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = layout.lineSpacing
        paragraph.paragraphSpacing = size * layout.paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0.2
        paragraph.baseWritingDirection = .leftToRight
        result.addAttributes([.font: ReaderTypography.font(face, size: size), .foregroundColor: ink,
                              .paragraphStyle: paragraph, .accessibilitySpeechLanguage: "en-US"], range: full)
        let text = chapter.text as NSString
        let runs = chapter.styles.filter { $0.location >= 0 && $0.length > 0 && NSMaxRange($0.range) <= result.length }

        /// Changes the font of a range, keeping its traits.
        func restyle(_ range: NSRange, _ change: (UIFont) -> UIFont) {
            result.enumerateAttribute(.font, in: range) { value, part, _ in
                if let font = value as? UIFont { result.addAttribute(.font, value: change(font), range: part) }
            }
        }
        /// Changes the paragraph style of every paragraph a range touches.
        func adjust(_ range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            result.enumerateAttribute(.paragraphStyle, in: text.paragraphRange(for: range)) { value, part, _ in
                let style = NSMutableParagraphStyle()
                style.setParagraphStyle((value as? NSParagraphStyle) ?? paragraph)
                change(style)
                result.addAttribute(.paragraphStyle, value: style, range: part)
            }
        }

        /// Whether the attachment at a run is all its paragraph holds; such a picture or formula stands as a block.
        func standsAlone(_ run: TextStyleRun) -> Bool {
            text.substring(with: text.paragraphRange(for: run.range)).allSatisfy { $0 == "\u{FFFC}" || $0 == "\n" }
        }

        // Inline styles and headings first; the paragraph-level ones below adjust the paragraph styles they leave.
        for run in runs {
            switch run.style {
            case .italic, .bold:
                let trait: UIFontDescriptor.SymbolicTraits = run.style == .italic ? .traitItalic : .traitBold
                restyle(run.range) { font in
                    let traits = font.fontDescriptor.symbolicTraits.union(trait).intersection([.traitItalic, .traitBold])
                    return ReaderTypography.font(face, size: font.pointSize, traits: traits)
                }
            case .sup, .sub:
                restyle(run.range) { UIFont(descriptor: $0.fontDescriptor, size: $0.pointSize * 0.72) }
                result.addAttribute(.baselineOffset, value: run.style == .sup ? size * 0.34 : -size * 0.14, range: run.range)
            case .code:
                result.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: size * 0.88, weight: .regular), range: run.range)
            case .strike:
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            case .link:
                guard let target = run.value else { continue }
                result.addAttributes([.foregroundColor: accent, .readerLink: target], range: run.range)
            case .image:
                guard let resources, let file = run.value else { continue }
                result.addAttribute(.attachment, value: ReaderImageAttachment(url: resources.appendingPathComponent(file), alt: run.alt), range: run.range)
            case .math:
                guard let latex = run.value else { continue }
                // The formula takes the size of the text around it (a superscript's formula is small too).
                let font = result.attribute(.font, at: run.location, effectiveRange: nil) as? UIFont
                result.addAttribute(.attachment, value: ReaderMathAttachment(latex: latex, pointSize: font?.pointSize ?? size, color: ink,
                                                                             typeface: face, display: standsAlone(run)), range: run.range)
            case .rule:
                result.addAttribute(.attachment, value: ReaderRuleAttachment(color: ink, pointSize: size), range: run.range)
            case .heading:
                // Headings found in plain text have no level and keep the size they always had.
                let scale: CGFloat = switch run.value { case "1": 1.4; case "2": 1.25; case "3": 1.12; case nil: 1.25; default: 1.0 }
                let heading = NSMutableParagraphStyle()
                heading.setParagraphStyle(paragraph)
                heading.paragraphSpacingBefore = run.location == 0 ? 0 : size
                heading.paragraphSpacing = max(size, paragraph.paragraphSpacing)
                heading.hyphenationFactor = 0
                result.addAttribute(.font, value: ReaderTypography.font(face, size: size * scale, traits: .traitBold), range: run.range)
                result.addAttribute(.paragraphStyle, value: heading, range: text.paragraphRange(for: run.range))
            case .quote, .list, .center, .table:
                break
            }
        }
        for run in runs {
            switch run.style {
            case .quote: adjust(run.range) { $0.firstLineHeadIndent += 22; $0.headIndent += 22 }
            case .list: adjust(run.range) { $0.firstLineHeadIndent += 20; $0.headIndent += 20; $0.paragraphSpacing = size * 0.25 }
            case .center: adjust(run.range) { $0.alignment = .center; $0.hyphenationFactor = 0 }
            case .image, .math, .rule:
                // A picture, formula or rule alone in its paragraph sits in the middle with no extra leading around it.
                guard standsAlone(run) else { continue }
                adjust(run.range) { $0.alignment = .center; $0.lineHeightMultiple = 1 }
            default: break
            }
        }
        // Tables last: they measure their cells as styled above and set the rows' paragraph styles whole.
        for run in runs where run.style == .table {
            ReaderTables.apply(run, to: result, size: size, width: width, base: paragraph)
        }
        return result
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReaderTextView {
        // TextKit 1 gives reliable character/glyph anchors and temporary attributes.
        let view = ReaderTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear // The backdrop behind shows paper and texture.
        view.tintColor = .readerAccent
        view.textContainer.lineFragmentPadding = 0
        // Insets follow the window, not the bars, so showing/hiding chrome never moves the text.
        view.contentInsetAdjustmentBehavior = .never
        view.dataDetectorTypes = []
        view.accessibilityIdentifier = "reading-text"
        view.accessibilityHint = "选中单词或词组即可查词；也可用辅助功能操作选择单词、查词或收藏。"
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        context.coordinator.update(self, in: view)
        return view
    }

    func updateUIView(_ uiView: ReaderTextView, context: Context) {
        context.coordinator.update(self, in: uiView)
    }

    static func dismantleUIView(_ uiView: ReaderTextView, coordinator: Coordinator) {
        coordinator.detach(from: uiView)
    }

    final class ReaderTextView: UITextView {
        var didLayout: (() -> Void)?
        var willChangeWidth: (() -> Void)?
        /// The width changed, including the first time it is known; called before the text is laid out at it.
        var widthChanged: (() -> Void)?
        private var laidOutWidth: CGFloat = 0

        override func layoutSubviews() {
            if laidOutWidth > 0, abs(bounds.width - laidOutWidth) > 0.5 { willChangeWidth?() }
            let changed = abs(bounds.width - laidOutWidth) > 0.5
            laidOutWidth = bounds.width
            if changed { widthChanged?() }
            updateWindowInsets()
            super.layoutSubviews()
            didLayout?()
        }

        override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
            ReaderTextTools.tightSelectionRects(super.selectionRects(for: range), in: self)
        }

        override func caretRect(for position: UITextPosition) -> CGRect {
            ReaderTextTools.tightRect(super.caretRect(for: position), in: self)
        }

        private func updateWindowInsets() {
            guard let window else { return }
            let insets = UIEdgeInsets(top: window.safeAreaInsets.top, left: 0, bottom: window.safeAreaInsets.bottom, right: 0)
            guard insets != contentInset else { return }
            let shift = insets.top - contentInset.top
            contentInset = insets
            verticalScrollIndicatorInsets = insets
            contentOffset.y -= shift
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var parent: ReadingSurface
        private weak var textView: ReaderTextView?
        private var renderedChapterID: String?
        private var renderedStyle: (size: CGFloat, layout: ReaderLayout, palette: ReaderPalette)?
        /// The text width tables were laid out for; nil when the chapter has none, since then the width doesn't matter.
        private var renderedTableWidth: CGFloat?
        private var wordRanges: [NSRange] = []
        private var marked: [NSRange] = []
        private var pendingAnchor: Int?
        private var pendingHighlight: Int?
        private var lastVisibleOffset = 0
        private var lastReported: (offset: Int, fraction: Double)?
        private var lastJumpID: UUID?
        private var restoring = false
        private var positionScheduled = false
        private var tapFilter = TapFilter()
        private let blankTap = DeferredTap()
        private let selectionLookup = SelectionLookup()
        private let flash = WordFlash()
        private var displayLink: CADisplayLink?
        private var lastTick: CFTimeInterval?
        private var autoScrollCarry: CGFloat = 0
        private var reachedEnd = false

        init(_ parent: ReadingSurface) { self.parent = parent }

        func attach(to view: ReaderTextView) {
            textView = view
            view.didLayout = { [weak self, weak view] in
                guard let self, let view, self.textView === view else { return }
                self.finishLayout()
            }
            view.willChangeWidth = { [weak self, weak view] in
                guard let self, let view, self.textView === view, self.pendingAnchor == nil else { return }
                self.pendingAnchor = self.lastVisibleOffset
            }
            view.widthChanged = { [weak self, weak view] in
                guard let self, let view, self.textView === view, let rendered = self.renderedTableWidth,
                      abs(self.textWidth(in: view) - rendered) > 0.5 else { return }
                self.render(in: view)
            }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            selectionLookup.look = { [weak self] value, _ in self?.parent.onLookup(value) }
            selectionLookup.clear = { [weak self] in self?.parent.onDeselect() }
            view.addGestureRecognizer(selectionLookup.fingers)
            view.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "选择下一个单词", target: self, selector: #selector(selectNextWord)),
                UIAccessibilityCustomAction(name: "选择上一个单词", target: self, selector: #selector(selectPreviousWord)),
                UIAccessibilityCustomAction(name: "查词", target: self, selector: #selector(accessibleLookup)),
                UIAccessibilityCustomAction(name: "收藏", target: self, selector: #selector(accessibleSave))
            ]
        }

        func detach(from view: ReaderTextView) {
            guard textView === view else { return } // A superseded view must not clear the current one.
            flash.cancel()
            blankTap.cancel()
            selectionLookup.cancel()
            view.removeGestureRecognizer(selectionLookup.fingers)
            stopAutoScroll()
            view.delegate = nil
            view.didLayout = nil
            view.willChangeWidth = nil
            view.widthChanged = nil
            textView = nil
        }

        func update(_ value: ReadingSurface, in view: ReaderTextView) {
            if parent.lookingUp && !value.lookingUp { selectionLookup.cardClosed() }
            parent = value // Refresh callbacks even when the document is unchanged.
            let size = ReaderTypography.pointSize(value.layout.fontSize)
            let chapterChanged = renderedChapterID != value.chapter.id
            let styleChanged = renderedStyle.map { $0.size != size || $0.layout != value.layout || $0.palette != value.palette } ?? true
            if chapterChanged || styleChanged {
                let anchor = pendingAnchor ?? (chapterChanged ? value.initialOffset : visibleOffset(in: view))
                let margin = value.layout.margin
                view.textContainerInset = UIEdgeInsets(top: 24, left: margin, bottom: 96, right: margin)
                render(in: view)
                view.tintColor = value.palette.accent
                if chapterChanged {
                    wordRanges = ReadingSurface.englishWordRanges(in: value.chapter.text)
                    lastReported = nil
                    lastVisibleOffset = max(0, value.initialOffset)
                }
                renderedChapterID = value.chapter.id
                renderedStyle = (size, value.layout, value.palette)
                pendingAnchor = anchor
                view.setNeedsLayout()
            }
            if marked != value.markedRanges {
                ReaderTextTools.applyMarks(value.markedRanges, replacing: marked, color: value.palette.accent, in: view.textStorage)
                marked = value.markedRanges
            }
            if let jump = value.jump, jump.id != lastJumpID {
                lastJumpID = jump.id
                pendingAnchor = jump.offset
                pendingHighlight = jump.highlight ? jump.offset : nil
                view.setNeedsLayout()
            }
            if view.isSelectable != value.interactive { view.isSelectable = value.interactive }
            if value.autoScrollSpeed != nil { startAutoScroll() } else { stopAutoScroll() }
        }

        /// Sets the chapter's text for the current settings and width, then puts the saved-word marks back.
        private func render(in view: ReaderTextView) {
            let value = parent
            let hasTables = value.chapter.styles.contains { $0.style == .table }
            let width = textWidth(in: view)
            view.attributedText = ReadingSurface.attributedText(for: value.chapter, size: ReaderTypography.pointSize(value.layout.fontSize),
                                                                layout: value.layout, ink: value.palette.ink, accent: value.palette.accent,
                                                                resources: value.resources, width: width > 1 ? width : nil)
            renderedTableWidth = hasTables ? width : nil
            marked = []
            flash.forget()
            if !value.markedRanges.isEmpty {
                ReaderTextTools.applyMarks(value.markedRanges, replacing: [], color: value.palette.accent, in: view.textStorage)
                marked = value.markedRanges
            }
        }

        private func textWidth(in view: ReaderTextView) -> CGFloat {
            view.bounds.width - view.textContainerInset.left - view.textContainerInset.right
        }

        // MARK: Layout and position

        private func finishLayout() {
            guard !restoring, let view = textView, view.bounds.width > 1, view.bounds.height > 1 else { return }
            if let anchor = pendingAnchor {
                restoring = true
                pendingAnchor = nil
                let length = view.textStorage.length
                if length > 0 {
                    let offset = min(max(0, anchor), length - 1)
                    let manager = view.layoutManager
                    manager.ensureLayout(for: view.textContainer) // Chapters are bounded by ChapterLayout.maximumLength.
                    let glyph = manager.glyphIndexForCharacter(at: offset)
                    let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let y = rect.minY + view.textContainerInset.top - view.adjustedContentInset.top - 16
                    view.setContentOffset(CGPoint(x: 0, y: min(maximumY(in: view), max(minimumY(in: view), y))), animated: false)
                }
                restoring = false
                if let offset = pendingHighlight {
                    pendingHighlight = nil
                    let range = ReaderTextTools.wordRange(containing: offset, in: wordRanges)
                        ?? NSRange(location: min(offset, max(0, length - 1)), length: length > 0 ? 1 : 0)
                    flash.show(range, in: view.textStorage)
                }
            }
            schedulePositionReport()
        }

        private func minimumY(in view: UIScrollView) -> CGFloat { -view.adjustedContentInset.top }

        private func maximumY(in view: UIScrollView) -> CGFloat {
            max(minimumY(in: view), view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        }

        private func visibleOffset(in view: UITextView) -> Int {
            guard view.textStorage.length > 0, view.bounds.width > 1 else { return 0 }
            let manager = view.layoutManager
            let y = max(0, view.contentOffset.y + view.adjustedContentInset.top + 16 - view.textContainerInset.top)
            let glyph = manager.glyphIndex(for: CGPoint(x: 0, y: y), in: view.textContainer)
            guard glyph < manager.numberOfGlyphs else { return max(0, view.textStorage.length - 1) }
            var line = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            return manager.characterIndexForGlyph(at: line.location)
        }

        private func fraction(in view: UITextView) -> Double {
            let scrollable = view.contentSize.height + view.adjustedContentInset.top + view.adjustedContentInset.bottom - view.bounds.height
            guard scrollable > 1 else { return 1 }
            return min(1, max(0, (view.contentOffset.y + view.adjustedContentInset.top) / scrollable))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !restoring, pendingAnchor == nil, let view = textView else { return }
            lastVisibleOffset = visibleOffset(in: view)
            schedulePositionReport()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            selectionLookup.dismiss()
            parent.onScroll()
        }

        private func schedulePositionReport() {
            guard !positionScheduled else { return }
            positionScheduled = true
            // Coalesce scrolling and never change SwiftUI state inside updateUIView.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.positionScheduled = false
                guard self.pendingAnchor == nil, let view = self.textView else { return }
                let offset = self.visibleOffset(in: view)
                let fraction = (self.fraction(in: view) * 100).rounded() / 100
                self.lastVisibleOffset = offset
                guard self.lastReported?.offset != offset || self.lastReported?.fraction != fraction else { return }
                self.lastReported = (offset, fraction)
                self.parent.onPosition(offset, fraction)
            }
        }

        // MARK: Auto reading

        private func startAutoScroll() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = nil
            reachedEnd = false
        }

        private func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            defer { lastTick = link.timestamp }
            guard let view = textView, let speed = parent.autoScrollSpeed, let last = lastTick,
                  !view.isDragging, !view.isDecelerating, pendingAnchor == nil else { return }
            // Whole pixels only, so text never renders between pixel rows.
            let scale = view.traitCollection.displayScale
            autoScrollCarry += CGFloat(speed * (link.timestamp - last)) * scale
            let step = autoScrollCarry.rounded(.down)
            guard step >= 1 else { return }
            autoScrollCarry -= step
            let limit = maximumY(in: view)
            if view.contentOffset.y >= limit - 0.5 {
                guard !reachedEnd else { return }
                reachedEnd = true
                parent.onReachEnd()
                return
            }
            view.contentOffset.y = min(limit, view.contentOffset.y + step / scale)
        }

        // MARK: Tapping

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = textView else { return false }
            tapFilter.began(touch, in: view)
            blankTap.touchBegan()
            // A tap that stops a fling only stops it.
            return !view.isDragging && !view.isDecelerating && !UIAccessibility.isVoiceOverRunning
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true // UITextView's own selection recognizers keep working.
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = textView, tapFilter.isQuick else { return }
            // Like the toolbars, the card (or a selection on its way to one) masks the page: a tap only closes it.
            if tapFilter.beganWithSelection || parent.lookingUp {
                selectionLookup.deselect()
                parent.onDeselect()
                return
            }
            guard view.selectedRange.length == 0 else { return } // The second tap of a double tap selected a word.
            guard parent.interactive else { parent.onTapBlank(); return }
            let location = gesture.location(in: view)
            if let target = ReaderTextTools.link(at: location, in: view) {
                parent.onTapLink(target)
            } else {
                blankTap.run { [weak self, weak view] in
                    guard let self, let view, view.selectedRange.length == 0 else { return }
                    self.parent.onTapBlank()
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

        // MARK: Accessibility

        private func accessibleSelection() -> ReadingSelection? {
            guard let view = textView else { return nil }
            if view.selectedRange.length > 0 { return ReaderTextTools.selection(for: view.selectedRange, in: view) }
            let offset = visibleOffset(in: view)
            guard let range = ReaderTextTools.wordRange(containing: offset, in: wordRanges)
                    ?? wordRanges.first(where: { $0.location >= offset }) else { return nil }
            return ReaderTextTools.selection(for: range, in: view)
        }

        @objc private func accessibleLookup() -> Bool {
            guard let value = accessibleSelection() else { return false }
            parent.onLookup(value)
            return true
        }

        @objc private func accessibleSave() -> Bool {
            guard let value = accessibleSelection() else { return false }
            parent.onSave(value)
            return true
        }

        @objc private func selectNextWord() -> Bool { moveAccessibleSelection(forward: true) }
        @objc private func selectPreviousWord() -> Bool { moveAccessibleSelection(forward: false) }

        private func moveAccessibleSelection(forward: Bool) -> Bool {
            guard let view = textView else { return false }
            let selected = view.selectedRange
            let start = selected.length > 0 ? selected.location : visibleOffset(in: view)
            let range = forward
                ? wordRanges.first { $0.location >= (selected.length > 0 ? NSMaxRange(selected) : start) }
                : wordRanges.last { $0.location < start }
            guard let range, let value = ReaderTextTools.selection(for: range, in: view) else { return false }
            view.selectedRange = range
            view.scrollRangeToVisible(range)
            UIAccessibility.post(notification: .announcement, argument: value.text)
            return true
        }
    }
}

// MARK: - Shared by the scrolling and paged surfaces

/// Hit-testing, sentence context and the edit menu work the same on any text
/// view whose storage holds the whole chapter text.
@MainActor
enum ReaderTextTools {
    /// The character under a point, or nil in margins, paragraph gaps and below the last line.
    static func characterIndex(at location: CGPoint, in view: UITextView) -> Int? {
        guard view.textStorage.length > 0 else { return nil }
        let point = CGPoint(x: location.x - view.textContainerInset.left, y: location.y - view.textContainerInset.top)
        let manager = view.layoutManager
        let glyph = manager.glyphIndex(for: point, in: view.textContainer)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer)
        guard rect.insetBy(dx: -3, dy: -2).contains(point) else { return nil }
        return manager.characterIndexForGlyph(at: glyph)
    }

    /// UIKit highlights whole line fragments, which hold the leading the line spacing adds above the text and the
    /// paragraph spacing around it. Selections and carets are cut down to the line's type, from its baseline, as
    /// book readers draw them.
    static func tightSelectionRects(_ rects: [UITextSelectionRect], in view: UITextView) -> [UITextSelectionRect] {
        // The lines between a selection's first and last come as one block, so each rect is cut line by line.
        var lines: [(base: UITextSelectionRect, rect: CGRect, start: Bool, end: Bool)] = []
        var marks: [(base: UITextSelectionRect, rect: CGRect)] = []
        for rect in rects {
            // The empty rects where the handles go sit apart from the highlight and on one line each.
            if rect.rect.width == 0 {
                marks.append((rect, tightRect(rect.rect, in: view)))
                continue
            }
            let pieces = typeRects(in: rect.rect, in: view)
            // One that can't be cut, as round a picture, keeps the system's rect.
            guard !pieces.isEmpty else { lines.append((rect, rect.rect, rect.containsStart, rect.containsEnd)); continue }
            for (index, piece) in pieces.enumerated() {
                lines.append((rect, piece, index == 0 && rect.containsStart, index == pieces.count - 1 && rect.containsEnd))
            }
        }
        // Neighbouring lines meet halfway across the leading between them, so the selection reads as one block,
        // cut to the type only at its top and bottom.
        lines.sort { $0.rect.minY < $1.rect.minY }
        for index in lines.indices.dropFirst() where lines[index].rect.minY > lines[index - 1].rect.maxY {
            let middle = (lines[index - 1].rect.maxY + lines[index].rect.minY) / 2
            lines[index - 1].rect.size.height = middle - lines[index - 1].rect.minY
            lines[index].rect.size.height = lines[index].rect.maxY - middle
            lines[index].rect.origin.y = middle
        }
        // A handle stands as tall as the highlight on its line.
        let handles = marks.map { mark in
            var rect = mark.rect
            if let line = lines.first(where: { $0.rect.minY <= mark.rect.midY && mark.rect.midY <= $0.rect.maxY })?.rect {
                rect.origin.y = line.minY
                rect.size.height = line.height
            }
            return TightSelectionRect(mark.base, rect: rect, start: mark.base.containsStart, end: mark.base.containsEnd)
        }
        return lines.map { TightSelectionRect($0.base, rect: $0.rect, start: $0.start, end: $0.end) } + handles
    }

    /// A caret or handle rect cut to the type of the line at its middle; it can reach into the next line's leading.
    static func tightRect(_ rect: CGRect, in view: UITextView) -> CGRect {
        guard !rect.isNull, !rect.isInfinite else { return rect }
        let pieces = typeRects(in: CGRect(x: rect.minX, y: rect.midY - 1, width: rect.width, height: 2), in: view)
        return pieces.count == 1 ? pieces[0] : rect
    }

    /// The part of a rect on each line it crosses, cut to that line's type; empty when it crosses none that can be cut.
    private static func typeRects(in rect: CGRect, in view: UITextView) -> [CGRect] {
        guard view.textLayoutManager == nil, !rect.isNull, !rect.isInfinite, rect.height > 0 else { return [] }
        let manager = view.layoutManager, container = view.textContainer, storage = view.textStorage
        guard manager.numberOfGlyphs > 0 else { return [] }
        let inset = view.textContainerInset
        // A caret has no width, which would find no glyphs.
        let local = rect.offsetBy(dx: -inset.left, dy: -inset.top).insetBy(dx: rect.width > 0 ? 0 : -1, dy: 0)
        let glyphs = manager.glyphRange(forBoundingRect: local, in: container)
        guard glyphs.length > 0 else { return [] }
        var pieces: [CGRect] = [], cut = true
        manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, stop in
            // Only lines the rect mostly covers: the system's rect for a line can reach a few points into the one above.
            let overlap = min(line.maxY, local.maxY) - max(line.minY, local.minY)
            guard overlap > min(line.height, local.height) / 2 else { return }
            let characters = manager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            var ascent: CGFloat = 0, descent: CGFloat = 0, picture = false
            storage.enumerateAttributes(in: characters) { attributes, _, stopAttributes in
                if attributes[.attachment] != nil { picture = true; stopAttributes.pointee = true; return }
                guard let font = attributes[.font] as? UIFont else { return }
                let offset = attributes[.baselineOffset] as? CGFloat ?? 0
                ascent = max(ascent, font.ascender + offset)
                descent = max(descent, -font.descender - offset)
            }
            guard !picture, ascent + descent > 0 else { cut = false; stop.pointee = true; return }
            let baseline = line.minY + manager.location(forGlyphAt: lineGlyphs.location).y + inset.top
            pieces.append(CGRect(x: rect.minX, y: baseline - ascent, width: rect.width, height: ascent + descent))
        }
        return cut ? pieces : []
    }

    static func wordRange(at location: CGPoint, in view: UITextView, words: [NSRange]) -> NSRange? {
        characterIndex(at: location, in: view).flatMap { wordRange(containing: $0, in: words) }
    }

    /// The target of the link under a point, if there is one.
    static func link(at location: CGPoint, in view: UITextView) -> String? {
        guard let index = characterIndex(at: location, in: view) else { return nil }
        return view.textStorage.attribute(.readerLink, at: index, effectiveRange: nil) as? String
    }

    static func wordRange(containing offset: Int, in words: [NSRange]) -> NSRange? {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            let range = words[middle]
            if offset < range.location { high = middle }
            else if offset >= NSMaxRange(range) { low = middle + 1 }
            else { return range }
        }
        return nil
    }

    /// `proposedRange` is in the view's text; the selection is in the chapter's, which a page only holds part of.
    static func selection(for proposedRange: NSRange, in view: UITextView) -> ReadingSelection? {
        let page = view as? PageTextView
        let base = page?.page.range.location ?? 0
        let string = page?.chapterText ?? view.textStorage.string as NSString
        guard proposedRange.location != NSNotFound, proposedRange.length > 0,
              NSMaxRange(proposedRange) <= view.textStorage.length else { return nil }
        let raw = string.substring(with: NSRange(location: proposedRange.location + base, length: proposedRange.length))
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let leading = (raw as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location
        let range = NSRange(location: proposedRange.location + base + leading, length: (trimmed as NSString).length)
        // Sentence boundaries are searched within the paragraph only.
        let paragraphRange = string.paragraphRange(for: range)
        let paragraph = string.substring(with: paragraphRange)
        var context: NSRange?
        paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: [.bySentences, .substringNotRequired]) { _, substringRange, _, stop in
            let local = NSRange(substringRange, in: paragraph)
            let sentence = NSRange(location: local.location + paragraphRange.location, length: local.length)
            if NSIntersectionRange(sentence, range).length > 0 {
                context = context.map { NSUnionRange($0, sentence) } ?? sentence
            }
            if sentence.location >= NSMaxRange(range) { stop = true }
        }
        let sentence = string.substring(with: context ?? paragraphRange)
            .replacingOccurrences(of: ChapterTextBuilder.lineSeparator, with: " ")
            .replacingOccurrences(of: ChapterTextBuilder.attachment, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadingSelection(text: trimmed, sentence: sentence, offset: range.location, length: range.length,
                                anchor: windowRect(for: NSRange(location: range.location - base, length: range.length), in: view))
    }

    /// The bounding box of the range's glyphs in window coordinates, which SwiftUI calls global.
    static func windowRect(for range: NSRange, in view: UITextView) -> CGRect? {
        guard view.window != nil else { return nil }
        var rects: [CGRect] = []
        if view.textLayoutManager == nil {
            // Measured with the view's own layout manager and container, as it draws.
            let manager = view.layoutManager, container = view.textContainer
            let glyphs = NSIntersectionRange(manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                             manager.glyphRange(for: container))
            guard glyphs.length > 0 else { return nil }
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in rects.append(rect) }
            rects = rects.map { $0.offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top) }
        } else if let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let textRange = view.textRange(from: start, to: end) {
            rects = view.selectionRects(for: textRange).map(\.rect)
        }
        rects = rects.filter { !$0.isNull && !$0.isEmpty }
        guard let first = rects.first else { return nil }
        return view.convert(rects.dropFirst().reduce(first) { $0.union($1) }, to: nil)
    }

    /// Shown in place of the edit menu: nothing.
    static let noEditMenu = UIMenu(children: [])

    /// Attribute-only edits; the string never changes.
    /// Occurrences of words still being learned, for the dotted underline.
    static func markedRanges(in text: String, words: [NSRange], forms: Set<String>) -> [NSRange] {
        guard !forms.isEmpty else { return [] }
        let string = text as NSString
        return words.filter { forms.contains(WordDictionary.normalize(string.substring(with: $0))) }
    }

    static func applyMarks(_ ranges: [NSRange], replacing old: [NSRange], color: UIColor, in storage: NSTextStorage) {
        let length = storage.length
        storage.beginEditing()
        for range in old where NSMaxRange(range) <= length {
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.underlineColor, range: range)
        }
        for range in ranges where NSMaxRange(range) <= length {
            storage.addAttributes([.underlineStyle: NSUnderlineStyle([.thick, .patternDot]).rawValue,
                                   .underlineColor: color], range: range)
        }
        storage.endEditing()
    }
}

/// Separates a quick tap from a press that became a native selection, or a tap that dismisses one.
@MainActor
struct TapFilter {
    private var beganAt: TimeInterval = 0
    private(set) var beganWithSelection = false

    mutating func began(_ touch: UITouch, in view: UITextView) {
        beganAt = touch.timestamp
        beganWithSelection = view.selectedRange.length > 0
    }

    var isQuick: Bool { ProcessInfo.processInfo.systemUptime - beganAt < 0.35 }
}

/// Holds a tap's action for the double-tap interval, so a double tap selects a word without also toggling the toolbars.
@MainActor
final class DeferredTap {
    private var task: Task<Void, Never>?
    private var interruptedAt: TimeInterval?

    /// A touch landed while a tap was waiting: that tap and the one now starting are a double tap.
    func touchBegan() {
        guard task != nil else { return }
        cancel()
        interruptedAt = ProcessInfo.processInfo.systemUptime
    }

    func run(_ action: @escaping @MainActor () -> Void) {
        if let interruptedAt, ProcessInfo.processInfo.systemUptime - interruptedAt < 0.5 {
            self.interruptedAt = nil // The second tap of a double tap.
            return
        }
        interruptedAt = nil
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.task = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Looks up the native selection once per gesture. Dragging a handle reports the selection once, as it lets go, but
/// a long press that slides on reports every word it passes and adjusts the selection once more just after the lift,
/// so a selection made under a finger is looked up when it lifts and the selection has stopped changing.
/// A finger that starts dragging while a card is open (most likely a handle) closes the card but keeps the selection.
@MainActor
final class SelectionLookup {
    /// Add to the view the selecting touches land in.
    let fingers = FingerWatch()
    var look: (ReadingSelection, UITextView) -> Void = { _, _ in }
    /// The selection went away.
    var clear: () -> Void = {}
    private weak var view: UITextView?
    private var pending = false
    private var settle: Task<Void, Never>?
    /// A card is showing this selection.
    private var showing = false
    /// The card was closed for a drag, so its closing must not let go of the selection.
    private var hidden = false

    init() {
        fingers.onMove = { [weak self] in
            guard let self, self.showing, let view = self.view, view.selectedRange.length > 0 else { return }
            self.showing = false
            self.hidden = true
            self.pending = true
            self.settle?.cancel()
            self.settle = nil
            self.clear()
        }
        fingers.onLift = { [weak self] in
            guard let self, self.pending else { return }
            self.pending = false
            self.lookUpWhenSettled()
        }
    }

    func changed(in view: UITextView) {
        guard view.selectedRange.length > 0 else {
            guard self.view === view else { return }
            self.view = nil
            cancel()
            showing = false
            hidden = false
            clear()
            return
        }
        self.view = view
        if fingers.touching {
            pending = true
            settle?.cancel()
        } else if settle != nil || pending {
            lookUpWhenSettled()
        } else {
            lookUp()
        }
    }

    /// The card closed: lets go of the selection it showed, unless it only closed for a drag.
    func cardClosed() {
        if hidden { hidden = false } else { dismiss() }
    }

    /// The card closed some other way: lets go of the selection it showed.
    func dismiss() {
        cancel()
        showing = false
        hidden = false
        guard let view else { return }
        self.view = nil
        if view.selectedRange.length > 0 { view.selectedRange = NSRange(location: 0, length: 0) }
    }

    /// Lets go of the selection and closes its card.
    func deselect() {
        guard view != nil else { return }
        dismiss()
        clear()
    }

    func cancel() {
        pending = false
        settle?.cancel()
        settle = nil
    }

    private func lookUpWhenSettled() {
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            self.settle = nil
            self.lookUp()
        }
    }

    private func lookUp() {
        guard let view, let value = ReaderTextTools.selection(for: view.selectedRange, in: view) else { return }
        showing = true
        hidden = false // Showing again before SwiftUI saw the card close: there is no closing left to skip.
        look(value, view)
    }
}

/// Follows fingers without taking part in any gesture: it never recognizes, and nothing prevents it from watching.
final class FingerWatch: UIGestureRecognizer {
    /// Once per gesture, when a finger has moved past a tap's slop.
    var onMove: () -> Void = {}
    var onLift: () -> Void = {}
    private(set) var touching = false
    private var start: CGPoint?
    private var moved = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if !touching { start = touches.first?.location(in: nil) }
        touching = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !moved, let start, let point = touches.first?.location(in: nil),
              hypot(point.x - start.x, point.y - start.y) > 10 else { return }
        moved = true
        onMove()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches, event) }

    private func lifted(_ touches: Set<UITouch>, _ event: UIEvent) {
        let down = (event.touches(for: self) ?? []).subtracting(touches).contains { $0.phase != .ended && $0.phase != .cancelled }
        guard !down else { return }
        touching = false
        start = nil
        moved = false
        state = .failed
        onLift()
    }

    override func reset() {
        super.reset()
        touching = false
        start = nil
        moved = false
    }
}

/// Briefly highlights a jumped-to word.
@MainActor
final class WordFlash {
    private var range: NSRange?
    private weak var storage: NSTextStorage?
    private var task: Task<Void, Never>?

    /// The highlight fades after a moment.
    func show(_ range: NSRange, in storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length else { return }
        cancel()
        self.range = range
        self.storage = storage
        storage.addAttribute(.backgroundColor, value: UIColor.readerHighlight, range: range)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    /// Removes the highlight now.
    func cancel() {
        task?.cancel()
        task = nil
        if let range, let storage, NSMaxRange(range) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        forget()
    }

    /// The text was replaced, so the old range no longer means anything.
    func forget() {
        range = nil
        storage = nil
    }
}




/// A system selection rect with its height cut to the type; see `ReaderTextTools.tightSelectionRects`.
final class TightSelectionRect: UITextSelectionRect {
    private let base: UITextSelectionRect
    private let tight: CGRect
    private let start: Bool
    private let end: Bool

    init(_ base: UITextSelectionRect, rect: CGRect, start: Bool, end: Bool) {
        self.base = base
        self.tight = rect
        self.start = start
        self.end = end
    }

    override var rect: CGRect { tight }
    override var writingDirection: NSWritingDirection { base.writingDirection }
    override var containsStart: Bool { start }
    override var containsEnd: Bool { end }
    override var isVertical: Bool { base.isVertical }
}
