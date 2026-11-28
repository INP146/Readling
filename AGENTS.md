# Readling

iOS 英文阅读器（SwiftUI，iOS 26，Xcode 26.3+）。离线 EPUB/TXT 导入、点词查释义（内置 ECDICT 子集）、生词本与间隔复习。

功能现状与已知边界见 `IMPLEMENTATION-HANDOFF.md`。

## 结构
- `Readling/` 应用源码
  - `BookImporter.swift` EPUB/TXT 安全解包（依赖 SPM 包 ZIPFoundation；公式排版依赖 SwiftMath）；`BookBuilder.swift` 从已存原书目录生成章节正文与元数据（导入与迁移后的后台重建共用同一份实现）
  - `ChapterText.swift` 统一的“纯文本 + 样式区间”章节构建；`HTMLEntities.swift` 实体表
  - `MathML.swift` 公式：导入时把 MathML 转成 LaTeX 存进章节（书里自带可排版的 TeX 注解就直接用；为 MathJax 准备的书在正文里写 `\( \)`、`\[ \]`、`$$ $$` 包住的 TeX，能排版的也画成公式，单个 `$` 不认），`ReaderMath.swift` 用 SPM 包 SwiftMath 把公式画成行内附件（独占一段时为居中的 display 样式），另有分隔线 `hr` 附件
  - `ReaderTable.swift` 表格：仍是可查词的文字（每行一段、单元格之间用 tab），按显示宽度选择排版：放得下就用制表位排成网格（数字列右对齐），放不下就让单元格逐行堆叠（行内唯一的制表位放在行尾，靠它换行；iOS 的 TextKit 不认 `NSLayoutManagerDelegate` 对 tab 返回的换行动作）
  - `LibraryStore.swift` 书库持久化（`library.json` v3 + `books/<uuid>/`）与后台正文重建；`Persistence/` 数据版本与迁移链（`DataVersion.swift`、`Migrator.swift`、`TextRemap.swift`、`Snapshots/`、`Migrations/`）；`DataStatusView.swift` “设置 › 关于 › 数据与升级”与降级拦截页；`SettingsKeys.swift` 全部 UserDefaults 键名
  - `ReaderView.swift` 阅读页与悬浮的玻璃按钮（轻点正文显示右上关闭、右下菜单，菜单展开为目录/搜索/主题与设置等；“目录”行左右拖动即进度条，按各章字数换算全书位置）；`ReadingSurface.swift` 上下滚动正文；`PagedSurface.swift` 分页正文（仿真/覆盖/平移/无动画；每页从上一页结束处起在页面大小的容器里单独排版，装下的就是这一页，显示的也正是这次排版）
  - `ReaderPanels.swift` 主题与设置 sheet（字体/间距/更多设置在其中推入）、书内搜索；`ReaderStyle.swift` 排版、配色主题、背景纹理
  - `WordsView.swift` 生词本与复习
  - `SettingsView.swift` 设置标签页（原生分组列表布局，配色与书架、生词本一致，见 `SettingsList`）：阅读器设置（与阅读页内设置共用同一批 `@AppStorage` 键）、词典、关于；翻译与 AI 服务页分别在 `Translation/`、`AI/`
  - `WordDictionary.swift` 词典：`DictionaryPack` 读取单个词典包（SQLite，schema 2），`WordDictionary` 以并集方式查询核心包（内置的 `Resources/dictionary-core.sqlite`，或已下载的更新版本，取较新者）与 Application Support/Readling/Dictionaries 下的已下载包。变形→原形只由核心包的 `form` 表决定，生词的 key 与安装了哪些包无关
  - `DictionaryDownloads.swift` 词典包下载：读取清单 `Dictionaries/manifest.json`（经 raw.githubusercontent），从本仓库 Releases 下载 zip，校验 sha256 后安装到 Application Support/Readling/Dictionaries。核心词典也在清单里，更新时核心与已下载的包整版一起更新，一批全部下载解压成功才替换；“设置 › 词典”页在 `SettingsView.swift`
  - `Online/` 联网服务共用的底层：`OnlineService.swift`（地址规范化、请求、SSE 流式运行、HTTP/网络错误映射为 `OnlineFailure`）、`APIKeychain.swift`（API Key 存 Keychain，仅本机；`.ai` 按端点 UUID，`.translation` 存 DeepL 等）、`ServiceForm.swift`（设置表单里的 Key 输入与“测试”区块）
  - `AI/` 大模型端点，与具体功能无关：`AIClient.swift`（`AIPrompt`、`AIClient` 协议、接口格式 `AIFormat`、端点 `AIEndpoint`）、`AIEndpointStore.swift`（端点增删改与持久化）、三种接口格式 `OpenAIClient.swift`（Chat Completions）/`ClaudeClient.swift`（Messages）/`GeminiClient.swift`（REST SSE），只负责拼请求和取文本增量、不含提示词；“设置 › AI 服务”与端点编辑页在 `AISettingsView.swift`。各功能自己选用哪个端点、自己写提示词，设计见 `docs/ai-design.md`
  - `Translation/` 词典查不到时的翻译：`TranslationService.swift`（所选服务 `TranslationProviderID`：Apple / DeepL / 某个 AI 端点，失败退回 Apple，本次启动内缓存）、`AppleTranslationEngine.swift`（默认、离线）、`DeepLEngine.swift`（DeepL/DeepLX `/v2/translate`，官方域名按 `:fx` 分流并附带原句 `context`）、`AITranslationEngine.swift`（翻译与语境释义的提示词，经 `AIClient` 发送）；“设置 › 翻译”与 DeepL 配置页在 `TranslationSettingsView.swift`
  - `Theme.swift` 颜色（自动适配深色）
