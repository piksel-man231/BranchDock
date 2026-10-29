import Foundation

struct GitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Worktree: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let branch: String
    let head: String
    let locked: Bool
    let dirty: Bool
    let merging: Bool
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct Branch: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let head: String
    let upstream: String
    let tracking: String
    let updated: String
    let subject: String
    var inTest: Bool? = nil
    var inMain: Bool? = nil
}

struct Repository {
    let root: String
    let worktrees: [Worktree]
    let branches: [Branch]
    let remotes: [String]
}

enum RemovalTarget: Identifiable {
    case worktree(Worktree)
    case branch(Branch)
    var id: String {
        switch self {
        case .worktree(let tree): return "worktree:" + tree.path
        case .branch(let branch): return "branch:" + branch.name
        }
    }
}

struct RemovalPreview {
    let tree: Worktree?
    let branch: Branch?
    let hasLocalFiles: Bool
}

enum Git {
    // A file captures combined output without pipe-buffer deadlocks on large fetches.
    static func run(_ directory: String, _ args: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oConnectTimeout=15"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitFailure(message: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text.trimmingCharacters(in: .newlines)
    }

    static func load(_ path: String) throws -> Repository {
        let root = try run(path, ["rev-parse", "--show-toplevel"])
        let raw = try run(root, ["worktree", "list", "--porcelain", "-z"])
        var worktrees: [Worktree] = []
        for record in raw.components(separatedBy: "\0\0") {
            let fields = record.components(separatedBy: "\0")
            guard let location = fields.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            if fields.contains("bare") { continue }
            let directory = String(location.dropFirst(9))
            let branch = fields.first(where: { $0.hasPrefix("branch refs/heads/") }).map { String($0.dropFirst("branch refs/heads/".count)) } ?? "Detached HEAD"
            let head = fields.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst(5).prefix(8)) } ?? ""
            let status = try? run(directory, ["status", "--porcelain"])
            let mergePath = try? run(directory, ["rev-parse", "--git-path", "MERGE_HEAD"])
            let mergeURL = mergePath.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: directory + "/")).standardizedFileURL }
            worktrees.append(Worktree(path: directory, branch: branch, head: head,
                locked: fields.contains(where: { $0.hasPrefix("locked") }),
                dirty: status == nil || status != "", merging: mergeURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false))
        }
        let remotes = try run(root, ["remote"]).split(separator: "\n").map(String.init)
        let preferredRemote = remotes.contains("origin") ? "origin" : remotes.first
        func containsFeature(_ feature: String, in target: String) -> Bool? {
            let ref = preferredRemote.map { "refs/remotes/\($0)/\(target)" } ?? "refs/heads/\(target)"
            guard let count = try? run(root, ["rev-list", "--count", "\(ref)..refs/heads/\(feature)"]) else { return nil }
            return count == "0"
        }
        let branches = try run(root, ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%00%(objectname:short)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:relative)%00%(subject)", "refs/heads/"])
            .split(separator: "\n").compactMap { line -> Branch? in
                let f = line.components(separatedBy: "\0")
                guard f.count == 6 else { return nil }
                return Branch(name: f[0], head: f[1], upstream: f[2], tracking: f[3], updated: f[4], subject: f[5],
                    inTest: Pipeline.isFeature(f[0]) ? containsFeature(f[0], in: "test") : nil,
                    inMain: Pipeline.isFeature(f[0]) ? containsFeature(f[0], in: "main") : nil)
            }
        return Repository(root: worktrees.first?.path ?? root, worktrees: worktrees, branches: branches, remotes: remotes)
    }

    static func create(_ repo: String, branch: String, base: String, path: String, existing: Bool) throws -> String {
        guard !branch.isEmpty, !path.isEmpty else { throw GitFailure(message: "Укажите ветку и папку worktree.") }
        _ = try run(repo, ["check-ref-format", "--branch", branch])
        if existing { return try run(repo, ["worktree", "add", "--", path, branch]) }
        return try run(repo, ["worktree", "add", "-b", branch, "--", path, base])
    }

    static func mergePreview(_ tree: Worktree, source: String) throws -> String {
        guard tree.branch != "main" else {
            throw GitFailure(message: "Изменения в main принимаются через MR с зелёным CI из той же feature. Прямой merge, включая test → main, запрещён.")
        }
        guard tree.branch != "Detached HEAD" else { throw GitFailure(message: "Для merge нужна ветка, а не detached HEAD.") }
        guard try run(tree.path, ["branch", "--show-current"]) == tree.branch else {
            throw GitFailure(message: "Ветка в целевом worktree изменилась. Обновите список и повторите операцию.")
        }
        guard try run(tree.path, ["status", "--porcelain"]).isEmpty else {
            throw GitFailure(message: "В целевом worktree есть незакоммиченные изменения. Сначала сохраните их или сделайте commit.")
        }
        let count = try run(tree.path, ["rev-list", "--count", "HEAD..refs/heads/" + source])
        return "\(source) → \(tree.branch)\n\nWorktree: \(tree.path)\nВходящих коммитов: \(count)\n\nБудет выполнен git merge. При конфликте операция остановится; разрешите его в редакторе или отмените merge здесь."
    }

    static func merge(_ tree: Worktree, source: String) throws -> String {
        _ = try mergePreview(tree, source: source)
        return try run(tree.path, ["merge", "--no-edit", "--", "refs/heads/" + source])
    }

    static func switchBranch(_ tree: Worktree, branch: String) throws -> String {
        guard try run(tree.path, ["status", "--porcelain"]).isEmpty else {
            throw GitFailure(message: "Сначала сохраните изменения в коммите или stash.")
        }
        _ = try run(tree.path, ["check-ref-format", "--branch", branch])
        return try run(tree.path, ["switch", "--no-guess", "--", branch])
    }

    static func push(_ tree: Worktree, remote: String) throws -> String {
        try validateCurrentBranch(tree)
        guard tree.branch != "main" else { throw GitFailure(message: "Прямой push в main запрещён. Откройте MR из принятой feature с зелёным CI.") }
        guard tree.branch != "Detached HEAD" else { throw GitFailure(message: "Сначала выберите ветку.") }
        guard !tree.merging, (try? run(tree.path, ["rev-parse", "--verify", "MERGE_HEAD"])) == nil else {
            throw GitFailure(message: "Сначала завершите или отмените merge.")
        }
        return try run(tree.path, ["push", "--set-upstream", remote, "refs/heads/\(tree.branch):refs/heads/\(tree.branch)"])
    }

    static func removalPreview(_ repo: String, target: RemovalTarget) throws -> RemovalPreview {
        let current = try load(repo)
        switch target {
        case .worktree(let expected):
            guard let tree = current.worktrees.first(where: { $0.path == expected.path }) else {
                throw GitFailure(message: "Worktree уже удалён. Обновите список.")
            }
            guard tree.path != current.worktrees.first?.path else {
                throw GitFailure(message: "Основной worktree репозитория удалять нельзя.")
            }
            guard !tree.locked else {
                throw GitFailure(message: "Worktree заблокирован в Git. Сначала снимите блокировку вручную.")
            }
            guard tree.branch == expected.branch, tree.head == expected.head else {
                throw GitFailure(message: "Ветка или коммит worktree изменились. Обновите список и повторите удаление.")
            }
            // Ignored files (including local .env files) are also lost on removal.
            let localFiles = try run(tree.path, ["status", "--porcelain", "--ignored", "--untracked-files=all"])
            return RemovalPreview(tree: tree, branch: current.branches.first { $0.name == tree.branch }, hasLocalFiles: !localFiles.isEmpty)
        case .branch(let expected):
            guard let branch = current.branches.first(where: { $0.name == expected.name }) else {
                throw GitFailure(message: "Ветка уже удалена. Обновите список.")
            }
            guard branch.head == expected.head else {
                throw GitFailure(message: "Коммит ветки изменился. Обновите список и повторите удаление.")
            }
            if let tree = current.worktrees.first(where: { $0.branch == branch.name }) {
                throw GitFailure(message: "Ветка используется в worktree: \(tree.path). Сначала смените ветку или удалите этот worktree.")
            }
            return RemovalPreview(tree: nil, branch: branch, hasLocalFiles: false)
        }
    }

    static func deleteBranch(_ repo: String, branch: Branch, force: Bool = false) throws -> String {
        try protectBranchDeletion(repo, branch: branch.name, force: force)
        _ = try removalPreview(repo, target: .branch(branch))
        return try run(repo, ["branch", force ? "-D" : "-d", "--", branch.name])
    }

    static func removeWorktree(_ repo: String, tree: Worktree, discardLocalFiles: Bool = false,
                               deleteBranch: Bool = false, forceBranch: Bool = false) throws -> String {
        let preview = try removalPreview(repo, target: .worktree(tree))
        guard !preview.hasLocalFiles || discardLocalFiles else {
            throw GitFailure(message: "В worktree есть локальные изменения, неотслеживаемые или игнорируемые файлы. Подтвердите их безвозвратное удаление.")
        }
        if deleteBranch, let branch = preview.branch { try protectBranchDeletion(repo, branch: branch.name, force: forceBranch) }
        var args = ["worktree", "remove"]
        if discardLocalFiles { args.append("--force") }
        args += ["--", tree.path]
        _ = try run(repo, args)
        var result = "Worktree и локальная папка удалены: \(tree.path)"
        if deleteBranch, let branch = preview.branch {
            do {
                result += "\n" + (try self.deleteBranch(repo, branch: branch, force: forceBranch))
            } catch {
                throw GitFailure(message: "\(result)\n\nЛокальная ветка \(branch.name) сохранена: \(error.localizedDescription)")
            }
        }
        return result
    }
}
