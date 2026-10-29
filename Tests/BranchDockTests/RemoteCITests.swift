import XCTest
@testable import BranchDock

private final class CIHTTPStub: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handle!(request)
            let data = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class MemoryTokens: CITokenStorage {
    var values: [String: String] = [:]
    func read(_ id: String) throws -> String {
        guard let value = values[id] else { throw CIError.message("No token") }
        return value
    }
    func save(_ token: String, id: String) throws { values[id] = token }
    func delete(_ id: String) throws { values[id] = nil }
}

final class RemoteCITests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)
    private let oldSHA = String(repeating: "b", count: 40)
    private var config: CIConnection { CIConnection(provider: .gitlab, remote: "origin", apiBase: "https://gitlab.example.com/api/v4", project: "team/sub/project") }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CIHTTPStub.self]
        return URLSession(configuration: config)
    }
    override func tearDown() { CIHTTPStub.handle = nil }

    func testRemoteDetectionAndEncodedProjectAndBranch() throws {
        let suggested = try XCTUnwrap(CIConnection.suggested(remote: "upstream", url: "git@gitlab.example.com:team/sub/project.git"))
        XCTAssertEqual(suggested.project, "team/sub/project")
        XCTAssertEqual(suggested.apiBase, "https://gitlab.example.com/api/v4")
        XCTAssertEqual(CIConnection.suggested(remote: "origin", url: "ssh://git@github.com/team/repo.git")?.apiBase, "https://api.github.com")
        let enterprise = CIConnection.suggested(remote: "origin", url: "ssh://git@ghe.example.com:2222/team/repo.git", provider: .github)
        XCTAssertEqual(enterprise?.apiBase, "https://ghe.example.com/api/v3")
        let url = try suggested.endpoint(["projects", suggested.project, "repository", "branches", "feature/поиск&filter"], query: [.init(name: "ref", value: "feature/поиск&filter")])
        XCTAssertTrue(url.absoluteString.contains("team%2Fsub%2Fproject"))
        XCTAssertTrue(url.absoluteString.contains("feature%2F"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "feature/поиск&filter")
    }

    func testRejectsUnsafeAPIAddressesAndUntrustedLinks() throws {
        for endpoint in ["http://example.com/api/v4", "https://user:password@example.com", "https://example.com?token=secret", "https://example.com/#fragment", "/api/v4"] {
            var value = config; value.apiBase = endpoint
            XCTAssertThrowsError(try value.validated())
        }
        XCTAssertNil(config.browserURL("https://other.example.com/steal"))
        XCTAssertNil(config.browserURL("https://user:secret@gitlab.example.com/path"))
        XCTAssertNotNil(config.browserURL("https://gitlab.example.com/team/sub/project/-/pipelines/1"))
        var gh = config; gh.provider = .github; gh.apiBase = "https://api.github.com"; gh.project = "team/repo"
        XCTAssertNotNil(gh.browserURL("https://github.com/team/repo/actions/runs/1"))
        gh.project = "team/sub/repo"
        XCTAssertThrowsError(try gh.validated())
    }

    func testGitLabUsesRemoteHEADAndShowsManualDeployment() async throws {
        var paths: [String] = []
        CIHTTPStub.handle = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "fake-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.url!.absoluteString.contains("fake-token"))
            paths.append(request.url!.absoluteString)
            if request.url!.path.hasSuffix("/jobs") {
                return (200, [
                    ["id": 11, "name": "deploy_prod", "stage": "deploy", "status": "manual", "web_url": "https://gitlab.example.com/jobs/11"],
                    ["id": 10, "name": "tests", "stage": "test", "status": "success"]
                ])
            }
            if request.url!.path.hasSuffix("/pipelines") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "sha" }?.value, self.sha)
                XCTAssertEqual(query.first { $0.name == "ref" }?.value, "feature/search")
                return (200, [["id": 4, "sha": self.sha, "status": "manual", "web_url": "https://gitlab.example.com/pipelines/4"]])
            }
            return (200, ["commit": ["id": self.sha]])
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let result = try await CIClient(connection: config, token: "fake-token", session: session).snapshot(branch: "feature/search")
        XCTAssertEqual(result.sha, sha)
        XCTAssertEqual(result.status, .manual)
        XCTAssertEqual(result.items.map(\.status), [.success, .manual])
        XCTAssertEqual(paths.count, 3)
    }

    func testManualJobLaunchRechecksHEADAndPostsOnlySelectedJob() async throws {
        var posts = 0
        CIHTTPStub.handle = { request in
            if request.httpMethod == "POST" {
                posts += 1
                XCTAssertTrue(request.url!.absoluteString.hasSuffix("/projects/team%2Fsub%2Fproject/jobs/11/play"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "fake-token")
                return (200, ["id": 11, "name": "deploy_prod", "stage": "deploy", "status": "pending"])
            }
            if request.url!.path.hasSuffix("/jobs") {
                return (200, [["id": 11, "name": "deploy_prod", "stage": "deploy", "status": "manual"]])
            }
            if request.url!.path.hasSuffix("/pipelines") {
                return (200, [["id": 4, "sha": self.sha, "status": "success"]])
            }
            return (200, ["commit": ["id": self.sha]])
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let client = CIClient(connection: config, token: "fake-token", session: session)
        let snapshot = try await client.snapshot(branch: "main")
        XCTAssertTrue(try XCTUnwrap(snapshot.items.first).canPlay)
        XCTAssertTrue(try XCTUnwrap(snapshot.items.first).isDeployment)
        try await client.playManualJob(branch: "main", sha: sha, itemID: "11")
        XCTAssertEqual(posts, 1)
    }

    func testManualJobLaunchRejectsChangedHEADJobAndProviderWithoutPOST() async throws {
        var jobStatus = "manual"
        CIHTTPStub.handle = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/jobs") {
                return (200, [["id": 11, "name": "deploy_prod", "stage": "deploy", "status": jobStatus]])
            }
            if request.url!.path.hasSuffix("/pipelines") {
                return (200, [["id": 4, "sha": self.sha, "status": "manual"]])
            }
            return (200, ["commit": ["id": self.sha]])
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let client = CIClient(connection: config, token: "fake-token", session: session)
        for (expectedSHA, itemID, status) in [(oldSHA, "11", "manual"), (sha, "12", "manual"), (sha, "11", "running")] {
            jobStatus = status
            do {
                try await client.playManualJob(branch: "main", sha: expectedSHA, itemID: itemID)
                XCTFail("Stale launch should be rejected")
            } catch { XCTAssertTrue(error.localizedDescription.contains("изменились")) }
        }
        var github = config; github.provider = .github
        do {
            try await CIClient(connection: github, token: "fake-token", session: session).playManualJob(branch: "main", sha: sha, itemID: "11")
            XCTFail("GitHub must not launch GitLab jobs")
        } catch { XCTAssertTrue(error.localizedDescription.contains("GitLab")) }
    }

    func testOldGreenGitLabPipelineNeverMarksNewHEADSuccessful() async throws {
        CIHTTPStub.handle = { request in
            if request.url!.path.hasSuffix("/pipelines") {
                return (200, [["id": 3, "sha": self.oldSHA, "status": "success"]])
            }
            return (200, ["commit": ["id": self.sha]])
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let result = try await CIClient(connection: config, token: "fake-token", session: session).snapshot(branch: "main")
        XCTAssertEqual(result.status, .none)
        XCTAssertTrue(result.items.isEmpty)
    }

    private func run(_ id: Int, workflow: Int, event: String = "push", status: String = "completed", conclusion: String = "success", sha: String? = nil) -> [String: Any] {
        ["id": id, "workflow_id": workflow, "name": "Workflow \(workflow)", "event": event, "head_sha": sha ?? self.sha,
         "status": status, "conclusion": conclusion, "html_url": "https://github.com/team/repo/actions/runs/\(id)"]
    }

    func testGitHubAggregatesLatestRunOfEveryWorkflowAndEvent() async throws {
        var config = config; config.provider = .github; config.apiBase = "https://api.github.com"; config.project = "team/repo"
        CIHTTPStub.handle = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"))
            if request.url!.path.hasSuffix("/runs") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "head_sha" }?.value, self.sha)
                return (200, ["workflow_runs": [
                    self.run(10, workflow: 1, conclusion: "failure"), self.run(11, workflow: 1),
                    self.run(12, workflow: 2, conclusion: "failure"),
                    self.run(13, workflow: 1, event: "pull_request", status: "waiting"),
                    self.run(14, workflow: 3, sha: self.oldSHA)
                ]])
            }
            return (200, ["commit": ["sha": self.sha]])
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let result = try await CIClient(connection: config, token: "fake-token", session: session).snapshot(branch: "feature/search")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(Set(result.items.map(\.id)), ["11", "12", "13"])
        XCTAssertTrue(result.items.contains { $0.status == .manual })
    }

    func testGitHubPaginationDoesNotMissFailingWorkflow() async throws {
        var config = config; config.provider = .github; config.apiBase = "https://api.github.com"; config.project = "team/repo"
        var pages = 0
        CIHTTPStub.handle = { request in
            if request.url!.path.hasSuffix("/runs") {
                pages += 1
                if pages == 1 { return (200, ["workflow_runs": (1...100).map { self.run($0, workflow: 1) }]) }
                return (200, ["workflow_runs": [self.run(101, workflow: 2, conclusion: "failure")]])
            }
            return (200, ["commit": ["sha": self.sha]])
        }
        let session = session(); defer { session.invalidateAndCancel() }
        let result = try await CIClient(connection: config, token: "fake-token", session: session).snapshot(branch: "main")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(pages, 2)
    }

    func testAPIErrorDoesNotExposeTokenOrResponseBody() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        for status in [301, 401, 403, 404, 429, 500] {
            CIHTTPStub.handle = { _ in (status, ["message": "fake-token secret-body"]) }
            do {
                _ = try await CIClient(connection: config, token: "fake-token", session: session).snapshot(branch: "main")
                XCTFail("Expected HTTP failure")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("fake-token"))
                XCTAssertFalse(error.localizedDescription.contains("secret-body"))
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testUnknownAndSkippedStatesDoNotBecomeGreen() {
        XCTAssertEqual(CIStatus.gitlab("new_status"), .unknown)
        XCTAssertEqual(CIStatus.github(status: "completed", conclusion: nil), .unknown)
        XCTAssertEqual(CIStatus.combined([.success, .unknown]), .unknown)
        XCTAssertEqual(CIStatus.combined([.success, .canceled]), .canceled)
        XCTAssertEqual(CIStatus.combined([.skipped]), .skipped)
        XCTAssertEqual(CIStatus.combined([]), .none)
    }

    @MainActor
    func testConnectionPersistsMetadataSeparatelyAndDisconnectDeletesToken() throws {
        let name = "BranchDockTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let tokens = MemoryTokens()
        let store = CIStore(defaults: defaults, tokenStorage: tokens)
        store.activate("/temporary/repo")
        try store.save(config, token: "fake-secret-token", root: "/temporary/repo")
        let saved = try XCTUnwrap(store.connection)
        let settings = try XCTUnwrap(defaults.data(forKey: "ci.connection:/temporary/repo"))
        XCTAssertFalse(String(decoding: settings, as: UTF8.self).contains("fake-secret-token"))
        let restored = CIStore(defaults: defaults, tokenStorage: tokens)
        restored.activate("/temporary/repo")
        XCTAssertEqual(restored.connection, saved)
        try restored.disconnect()
        XCTAssertNil(tokens.values[saved.id])
        XCTAssertNil(defaults.data(forKey: "ci.connection:/temporary/repo"))
        XCTAssertNil(restored.connection)
    }

    @MainActor
    func testSwitchingRepositoryClearsCIAndRejectsOldSettingsSave() throws {
        let name = "BranchDockTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let tokens = MemoryTokens()
        let store = CIStore(defaults: defaults, tokenStorage: tokens)
        store.activate("/repo-a")
        try store.save(config, token: "fake-secret-token", root: "/repo-a")
        store.activate("/repo-b")
        XCTAssertNil(store.connection)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertThrowsError(try store.save(config, token: "fake-secret-token", root: "/repo-a"))
        store.activate("/repo-a")
        XCTAssertNotNil(store.connection)
    }

    func testRedirectGuardNeverForwardsAuthenticatedRequest() {
        let session = session(); defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://other.example.com")!)
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: URL(string: "https://gitlab.example.com")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var called = false
        CIRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { forwarded in
            called = true
            XCTAssertNil(forwarded)
        }
        XCTAssertTrue(called)
    }

    func testMalformedRemoteHEADCannotProduceGreenStatus() async throws {
        CIHTTPStub.handle = { _ in (200, ["commit": ["id": ""]]) }
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            _ = try await CIClient(connection: config, token: "fake-token", session: session).snapshot(branch: "main")
            XCTFail("Malformed HEAD must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HEAD")) }
    }

}
