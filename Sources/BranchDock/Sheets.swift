import SwiftUI
import AppKit

struct RemovalView: View {
    let root: String
    let target: RemovalTarget
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var preview: RemovalPreview?
    @State private var problem = ""
    @State private var discardLocalFiles = false
    @State private var alsoDeleteBranch = false
    @State private var forceBranch = false

    var isWorktree: Bool { if case .worktree = target { return true }; return false }
    var deletingBranch: Bool { !isWorktree || alsoDeleteBranch }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(isWorktree ? "Удалить worktree" : "Удалить локальную ветку", systemImage: "trash").font(.title2.bold())
            switch target {
            case .worktree(let tree):
                Text(tree.branch).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                Text(tree.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Worktree и вся его папка будут удалены с диска, включая локальные файлы. Файлы не попадут в Корзину.")
                    .foregroundStyle(.orange).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            case .branch(let branch):
                Text(branch.name).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                Text("Будет удалена локальная ссылка на ветку. Другие рабочие папки и файлы останутся на месте.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let preview {
                if isWorktree {
                    Toggle("Разрешаю безвозвратно удалить локальные изменения, неотслеживаемые и игнорируемые файлы, подмодули", isOn: $discardLocalFiles)
                        .foregroundStyle(preview.hasLocalFiles ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
                    if preview.hasLocalFiles {
                        Text("Найдены локальные изменения или файлы. Для удаления требуется разрешение выше.").font(.caption).foregroundStyle(.orange)
                    }
                    if let branch = preview.branch {
                        Toggle("Также удалить локальную ветку \(branch.name)", isOn: $alsoDeleteBranch)
                            .onChange(of: alsoDeleteBranch) { _, enabled in if !enabled { forceBranch = false } }
                    }
                }
                if deletingBranch, preview.branch != nil {
                    Toggle("Удалить ветку, даже если Git считает её неслитой", isOn: $forceBranch)
                    if forceBranch {
                        Text("Коммиты, на которые ссылается только эта ветка, могут быть потеряны.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(isWorktree ? "Git сохранит неслитую ветку. Папка worktree при этом всё равно будет удалена." : "Git сохранит неслитую ветку.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Без принудительного удаления feature сохраняется до слияния в main. Ветки main и test защищены от удаления. Ветки на remote не удаляются.").font(.caption).foregroundStyle(.secondary)
            } else if problem.isEmpty {
                ProgressView("Проверка текущего состояния Git…").controlSize(.small)
            }
            if !problem.isEmpty { Text(problem).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorktree ? "Удалить worktree и файлы" : "Удалить ветку", role: .destructive) {
                    let discard = discardLocalFiles, deleteBranch = alsoDeleteBranch, force = forceBranch
                    dismiss()
                    switch target {
                    case .worktree(let tree):
                        store.perform("Удаление worktree \(tree.path)") {
                            try Git.removeWorktree(root, tree: tree, discardLocalFiles: discard, deleteBranch: deleteBranch, forceBranch: force)
                        }
                    case .branch(let branch):
                        store.perform("Удаление ветки \(branch.name)") { try Git.deleteBranch(root, branch: branch, force: force) }
                    }
                }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(preview == nil || (preview?.hasLocalFiles == true && !discardLocalFiles))
            }
        }.padding(30).frame(width: 590)
            .task {
                do { preview = try await Task.detached { try Git.removalPreview(root, target: target) }.value }
                catch { problem = error.localizedDescription }
            }
    }
}

struct CreateView: View {
    var initialBranch: String? = nil
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var existing = false
    @State private var branch = ""
    @State private var base = ""
    @State private var path = ""
    var available: [Branch] { store.repo?.branches.filter { b in !(store.repo?.worktrees.contains { $0.branch == b.name } ?? false) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Новый worktree", systemImage: "square.stack.3d.up").font(.title2.bold())
            Text("Создайте feature от main и сохраните её до приёмки. Для релиза используется эта же feature, а не test.").foregroundStyle(.secondary)
            Picker("Ветка", selection: $existing) {
                Text("Новая ветка").tag(false)
                Text("Существующая").tag(true)
            }.pickerStyle(.segmented).onChange(of: existing) { _, value in
                if value { if !available.contains(where: { $0.name == branch }) { branch = available.first?.name ?? "" } }
                else { branch = "" }
            }
            if existing {
                Picker("Свободная ветка", selection: $branch) {
                    ForEach(available) { Text($0.name).tag($0.name) }
                }
                if available.isEmpty { Text("Все ветки уже заняты в worktree.").foregroundStyle(.orange) }
            } else {
                TextField("Имя новой ветки, например feature/search", text: $branch)
                Picker("Создать от", selection: $base) {
                    ForEach(store.repo?.branches ?? []) { Text($0.name).tag($0.name) }
                }
            }
            HStack {
                TextField("Папка нового worktree", text: $path)
                Button("Выбрать…") {
                    let panel = NSSavePanel()
                    panel.title = "Папка нового worktree"
                    panel.nameFieldStringValue = branch.replacingOccurrences(of: "/", with: "-")
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK { path = panel.url?.path ?? "" }
                }
            }
            Text("Выберите новую или пустую папку. Git проверит, что ветка не занята в другом worktree.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Создать worktree") {
                    guard let root = store.repo?.root else { return }
                    let name = branch, source = base, location = NSString(string: path).expandingTildeInPath, useExisting = existing
                    dismiss()
                    store.perform("Создание worktree") { try Git.create(root, branch: name, base: source, path: location, existing: useExisting) }
                }.buttonStyle(AccentButton()).disabled(branch.isEmpty || path.isEmpty || (!existing && base.isEmpty))
            }
        }.textFieldStyle(.roundedBorder).padding(30).frame(width: 560)
            .onAppear {
                base = store.repo?.branches.first(where: { $0.name == "main" })?.name ?? store.repo?.branches.first?.name ?? ""
                if let initialBranch { existing = true; branch = initialBranch }
            }
    }
}

struct SwitchView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var branch = ""
    var available: [Branch] { store.repo?.branches.filter { b in !(store.repo?.worktrees.contains { $0.branch == b.name } ?? false) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Сменить ветку в worktree", systemImage: "arrow.left.arrow.right").font(.title2.bold())
            Text(store.tree?.path ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
            if available.isEmpty {
                Text("Нет свободных веток. Все существующие ветки уже заняты в worktree. Можно создать новую через «Новый worktree».").foregroundStyle(.secondary)
            } else {
                Picker("Новая ветка", selection: $branch) { ForEach(available) { Text($0.name).tag($0.name) } }
                Text("\(store.tree?.branch ?? "") → \(branch)\nПапка worktree останется той же.").lineSpacing(5)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сменить ветку") {
                    guard let tree = store.tree else { return }
                    let name = branch
                    dismiss()
                    store.perform("Switch → \(name)") { try Git.switchBranch(tree, branch: name) }
                }.buttonStyle(AccentButton()).disabled(branch.isEmpty)
            }
        }.padding(30).frame(width: 540).onAppear { branch = available.first?.name ?? "" }
    }
}

struct MergeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var source = ""
    @State private var preview = ""
    @State private var loading = false
    @State private var problem = ""
    var candidates: [Branch] { store.tree?.branch == "main" ? [] : store.repo?.branches.filter { $0.name != store.tree?.branch } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Влить ветку в worktree", systemImage: "arrow.triangle.merge").font(.title2.bold())
            Text("Цель: \(store.tree?.branch ?? "")").font(.headline)
            Text(store.tree?.path ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("В test вливайте feature для проверки; затем опубликуйте test. Автодеплой начнётся только после успешных тестов и сборок на сервере. В main изменения идут через MR.").font(.caption).foregroundStyle(.secondary)
            Picker("Исходная ветка", selection: $source) {
                ForEach(candidates) { Text($0.name).tag($0.name) }
            }.onChange(of: source) { _, _ in preview = ""; problem = "" }
            if !preview.isEmpty { Text(preview).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled) }
            if !problem.isEmpty { Text(problem).foregroundStyle(.orange).font(.caption) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                if preview.isEmpty {
                    Button(loading ? "Проверка…" : "Проверить merge") {
                        guard let tree = store.tree else { return }
                        let name = source
                        loading = true
                        Task {
                            do { preview = try await Task.detached { try Git.mergePreview(tree, source: name) }.value }
                            catch { problem = error.localizedDescription }
                            loading = false
                        }
                    }.buttonStyle(AccentButton()).disabled(source.isEmpty || loading)
                } else {
                    Button("Выполнить merge") {
                        guard let tree = store.tree else { return }
                        let name = source
                        dismiss()
                        store.perform("Merge \(name) → \(tree.branch)") { try Git.merge(tree, source: name) }
                    }.buttonStyle(AccentButton())
                }
            }
        }.padding(30).frame(width: 570).onAppear { source = candidates.first?.name ?? "" }
    }
}

