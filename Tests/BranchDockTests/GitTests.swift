import XCTest
@testable import BranchDock

final class GitTests: XCTestCase {
    var folder: URL!
    var repo: String { folder.appendingPathComponent("репозиторий с пробелами").path }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BranchDockTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try Git.run(repo, ["init", "-b", "main"])
        _ = try Git.run(repo, ["config", "user.name", "BranchDock Test"])
        _ = try Git.run(repo, ["config", "user.email", "test@example.invalid"])
        _ = try Git.run(repo, ["config", "commit.gpgsign", "false"])
        _ = try Git.run(repo, ["config", "core.hooksPath", "/dev/null"])
        try commit(repo, text: "initial\n")
        // Git reports physical paths; Foundation's temp directory uses /var.
        folder = URL(fileURLWithPath: try Git.run(repo, ["rev-parse", "--show-toplevel"])).deletingLastPathComponent()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func commit(_ path: String, text: String, file: String = "example.txt") throws {
        try text.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        _ = try Git.run(path, ["add", "--", file])
        _ = try Git.run(path, ["commit", "-m", "Test commit"])
    }

    func create(_ name: String = "feature/search") throws -> String {
        let location = folder.appendingPathComponent("worktree с пробелами").path
        _ = try Git.create(repo, branch: name, base: "main", path: location, existing: false)
        return location
    }

    func testWorktreeAndBranchDiscovery() throws {
        let path = try create()
        let snapshot = try Git.load(path)
        XCTAssertEqual(snapshot.root, repo)
        XCTAssertEqual(snapshot.worktrees.count, 2)
        XCTAssertEqual(Set(snapshot.branches.map(\.name)), ["main", "feature/search"])
        let tree = try XCTUnwrap(snapshot.worktrees.first { $0.path == path }, "Expected \(path); actual: \(snapshot.worktrees.map(\.path))")
        XCTAssertEqual(tree.branch, "feature/search")
        XCTAssertFalse(tree.dirty)
        try "untracked".write(toFile: path + "/untracked.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path }).dirty)
    }

    func testExistingBranchAndOccupiedBranchRejection() throws {
        _ = try Git.run(repo, ["branch", "existing"])
        let path = folder.appendingPathComponent("existing-tree").path
        _ = try Git.create(repo, branch: "existing", base: "", path: path, existing: true)
        XCTAssertEqual(try Git.load(repo).worktrees.count, 2)
        XCTAssertThrowsError(try Git.create(repo, branch: "existing", base: "", path: folder.appendingPathComponent("other").path, existing: true))
    }

    func testMergeDirectionAndDirtyWorktreeGuard() throws {
        let path = try create()
        try commit(path, text: "feature\n", file: "feature.txt")
        _ = try Git.run(repo, ["switch", "-c", "test"])
        let target = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == repo })
        XCTAssertTrue(try Git.mergePreview(target, source: "feature/search").contains("Входящих коммитов: 1"))
        try "dirty".write(toFile: repo + "/dirty.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Git.merge(target, source: "feature/search"))
        try FileManager.default.removeItem(atPath: repo + "/dirty.txt")
        _ = try Git.merge(target, source: "feature/search")
        XCTAssertEqual(try String(contentsOfFile: repo + "/feature.txt", encoding: .utf8), "feature\n")
        XCTAssertEqual(try Git.run(repo, ["branch", "--show-current"]), "test")
    }

