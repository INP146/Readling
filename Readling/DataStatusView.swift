import SwiftUI

/// 设置 › 关于 › 数据与升级: which version the data is at, how the last upgrade went, and the progress of
/// rebuilding reading text (see docs/data-versioning.md 5).
struct DataStatusView: View {
    let store: LibraryStore
    /// Bumped to read the migration files again after acting on them.
    @State private var refresh = 0
    @State private var confirmRemoveBackups = false
    @State private var confirmRemigrate = false

    private var migrator: Migrator { _ = refresh; return store.migrator }

    var body: some View {
        let history = migrator.history()
        SettingsList {
            Section("版本") {
                LabeledContent("应用版本", value: Self.appVersion)
                LabeledContent("数据版本", value: store.dataVersionLabel)
            }
            Section {
                if let last = history.last {
                    MigrationRecordRow(record: last)
                    if history.count > 1 {
                        NavigationLink("升级历史") { MigrationHistoryView(history: history) }
                    }
                } else {
                    Text("这台设备上的数据还没有升级过。").foregroundStyle(.secondary)
                }
            } header: { Text("上次升级") } footer: {
                if case .failed(_, let reason) = store.migrationOutcome {
                    Text("本次启动升级失败：\(reason)").foregroundStyle(.orange)
                }
            }
            rebuildSection
            Section {
                let size = migrator.backupSize()
                LabeledContent("升级前的备份") {
                    Text(size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "无")
                }
                if size > 0 {
                    Button("删除备份", role: .destructive) { confirmRemoveBackups = true }
                }
            } header: { Text("备份") } footer: {
                Text("升级会先把要改动的文件另存一份，保留到下一次升级成功为止。")
            }
            if Self.isDevelopmentBuild {
                Section {
                    Button("从备份重新迁移") { confirmRemigrate = true }
                        .disabled(migrator.latestBackups() == nil)
                } header: { Text("开发版") } footer: {
                    Text("把数据恢复到上次升级之前，再按当前代码重新升级一遍，用于调试还没发布的迁移步骤。设置不会恢复。")
                }
            }
        }
        .navigationTitle("数据与升级")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除升级前的备份？", isPresented: $confirmRemoveBackups, titleVisibility: .visible) {
            Button("删除备份", role: .destructive) {
                store.removeMigrationBackups()
                refresh += 1
            }
        } message: { Text("删除后就不能再回到升级之前的数据。") }
        .confirmationDialog("从备份重新迁移？", isPresented: $confirmRemigrate, titleVisibility: .visible) {
            Button("恢复并重新迁移", role: .destructive) {
                store.remigrateFromBackups()
                refresh += 1
            }
        }
    }

    @ViewBuilder private var rebuildSection: some View {
        let status = store.rebuild
        Section {
            if status.isFinished && status.failures.isEmpty {
                Label("全部书籍已是最新", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                if !status.isFinished || status.total > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(status.done), total: Double(max(status.total, 1)))
                        Group {
                            if let current = status.current {
                                Text("正在更新 \(status.done + 1)/\(status.total)：\(title(of: current))")
                            } else if status.pending.allSatisfy({ status.failures[$0] != nil }) {
                                Text("已更新 \(status.done)/\(status.total)")
                            } else {
                                Text("等待更新 \(status.pending.count) 本")
                            }
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(status.failures.keys.sorted { title(of: $0) < title(of: $1) }, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(of: id))
                        Text(status.failures[id] ?? "").font(.footnote).foregroundStyle(.orange)
                    }
                }
                if !status.failures.isEmpty {
                    Button("重试") { store.retryFailedRebuilds() }
                }
            }
            let stale = store.books.filter { !$0.isSample && !$0.canRebuild }
            if !stale.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("不能自动更新：\(stale.map(\.title).joined(separator: "、"))")
                    Text("导入时没有保存原书。删除后重新导入即可。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: { Text("正文更新") } footer: {
            Text("新版本改进了排版（例如公式、表格）时，已导入的书会在后台按新版本重新生成正文，阅读位置和生词会跟着换算。打开还没更新的书时会先更新这一本。")
        }
    }

    private func title(of id: UUID) -> String {
        store.books.first { $0.id == id }?.title ?? "已移除的书"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// Development builds (Xcode, or `iosign dev`, whose bundle id ends in .dev) can rerun the last migration.
    static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        #endif
    }
}

/// The trailing text of the 数据与升级 row: the data version, or what is going on with it.
struct DataStatusSummary: View {
    let store: LibraryStore

    var body: some View {
        let status = store.rebuild
        if !status.isFinished {
            Text("正在更新 \(status.done)/\(status.total)")
        } else if !status.failures.isEmpty {
            Text("\(status.failures.count) 本更新失败").foregroundStyle(.orange)
        } else {
            Text(store.dataVersionLabel)
        }
    }
}

private struct MigrationRecordRow: View {
    let record: MigrationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: "\(record.from) → \(record.to)").monospacedDigit()
                Spacer()
                if record.failure == nil {
                    Label("成功", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
                } else {
                    Label("失败", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon).foregroundStyle(.orange)
                }
            }
            Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
            if let failure = record.failure {
                Text(failure).font(.footnote).foregroundStyle(.orange)
            } else if record.rebuilds.contains(.content) {
                Text("已安排重新生成所有书的正文").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MigrationHistoryView: View {
    let history: [MigrationRecord]

    var body: some View {
        SettingsList {
            Section {
                ForEach(Array(history.enumerated().reversed()), id: \.offset) { _, record in
                    MigrationRecordRow(record: record)
                }
            }
        }
        .navigationTitle("升级历史")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shown instead of the app when the data belongs to a newer version: like iOS, no going back a version with data.
struct NewerDataView: View {
    let store: LibraryStore
    let version: String
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.up.circle").font(.system(size: 56)).foregroundStyle(Color.accent)
            Text("请安装新版本").font(.title2.weight(.semibold))
            Text("这台设备上的数据来自 Readling \(version)，当前安装的是 \(DataStatusView.appVersion)。旧版本不能读取新版本的数据，请安装 \(version) 或更高版本。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("另存数据并重新开始") { confirm = true }
                .buttonStyle(.bordered)
            Text("数据会改名保留在应用内，不会删除；之后从空书架开始。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
        .confirmationDialog("另存这些数据并从空书架开始？", isPresented: $confirm, titleVisibility: .visible) {
            Button("另存并重新开始", role: .destructive) { store.setAsideNewerData() }
        }
    }
}