struct PushView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var remote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Опубликовать ветку", systemImage: "arrow.up.circle").font(.title2.bold())
            Text(store.tree?.branch ?? "").font(.system(.headline, design: .monospaced))
            Picker("Remote", selection: $remote) { ForEach(store.repo?.remotes ?? [], id: \.self) { Text($0).tag($0) } }
            Text("Ветка будет отправлена в \(remote)/\(store.tree?.branch ?? "") с настройкой upstream. Используются локальные Git credentials и SSH agent.").foregroundStyle(.secondary).lineSpacing(4)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Push ветки") {
                    guard let tree = store.tree else { return }
                    let name = remote
                    dismiss()
                    store.perform("Push \(tree.branch) → \(name)") { try Git.push(tree, remote: name) }
                }.buttonStyle(AccentButton()).disabled(remote.isEmpty)
            }
        }.padding(30).frame(width: 510).onAppear {
            let upstream = store.repo?.branches.first { $0.name == store.tree?.branch }?.upstream ?? ""
            remote = store.repo?.remotes.first { upstream.hasPrefix($0 + "/") } ?? store.repo?.remotes.first ?? ""
        }
    }
}

struct MergeRequestView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var remote = ""
    @State private var target = "test"
    @State private var project: URL?
    @State private var problem = ""
    @State private var accepted = false
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Feature → Merge Request", systemImage: "arrow.triangle.pull").font(.title2.bold())
            Text(store.tree?.branch ?? "").font(.headline.monospaced())
            Picker("Remote GitLab", selection: $remote) {
                ForEach(store.repo?.remotes ?? [], id: \.self) { Text($0).tag($0) }
            }
            Picker("Целевая ветка", selection: $target) {
                Text("test · тестовый контур").tag("test")
                Text("main · после приёмки").tag("main")
            }.pickerStyle(.segmented)
            Text(target == "test" ? "Опубликуйте feature кнопкой Push. После MR в test дождитесь всех тестов, сборок и автодеплоя, затем проведите приёмку. Сохраните исходную feature." : "Откройте MR из этой же feature в main. Проверьте зелёный CI на сервере. После слияния прод запускается вручную в CI.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if target == "main" {
                Toggle("Приёмка этой версии feature завершена", isOn: $accepted)
                Text("Это ваше подтверждение; приложение не проверяет приёмку и CI.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Откроется форма GitLab без автоматического создания или слияния MR. Снимите удаление исходной ветки в MR в test.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Открыть форму MR ↗") {
                    guard let project, let tree = store.tree else { return }
                    do {
                        let url = try Pipeline.mergeRequestURL(project: project, source: tree.branch, target: target)
                        if NSWorkspace.shared.open(url) { dismiss() }
                        else { problem = "Не удалось открыть браузер." }
                    } catch { problem = error.localizedDescription }
                }.buttonStyle(AccentButton()).disabled(loading || project == nil || (target == "main" && !accepted))
            }
        }.padding(30).frame(width: 570)
            .onAppear {
                let upstream = store.repo?.branches.first { $0.name == store.tree?.branch }?.upstream ?? ""
                remote = store.repo?.remotes.first { upstream.hasPrefix($0 + "/") } ?? store.repo?.remotes.first ?? ""
            }
            .task(id: remote) {
                project = nil; problem = ""; loading = true
                defer { loading = false }
                guard let root = store.repo?.root, !remote.isEmpty else { return }
                let name = remote
                do {
                    let value = try await Task.detached { try Git.run(root, ["remote", "get-url", "--push", name]) }.value
                    guard !Task.isCancelled else { return }
                    project = Pipeline.projectURL(value)
                    if project == nil { problem = "Нужен HTTP(S) или SSH remote проекта GitLab. Для этого remote откройте MR вручную." }
                } catch { if !Task.isCancelled { problem = error.localizedDescription } }
            }
    }
}

