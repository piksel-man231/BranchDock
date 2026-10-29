import Foundation
import SwiftUI

@MainActor
final class CIStore: ObservableObject {
    @Published private(set) var connection: CIConnection?
    @Published private(set) var snapshots: [String: CISnapshot] = [:]
    @Published private(set) var problems: [String: String] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var repositoryRoot = ""
    @Published private(set) var launchingJobID: String?
    @Published private(set) var launchProblems: [String: String] = [:]
    private var contextID = UUID()
    private var requestID = UUID()
    private var watchedBranches: [String] = []
    private let defaults: UserDefaults

    private let tokenStorage: CITokenStorage
    private let clientFactory: (CIConnection, String) -> CIClient

    init(defaults: UserDefaults = .standard, tokenStorage: CITokenStorage = KeychainTokenStorage(),
         clientFactory: @escaping (CIConnection, String) -> CIClient = { CIClient(connection: $0, token: $1) }) {
        self.defaults = defaults; self.tokenStorage = tokenStorage; self.clientFactory = clientFactory
    }
    private func key(_ root: String) -> String { "ci.connection:" + root }

    func activate(_ root: String) {
        guard repositoryRoot != root else { return }
        contextID = UUID(); launchProblems = [:]; requestID = UUID(); repositoryRoot = root
        snapshots = [:]; problems = [:]; refreshing = false
        connection = defaults.data(forKey: key(root)).flatMap { try? JSONDecoder().decode(CIConnection.self, from: $0) }
    }

    func save(_ config: CIConnection, token: String, root: String) throws {
        guard root == repositoryRoot else { throw CIError.message("Репозиторий изменился. Откройте настройки CI заново.") }
        let config = try config.validated()
        let data = try JSONEncoder().encode(config)
        try tokenStorage.save(token, id: config.id)
        let old = connection
        defaults.set(data, forKey: key(root))
        contextID = UUID(); launchProblems = [:]; requestID = UUID(); snapshots = [:]; problems = [:]; refreshing = false
        connection = config
        // The new credential and settings are committed before removing the previous credential.
        if let old, old.id != config.id { try? tokenStorage.delete(old.id) }
    }

    func disconnect() throws {
        if let connection { try tokenStorage.delete(connection.id) }
        defaults.removeObject(forKey: key(repositoryRoot))
        contextID = UUID(); launchProblems = [:]; requestID = UUID(); connection = nil; snapshots = [:]; problems = [:]; refreshing = false
    }

    func play(branch: String, snapshot: CISnapshot, item: CIItem, expectedConnection: CIConnection?, expectedRoot: String) async {
        guard launchingJobID == nil, let connection, connection.provider == .gitlab,
              connection == expectedConnection, repositoryRoot == expectedRoot,
              snapshots[branch]?.sha == snapshot.sha, item.canPlay else { return }
        let root = repositoryRoot, context = contextID
        launchingJobID = item.id; launchProblems[branch] = nil
        defer { launchingJobID = nil }
        do {
            let token = try tokenStorage.read(connection.id)
            let client = clientFactory(connection, token)
            defer { client.session.finishTasksAndInvalidate() }
            // Verify remote state immediately before POST; never retry a POST automatically.
            try await client.playManualJob(branch: branch, sha: snapshot.sha, itemID: item.id) {
                guard self.repositoryRoot == root, self.contextID == context else {
                    throw CIError.message("Подключение CI изменилось. Откройте запуск заново.")
                }
            }
            guard repositoryRoot == root, contextID == context else { return }
            requestID = UUID()
            snapshots[branch] = nil
            await refresh()
        } catch {
            guard repositoryRoot == root, contextID == context else { return }
            launchProblems[branch] = error.localizedDescription + " Если запрос уже был отправлен, проверьте статус CI перед повторным запуском."
            await refresh()
        }
    }

    func monitor(branches: [String]) async {
        watchedBranches = Array(Set(branches.filter { !$0.isEmpty && $0 != "Detached HEAD" })).sorted()
        guard connection != nil else { return }
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
        }
    }

    func refresh() async {
        guard let connection, !Task.isCancelled else { return }
        let root = repositoryRoot, branches = watchedBranches, id = UUID()
        requestID = id; refreshing = true
        defer { if requestID == id { refreshing = false } }
        do {
            let token = try tokenStorage.read(connection.id)
            let client = clientFactory(connection, token)
            defer { client.session.finishTasksAndInvalidate() }
            let results = await withTaskGroup(of: (String, Result<CISnapshot, Error>).self) { group in
                for branch in branches {
                    group.addTask {
                        do { return (branch, .success(try await client.snapshot(branch: branch))) }
                        catch { return (branch, .failure(error)) }
                    }
                }
                var values: [(String, Result<CISnapshot, Error>)] = []
                for await value in group { values.append(value) }
                return values
            }
            guard !Task.isCancelled, requestID == id, repositoryRoot == root, self.connection == connection else { return }
            for (branch, result) in results {
                switch result {
                case .success(let snapshot): snapshots[branch] = snapshot; problems[branch] = nil
                case .failure(let error): snapshots[branch] = nil; problems[branch] = error.localizedDescription
                }
            }
        } catch {
            guard !Task.isCancelled, requestID == id, repositoryRoot == root else { return }
            snapshots = [:]
            problems = Dictionary(uniqueKeysWithValues: branches.map { ($0, error.localizedDescription) })
        }
    }
}
