import SwiftUI
import UIKit

/// Everything that changes how chapter text is laid out. Changing any of it
/// re-renders (and in page modes re-paginates) the chapter.
struct ReaderLayout: Equatable {
    static let defaultLineSpacing = 1.32
    static let defaultParagraphSpacing = 0.75
    static let defaultMargin = 26.0

    var fontSize = ReaderTypography.defaultSize
    var typeface = ReaderTypeface.newYork
    /// Line height multiple.
    var lineSpacing = defaultLineSpacing
    /// Space after a paragraph, in multiples of the font size.
    var paragraphSpacing = defaultParagraphSpacing
    /// Left and right page margin in points.
    var margin = defaultMargin
}

enum ReaderTypeface: String, CaseIterable, Identifiable {
    case newYork, system, georgia, palatino, baskerville, charter, times

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .newYork: "系统衬线"
        case .system: "系统字体"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .baskerville: "Baskerville"
        case .charter: "Charter"
        case .times: "Times New Roman"
        }
    }

    fileprivate var family: String? {
        switch self {
        case .newYork, .system: nil
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .baskerville: "Baskerville"
        case .charter: "Charter"
        case .times: "Times New Roman"
        }
    }
}

extension ReaderTypography {
    static func font(_ typeface: ReaderTypeface, size: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        let base: UIFontDescriptor
        switch typeface {
        case .newYork: return serif(size, traits: traits)
        case .system: base = UIFont.systemFont(ofSize: size).fontDescriptor
        default:
            let named = UIFontDescriptor(fontAttributes: [.family: typeface.family ?? ""])
            // A missing family falls back to the default serif rather than to Helvetica.
            guard !named.matchingFontDescriptors(withMandatoryKeys: [.family]).isEmpty else { return serif(size, traits: traits) }
            base = named
        }
        return UIFont(descriptor: base.withSymbolicTraits(traits) ?? base, size: size)
    }
}

enum PageTurn: String, CaseIterable, Identifiable {
    case curl, cover, slide, scroll, none

    var id: String { rawValue }

    /// A resource rather than a key, so UIKit controls can take it as a plain string too.
    var title: LocalizedStringResource {
        switch self {
        case .curl: "仿真"
        case .cover: "覆盖"
        case .slide: "平移"
        case .scroll: "上下"
        case .none: "无动画"
        }
    }

    var isPaged: Bool { self != .scroll }
}

/// A paper and ink pair, with an accent for links and saved words that stays clear of both.
/// Day and night each remember their own theme; the palette resolves between them through the trait collection.
struct ReaderTheme: Identifiable, Equatable {
    let id: String
    let paper: UInt32
    let ink: UInt32
    let accent: UInt32
    let isDark: Bool

    static let all = [
        ReaderTheme(id: "paper", paper: 0xF7F4ED, ink: 0x292D28, accent: 0x08785E, isDark: false),
        ReaderTheme(id: "white", paper: 0xFFFFFF, ink: 0x222222, accent: 0x08785E, isDark: false),
        ReaderTheme(id: "parchment", paper: 0xEADFC8, ink: 0x3A3125, accent: 0x08705A, isDark: false),
        ReaderTheme(id: "green", paper: 0xCFE3CF, ink: 0x22362A, accent: 0x1C5FA6, isDark: false),
        ReaderTheme(id: "blue", paper: 0xD8E2EC, ink: 0x24303C, accent: 0x0A6F5A, isDark: false),
        ReaderTheme(id: "night", paper: 0x191D1B, ink: 0xC9CEC6, accent: 0x4FD1A0, isDark: true),
        ReaderTheme(id: "black", paper: 0x000000, ink: 0xA8A8A8, accent: 0x3FC28F, isDark: true),
        ReaderTheme(id: "slate", paper: 0x23272D, ink: 0xBFC5CE, accent: 0x5ED3A8, isDark: true)
    ]
    static let defaultDay = "paper"
    static let defaultNight = "night"

    static func named(_ id: String, dark: Bool) -> ReaderTheme {
        all.first { $0.id == id && $0.isDark == dark } ?? all.first { $0.id == (dark ? defaultNight : defaultDay) }!
    }
}

struct ReaderPalette: Equatable {
    var day: ReaderTheme
    var night: ReaderTheme

    init(day: String, night: String) {
        self.day = ReaderTheme.named(day, dark: false)
        self.night = ReaderTheme.named(night, dark: true)
    }

    private func adaptive(_ pick: @escaping @Sendable (ReaderTheme) -> UIColor) -> UIColor {
        let light = pick(day), dark = pick(night)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    var paper: UIColor { adaptive { UIColor(hex: $0.paper) } }
    var ink: UIColor { adaptive { UIColor(hex: $0.ink) } }
    var accent: UIColor { adaptive { UIColor(hex: $0.accent) } }
    var secondaryInk: UIColor { adaptive { UIColor(hex: $0.ink).withAlphaComponent(0.5) } }
    /// Toolbars sit a shade away from the page so they read as a separate layer.
    var chrome: UIColor {
        adaptive { theme in
            UIColor(hex: theme.paper).mixed(with: theme.isDark ? .white : UIColor(hex: theme.ink), amount: theme.isDark ? 0.07 : 0.05)
        }
    }
}

extension UIColor {
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var (r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: a1 + (a2 - a1) * amount)
    }
}