struct ResetTestView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var remote = ""
    @State private var preview: TestResetPreview?
    @State private var problem = ""
    @State private var loading = false
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Пересоздать test от main", systemImage: "arrow.counterclockwise").font(.title2.bold())
            Picker("Remote", selection: $remote) {
                ForEach(store.repo?.remotes ?? [], id: \.self) { Text($0).tag($0) }
            }.onChange(of: remote) { _, _ in preview = nil; confirmed = false; problem = "" }
                .disabled(loading)
            Text("Текущий test на remote будет сохранён в отдельной архивной ветке, затем test заменится проверенным снимком main. Чужой push после проверки остановит операцию. Локальные ветки и файлы останутся на месте.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let preview {
                Text("\(preview.remote)/test: \(preview.test.prefix(8)) → main: \(preview.main.prefix(8))\nАрхив: \(preview.archive)")
                    .font(.caption.monospaced()).textSelection(.enabled).lineSpacing(5)
                Toggle("Подтверждаю пересоздание test на этом remote", isOn: $confirmed)
                Text("Push может запустить тестовый CI и автодеплой. При отсутствии поддержки atomic push сервер отклонит всю операцию.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(loading)
                if let preview {
                    Button("Архивировать и пересоздать") {
                        guard let root = store.repo?.root else { return }
                        dismiss()
                        store.perform("Пересоздание \(preview.remote)/test") { try Git.resetTest(root, preview: preview) }
                    }.buttonStyle(AccentButton()).disabled(!confirmed)
                } else {
                    Button(loading ? "Проверка…" : "Проверить remote") {
                        guard let root = store.repo?.root else { return }
                        let name = remote
                        loading = true; problem = ""
                        Task {
                            defer { loading = false }
                            do { preview = try await Task.detached { try Git.testResetPreview(root, remote: name) }.value }
                            catch { problem = error.localizedDescription }
                        }
                    }.buttonStyle(AccentButton()).disabled(remote.isEmpty || loading)
                }
            }
        }.padding(30).frame(width: 610)
            .onAppear { remote = store.repo?.remotes.first ?? "" }
    }
}
