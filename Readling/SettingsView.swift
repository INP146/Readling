import PhotosUI
import SwiftUI

/// The app's own Settings tab, laid out like the system Settings app but in
/// the app's paper and card colors.
struct SettingsView: View {
    let store: LibraryStore

    var body: some View {
        NavigationStack {
            SettingsList {
                Section {
                    NavigationLink { ReaderPreferencesView() } label: {
                        SettingsIconLabel("阅读器设置", systemImage: "book.pages.fill", color: .accent)
                    }
                    NavigationLink { DictionarySettingsView() } label: {
                        HStack {
                            SettingsIconLabel("词典", systemImage: "character.book.closed.fill", color: .accent)
                            Spacer()
                            if !DictionaryDownloads.shared.updates.isEmpty { UpdateBadge() }
                        }
                    }
                    NavigationLink { TranslationSettingsView() } label: {
                        SettingsIconLabel("翻译", systemImage: "translate", color: .accent)
                    }
                    NavigationLink { AISettingsView() } label: {
                        SettingsIconLabel("AI 服务", systemImage: "sparkles", color: .accent)
                    }
                }
                Section {
                    NavigationLink { AboutView(store: store) } label: {
                        SettingsIconLabel("关于", systemImage: "info", color: .gray)
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

/// A row title with a white glyph on a colored rounded square, as in the system Settings app.
private struct SettingsIconLabel: View {
    var title: LocalizedStringKey
    var systemImage: String
    var color: Color
    @ScaledMetric(relativeTo: .body) private var size = 29.0

    init(_ title: LocalizedStringKey, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            // Fit every glyph in the same box so wide ones like "translate" stay inside the square.
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(width: size * 0.7, height: size * 0.6)
                .frame(width: size, height: size)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.23))
        }
    }
}

/// The red "1" the system Settings app puts on a row with a pending update.
private struct UpdateBadge: View {
    @ScaledMetric(relativeTo: .body) private var size = 22.0

    var body: some View {
        Text(verbatim: "1")
            .font(.system(size: size * 0.68, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.red, in: Circle())
            .accessibilityLabel("有更新")
    }
}

// MARK: Reader settings

/// The same settings as the reader's own panel, sharing its stored values.
/// Screen brightness stays in the reader: it only lasts while a book is open.
struct ReaderPreferencesView: View {
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
    @State private var photo: PhotosPickerItem?
    @State private var photoError = false

    private var palette: ReaderPalette { ReaderPalette(day: dayTheme, night: nightTheme) }
    private var hasCustomImage: Bool { _ = backdropVersion; return ReaderBackdrop.customImage != nil }

    var body: some View {
        SettingsList {
            Section {
                preview
            }
            Section("文字") {
                Picker("字体", selection: $typeface) {
                    ForEach(ReaderTypeface.allCases) { item in
                        Text(item.title).font(Font(ReaderTypography.font(item, size: 17) as CTFont)).tag(item)
                    }
                }
                .pickerStyle(.navigationLink)
                Stepper(value: $fontSize, in: ReaderTypography.sizeRange, step: 1) {
                    LabeledContent("字号") { Text("\(Int(fontSize))").monospacedDigit() }
                }
            }
            Section {
                ReaderSettingSlider(title: "行距", value: $lineSpacing, range: 1.0...2.2, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "段距", value: $paragraphSpacing, range: 0...1.5, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "页边距", value: $margin, range: 12...48, step: 2) { "\(Int($0))" }
                Button("恢复默认间距") {
                    lineSpacing = ReaderLayout.defaultLineSpacing
                    paragraphSpacing = ReaderLayout.defaultParagraphSpacing
                    margin = ReaderLayout.defaultMargin
                }
                .disabled(lineSpacing == ReaderLayout.defaultLineSpacing && paragraphSpacing == ReaderLayout.defaultParagraphSpacing
                    && margin == ReaderLayout.defaultMargin)
            } header: { Text("间距") }
            Section("外观") {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("日间").tag("light")
                    Text("夜间").tag("dark")
                }
                themePicker("日间配色", selection: $dayTheme, dark: false)
                themePicker("夜间配色", selection: $nightTheme, dark: true)
                Picker("背景", selection: $backdrop) {
                    ForEach(ReaderBackdrop.allCases.filter { $0 != .custom || hasCustomImage }) { item in
                        Text(item.title).tag(item)
                    }
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Text(hasCustomImage ? "更换背景图片" : "从相册选择背景图片")
                }
                Toggle("护眼模式", isOn: $eyeCare)
            }
            Section("翻页") {
                Picker("翻页方式", selection: $pageTurn) {
                    ForEach(PageTurn.allCases) { item in Text(item.title).tag(item) }
                }
                Stepper(value: $autoSpeed, in: 1...10) {
                    LabeledContent("自动阅读速度") { Text("\(autoSpeed)").monospacedDigit() }
                }
            }
            Section {
                Toggle("阅读时屏幕常亮", isOn: $keepAwake)
            } footer: {
                Text("自动阅读时屏幕总是保持常亮。")
            }
        }
        .navigationTitle("阅读器设置")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    /// A few lines set as the reader would set them, on the current day or night page.
    private var preview: some View {
        let font = ReaderTypography.font(typeface, size: fontSize)
        let theme = appearance == "dark" ? palette.night : appearance == "light" ? palette.day : nil
        return Text(verbatim: "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.")
            .font(Font(font as CTFont))
            .lineSpacing(max(0, font.lineHeight * (lineSpacing - 1)))
            .foregroundStyle(Color(uiColor: palette.ink))
            .padding(.horizontal, margin)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { BackdropRepresentable(backdrop: backdrop, palette: palette, version: backdropVersion) }
            .environment(\.colorScheme, theme.map { $0.isDark ? .dark : .light } ?? colorScheme)
            .listRowInsets(EdgeInsets())
            .accessibilityHidden(true)
    }

    @Environment(\.colorScheme) private var colorScheme

    private func themePicker(_ title: LocalizedStringKey, selection: Binding<String>, dark: Bool) -> some View {
        NavigationLink {
            SettingsList {
                ForEach(ReaderTheme.all.filter { $0.isDark == dark }) { theme in
                    Button { selection.wrappedValue = theme.id } label: {
                        HStack(spacing: 12) {
                            ReaderThemeSwatch(theme: theme)
                            Text(theme.title).foregroundStyle(.primary)
                            Spacer()
                            if theme.id == ReaderTheme.named(selection.wrappedValue, dark: dark).id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(theme.id == selection.wrappedValue ? .isSelected : [])
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    ReaderThemeSwatch(theme: ReaderTheme.named(selection.wrappedValue, dark: dark), size: 24)
                    Text(ReaderTheme.named(selection.wrappedValue, dark: dark).title)
                }
            }
        }
    }
}

private struct ReaderThemeSwatch: View {
    var theme: ReaderTheme
    var size: CGFloat = 32

    var body: some View {
        Text(verbatim: "Aa")
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(Color(hex: theme.ink))
            .frame(width: size, height: size)
            .background(Color(hex: theme.paper), in: Circle())
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
            .accessibilityHidden(true)
    }
}

// MARK: Dictionary

struct DictionarySettingsView: View {
    @AppStorage(SettingsKeys.dictionaryExpandByDefault) private var expandByDefault = false
    @AppStorage(SettingsKeys.dictionaryAccent) private var accent = "en-US"
    private let downloads = DictionaryDownloads.shared

    var body: some View {
        SettingsList {
            let updates = downloads.updates
            if !updates.isEmpty, let release = downloads.catalog?.release {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("词典 \(release) 可更新")
                            Text(ByteCountFormatter.string(fromByteCount: updates.reduce(0) { $0 + $1.size }, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if downloads.isUpdating {
                            ProgressView()
                        } else {
                            Button("更新") { Task { await downloads.updateAll() } }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                } footer: {
                    Text("核心词典和已下载的词典包一起更新，下载新词典包时也会顺带更新，以免各包收录的词条对不上。")
                }
            }
            Section {
                if let core = downloads.dictionary.core {
                    if let pack = downloads.packs.first(where: { $0.id == core.id }) {
                        row(pack)
                    } else {
                        packLabel(core.title, details: [Self.count(core.entryCount), core.version])
                    }
                }
            } header: { Text("已内置") } footer: {
                Text("常用词、它们的变形和通用短语（含短语动词），不联网也能用。")
            }
            if downloads.packs.isEmpty {
                Section {
                    if downloads.isRefreshing {
                        HStack { Text("正在获取词典列表…").foregroundStyle(.secondary); Spacer(); ProgressView() }
                    } else if let error = downloads.catalogError {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试") { Task { await downloads.refresh() } }
                    }
                }
            } else {
                group("vocabulary", title: "词汇", footer: "其余的普通单词和短语，多为生僻词。")
                group("field", title: "学科",
                      footer: "只收全部义项都属于该学科的词条；常用词即使带学科义项，也已在核心词典里。")
                group("names", title: "专有名词", footer: "人名、地名、机构名和生物学名。")
            }
            Section("单词卡") {
                Toggle("默认展开", isOn: $expandByDefault)
                Picker("朗读口音", selection: $accent) {
                    Text("美音").tag("en-US")
                    Text("英音").tag("en-GB")
                }
            }
            Section {
            } footer: {
                Text("词典数据来自 ECDICT（MIT 许可），各词典包可以任意组合。应用每天最多自动检查一次词典更新，此外只有打开此页或下载词典时才会联网。")
            }
        }
        .navigationTitle("词典")
        .navigationBarTitleDisplayMode(.inline)
        .task { await downloads.refresh() }
        .refreshable { await downloads.refresh() }
    }

    @ViewBuilder
    private func group(_ group: String, title: LocalizedStringKey, footer: LocalizedStringKey) -> some View {
        let packs = downloads.packs.filter { $0.group == group }
        if !packs.isEmpty {
            Section {
                ForEach(packs) { pack in row(pack) }
            } header: { Text(title) } footer: { Text(footer) }
        }
    }

    private func row(_ pack: DictionaryCatalog.Pack) -> some View {
        let status = downloads.status(of: pack)
        let installed = downloads.installed(pack.id)
        let isCore = pack.id == DictionaryPack.coreID
        // The installed version's figures until it is updated.
        var details = [Self.count(installed?.entryCount ?? pack.entries)]
        if !isCore {
            details.append(ByteCountFormatter.string(fromByteCount: installed == nil ? pack.size : pack.installedSize, countStyle: .file))
        }
        details.append(installed?.version ?? pack.version)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                packLabel(pack.title, details: details)
                if case .failed(let message) = status {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch status {
            case .notInstalled, .failed:
                Button(status == .notInstalled ? "下载" : "重试") { Task { await downloads.download(pack) } }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            case .updateAvailable:
                Text("可更新").foregroundStyle(.secondary)
            case .downloading(let fraction):
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button { downloads.cancel(pack) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("取消下载")
            case .installing:
                ProgressView()
            case .installed:
                if !isCore { Text("已安装").foregroundStyle(.secondary) }
            }
        }
        .swipeActions {
            if installed != nil && !isCore {
                Button("删除", role: .destructive) { downloads.remove(pack) }
            }
        }
        .contextMenu {
            if installed != nil && !isCore {
                Button("删除", systemImage: "trash", role: .destructive) { downloads.remove(pack) }
            }
        }
    }

    private func packLabel(_ title: String, details: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(verbatim: details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "23.1 万条", "8,412 条".
    static func count(_ entries: Int) -> String {
        entries >= 10_000 ? String(localized: "\(Double(entries) / 10_000, format: .number.precision(.fractionLength(1))) 万条")
            : String(localized: "\(entries) 条")
    }
}

// MARK: About

struct AboutView: View {
    let store: LibraryStore

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        SettingsList {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accent)
                        .padding(.bottom, 4)
                    Text(verbatim: "Readling").font(.title3.weight(.semibold))
                    Text("离线阅读英文书，点词即查，生词随读随记。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("版本", value: version)
                NavigationLink { DataStatusView(store: store) } label: {
                    LabeledContent("数据与升级") { DataStatusSummary(store: store) }
                }
            }
            Section {
                Text("书籍、阅读位置和生词都只保存在这台设备上，不会上传。删除应用会一并删除。")
                Text("应用每天最多自动检查一次词典更新；此外只有在打开“词典”设置或下载词典时才会联网。")
                Text("选用 DeepL 或 AI 服务翻译后，查不到的词和选中的句子（连同所在的句子）会发给你选择的服务；书的其余内容和生词本不会上传。默认的 Apple 本机翻译不联网。")
            } header: { Text("数据") }
            Section {
                Text("释义来自离线英汉词典 ECDICT（MIT 许可）。")
                Text("示例书节选自 Project Gutenberg 的公版《爱丽丝梦游仙境》。")
            } header: { Text("致谢") }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Shared pieces

/// A grouped settings list on the app's paper background with card rows, as in
/// the library and word list, instead of the system grays.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List { content.listRowBackground(Color.card) }
            .scrollContentBackground(.hidden)
            .background(Color.paper)
    }
}

/// A titled slider with its value on the trailing side, for settings forms.
struct ReaderSettingSlider: View {
    var title: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

extension ReaderTheme {
    var title: LocalizedStringKey {
        switch id {
        case "paper": "米白"
        case "white": "纯白"
        case "parchment": "羊皮纸"
        case "green": "豆沙绿"
        case "blue": "雾蓝"
        case "night": "墨绿夜"
        case "black": "纯黑"
        case "slate": "石板灰"
        default: LocalizedStringKey(id)
        }
    }
}

extension ReaderBackdrop {
    /// Loads a picture chosen in the photo picker and saves it as the custom background.
    @MainActor static func saveCustomImage(from item: PhotosPickerItem) async throws {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
        try saveCustomImage(data)
    }
}