- `ReadlingTests/` 单元测试（`Fixtures/alice.epub`、`Fixtures/formulas.epub`、`Fixtures/verse.txt`，以及各已发布版本的真实数据夹具 `Fixtures/AppData/<版本>.bundle`）
- `ReadlingUITests/` UI 测试：`SelectionUITests.m` 在四种翻页模式下翻页前后长按选词，要求弹出单词卡、点按后关闭，另有长按拖选多行、要求单词卡显示译文；`PagingUITests.m` 在仿真/平移/覆盖模式下连发快速滑动和点按（重叠的手势，跨章节），每轮后要求正常翻页逐页落地。用 XCUIAutomation 的私有事件合成（`XCSynthesizedEventRecord`），因为 XCUIElement 的手势会等应用空闲、无法重叠；该 API 不可用时测试会跳过。应用侧钩子：启动参数 `-freshLibrary` 使用临时空书库；`-dictionaryManifestURL <url>` 改用别的词典清单（可配合本地 `python3 -m http.server` 试下载）；分页正文的 `accessibilityIdentifier` 为 `page 章/总章 页/本章总页`；`-translationEngine stub` 改用返回固定文本的测试翻译引擎
- `Tools/build-dictionary.py` 从 ECDICT CSV 生成词典包，每条只归入一个包（core/extended/八个学科/names），输出 `OUT_DIR/dictionary-<包>.sqlite`：`python3 -I Tools/build-dictionary.py ecdict.csv Readling/Resources core`（只重建内置核心包），不写包名则生成全部
- `Tools/app_release.py` App 发布（prepare / check / build / post-release），以 `Readling.xcodeproj/project.pbxproj` 为版本唯一事实来源（SemVer，首次发版前为 `0.0.0`），校验 `DataVersion` 迁移链与数据夹具一致，推送 `v*.*.*` tag 后由 `.github/workflows/publish-app.yml` 在 `macos-26` 上跑测试、打未签名 `Readling-<版本>.ipa` 与 `SHA256SUMS` 并创建 GitHub Release
- `Tools/dictionary_release.py` 词典发布（prepare / check / build / adopt），`Dictionaries/release.json` 记录版本与固定的 ECDICT 数据源，`docs/releases/` 放发布说明；推送 `dict-*` tag 后由 `.github/workflows/publish-dictionaries.yml` 构建并创建 Release。`.env` 的 `RELEASE_AI_PROVIDER=codex|claude` 让两者的 prepare 调用本机 CLI 起草发布说明（`Tools/release_ai.py`，模板见 `.env.example`）。流程见 `docs/release.md`，脚本测试：`python3 -m unittest discover -s Tools/tests`
- `docs/screenshots/` 模拟器截图
- `docs/data-versioning.md` 本机数据版本、相邻版本迁移链与后台正文重建的设计与规范
- `docs/dictionary-design.md` 词典分包、单词卡、下载的设计与实施进度
- `docs/ai-design.md` AI 层（大模型端点）与各功能的分工
- `docs/translation-design.md` 查不到时的翻译、可选翻译引擎（用户自带 Key）的设计与实施进度
- `docs/release.md` App 与词典包的发布流程；`docs/releases/` 各 tag 的发布说明

