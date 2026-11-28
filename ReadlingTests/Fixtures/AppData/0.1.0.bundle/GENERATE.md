# v0.1.0 数据夹具

用 v0.1.0 自己的代码生成的真实数据目录（见 `docs/data-versioning.md` 3.7），冻结，不要手改。

- `Readling/`：应用数据目录（`library.json` 与 `books/`）。三本书：`alice.epub`、`formulas.epub`、`verse.txt`；有阅读进度、生词（含复习、已掌握、机器翻译释义）。
- `settings.plist`：当时会设置的 UserDefaults。

重新生成（一般不需要）：

```sh
git worktree add /tmp/readling-v010 v0.1.0
cp ReadlingTests/Fixtures/{formulas.epub,verse.txt} /tmp/readling-v010/ReadlingTests/Fixtures/
cp ReadlingTests/Fixtures/AppData/0.1.0.bundle/GenerateDataFixture.swift.txt /tmp/readling-v010/ReadlingTests/GenerateDataFixture.swift
cd /tmp/readling-v010 && xcodebuild -project Readling.xcodeproj -scheme Readling \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:'ReadlingTests/generateDataFixture()'
# 输出在 /tmp/readling-fixture-0.1.0
```
