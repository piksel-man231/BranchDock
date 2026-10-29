import SwiftUI
import AppKit

@MainActor
final class Store: ObservableObject {
    @Published var repo: Repository?
    @Published var selected: String?
    @Published var busy = false
    @Published var error: String?
    @Published var notice = ""
    @Published var log = ""
    var tree: Worktree? { repo?.worktrees.first { $0.path == selected } }

    func open() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Открыть репозиторий"
        if panel.runModal() == .OK, let url = panel.url { load(url.path) }
    }

    func load(_ path: String) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let result = try await Task.detached { try Git.load(path) }.value
                repo = result
                if !result.worktrees.contains(where: { $0.path == selected }) { selected = result.worktrees.first?.path }
                UserDefaults.standard.set(result.root, forKey: "lastRepository")
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func perform(_ title: String, operation: @escaping () throws -> String) {
        guard !busy, let root = repo?.root else { return }
        busy = true
        Task {
            do {
                let output = try await Task.detached { try operation() }.value
                log = "$ \(title)\n\(output)"
                notice = title + " — готово"
            } catch {
                log = "$ \(title)\n\(error.localizedDescription)"
                self.error = error.localizedDescription
            }
            // Reload even on failure: a merge conflict changes repository state.
            if let refreshed = try? await Task.detached(operation: { try Git.load(root) }).value {
                repo = refreshed
                if !refreshed.worktrees.contains(where: { $0.path == selected }) { selected = refreshed.worktrees.first?.path }
            }
            busy = false
        }
    }
}

@main
struct BranchDockApp: App {
    @StateObject private var store = Store()
    @StateObject private var ci = CIStore()
    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(store).environmentObject(ci)
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    if store.repo == nil, let path = UserDefaults.standard.string(forKey: "lastRepository") { store.load(path) }
                }
        }
        .defaultSize(width: 1320, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть репозиторий…", action: store.open).keyboardShortcut("o")
                Button("Обновить") { if let root = store.repo?.root { store.load(root) } }.keyboardShortcut("r")
            }
        }
    }
}

private let canvas = Color(red: 0.055, green: 0.067, blue: 0.075)
private let panelColor = Color(red: 0.085, green: 0.10, blue: 0.11)
private let accent = Color(red: 0.64, green: 0.88, blue: 0.43)
private let muted = Color(red: 0.52, green: 0.57, blue: 0.59)