## 构建与测试
```sh
# 构建（模拟器，无需签名）
xcodebuild -project Readling.xcodeproj -scheme Readling \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 测试（单元测试 + UI 测试，UI 测试约 4 分钟）
xcodebuild -project Readling.xcodeproj -scheme Readling \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# 只跑单元测试（快速迭代时）
xcodebuild -project Readling.xcodeproj -scheme Readling \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:ReadlingTests
```
真机构建需在 Xcode 中为 target 设置 Development Team（项目未写死 Team）；没有开发者账号时，用外部工具 `iosign install`（`~/Projects/iosign`）以第三方证书重签安装。Bundle ID：`com.inp146.readling`。

## 约定
- 用中文回答用户。
- 界面文案为中文，放在 `Localizable.xcstrings`。
- 测试按改动范围分级，提交前（或一组改动收尾时）跑一次完整测试：
  - 不碰正文的界面改动（文案、颜色、设置面板、生词本界面等）：构建或单元测试即可
  - 导入/章节构建/持久化/词典：单元测试（改了构建或发布脚本再加 `python3 -m unittest discover -s Tools/tests`）；涉及导入/渲染时注意“渲染字符串与正文逐字一致”的测试
  - 分页/翻页：单元测试 + `-only-testing:ReadlingUITests/PagingUITests`
  - 选词/查词：单元测试 + `-only-testing:ReadlingUITests/SelectionUITests`
  - 反复迭代时可先 `build-for-testing`，再用 `test-without-building -only-testing:...` 省去编译；修某个失败用例时先只跑该用例（如 `.../SelectionUITests/testCurl`）
- app 内的实质性改动（功能、界面、行为，不含纯文档/脚本/测试改动）完成并通过对应测试后，直接在仓库根目录运行 `iosign dev` 装到真机（开发版，Bundle ID 加 `.dev`，与正式版并存、数据隔离；不要用 `prod`），不用先问；设备没连接或签名失败时如实告知。

## 数据版本与迁移（必读，v0.1.0 起已有用户数据）
完整规范见 `docs/data-versioning.md`，改动任何会存到本机的东西之前先读。要点：
- 数据分两类：**源数据**（书库 `library.json`、原书 `book.json`/`docs/`/`res/`、UserDefaults 设置、Keychain）丢了找不回，只能由迁移步骤转换；**派生数据**（`content.json` 正文、章节信息、封面缩略图）能从源数据算出来，不做格式转换，由迁移步骤要求重建。
- 整个数据目录只有一个版本：最后迁移到的 app 版本（`data-version.json`）。迁移只在相邻的已发布版本之间进行（`Persistence/Migrations/Migration_<旧>_to_<新>.swift`，每对相邻版本恰好一个，没变化也写空步骤），跨版本升级依次执行，不写捷径步骤。开发中的下一版还没有版本号，写作 `next`（`VNext`、`Migration_<上一版>_to_Next`），到 `prepare` 时才改成实际版本号，不要自己猜版本号。
- 步骤是纯函数，只用 `Persistence/Snapshots/` 里冻结的旧结构，不引用现行模型。版本发布后它的快照和步骤冻结，不再修改、不再删除；开发中的那一步可以随意改。
- 以下改动都要写进开发中版本的迁移步骤：改了源数据的结构（包括新增字段、改 UserDefaults 键名或取值的含义）；改了导入/章节构建的输出（`BookImporter`、`BookBuilder`、`ChapterText`、`MathML`、`PlainTextLayout`、`ChapterLayout.split` 等），这时要在步骤里要求重建正文。测试会拿正文输出和上一个已发布版本的夹具比较，输出变了却没要求重建就会失败。
- UserDefaults 键名只在 `SettingsKeys.swift` 定义；键名一旦发布就不再挪作他用。存下来的枚举要容忍未知值。
- 不允许带数据降级：数据版本比应用新时不读不写，只提示安装新版本。
- 每个已发布版本的真实数据目录是测试夹具（`ReadlingTests/Fixtures/AppData/<版本>.bundle`），每次测试都要能从每个夹具迁移到当前版本；发版后在新 tag 上运行 `python3 Tools/app_release.py post-release` 生成该版本的夹具，并开启下一版。