// MARK: Page backgrounds

enum ReaderBackdrop: String, CaseIterable, Identifiable {
    case plain, grain, linen, grid, custom

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .plain: "纯色"
        case .grain: "纸纹"
        case .linen: "布纹"
        case .grid: "格纹"
        case .custom: "自定义"
        }
    }

    /// The reader's own picture, kept beside the library.
    static let customImageURL = URL.appData.appendingPathComponent("reader-background.jpg")

    @MainActor static var customImage: UIImage? {
        if let cached = imageCache, cached.version == customImageVersion { return cached.image }
        let image = UIImage(contentsOfFile: customImageURL.path)
        imageCache = (customImageVersion, image)
        return image
    }

    @MainActor private static var imageCache: (version: Int, image: UIImage?)?
    @MainActor static var customImageVersion: Int { UserDefaults.standard.integer(forKey: SettingsKeys.readerBackdropVersion) }

    /// Callers bump `readerBackdropVersion` afterwards so cached images and views refresh.
    @MainActor static func saveCustomImage(_ data: Data) throws {
        guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        // Screen-sized is plenty for a page background.
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: customImageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: customImageURL, options: .atomic)
    }

    /// A small tile drawn in the ink color at low opacity, so patterns follow the theme.
    fileprivate func tile(ink: UIColor) -> UIImage? {
        let size = CGSize(width: 160, height: 160)
        switch self {
        case .plain, .custom: return nil
        case .grain:
            return UIGraphicsImageRenderer(size: size).image { context in
                var random = SeededRandom(seed: 7)
                for _ in 0..<900 {
                    let alpha = 0.03 + 0.06 * random.next()
                    ink.withAlphaComponent(alpha).setFill()
                    let side = 0.6 + 1.2 * random.next()
                    context.fill(CGRect(x: random.next() * size.width, y: random.next() * size.height, width: side, height: side))
                }
            }
        case .linen:
            return UIGraphicsImageRenderer(size: size).image { context in
                var random = SeededRandom(seed: 11)
                for index in stride(from: 0.0, to: size.width, by: 2) {
                    ink.withAlphaComponent(0.015 + 0.035 * random.next()).setFill()
                    context.fill(CGRect(x: 0, y: index, width: size.width, height: 1))
                    ink.withAlphaComponent(0.015 + 0.035 * random.next()).setFill()
                    context.fill(CGRect(x: index, y: 0, width: 1, height: size.height))
                }
            }
        case .grid:
            return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
                ink.withAlphaComponent(0.06).setFill()
                context.fill(CGRect(x: 0, y: 23.5, width: 24, height: 0.5))
                context.fill(CGRect(x: 23.5, y: 0, width: 0.5, height: 24))
            }
        }
    }
}

private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
    }
}

/// Paper color plus the chosen texture or picture. Used behind the scrolling
/// text and as the opaque face of every page in page modes.
final class BackdropView: UIView {
    private let pattern = UIView()
    private let picture = UIImageView()
    private let veil = UIView()
    private var tileKey: (ReaderBackdrop, UIUserInterfaceStyle)?

    var backdrop = ReaderBackdrop.plain { didSet { refresh() } }
    var palette = ReaderPalette(day: ReaderTheme.defaultDay, night: ReaderTheme.defaultNight) { didSet { tileKey = nil; refresh() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        for view in [picture, veil, pattern] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BackdropView, _: UITraitCollection) in view.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        backgroundColor = palette.paper
        let image = backdrop == .custom ? ReaderBackdrop.customImage : nil
        picture.image = image
        picture.isHidden = image == nil
        // Keep text readable over a photo by washing it with the paper color.
        veil.backgroundColor = palette.paper.withAlphaComponent(0.55)
        veil.isHidden = image == nil
        let style = traitCollection.userInterfaceStyle
        if tileKey?.0 != backdrop || tileKey?.1 != style {
            tileKey = (backdrop, style)
            let ink = palette.ink.resolvedColor(with: traitCollection)
            pattern.backgroundColor = backdrop.tile(ink: ink).map { UIColor(patternImage: $0) } ?? .clear
        }
    }
}

struct BackdropRepresentable: UIViewRepresentable {
    var backdrop: ReaderBackdrop
    var palette: ReaderPalette
    var version: Int

    func makeUIView(context: Context) -> BackdropView { BackdropView() }

    func updateUIView(_ view: BackdropView, context: Context) {
        if view.palette != palette { view.palette = palette }
        view.backdrop = backdrop
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}
