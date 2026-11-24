import PhotosUI
import SwiftUI
import UIKit

/// Finer reader settings, pushed inside the settings sheet.
enum ReaderSettingsPage: Hashable {
    case fonts
}

/// "主题与设置": a half-height sheet over the page, so changes show on the text above it.
/// The everyday controls fill the half height; spacing and the rest sit below them, shown by pulling the sheet up.
struct ReaderSettingsSheet: View {
    var isNight: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var detent = PresentationDetent.medium

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ReaderSettingsPanel(isNight: isNight, showsAll: detent == .large)
                        // Centered in the room left under the controls; the top padding evens out the gap the safe
                        // area leaves under it, so it sits as far from the controls as from the sheet's edge.
                        if detent != .large { expandHint.padding(.top, 16).frame(maxHeight: .infinity) }
                    }
                    .frame(minHeight: proxy.size.height)
                }
            }
                .navigationTitle("主题与设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .navigationDestination(for: ReaderSettingsPage.self) { page in
                    switch page {
                    case .fonts: ReaderFontPicker()
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    /// At half height, a wide upward chevron under the controls says there is more; tapping it pulls the sheet up too.
    private var expandHint: some View {
        Button {
            withAnimation { detent = .large }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 30, weight: .medium))
                    .imageScale(.large)
                Text("上滑展开更多设置").font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开更多设置")
    }
}

/// Brightness, type, color, background and page turning; below the half-height fold, appearance, screen wake and spacing.
struct ReaderSettingsPanel: View {
    var isNight: Bool
    /// The sheet is pulled up: the settings below the fold appear; at half height they stay hidden, not peeking.
    var showsAll: Bool

    @AppStorage("readerFont") private var fontSize = ReaderTypography.defaultSize
    @AppStorage("readerTypeface") private var typeface = ReaderTypeface.newYork
    @AppStorage("readerAppearance") private var appearance = "system"
    @AppStorage("readerDayTheme") private var dayTheme = ReaderTheme.defaultDay
    @AppStorage("readerNightTheme") private var nightTheme = ReaderTheme.defaultNight
    @AppStorage("readerBackdrop") private var backdrop = ReaderBackdrop.plain
    @AppStorage("readerBackdropVersion") private var backdropVersion = 0
    @AppStorage("readerPageTurn") private var pageTurn = PageTurn.scroll
    @AppStorage("readerLineSpacing") private var lineSpacing = ReaderLayout.defaultLineSpacing
    @AppStorage("readerParagraphSpacing") private var paragraphSpacing = ReaderLayout.defaultParagraphSpacing
    @AppStorage("readerMargin") private var margin = ReaderLayout.defaultMargin
    @AppStorage("readerKeepAwake") private var keepAwake = false
    @State private var brightness = ScreenBrightness.current
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var photoError = false

