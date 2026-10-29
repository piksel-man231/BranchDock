import Foundation

// These are workflow rules, not a claim about server-side CI or acceptance.
enum Pipeline {
    static func isFeature(_ branch: String) -> Bool {
        branch != "main" && branch != "test" && branch != "Detached HEAD" && !branch.hasPrefix("archive/")
    }

    static func projectURL(_ remote: String) -> URL? {
        var value = remote
        if !value.contains("://"), let colon = value.firstIndex(of: ":"), value[..<colon].contains("@") {
            let host = value[..<colon].split(separator: "@").last ?? ""
            value = "https://\(host)/\(value[value.index(after: colon)...])"
        }
        guard var parts = URLComponents(string: value), let host = parts.host,
              ["https", "http", "ssh"].contains(parts.scheme ?? ""), host != "github.com" else { return nil }
        if parts.scheme == "ssh" { parts.scheme = "https"; parts.port = nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        if parts.path.hasSuffix(".git") { parts.path.removeLast(4) }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard !parts.path.isEmpty else { return nil }
        return parts.url
    }

    static func mergeRequestURL(project: URL, source: String, target: String) throws -> URL {
        guard isFeature(source), ["test", "main"].contains(target) else {
            throw GitFailure(message: "MR создаётся из feature в test или main. Слияние test → main запрещено.")
        }
        var parts = URLComponents(url: project.appendingPathComponent("-/merge_requests/new"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "merge_request[source_branch]", value: source),
            URLQueryItem(name: "merge_request[target_branch]", value: target),
            URLQueryItem(name: "merge_request[remove_source_branch]", value: "false")
        ]
        return parts.url!
    }
}

struct TestResetPreview {
    let remote: String
    let main: String
    let test: String
    let archive: String
}

extension Git {
    static func validateCurrentBranch(_ tree: Worktree) throws {
        guard try run(tree.path, ["branch", "--show-current"]) == tree.branch else {
            throw GitFailure(message: "Ветка в worktree изменилась. Обновите список и повторите операцию.")
        }
    }

    static func mainReference(_ repo: String) throws -> String {
        let remotes = try run(repo, ["remote"]).split(separator: "\n").map(String.init)
        if !remotes.isEmpty {
            let remote = remotes.contains("origin") ? "origin" : remotes[0]
            let ref = "refs/remotes/\(remote)/main"
            guard (try? run(repo, ["rev-parse", "--verify", ref])) != nil else {
                throw GitFailure(message: "Нет данных \(remote)/main. Выполните Fetch перед удалением feature.")
            }
            return ref
        }
        return "refs/heads/main"
    }

    static func protectBranchDeletion(_ repo: String, branch: String, force: Bool = false) throws {
        guard branch != "main", branch != "test" else {
            throw GitFailure(message: "Ветки main и test нельзя удалять. Для test используйте пересоздание с архивом.")
        }
        if !force, Pipeline.isFeature(branch) {
            let main = try mainReference(repo)
            guard let count = try? run(repo, ["rev-list", "--count", "\(main)..refs/heads/\(branch)"]), count == "0" else {
                throw GitFailure(message: "Сохраните feature до приёмки и слияния через MR в main. Ветка ещё содержит коммиты вне main; после MR выполните Fetch.")
            }
        }
    }

    static func testResetPreview(_ repo: String, remote: String) throws -> TestResetPreview {
        guard try run(repo, ["remote"]).split(separator: "\n").contains(Substring(remote)) else {
            throw GitFailure(message: "Выберите существующий remote.")
        }
        let refs = try run(repo, ["ls-remote", "--heads", remote, "refs/heads/main", "refs/heads/test"])
        let entries = Dictionary(uniqueKeysWithValues: refs.split(separator: "\n").compactMap { line -> (String, String)? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.count == 2 ? (String(fields[1]), String(fields[0])) : nil
        })
        guard let main = entries["refs/heads/main"], let test = entries["refs/heads/test"] else {
            throw GitFailure(message: "На remote должны существовать main и test.")
        }
        // Fetch into FETCH_HEAD only: don't change local branches or worktrees.
        _ = try run(repo, ["fetch", "--no-tags", remote, main, test])
        return TestResetPreview(remote: remote, main: main, test: test,
            archive: "archive/test-" + UUID().uuidString.lowercased())
    }

    static func resetTest(_ repo: String, preview: TestResetPreview) throws -> String {
        let current = try run(repo, ["ls-remote", "--heads", preview.remote, "refs/heads/test"])
        guard current.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) == preview.test else {
            throw GitFailure(message: "test на remote изменился после проверки. Повторите предпросмотр; чужие изменения сохранены.")
        }
        _ = try run(repo, ["check-ref-format", "refs/heads/" + preview.archive])
        guard preview.archive.hasPrefix("archive/test-") else { throw GitFailure(message: "Некорректное имя архива.") }
        // Atomic guarantees the archive and reset either both succeed or both fail.
        // Explicit leases protect both the reviewed test head and archive creation.
        _ = try run(repo, ["push", "--atomic", "--force-with-lease=refs/heads/test:\(preview.test)",
            "--force-with-lease=refs/heads/\(preview.archive):", preview.remote,
            "\(preview.test):refs/heads/\(preview.archive)", "\(preview.main):refs/heads/test"])
        return "\(preview.remote)/test пересоздан от main \(preview.main.prefix(8)).\nПрежний test сохранён: \(preview.remote)/\(preview.archive).\nЛокальные ветки и worktree не изменены. Выполните Fetch; автоматический деплой test зависит от серверного CI."
    }
}
