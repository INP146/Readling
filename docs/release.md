# 发布

本仓库包含两条独立的发布流水线：**App**（`v*.*.*`）与**词典包**（`dict-*`）。只改 app 时不需要发词典包，只更新词典包时已安装的 app 也可直接在线更新。

## 通用约定

- 本地脚本（只用标准库，兼容 macOS 自带的 Python 3.9+）负责准备与校验，推送 tag 后由 GitHub Actions 构建并创建 Release。脚本从不提交、打 tag 或推送，这几步都由人执行。
- 每个发布 tag 的发布说明放在 `docs/releases/<tag>.md`，同时用作该 tag 的 GitHub Release 正文。发布失败的 tag 的说明也保留，作为记录。
- 已推送的 tag 不移动、不删除。校验或构建失败、或者发布后发现问题，修好后用下一个版本号重新发布。

**AI 起草发布说明**（`Tools/release_ai.py`，App 与词典包共用）：在仓库根目录的 `.env`（不提交，模板见 `.env.example`）里配置一次：

```dotenv
RELEASE_AI_PROVIDER=claude      # codex / claude / none；没有 .env 时为 none，只生成模板
RELEASE_AI_MODEL=               # 留空沿用 CLI 自己的配置，不需要 API key
RELEASE_AI_TIMEOUT_SECONDS=600
```

- Shell 里已设置的同名变量优先于 `.env`；脚本只读这三个键，不执行 `.env`。CI 的 `check` 不读 `.env`，也不调用 AI。
- `prepare` 先把模板写入 `docs/releases/<tag>.md`，再在仓库根目录非交互地运行本机已登录的 CLI：codex 用 `exec --sandbox workspace-write`；claude 用 `-p`（只读文件/搜索、编辑/写入、`git`，词典发布额外允许 `sqlite3`）。
- Agent 自行阅读 `AGENTS.md`、本文档、设计文档和历史发布说明，查看比较基准到当前工作区（含未提交改动）的提交与差异，填写目标发布说明。除 App 首个版本（无旧 `v*` tag，按全仓当前状态起草）外，比较基准 tag 必须存在且在 `HEAD` 历史里，否则在写入任何版本文件前就拒绝。
- 脚本读回实际写入的文件，检查标题和必需章节；草稿始终带顶部的 `RELEASE_TODO` 审阅标记（agent 删掉了也会补回），必须人工审阅并删除全部 `RELEASE_TODO` 后才能通过 `check --require-notes`。
- 生成失败、超时或草稿格式不对时，删除本次新建的草稿，版本文件保持原样；已有的发布说明从不覆盖。claude 失败时报出它返回的原因（例如网络错误），不输出 stderr。

## App