    private var palette: ReaderPalette { ReaderPalette(day: dayTheme, night: nightTheme) }
    private var hasCustomImage: Bool { _ = backdropVersion; return ReaderBackdrop.customImage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("亮度") {
                Slider(value: $brightness, in: 0...1)
                    .onChange(of: brightness) { _, value in ScreenBrightness.set(value) }
                    .accessibilityLabel("亮度")
            }
            row("字号") {
                Button { fontSize = max(ReaderTypography.sizeRange.lowerBound, fontSize - 1) } label: {
                    sizeGlyph("−").pill()
                }
                .glassPill()
                .disabled(fontSize <= ReaderTypography.sizeRange.lowerBound)
                .accessibilityLabel("字号减小")
                Text("\(Int(fontSize))").monospacedDigit().frame(minWidth: 28)
                Button { fontSize = min(ReaderTypography.sizeRange.upperBound, fontSize + 1) } label: {
                    sizeGlyph("+").pill()
                }
                .glassPill()
                .disabled(fontSize >= ReaderTypography.sizeRange.upperBound)
                .accessibilityLabel("字号增大")
                NavigationLink(value: ReaderSettingsPage.fonts) {
                    HStack(spacing: 4) {
                        Text(typeface.title).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .frame(minHeight: ReaderPanelMetrics.labelHeight)
                    .fixedSize()
                }
                .glassPill()
                .accessibilityIdentifier("choose-font")
            }
            row("颜色") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ReaderTheme.all) { theme in themeSwatch(theme) }
                    }
                    .padding(2)
                }
            }
            row("背景") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ReaderBackdrop.allCases) { item in backdropTile(item) }
                    }
                    .padding(2)
                }
            }
            row("翻页") {
                SegmentedControl(items: PageTurn.allCases.map { (String(localized: $0.title), $0) },
                                 selection: $pageTurn, height: ReaderPanelMetrics.controlHeight)
                    .accessibilityLabel("翻页")
            }

            if showsAll {
                Divider().padding(.vertical, 6)

                row("外观") {
                    SegmentedControl(items: [(String(localized: "跟随系统"), "system"),
                                             (String(localized: "日间"), "light"),
                                             (String(localized: "夜间"), "dark")],
                                     selection: $appearance, height: ReaderPanelMetrics.controlHeight)
                        .accessibilityLabel("外观")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("阅读时屏幕常亮", isOn: $keepAwake)
                    Text("自动阅读时屏幕总是保持常亮。").font(.footnote).foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 6)

                HStack {
                    Text("间距").foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") {
                        lineSpacing = ReaderLayout.defaultLineSpacing
                        paragraphSpacing = ReaderLayout.defaultParagraphSpacing
                        margin = ReaderLayout.defaultMargin
                    }
                    .glassPill()
                    .disabled(lineSpacing == ReaderLayout.defaultLineSpacing
                              && paragraphSpacing == ReaderLayout.defaultParagraphSpacing
                              && margin == ReaderLayout.defaultMargin)
                }
                ReaderSettingSlider(title: "行距", value: $lineSpacing, range: 1.0...2.2, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "段距", value: $paragraphSpacing, range: 0...1.5, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "页边距", value: $margin, range: 12...48, step: 2) { "\(Int($0))" }
            }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    try await ReaderBackdrop.saveCustomImage(from: item)
                    backdropVersion += 1
                    backdrop = .custom
                } catch {
                    photoError = true
                }
                photo = nil
            }
        }
        .alert("无法使用这张图片", isPresented: $photoError) { Button("好", role: .cancel) {} }
        .onAppear { brightness = ScreenBrightness.current }
    }

    /// "A−" / "A+" drawn as text; the SF size symbols localize to 小/大.
    private func sizeGlyph(_ sign: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "A").font(.body)
            Text(verbatim: sign).font(.caption.weight(.semibold)).baselineOffset(7)
        }
        // Laid out as one line of the row's text, so these buttons stand as tall as the others in the panel.
        .frame(height: UIFont.preferredFont(forTextStyle: .subheadline).lineHeight)
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            content()
        }
        .frame(minHeight: 40)
    }

    private func themeSwatch(_ theme: ReaderTheme) -> some View {
        let selected = theme.isDark == isNight && theme.id == (isNight ? nightTheme : dayTheme)
        return Button {
            if theme.isDark { nightTheme = theme.id; appearance = "dark" } else { dayTheme = theme.id; appearance = "light" }
        } label: {
            Text("Aa")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(hex: theme.ink))
                .frame(width: 40, height: 40)
                .background(Color(hex: theme.paper), in: Circle())
                .overlay { Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: 1) }
        }
        .accessibilityLabel(theme.isDark ? "夜间配色" : "日间配色")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func backdropTile(_ item: ReaderBackdrop) -> some View {
        let selected = backdrop == item && (item != .custom || hasCustomImage)
        return Button {
            if item == .custom && (!hasCustomImage || backdrop == .custom) { choosingPhoto = true } else { backdrop = item }
        } label: {
            BackdropRepresentable(backdrop: item, palette: palette, version: backdropVersion)
                .frame(width: 64, height: 40)
                .overlay {
                    if item == .custom {
                        VStack(spacing: 0) {
                            if !hasCustomImage { Image(systemName: "plus") }
                            Text(backdrop == .custom ? "更换" : item.title).font(.caption2)
                        }
                    } else {
                        Text(item.title).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: 1)
                }
        }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The system segmented control at a chosen height, on glass. SwiftUI's segmented picker only comes in the fixed
/// control sizes, none of them as tall as the panel's other buttons; UIKit's stretches to its frame.
struct SegmentedControl<Value: Hashable>: UIViewRepresentable {
    var items: [(title: String, value: Value)]
    @Binding var selection: Value
    var height: CGFloat

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: items.map(\.title))
        // The panel's text size, which follows Dynamic Type like the rest of it.
        control.setTitleTextAttributes([.font: UIFont.preferredFont(forTextStyle: .subheadline)], for: .normal)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        Self.useGlass(control)
        return control
    }

    /// A glass track at rest like the panel's glass buttons, keeping the system's liquid selection thumb; by default the
    /// track is a plain fill. There's no public switch: clearing the track through the appearance API also drops the
    /// thumb. Should the private one go away, the control keeps its default look.
    private static func useGlass(_ control: UISegmentedControl) {
        let selector = NSSelectorFromString("_setUseGlass:")
        guard control.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(control.method(for: selector), to: Setter.self)(control, selector, true)
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegmentIndex = items.firstIndex { $0.value == selection } ?? UISegmentedControl.noSegment
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: SegmentedControl

        init(parent: SegmentedControl) { self.parent = parent }

        @objc func changed(_ control: UISegmentedControl) {
            guard parent.items.indices.contains(control.selectedSegmentIndex) else { return }
            parent.selection = parent.items[control.selectedSegmentIndex].value
        }
    }
}

enum ReaderPanelMetrics {
    /// Every capsule control in the settings panel stands this tall.
    static let controlHeight: CGFloat = 36
    /// The label inside a system glass button that makes the button `controlHeight` tall.
    static let labelHeight: CGFloat = controlHeight - 14
}

private extension View {
    /// A label spread across its share of the row; the control around it is a system glass button.
    func pill(expand: Bool = true) -> some View {
        frame(maxWidth: expand ? .infinity : nil, minHeight: ReaderPanelMetrics.labelHeight)
    }

