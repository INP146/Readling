# AI 层：设计与计划

大模型端点从翻译里拆出来，作为独立的一层，翻译、词典等功能都可以接入。翻译本身见 `docs/translation-design.md`。

## 分层

```
Online/       联网服务共用：地址规范化、请求、SSE、HTTP/网络错误 → OnlineFailure、Keychain、设置表单零件
AI/           大模型端点：AIEndpoint、AIEndpointStore、AIClient（OpenAI 兼容 / Claude / Gemini）
Translation/  翻译：Apple 本机翻译、DeepL、AITranslationEngine（翻译的提示词）
（以后）词典  语境释义等：自己的提示词，自己选用端点
```

- **AI 层不知道有哪些功能**。`AIClient.complete(_ prompt: AIPrompt) -> AsyncThrowingStream<String, Error>` 只接收系统提示和用户消息，逐段给出累计文本；提示词、输出格式、失败时怎么办都由功能层决定。
- **端点由 AI 层统一管理，选用由各功能分别决定**。`AIEndpointStore` 只存端点列表（`UserDefaults` 键 `aiEndpoints`）和 Key（Keychain service `com.inp146.readling.ai`，account 为端点 UUID），不存“默认端点”。翻译的选择存在 `translationEngine`，以后词典有自己的键。这样可以让翻译用便宜快速的模型，词典释义用更好的模型。
- **端点被删除时**，引用它的功能不改自己保存的选择，只在用的时候发现端点不在了，按“未配置”处理（翻译退回 Apple 本机翻译）。这样 AI 层不需要知道谁引用了它。
- **DeepL 不在 AI 层**：它不是大模型，不能回答任意提示词，所以和 Apple 本机翻译一样，算作翻译层的内置服务。HTTP 和 Keychain 的底层与 AI 层共用（`Online/`）。
- **错误**：联网层抛 `OnlineFailure`（未配置 / 没网 / 失败原因），各功能在自己的边界换成自己的错误类型（翻译换成 `TranslationFailure`），界面只认功能自己的类型。

## 为什么不做成 Swift Package

考虑过把 `Online/` 和 `AI/` 做成本地 Swift Package（边界由编译器保证，测试能在 macOS 上用 `swift test` 跑）。暂时只按文件夹分：错误文案要放进包自己的 `Localizable.xcstrings` 并改用 `bundle: .module`，工程配置也要多维护一份，而现在只有一个 app target 用它。等有第二个使用方（如扩展、macOS 版）时再拆。

## 设置

- **设置 › AI 服务**：端点列表，点按编辑，左滑删除，“添加服务…”。编辑页：名称、接口格式、常用预设、服务地址（实时预览请求地址）、API Key、模型（可从服务拉取列表）、测试（用 `AIPrompt.connectionTest` 请模型翻译一句短英文）、删除。
- 各功能的设置页列出全部端点供选择，也可以直接“添加 AI 服务…”，从那里新建的端点保存后直接被该功能选中。
- **提示词归功能，不归端点**：提示词的入口统一放在“设置 › AI 服务 › 提示词”，每个功能一行（现在只有“翻译”），所有端点通用；数据仍归功能自己：翻译的（`TranslationPrompts`，`UserDefaults` 键 `translationPromptTranslate` / `translationPromptExplain`，只存与默认不同的，留空即默认）。用户只能改“要求”部分；书中文字放在标签里、并提醒模型只当数据的那句由 app 固定附加，自定义提示词不会去掉这层防护。缓存键包含提示词，改了就不会拿到旧结果。

## 以后

1. 词典接入：查到时按句子挑出合适的义项（“语境释义”），查不到时生成简短词条。需要时给 `AIPrompt` 加结构化输出（JSON）选项，由各接口格式分别实现（OpenAI `response_format`、Gemini `responseMimeType`，Claude 用提示词约束）。
2. 本机大模型（Foundation Models 等）作为一种不需要地址和 Key 的 `AIClient`。

## 进度

- [x] 第 1 步：拆出 `Online/`、`AI/`、`Translation/`，翻译只选用端点并自带提示词，DeepL 与 Apple 并列；设置拆为“AI 服务”与“翻译”两页。未发布，不迁移旧配置（2026-11-20）
- [ ] 第 2 步：词典接入