**版本与唯一事实来源**：采用 SemVer（如 `0.1.0`、预发布 `0.1.0-rc1`），tag 为 `v<版本>`（如 `v0.1.0`、`v0.1.0-rc1`）。版本号只保存在 `Readling.xcodeproj/project.pbxproj` 中 `Readling` target 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`（Debug 与 Release 始终保持一致）：

- 首次发布前工程保持未发布基线 `0.0.0`（Build `1`）。
- 首次 `prepare` 将版本设为首个发布号（Build 保持 `1`）；之后每次 `prepare` 要求新版本严格递增（`0.1.0-rc1 < 0.1.0-rc2 < 0.1.0 < 0.1.1`），并将 `CURRENT_PROJECT_VERSION` 自动 `+1`。
- 含连字符的预发布版本（如 `"0.1.0-rc1"`）在 `project.pbxproj` 中自动加双引号，保证 Xcode 工程语法合法。

**Tools/app_release.py**：

| 命令 | 作用 |
|---|---|
| `prepare <版本> [--dry-run] [--base-tag <tag>]` | 校验当前工程与内置词典一致且新版本更高；起草 `docs/releases/v<版本>.md`（成功后再更新 `project.pbxproj`）。比较基准默认是上一个 app 版本的 tag（如 `v0.1.0-rc1`），首版默认按全仓起草。`--dry-run` 只检查配置与基准 tag、列出将修改的文件，不调用模型也不写文件。 |
| `check [tag] [--require-notes]` | 核对 `project.pbxproj`（Debug/Release 一致、Bundle ID、语法）以及内置词典（调用 `dictionary_release.check`）；传入 `tag` 时要求与工程版本一致且不为 `0.0.0`；`--require-notes` 要求发布说明已完成（标题一致、填写了“主要变更 / 安装与重签 / 升级与兼容”、不含 `RELEASE_TODO`）。 |
| `build [--allow-unreleased]` | 在 macOS 上用 `xcodebuild` 编译无签名的 Release 真机包 `Readling.app`，核对产物 `Info.plist` 的版本号、Build 号、Bundle ID 以及包内 `dictionary-core.sqlite` 版本，打包为逐字节可复现的 `build/app/Readling-<版本>.ipa`（保留可执行权限与符号链接）和 `SHA256SUMS`。`--allow-unreleased` 供日常 CI 在 `0.0.0` 基线阶段验证编译与打包链路。 |

**Actions**：

- `validate-app.yml`：在 PR 和推送 `main` 时运行，也由发布流程调用。先在 `ubuntu-latest` 上运行 `app_release.py check`（含词典元数据检查）和 `Tools/tests` 全部脚本单元测试，再在 `macos-26` 上运行 `ReadlingTests` 单元测试并编译校验无签名 Release IPA。tag 发布时额外要求 tag 与 `project.pbxproj` 一致且发布说明已完成。
- `publish-app.yml`：推送 `v*.*.*` tag 时运行。先完整通过 `validate-app.yml`，再在 `macos-26` 上构建 `Readling-<版本>.ipa` 与 `SHA256SUMS`，核对哈希后以 `docs/releases/v<版本>.md` 创建 GitHub Release。正式版设为仓库的 Latest Release（`--latest`）；`-rc*` 标记为预发布（`--prerelease --latest=false`）。已存在的 Release 不覆盖。

**日常发版**：

```sh
python3 Tools/app_release.py prepare 0.1.0 --dry-run
python3 Tools/app_release.py prepare 0.1.0
# 审阅（或在 none 模式下填写）docs/releases/v0.1.0.md，删除全部 RELEASE_TODO
python3 Tools/app_release.py check --require-notes
# 按改动范围跑完本地测试（建议发版前跑一次完整 xcodebuild test）
git diff && git status --short
git add -A && git commit -m "Release v0.1.0"
git push origin main
git tag -a v0.1.0 -m "Readling v0.1.0"
git push origin v0.1.0
```

首次引入发布流程时，先把脚本、测试和 workflows 提交到 `main`（此时版本仍为 `0.0.0`，不会触发发布）；确认就绪后再按上面步骤准备首个版本。

**安装与升级**：Release 中的 `Readling-<版本>.ipa` 为未签名真机包，本机可运行 `iosign prod Readling-<版本>.ipa` 重签并安装到 iPhone，也可导入 AltStore、SideStore、Feather、Sideloadly 等工具自签安装。升级时保持同一张签名证书和原 Bundle ID（`com.inp146.readling`）直接覆盖安装，即可保留全部书籍、阅读位置、生词、已下载词典包及钥匙串中的 API Key。

**失败与重跑**：在 GitHub Actions 的 `Publish app` 页面查看失败步骤；若因偶发环境问题失败可直接 Re-run failed jobs（已创建的 Release 不会被覆盖）。若代码、版本号或发布说明有误，修复后用下一个版本号（如 `0.1.0-rc2` 或 `0.1.1`）重新 `prepare` 发布。

## 词典包

数据与分包的设计见 `docs/dictionary-design.md`。

**版本**：`2026.11.18`，同一天再发布一次用 `2026.11.18.1`。tag 为 `dict-<版本>`。每个包的 `meta.version` 和清单都记录版本；app 按数字逐段比较，清单里的版本更新时提示更新，核心词典和已下载的包一起更新。

**核心词典**：`prepare` 把它放进 app（`Readling/Resources/dictionary-core.sqlite`），作为新安装的初始版本；Release 和清单里也有它，所以已安装的 app 不必等下一次发布 app，adopt 之后就能更新核心词典。

**数据源固定**：`Dictionaries/release.json` 记录当前版本，以及 ECDICT 的提交号、`ecdict.csv` 的下载地址和 sha256。构建只用这份固定的数据，下载后先核对 sha256，所以任何时候都能重建出同一批包。

**Tools/dictionary_release.py**：

| 命令 | 作用 |
|---|---|
| `prepare <版本> [--source-commit <ECDICT 提交>] [--base-tag <tag>]` | 版本必须比当前新。构建全部包，起草发布说明 `docs/releases/dict-<版本>.md`，最后才更新 app 内置的核心词典和 `release.json`，所以起草失败时什么都没变。`--dry-run` 只列出将修改的文件、检查 AI 配置和比较基准，不构建也不调用模型。 |
| `check [tag] [--require-notes]` | 核对 `release.json`、内置核心词典的 meta、`manifest.json`；`--require-notes` 还要求发布说明已完成（标题与 tag 一致、填写了“主要变更”、不含 `RELEASE_TODO`）。 |
| `build [--verify-core]` | 按 `release.json` 构建全部包（含核心词典）到 `build/dict`，打成 zip，生成 `manifest.json` 和 `SHA256SUMS`。zip 的时间戳和权限固定，同一环境构建两次逐字节一致。`--verify-core` 用表内容哈希比对构建出的核心词典和 app 内置的，不受 SQLite 版本影响。 |
| `adopt <版本>` | 下载已发布 Release 的 `manifest.json` 和 `SHA256SUMS`，核对哈希，确认每个包都能下载，再写入 `Dictionaries/manifest.json`。 |

**Actions**：

- `validate-dictionaries.yml`：在 PR 和推送 main 时运行，也由发布流程调用。运行 `check` 和 `Tools/tests` 里的脚本测试；发布时还要求 tag 与 `release.json` 一致，并要求发布说明已完成。
- `publish-dictionaries.yml`：推送 `dict-*` tag 时运行。先校验，再 `build --verify-core`，然后用发布说明创建 Release，附上各包 zip、`manifest.json` 和 `SHA256SUMS`。Release 带 `--latest=false`，不占用仓库的 Latest Release。已存在的 Release 不覆盖。

**日常发版**：

```sh
python3 Tools/dictionary_release.py prepare 2026.12.01 --dry-run
python3 Tools/dictionary_release.py prepare 2026.12.01        # 换数据源时加 --source-commit <40 位提交号>
# 审阅（或在 none 模式下填写）docs/releases/dict-2026.12.01.md，删除全部 RELEASE_TODO
python3 Tools/dictionary_release.py check --require-notes
# 跑 app 的单元测试和选词 UI 测试（核心词典变了）
git add -A && git commit
git push origin main
git tag -a dict-2026.12.01 -m "词典包 dict-2026.12.01"
git push origin dict-2026.12.01
# Actions 成功后：
python3 Tools/dictionary_release.py adopt 2026.12.01
git add Dictionaries/manifest.json && git commit && git push origin main
```

清单最后由人来提交：Release 的资源都确认能下载之后，app 才会看到新包。只改 app 而不改词典时，不需要走这个流程。

**失败与重跑**：校验或构建失败时不会创建 Release，修好后用下一个版本号重新发布。Release 创建后发现问题，同样发下一个版本，再 `adopt`。