    /// The system's glass capsule, so these share their height with the segmented control beside them.
    func glassPill() -> some View {
        // Plain ink like the rest of the panel, not the app's accent.
        buttonStyle(.glass).buttonBorderShape(.capsule).tint(.primary)
    }
}

// MARK: Screen brightness

/// The reader may dim or brighten the screen; the system level comes back
/// whenever the reader closes or the app leaves the foreground.
@MainActor
enum ScreenBrightness {
    private static var original: CGFloat?
    private static var chosen: CGFloat?

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    static var current: Double { Double(chosen ?? screen?.brightness ?? 0.5) }

    static func set(_ value: Double) {
        guard let screen, abs(screen.brightness - value) > 0.001 else { return }
        if original == nil { original = screen.brightness }
        chosen = value
        screen.brightness = value
    }

    /// Back to the system level, remembering the reader's choice.
    static func restore() {
        if let original, let screen { screen.brightness = original }
        original = nil
    }

    static func reapply() {
        if let chosen { set(chosen) }
    }

    static func reset() {
        restore()
        chosen = nil
    }
}

// MARK: Sheets

struct ReaderFontPicker: View {
    @AppStorage("readerTypeface") private var typeface = ReaderTypeface.newYork

    var body: some View {
        List(ReaderTypeface.allCases) { item in
            Button { typeface = item } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: "The pleasure of reading begins with a single page.")
                            .font(Font(ReaderTypography.font(item, size: 18) as CTFont))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    if item == typeface { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                }
                .padding(.vertical, 4)
            }
            .accessibilityAddTraits(item == typeface ? .isSelected : [])
        }
        .navigationTitle("字体").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Search

struct BookSearchHit: Identifiable, Sendable {
    var id: Int
    var chapter: Int
    var offset: Int
    var snippet: AttributedString
}

enum BookSearch {
    /// Case- and diacritic-insensitive matches across chapters, in reading order.
    nonisolated static func search(_ query: String, in chapters: [ReaderChapter], limit: Int = 300) -> (hits: [BookSearchHit], truncated: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ([], false) }
        var hits: [BookSearchHit] = []
        for (index, chapter) in chapters.enumerated() {
            let text = chapter.text as NSString
            var start = 0
            while start < text.length {
                let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: start, length: text.length - start))
                guard found.location != NSNotFound else { break }
                guard hits.count < limit else { return (hits, true) }
                hits.append(BookSearchHit(id: hits.count, chapter: index, offset: found.location, snippet: snippet(text, around: found)))
                start = NSMaxRange(found)
            }
        }
        return (hits, false)
    }

    nonisolated private static func snippet(_ text: NSString, around match: NSRange) -> AttributedString {
        // Start and end on composed-character boundaries so emoji never split.
        let lower = text.rangeOfComposedCharacterSequence(at: max(0, match.location - 30)).location
        let upperIndex = min(text.length - 1, NSMaxRange(match) + 60)
        let upper = upperIndex < NSMaxRange(match) ? NSMaxRange(match) : NSMaxRange(text.rangeOfComposedCharacterSequence(at: upperIndex))
        func clean(_ string: String) -> String {
            string.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ChapterTextBuilder.lineSeparator, with: " ")
                .replacingOccurrences(of: ChapterTextBuilder.attachment, with: " ")
        }
        var result = AttributedString(lower > 0 ? "…" : "")
        result += AttributedString(clean(text.substring(with: NSRange(location: lower, length: match.location - lower))))
        var found = AttributedString(clean(text.substring(with: match)))
        found.inlinePresentationIntent = .stronglyEmphasized
        found.foregroundColor = Color.accent
        result += found
        result += AttributedString(clean(text.substring(with: NSRange(location: NSMaxRange(match), length: upper - NSMaxRange(match)))))
        if upper < text.length { result += AttributedString("…") }
        return result
    }
}

struct BookSearchView: View {
    let chapters: [ReaderChapter]
    var onSelect: (_ chapter: Int, _ offset: Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [BookSearchHit] = []
    @State private var truncated = false
    @State private var searchedQuery = ""

    var body: some View {
        NavigationStack {
            List {
                if !hits.isEmpty {
                    Section {
                        ForEach(hits) { hit in
                            Button { onSelect(hit.chapter, hit.offset); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapters.indices.contains(hit.chapter) ? chapters[hit.chapter].title : "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(hit.snippet).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                                }
                            }
                        }
                    } header: {
                        Text(truncated ? "显示前 \(hits.count) 条结果" : "共 \(hits.count) 条结果")
                    }
                }
            }
            .overlay {
                if !searchedQuery.isEmpty && hits.isEmpty { ContentUnavailableView.search(text: searchedQuery) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索本书")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let needle = query
                let chapters = chapters
                let result = await Task.detached(priority: .userInitiated) { BookSearch.search(needle, in: chapters) }.value
                guard !Task.isCancelled else { return }
                hits = result.hits
                truncated = result.truncated
                searchedQuery = needle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
