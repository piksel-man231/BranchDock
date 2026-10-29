import SwiftUI
import AppKit

extension CIStatus {
    var color: Color {
        switch self {
        case .success: return Color(red: 0.64, green: 0.88, blue: 0.43)
        case .failed: return .red
        case .running: return .cyan
        case .waiting, .manual: return .orange
        default: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .waiting: return "clock"
        case .manual: return "hand.raised"
        case .canceled: return "stop.circle"
        case .skipped: return "forward.end"
        default: return "questionmark.circle"
        }
    }
}

struct CIBranchBadge: View {
    @EnvironmentObject var ci: CIStore
    let branch: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(branch).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
            if let problem = ci.problems[branch] {
                Label("Ошибка запроса", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(problem)
            } else if let snapshot = ci.snapshots[branch] {
                Label(snapshot.status.title, systemImage: snapshot.status.symbol).foregroundStyle(snapshot.status.color)
                Text("\(snapshot.sha.prefix(8)) · \(snapshot.checkedAt.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary).font(.system(size: 9, design: .monospaced))
            } else {
                Text(ci.refreshing ? "Загрузка…" : "Нет данных").foregroundStyle(.secondary)
            }
        }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CIInspector: View {
    @EnvironmentObject var ci: CIStore
    let tree: Worktree
    @State private var launch: ManualJobLaunch?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ci.connection?.provider == .github ? "GITHUB ACTIONS" : "GITLAB CI")
                .font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
            if let problem = ci.problems[tree.branch] {
                Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            } else if let snapshot = ci.snapshots[tree.branch] {
                Label(snapshot.status.title, systemImage: snapshot.status.symbol).font(.headline).foregroundStyle(snapshot.status.color)
                Text("Remote HEAD · \(snapshot.sha.prefix(8))").font(.caption.monospaced()).foregroundStyle(.secondary)
                if !snapshot.sha.hasPrefix(tree.head) {
                    Text("На remote другая версия ветки. CI относится к коммиту на сервере, а не к локальному HEAD.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Обновлено \(snapshot.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(snapshot.items) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: item.status.symbol).foregroundStyle(item.status.color)
                        VStack(alignment: .leading, spacing: 3) {
                            if let url = item.url { Link(item.title, destination: url) }
                            else { Text(item.title) }
                            Text(item.status.title).foregroundStyle(item.status.color)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if item.canPlay && ci.connection?.provider == .gitlab {
                            Button {
                                launch = ManualJobLaunch(branch: tree.branch, snapshot: snapshot, item: item,
                                                         connection: ci.connection, root: ci.repositoryRoot)
                            } label: {
                                Label(ci.launchingJobID == item.id ? "Запуск…" : (item.isDeployment ? "Деплой" : "Запустить"), systemImage: "play.fill")
                            }.disabled(ci.launchingJobID != nil || ci.refreshing)
                        }
                    }.font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                }
                if let url = snapshot.url { Link("Открыть на сервере ↗", destination: url).font(.caption) }
                if snapshot.items.isEmpty { Text("Для текущего коммита нет запусков CI.").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(ci.refreshing ? "Загрузка CI…" : "Нет данных о CI этой ветки.").font(.caption).foregroundStyle(.secondary)
            }
            if let problem = ci.launchProblems[tree.branch] {
                Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text(ci.connection?.provider == .github ? "Показаны GitHub Actions. Внешние checks и правила защиты ветки проверяйте на GitHub." : "Показан последний пайплайн для HEAD и его jobs. Дочерние пайплайны и приёмку проверяйте в GitLab.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $launch) { selection in
            VStack(alignment: .leading, spacing: 14) {
                Label(selection.item.isDeployment ? "Запуск деплоя" : "Запуск ручной job", systemImage: "play.circle").font(.title2.bold())
                Text(selection.connection?.project ?? "").font(.headline)
                Text("Ветка: \(selection.branch)\nКоммит на сервере: \(selection.snapshot.sha)\nJob: \(selection.item.title)")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("Будет запущена выбранная job существующего пайплайна на сервере. Настройки и окружение берутся из GitLab CI.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Отмена") { launch = nil }.keyboardShortcut(.cancelAction)
                    Button("Подтвердить запуск") {
                        launch = nil
                        Task { await ci.play(branch: selection.branch, snapshot: selection.snapshot, item: selection.item, expectedConnection: selection.connection, expectedRoot: selection.root) }
                    }.buttonStyle(AccentButton()).disabled(ci.launchingJobID != nil)
                }
            }.padding(28).frame(width: 520)
        }
    }
}

private struct ManualJobLaunch: Identifiable {
    let id = UUID()
    let branch: String
    let snapshot: CISnapshot
    let item: CIItem
    let connection: CIConnection?
    let root: String
}

struct CIConnectionView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ci: CIStore
    @Environment(\.dismiss) var dismiss
    @State private var provider = CIProvider.gitlab
    @State private var remote = ""
    @State private var apiBase = "https://gitlab.com/api/v4"
    @State private var project = ""
    @State private var token = ""
    @State private var urls: [String: String] = [:]
    @State private var root = ""
    @State private var loading = false
    @State private var problem = ""

    private var canReuseToken: Bool {
        guard let current = ci.connection else { return false }
        return current.provider == provider && current.remote == remote && current.apiBase == apiBase && current.project == project
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("Подключение CI", systemImage: "network").font(.title2.bold())
            Picker("Remote", selection: $remote) {
                ForEach(store.repo?.remotes ?? [], id: \.self) { Text($0).tag($0) }
            }.onChange(of: remote) { _, _ in suggest() }
            Picker("Сервис", selection: $provider) {
                ForEach(CIProvider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).onChange(of: provider) { _, value in
                if let url = urls[remote], let suggested = CIConnection.suggested(remote: remote, url: url, provider: value) { apiBase = suggested.apiBase }
            }
            TextField("API URL, например https://gitlab.example.com/api/v4", text: $apiBase)
            TextField("Проект: group/repository", text: $project)
            Text("API URL и проект заполнены из remote. Для своего GitLab или GitHub Enterprise их можно поправить.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(canReuseToken ? "Новый access token (пусто — оставить сохранённый)" : "Access token", text: $token)
                .textContentType(.password)
            Text(provider.permissions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Токен хранится в macOS Keychain. Он отправляется только в заголовке HTTPS-запросов к указанному API. Статус CI обновляется раз в минуту. Ручные jobs GitLab запускаются только по кнопке с подтверждением.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Права токена ↗", destination: URL(string: provider == .gitlab ? "https://docs.gitlab.com/security/tokens/access_token_scopes/" : "https://docs.github.com/en/rest/actions/workflow-runs")!)
                Spacer()
                Text("Проверка: \(store.tree?.branch ?? "main")").foregroundStyle(.secondary)
            }.font(.caption)
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if ci.connection != nil {
                    Button("Отключить", role: .destructive) {
                        do { try ci.disconnect(); token = ""; dismiss() }
                        catch { problem = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Отмена") { token = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button(loading ? "Проверка…" : "Проверить и сохранить") { connect() }
                    .buttonStyle(AccentButton()).disabled(remote.isEmpty || project.isEmpty || (token.isEmpty && !canReuseToken))
            }
        }.textFieldStyle(.roundedBorder).padding(30).frame(width: 600).disabled(loading)
            .interactiveDismissDisabled(loading)
            .task {
                guard let repo = store.repo else { return }
                root = repo.root
                if let current = ci.connection {
                    remote = current.remote; provider = current.provider; apiBase = current.apiBase; project = current.project
                } else { remote = repo.remotes.contains("origin") ? "origin" : repo.remotes.first ?? "" }
                for name in repo.remotes {
                    if let value = try? await Task.detached(operation: { try Git.run(repo.root, ["remote", "get-url", name]) }).value { urls[name] = value }
                }
                if ci.connection == nil { suggest() }
            }
    }

    private func suggest() {
        guard let url = urls[remote], let value = CIConnection.suggested(remote: remote, url: url) else { return }
        provider = value.provider; apiBase = value.apiBase; project = value.project
    }

    private func connect() {
        loading = true; problem = ""
        let draft = CIConnection(provider: provider, remote: remote, apiBase: apiBase, project: project)
        let supplied = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingID = canReuseToken ? ci.connection?.id : nil
        let branch = store.tree?.branch == "Detached HEAD" ? "main" : store.tree?.branch ?? "main"
        Task {
            defer { loading = false }
            do {
                let config = try draft.validated()
                let secret: String
                if !supplied.isEmpty { secret = supplied }
                else if let existingID { secret = try TokenVault.read(existingID) }
                else { throw CIError.message("Введите access token для этого подключения.") }
                let client = CIClient(connection: config, token: secret)
                defer { client.session.finishTasksAndInvalidate() }
                // Missing remote feature branches are normal before the first push. Validate access via main instead.
                do { _ = try await client.snapshot(branch: branch) }
                catch CIError.http(404) where branch != "main" { _ = try await client.snapshot(branch: "main") }
                try ci.save(config, token: secret, root: root)
                token = ""; dismiss()
            } catch { problem = error.localizedDescription }
        }
    }
}