    func testConflictDetectionAndAbort() throws {
        let path = try create()
        try commit(path, text: "feature\n")
        _ = try Git.run(repo, ["switch", "-c", "test"])
        try commit(repo, text: "main\n")
        let target = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == repo })
        XCTAssertThrowsError(try Git.merge(target, source: "feature/search"))
        XCTAssertTrue(try Git.load(repo).worktrees.first { $0.path == repo }!.merging)
        _ = try Git.run(repo, ["merge", "--abort"])
        XCTAssertFalse(try Git.load(repo).worktrees.first { $0.path == repo }!.merging)
        XCTAssertEqual(try String(contentsOfFile: repo + "/example.txt", encoding: .utf8), "main\n")
    }

    func testPushAndUpstreamTracking() throws {
        let remote = folder.appendingPathComponent("remote.git").path
        _ = try Git.run(folder.path, ["init", "--bare", remote])
        _ = try Git.run(repo, ["remote", "add", "origin", remote])
        let path = try create()
        let target = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        _ = try Git.push(target, remote: "origin")
        let branch = try XCTUnwrap(Git.load(repo).branches.first { $0.name == "feature/search" })
        XCTAssertEqual(branch.upstream, "origin/feature/search")
        XCTAssertEqual(branch.tracking, "")
        try commit(path, text: "next\n")
        XCTAssertTrue(try Git.load(repo).branches.first { $0.name == "feature/search" }!.tracking.contains("ahead 1"))
    }

    func testSwitchAndStaleMergeTargetGuard() throws {
        _ = try Git.run(repo, ["branch", "develop"])
        let target = try XCTUnwrap(Git.load(repo).worktrees.first)
        _ = try Git.switchBranch(target, branch: "develop")
        XCTAssertEqual(try Git.run(repo, ["branch", "--show-current"]), "develop")
        XCTAssertThrowsError(try Git.merge(target, source: "develop"))
        try "dirty".write(toFile: repo + "/dirty.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Git.switchBranch(target, branch: "main"))
    }

    func testRemoveWorktreeDeletesDirectoryAndKeepsBranchByDefault() throws {
        let path = try create()
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        _ = try Git.removeWorktree(repo, tree: tree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let snapshot = try Git.load(repo)
        XCTAssertEqual(snapshot.worktrees.count, 1)
        XCTAssertTrue(snapshot.branches.contains { $0.name == "feature/search" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/example.txt"))
    }

    func testRemoveWorktreeAndBranchTogether() throws {
        let path = try create()
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        _ = try Git.removeWorktree(repo, tree: tree, deleteBranch: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(try Git.load(repo).branches.contains { $0.name == "feature/search" })
    }

    func testLocalFilesRequireConsentIncludingIgnoredFiles() throws {
        try commit(repo, text: ".env\n", file: ".gitignore")
        let path = try create()
        try "local config".write(toFile: path + "/.env", atomically: true, encoding: .utf8)
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        XCTAssertFalse(tree.dirty)
        XCTAssertTrue(try Git.removalPreview(repo, target: .worktree(tree)).hasLocalFiles)
        XCTAssertThrowsError(try Git.removeWorktree(repo, tree: tree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/.env"))
        try "changed".write(toFile: path + "/example.txt", atomically: true, encoding: .utf8)
        try "new".write(toFile: path + "/untracked.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Git.removeWorktree(repo, tree: tree))
        _ = try Git.removeWorktree(repo, tree: tree, discardLocalFiles: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testMainAndLockedWorktreesCannotBeRemoved() throws {
        let main = try XCTUnwrap(Git.load(repo).worktrees.first)
        XCTAssertThrowsError(try Git.removeWorktree(repo, tree: main, discardLocalFiles: true, deleteBranch: true, forceBranch: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/example.txt"))
        let path = try create()
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        _ = try Git.run(repo, ["worktree", "lock", "--", path])
        XCTAssertThrowsError(try Git.removeWorktree(repo, tree: tree, discardLocalFiles: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testBranchDeletionRejectsOccupiedAndStaleBranches() throws {
        let path = try create()
        let branch = try XCTUnwrap(Git.load(repo).branches.first { $0.name == "feature/search" })
        XCTAssertThrowsError(try Git.deleteBranch(repo, branch: branch, force: true))
        try commit(path, text: "new commit\n")
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        _ = try Git.removeWorktree(repo, tree: tree)
        XCTAssertThrowsError(try Git.deleteBranch(repo, branch: branch, force: true))
        let updated = try XCTUnwrap(Git.load(repo).branches.first { $0.name == branch.name })
        XCTAssertThrowsError(try Git.deleteBranch(repo, branch: updated))
        _ = try Git.deleteBranch(repo, branch: updated, force: true)
        XCTAssertFalse(try Git.load(repo).branches.contains { $0.name == updated.name })
    }

    func testRemovalKeepsWorktreeWhenFeatureHasNotReachedMain() throws {
        let path = try create()
        try commit(path, text: "unmerged commit\n")
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        XCTAssertThrowsError(try Git.removeWorktree(repo, tree: tree, deleteBranch: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Сохраните feature"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try Git.load(repo).branches.contains { $0.name == "feature/search" })
    }

    func testForceBranchRemovalAndRemoteBranchPreservation() throws {
        let remote = folder.appendingPathComponent("remote.git").path
        _ = try Git.run(folder.path, ["init", "--bare", remote])
        _ = try Git.run(repo, ["remote", "add", "origin", remote])
        let path = try create()
        try commit(path, text: "feature commit\n")
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        _ = try Git.push(tree, remote: "origin")
        // Force must work even when origin/main has not been fetched yet.
        XCTAssertThrowsError(try Git.removeWorktree(repo, tree: tree, deleteBranch: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        _ = try Git.removeWorktree(repo, tree: tree, deleteBranch: true, forceBranch: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(try Git.load(repo).branches.contains { $0.name == tree.branch })
        XCTAssertFalse(try Git.run(remote, ["rev-parse", "--verify", "refs/heads/feature/search"]).isEmpty)
    }

    func testForceBranchRemovalStillRequiresLocalFileConsent() throws {
        let path = try create()
        try commit(path, text: "unmerged commit\n")
        try "local config".write(toFile: path + "/local.txt", atomically: true, encoding: .utf8)
        let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        XCTAssertThrowsError(try Git.removeWorktree(repo, tree: tree, deleteBranch: true, forceBranch: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/local.txt"))
        XCTAssertTrue(try Git.load(repo).branches.contains { $0.name == tree.branch })
        _ = try Git.removeWorktree(repo, tree: tree, discardLocalFiles: true, deleteBranch: true, forceBranch: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(try Git.load(repo).branches.contains { $0.name == tree.branch })
    }

    func testForceRemovalPreservesProtectedBranchWorktrees() throws {
        _ = try Git.run(repo, ["switch", "-c", "other"])
        for name in ["main", "test"] {
            let path = folder.appendingPathComponent(name + "-worktree").path
            _ = try Git.create(repo, branch: name, base: "main", path: path, existing: name == "main")
            let tree = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
            XCTAssertThrowsError(try Git.removeWorktree(repo, tree: tree, deleteBranch: true, forceBranch: true))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertTrue(try Git.load(repo).branches.contains { $0.name == name })
        }
    }

    func testMainMergeAndPushAreBlockedIncludingStaleWorktree() throws {
        let path = try create()
        let main = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == repo })
        XCTAssertThrowsError(try Git.mergePreview(main, source: "feature/search"))
        XCTAssertThrowsError(try Git.merge(main, source: "test"))
        XCTAssertThrowsError(try Git.push(main, remote: "origin"))
        let feature = try XCTUnwrap(Git.load(repo).worktrees.first { $0.path == path })
        _ = try Git.run(path, ["switch", "-c", "other"])
        XCTAssertThrowsError(try Git.push(feature, remote: "origin"))
    }

    func testProtectedBranchesCannotBeDeleted() throws {
        _ = try Git.run(repo, ["branch", "test"])
        _ = try Git.run(repo, ["switch", "-c", "other"])
        for name in ["main", "test"] {
            let branch = try XCTUnwrap(Git.load(repo).branches.first { $0.name == name })
            XCTAssertThrowsError(try Git.deleteBranch(repo, branch: branch, force: true))
        }
    }

    func resetRemote() throws -> String {
        let remote = folder.appendingPathComponent("remote.git").path
        _ = try Git.run(folder.path, ["init", "--bare", remote])
        _ = try Git.run(repo, ["remote", "add", "origin", remote])
        _ = try Git.run(repo, ["branch", "test"])
        _ = try Git.run(repo, ["push", "origin", "main", "test"])
        try commit(repo, text: "new main\n", file: "main.txt")
        _ = try Git.run(repo, ["push", "origin", "main"])
        return remote
    }

    func testResetArchivesRemoteTestWithoutChangingLocalBranches() throws {
        let remote = try resetRemote()
        let localTest = try Git.run(repo, ["rev-parse", "test"])
        let preview = try Git.testResetPreview(repo, remote: "origin")
        _ = try Git.resetTest(repo, preview: preview)
        XCTAssertEqual(try Git.run(remote, ["rev-parse", "test"]), preview.main)
        XCTAssertEqual(try Git.run(remote, ["rev-parse", preview.archive]), preview.test)
        XCTAssertEqual(try Git.run(repo, ["rev-parse", "test"]), localTest)
    }

    func testResetRejectsConcurrentPushAndDoesNotCreateArchive() throws {
        let remote = try resetRemote()
        let preview = try Git.testResetPreview(repo, remote: "origin")
        _ = try Git.run(repo, ["push", "origin", "main:test"])
        XCTAssertThrowsError(try Git.resetTest(repo, preview: preview))
        XCTAssertEqual(try Git.run(remote, ["rev-parse", "test"]), preview.main)
        XCTAssertThrowsError(try Git.run(remote, ["rev-parse", "--verify", preview.archive]))
    }

    func testResetRejectsArchiveCollisionAtomically() throws {
        let remote = try resetRemote()
        let preview = try Git.testResetPreview(repo, remote: "origin")
        _ = try Git.run(repo, ["push", "origin", "main:refs/heads/" + preview.archive])
        XCTAssertThrowsError(try Git.resetTest(repo, preview: preview))
        XCTAssertEqual(try Git.run(remote, ["rev-parse", "test"]), preview.test)
        XCTAssertEqual(try Git.run(remote, ["rev-parse", preview.archive]), preview.main)
    }

    func testGitLabMRUsesSameFeatureAndRetainsSource() throws {
        let project = try XCTUnwrap(Pipeline.projectURL("git@gitlab.example.com:team/sub/project.git"))
        XCTAssertEqual(project.absoluteString, "https://gitlab.example.com/team/sub/project")
        for target in ["test", "main"] {
            let url = try Pipeline.mergeRequestURL(project: project, source: "feature/поиск&filter", target: target)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "merge_request[source_branch]" }?.value, "feature/поиск&filter")
            XCTAssertEqual(items.first { $0.name == "merge_request[target_branch]" }?.value, target)
            XCTAssertEqual(items.first { $0.name == "merge_request[remove_source_branch]" }?.value, "false")
        }
        XCTAssertThrowsError(try Pipeline.mergeRequestURL(project: project, source: "test", target: "main"))
        XCTAssertNil(Pipeline.projectURL("/local/repo.git"))
        XCTAssertNil(Pipeline.projectURL("git@github.com:team/repo.git"))
        XCTAssertEqual(Pipeline.projectURL("https://user:secret@gitlab.example.com/team/repo.git")?.absoluteString,
                       "https://gitlab.example.com/team/repo")
    }


    func testResetRequiresAtomicPushSupport() throws {
        let remote = try resetRemote()
        let preview = try Git.testResetPreview(repo, remote: "origin")
        _ = try Git.run(remote, ["config", "receive.advertiseAtomic", "false"])
        XCTAssertThrowsError(try Git.resetTest(repo, preview: preview))
        XCTAssertEqual(try Git.run(remote, ["rev-parse", "test"]), preview.test)
        XCTAssertThrowsError(try Git.run(remote, ["rev-parse", "--verify", preview.archive]))
    }

}