struct MainView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ci: CIStore
    @State private var search = ""
    @State private var section = "Worktrees"
    @State private var createSheet = false
    @State private var createBranch: String?
    @State private var mergeSheet = false
    @State private var pushSheet = false
    @State private var mrSheet = false
    @State private var resetSheet = false
    @State private var ciSheet = false
    @State private var switchSheet = false
    @State private var showLog = false
    @State private var removal: RemovalTarget?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                topbar
                if let repo = store.repo {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 24) {
                            heading(repo)
                            pipeline
                            summary(repo)
                            HStack {
                                HStack(spacing: 20) {
                                    ForEach(["Worktrees", "Ветки"], id: \.self) { item in
                                        Button { section = item } label: {
                                            VStack(spacing: 12) {
                                                Text(item).fontWeight(.medium).foregroundStyle(section == item ? .white : muted)
                                                Rectangle().fill(section == item ? accent : .clear).frame(height: 2)
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }.fixedSize()
                                Spacer()
                                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                                TextField("Найти ветку…", text: $search).textFieldStyle(.plain).frame(width: 170)
                            }.overlay(alignment: .bottom) { Color.white.opacity(0.07).frame(height: 1) }
                            ScrollView {
                                if section == "Worktrees" {
                                    LazyVStack(spacing: 12) {
                                        ForEach(repo.worktrees.filter { search.isEmpty || $0.branch.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) }) { tree in
                                            worktreeCard(tree, repo: repo)
                                        }
                                    }
                                } else {
                                    LazyVStack(spacing: 8) {
                                        ForEach(repo.branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { branch in
                                            branchRow(branch, repo: repo)
                                        }
                                        if repo.branches.isEmpty { Text("Ветки появятся после первого коммита.").foregroundStyle(muted).padding(30) }
                                    }
                                }
                            }
                            footer
                        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if let tree = store.tree { inspector(tree, repo: repo) }
                    }
                } else {
                    Spacer()
                    VStack(spacing: 22) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 60)).foregroundStyle(accent)
                        Text("Все ветки. На своих местах.").font(.system(size: 30, weight: .semibold))
                        Text("Откройте локальный репозиторий, чтобы увидеть его worktree,\nвести feature через test и приёмку в main.")
                            .foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(6)
                        Button("Открыть репозиторий…", action: store.open).buttonStyle(AccentButton())
                        Text("⌘O  ·  Локальный Git  ·  Без облачного аккаунта").font(.system(size: 11)).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity)
                    Spacer()
                }
            }
        }
        .task(id: "\(store.repo?.root ?? "")|\(store.tree?.branch ?? "")|\(store.tree?.head ?? "")|\(ci.connection?.id ?? "")") {
            let root = store.repo?.root ?? ""
            ci.activate(root)
            await ci.monitor(branches: ["main", "test", store.tree?.branch ?? ""])
        }
        .background(canvas)
        .tint(accent)
        .disabled(store.busy)
        .overlay(alignment: .top) { if store.busy { ProgressView().controlSize(.small).padding(12).background(.regularMaterial, in: Capsule()).padding(.top, 8) } }
        .alert("Не удалось завершить операцию", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $ciSheet) { CIConnectionView().environmentObject(store).environmentObject(ci) }
        .sheet(isPresented: $createSheet) { CreateView(initialBranch: createBranch).environmentObject(store) }
        .sheet(isPresented: $mergeSheet) { MergeView().environmentObject(store) }
        .sheet(isPresented: $mrSheet) { MergeRequestView().environmentObject(store) }
        .sheet(isPresented: $resetSheet) { ResetTestView().environmentObject(store) }
        .sheet(isPresented: $pushSheet) { PushView().environmentObject(store) }
        .sheet(isPresented: $switchSheet) { SwitchView().environmentObject(store) }
        .sheet(item: $removal) { target in
            if let root = store.repo?.root { RemovalView(root: root, target: target).environmentObject(store) }
        }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Последняя операция").font(.title2.bold())
                ScrollView { Text(store.log.isEmpty ? "Операций пока нет." : store.log).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Закрыть") { showLog = false }.keyboardShortcut(.cancelAction)
            }.padding(28).frame(width: 720, height: 420)
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                if let icon = NSImage(named: "BranchDock") {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(accent).font(.title2)
                }
                Text("branchdock").font(.system(size: 21, weight: .bold, design: .rounded))
            }.padding(.top, 48).padding(.bottom, 42)
            Text("РАБОЧЕЕ ПРОСТРАНСТВО").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(muted).padding(.bottom, 14)
            Label("Обзор репозитория", systemImage: "square.grid.2x2")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            Button(action: store.open) { Label("Открыть другой…", systemImage: "folder") }.buttonStyle(.plain).foregroundStyle(muted).padding(12)
            Spacer().frame(height: 30)
            HStack {
                Text("РЕПОЗИТОРИЙ").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                Spacer()
                Button(action: store.open) { Image(systemName: "plus") }.buttonStyle(.plain)
            }.foregroundStyle(muted)
            if let repo = store.repo {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)).frame(width: 30, height: 30).overlay { Image(systemName: "shippingbox").foregroundStyle(muted) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: repo.root).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(repo.worktrees.count) worktree · \(repo.branches.count) веток").font(.system(size: 10)).foregroundStyle(muted)
                    }
                }.padding(.top, 18)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text("Локальное подключение").font(.system(size: 10)).foregroundStyle(muted)
            }
            Text("BRANCHDOCK / 0.3").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted.opacity(0.6)).padding(.top, 12)
        }.padding(20).frame(width: 205).background(Color.black.opacity(0.18))
            .overlay(alignment: .trailing) { Color.white.opacity(0.06).frame(width: 1) }
    }

    var topbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(muted)
            Text(store.repo.map { URL(fileURLWithPath: $0.root).lastPathComponent } ?? "Рабочее пространство").fontWeight(.medium)
            Text("/  Обзор").foregroundStyle(muted)
            Spacer()
            Button { ciSheet = true } label: { Label(ci.connection == nil ? "Подключить CI" : "Настройки CI", systemImage: "network") }
                .buttonStyle(.plain).disabled(store.repo?.remotes.isEmpty != false)
            Button { if let root = store.repo?.root { store.perform("Fetch") { try Git.run(root, ["fetch", "--all", "--prune"]) } } } label: { Label("Fetch", systemImage: "arrow.down") }.buttonStyle(.plain).disabled(store.repo == nil)
            Button { if let root = store.repo?.root { store.load(root) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).padding(.leading, 12).help("Обновить · ⌘R")
        }.font(.system(size: 11)).padding(.horizontal, 28).frame(height: 64)
            .overlay(alignment: .bottom) { Color.white.opacity(0.07).frame(height: 1) }
    }

    func heading(_ repo: Repository) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 9) {
                Text("От feature до продакшена").font(.system(size: 27, weight: .semibold))
                Text("Одна feature на весь путь: разработка, test, приёмка, MR в main.").font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Button { createBranch = nil; createSheet = true } label: { Label("Новый worktree", systemImage: "plus") }.buttonStyle(AccentButton())
        }
    }

    var pipeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("main → feature → test → приёмка → та же feature → main")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                Text("TEST\nАвтодеплой после тестов и сборок")
                Text("MAIN\nMR + зелёный CI")
                Text("ПРОД\nРучной деплой из CI")
            }.font(.system(size: 10)).foregroundStyle(muted).lineSpacing(5)
            HStack {
                Text("test → main запрещён. Приёмка — вручную.")
                    .font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Button("Пересоздать test…") { resetSheet = true }
                    .buttonStyle(.bordered).controlSize(.small).disabled(store.repo?.remotes.isEmpty != false)
            }
            if let connection = ci.connection {
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(Set(["main", "test", store.tree?.branch ?? ""].filter { !$0.isEmpty && $0 != "Detached HEAD" })).sorted(), id: \.self) { branch in
                        CIBranchBadge(branch: branch).environmentObject(ci)
                    }
                    Button { Task { await ci.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.buttonStyle(.plain).disabled(ci.refreshing).help("Обновить \(connection.provider.title) CI · автоматически раз в минуту")
                }
                Text("\(connection.provider.title) · \(connection.project) · remote \(connection.remote)")
                    .font(.system(size: 9)).foregroundStyle(muted).lineLimit(1)
            } else {
                Button("Подключить GitLab / GitHub по access token…") { ciSheet = true }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(accent)
                    .disabled(store.repo?.remotes.isEmpty != false)
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(panelColor, in: RoundedRectangle(cornerRadius: 9))
    }

    func summary(_ repo: Repository) -> some View {
        HStack(spacing: 12) {
            metric("WORKTREES", value: repo.worktrees.count, icon: "square.stack.3d.up")
            metric("ЛОКАЛЬНЫЕ ВЕТКИ", value: repo.branches.count, icon: "arrow.triangle.branch")
            metric("БЕЗ UPSTREAM", value: repo.branches.filter { $0.upstream.isEmpty }.count, icon: "arrow.up.right")
        }
    }

    func metric(_ label: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text(label).font(.system(size: 9, weight: .medium)).tracking(0.8); Spacer(); Image(systemName: icon) }.foregroundStyle(muted)
            Text("\(value)").font(.system(size: 28, weight: .medium, design: .rounded))
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(panelColor, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.06)) }
    }

    func worktreeCard(_ tree: Worktree, repo: Repository) -> some View {
        let branch = repo.branches.first { $0.name == tree.branch }
        return Button { store.selected = tree.path } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 17)).foregroundStyle(store.selected == tree.path ? accent : muted)
                    .frame(width: 36, height: 36).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        Text(tree.branch).font(.system(size: 14, weight: .semibold, design: .monospaced)).lineLimit(1)
                        if tree.path == repo.worktrees.first?.path { pill("ОСНОВНОЙ", color: muted) }
                        if tree.branch == "main" { pill("MR ONLY", color: accent) }
                        if tree.branch == "test" { pill("АВТОДЕПЛОЙ", color: accent) }
                        if tree.locked { Image(systemName: "lock.fill").foregroundStyle(muted) }
                        Spacer(minLength: 0)
                        Circle().fill(tree.merging ? .red : tree.dirty ? .orange : accent).frame(width: 6, height: 6)
                        Text(tree.merging ? "Конфликт merge" : tree.dirty ? "Есть изменения" : "Чисто").font(.system(size: 10)).foregroundStyle(muted)
                    }
                    Text(tree.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(muted)
                        Text(branch?.upstream.isEmpty == false ? branch!.upstream : "Нет upstream").foregroundStyle(muted)
                        Spacer()
                        Text(trackingText(branch)).foregroundStyle(branch?.tracking.isEmpty == false ? accent : muted)
                    }.font(.system(size: 10))
                }
            }.padding(17).background(store.selected == tree.path ? accent.opacity(0.045) : panelColor, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(store.selected == tree.path ? accent.opacity(0.6) : .white.opacity(0.07)) }
        }.buttonStyle(.plain)
    }

    func branchRow(_ branch: Branch, repo: Repository) -> some View {
        let tree = repo.worktrees.first { $0.branch == branch.name }
        return HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(tree == nil ? muted : accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(branch.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(tree?.name ?? "Без worktree").font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer()
            Text(trackingText(branch)).font(.system(size: 10)).foregroundStyle(muted)
            Button(tree == nil ? "Создать worktree" : "Показать") {
                if let tree { store.selected = tree.path; section = "Worktrees" } else { createBranch = branch.name; createSheet = true }
            }.buttonStyle(.bordered).controlSize(.small)
            Button(role: .destructive) { removal = .branch(branch) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).disabled(tree != nil)
                .help(tree == nil ? "Удалить локальную ветку" : "Ветка занята: сначала смените её или удалите worktree")
        }.padding(15).background(panelColor, in: RoundedRectangle(cornerRadius: 8))
    }

    func inspector(_ tree: Worktree, repo: Repository) -> some View {
        let branch = repo.branches.first { $0.name == tree.branch }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            HStack { Text("ВЫБРАННЫЙ WORKTREE").font(.system(size: 9, weight: .medium)).tracking(1); Spacer(); Image(systemName: "sidebar.right") }.foregroundStyle(muted)
            Image(systemName: "square.stack.3d.up").font(.system(size: 26)).foregroundStyle(accent).padding(.top, 10)
            VStack(alignment: .leading, spacing: 9) {
                Text(tree.name).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                Label(tree.branch, systemImage: "arrow.triangle.branch").font(.system(size: 11, design: .monospaced)).foregroundStyle(accent).textSelection(.enabled)
            }
            Divider().opacity(0.4)
            detail("СОСТОЯНИЕ", tree.merging ? "Незавершённый merge" : tree.dirty ? "Есть изменения" : "Рабочая папка чистая")
            detail("UPSTREAM", branch?.upstream.isEmpty == false ? branch!.upstream : "Не настроен")
            detail("ПУТЬ", tree.path)
            if ci.connection != nil { CIInspector(tree: tree).environmentObject(ci) }
            if Pipeline.isFeature(tree.branch) {
                detail("КОММИТЫ FEATURE В ВЕТКАХ", "test: \(inclusionText(branch?.inTest))\nmain: \(inclusionText(branch?.inMain))")
                Text("По Git после последнего Fetch. Наличие коммитов не подтверждает CI, деплой или приёмку.")
                    .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            detail("ЭТАП ПРОЦЕССА", tree.branch == "main" ? "Защищённая main · изменения через MR с зелёным CI. Прод — ручной запуск в CI." : tree.branch == "test" ? "Интеграция feature · автодеплой после всех тестов и сборок. test → main запрещён." : "Сохраните эту feature до приёмки. После приёмки откройте MR из неё в main.")
            VStack(spacing: 9) {
                if Pipeline.isFeature(tree.branch) {
                    Button { mrSheet = true } label: { Label("MR: test / main…", systemImage: "arrow.triangle.pull").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large).disabled(repo.remotes.isEmpty)
                }
                Button { pushSheet = true } label: { Label("Push ветки", systemImage: "arrow.up").frame(maxWidth: .infinity) }.buttonStyle(AccentButton()).disabled(repo.remotes.isEmpty || tree.branch == "Detached HEAD" || tree.branch == "main" || tree.merging)
                Button { mergeSheet = true } label: { Label("Влить ветку сюда…", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large).disabled(tree.dirty || tree.merging || tree.branch == "Detached HEAD" || tree.branch == "main" || repo.branches.count < 2)
                Button { switchSheet = true } label: { Label("Сменить ветку…", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large).disabled(tree.dirty || tree.merging)
                if tree.merging {
                    Button("Отменить merge", role: .destructive) { store.perform("Merge abort") { try Git.run(tree.path, ["merge", "--abort"]) } }.buttonStyle(.bordered)
                }
                Button(role: .destructive) { removal = .worktree(tree) } label: {
                    Label("Удалить worktree…", systemImage: "trash").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)
                    .disabled(tree.path == repo.worktrees.first?.path || tree.locked)
                    .help(tree.path == repo.worktrees.first?.path ? "Основной worktree удалять нельзя" : tree.locked ? "Worktree заблокирован в Git" : "Удалить worktree вместе с локальными файлами")
            }
            if tree.dirty { Text("Для merge сначала сохраните изменения в коммите или stash.").font(.system(size: 10)).foregroundStyle(.orange).lineSpacing(3) }
            if repo.remotes.isEmpty { Text("Push станет доступен после добавления remote в Git.").font(.system(size: 10)).foregroundStyle(muted) }
            Divider().opacity(0.4)
            HStack(spacing: 16) {
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tree.path) } label: { Label("Finder", systemImage: "folder") }
                Button {
                    NSWorkspace.shared.open([URL(fileURLWithPath: tree.path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) { _, error in
                        if let error { Task { @MainActor in store.error = error.localizedDescription } }
                    }
                } label: { Image(systemName: "terminal") }.help("Открыть Terminal в этом worktree")
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tree.path, forType: .string); store.notice = "Путь скопирован" } label: { Image(systemName: "doc.on.doc") }.help("Скопировать путь")
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(muted)
            Spacer()
            detail("ПОСЛЕДНИЙ КОММИТ · \(tree.head)", branch?.subject ?? "Detached HEAD")
            }.padding(23)
        }.frame(width: 258).frame(maxHeight: .infinity).background(Color.white.opacity(0.015))
            .overlay(alignment: .leading) { Color.white.opacity(0.07).frame(width: 1) }
    }

    var footer: some View {
        HStack {
            Circle().fill(accent).frame(width: 5, height: 5)
            Text(store.notice.isEmpty ? "Данные локального Git · ⌘R для обновления" : store.notice).lineLimit(1)
            Spacer()
            Button("Журнал ↗") { showLog = true }.buttonStyle(.plain)
        }.font(.system(size: 10)).foregroundStyle(muted)
    }
}

func detail(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(muted)
        Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled).lineSpacing(4)
    }
}

func pill(_ title: String, color: Color) -> some View {
    Text(title).font(.system(size: 8, weight: .semibold)).foregroundStyle(color).padding(.horizontal, 5).padding(.vertical, 3).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
}

func inclusionText(_ included: Bool?) -> String {
    guard let included else { return "нет данных" }
    return included ? "все присутствуют" : "есть невлитые"
}

func trackingText(_ branch: Branch?) -> String {
    guard let branch, !branch.upstream.isEmpty else { return "Без upstream" }
    if branch.tracking.isEmpty { return "Синхронизирована" }
    return branch.tracking.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "ahead ", with: "↑ ").replacingOccurrences(of: "behind ", with: "↓ ").replacingOccurrences(of: "gone", with: "Upstream удалён")
}

struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 11)
            .foregroundStyle(Color.black.opacity(0.85)).background(accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}