## 设计原则（教训）
分页正文曾为求改动最小，让整章共享一条 `NSLayoutManager` 容器链、每页借一个容器显示；后来改为选中查词时才发现 UIKit 不允许这种页面被选择，只能层层打补丁。由此：
- 不追求最小实现。有成熟架构就直接采用成熟架构，有可用的开源库就优先评估并使用开源库，而不是自己从头实现。动核心机制（排版分页、文本选择、手势、持久化格式）之前，先查成熟阅读器、框架和开源库的做法（例如原生阅读器用 CoreText/TextKit 按页填充排版、`CTFrameGetVisibleStringRange` 定页；EPUB 阅读器用 WebView + CSS 分栏，如 Readium Swift Toolkit），偏离时要写明理由。不要因为改动最小就在不合适的地基上叠功能。
- 遇到与假设不符的平台限制时，先停下复查架构假设是否还站得住，而不是绕过限制继续堆特例；需要较大重构时先向用户说明取舍再动手。
- 同一件事只留一个事实来源：例如分页结果必须来自实际用于显示的那次排版，不能“一处测量、另一处重排显示”再靠测试保证两者一致。
- 测试通过不等于设计可靠：只覆盖了样例书和少数参数的测试，挡不住结构性隐患。

## 已知坑
- 一个 `NSLayoutManager` 挂多个 `NSTextContainer` 时，只有显示第一个容器的 `UITextView` 能被选择，其余的 `isSelectable` 会被强制为 false（设为 true 也无效）。
- `NSLayoutManagerDelegate.layoutManager(_:shouldUse:forControlCharacterAt:)` 对 tab 返回 `.lineBreak`/`.paragraphBreak`/`.containerBreak`（iOS 26 模拟器实测）都不会换行，只会把 tab 的宽度清零。要在 tab 处换行，就把制表位放在行尾附近（不能超出行宽，否则会多出一个空行）。
- `@State private var x = SomeObject()` 的初始值表达式在视图每次被创建时都会执行（SwiftUI 只保留第一个实例）。有副作用的对象（读写磁盘、启动任务，如 `LibraryStore`）不能这样创建：要在只初始化一次的地方创建，例如 `ReadlingApp.init`。曾因此在 App.body 求值时反复新建书库、并发重建同一本书、互相覆盖 `library.json`，形成死循环。
- `textViewDidChangeSelection`（iOS 26 模拟器实测）：拖选区手柄只在松手时回调一次；长按后不松手继续滑动会逐词回调，松手后约 7ms 还会再微调一次选区。
- 系统控件的 iOS 26 液态玻璃样式没有公开开关时（例如 `UISegmentedControl` 静止时轨道是普通填充，`backgroundColor` 无效，`setBackgroundImage` 会让控件退回旧式绘制、连选中滑块一起丢掉）：
  1. 用 `control.value(forKey: "recursiveDescription")` 把视图层级写到 `/tmp`，看清楚是哪一层在画；
  2. 在模拟器运行时的 UIKitCore 里搜私有开关：`strings "$(find /Library/Developer/CoreSimulator/Volumes -path '*26*UIKitCore.framework/UIKitCore' | head -1)" | grep -i <控件名> | grep -iE 'glass|lens|transparent'`；
  3. 运行时用 `responds(to:)` 确认，再逐个试，用临时 UI 测试截图（`XCUIScreen.mainScreen.screenshot` 写到 `/tmp`）对比，试完撤掉临时代码；
  4. 带 `Bool` 参数的私有方法不能用 KVC（键名带下划线时会抛异常崩溃）或 `perform(_:with:)`，要取 `method(for:)` 转成 `@convention(c)` 函数调用。调用前先用 `responds(to:)` 检查，方法没了就保持默认样式。
  
  分段控件用的是 `_setUseGlass:`（见 `ReaderPanels.swift` 的 `SegmentedControl.useGlass`）。私有 API 上架 App Store 前需要重新评估。
