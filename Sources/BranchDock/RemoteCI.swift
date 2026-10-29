import Foundation
import Security

enum CIProvider: String, Codable, CaseIterable, Identifiable {
    case gitlab, github
    var id: String { rawValue }
    var title: String { self == .gitlab ? "GitLab" : "GitHub" }
    var permissions: String {
        self == .gitlab ? "Access token с правом read_api для просмотра; для запуска ручного деплоя нужно право api и разрешение на запуск job в проекте." : "Fine-grained token: Actions — Read, Contents — Read, доступ к этому репозиторию. Для classic token приватного репозитория нужен repo."
    }
}

struct CIConnection: Codable, Equatable {
    var id = UUID().uuidString
    var provider: CIProvider
    var remote: String
    var apiBase: String
    var project: String

    func validated() throws -> CIConnection {
        var result = self
        result.apiBase = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.apiBase.hasSuffix("/") { result.apiBase.removeLast() }
        guard let url = URLComponents(string: result.apiBase), url.scheme == "https", !(url.host ?? "").isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw CIError.message("Укажите HTTPS-адрес API без логина, пароля и параметров.")
        }
        result.project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = result.project.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { $0.isWhitespace || $0.isNewline }) }),
              provider != .github || parts.count == 2 else {
            throw CIError.message("Укажите проект в формате namespace/repository, без URL. В GitLab допустимы подгруппы.")
        }
        return result
    }

    static func suggested(remote: String, url: String, provider override: CIProvider? = nil) -> CIConnection? {
        var value = url
        if !value.contains("://"), let colon = value.firstIndex(of: ":"), value[..<colon].contains("@") {
            value = "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...]
        }
        guard let parts = URLComponents(string: value), let host = parts.host,
              ["ssh", "http", "https"].contains(parts.scheme ?? "") else { return nil }
        let provider = override ?? (host.lowercased() == "github.com" ? .github : .gitlab)
        var origin = URLComponents()
        origin.scheme = "https"; origin.host = host
        if parts.scheme != "ssh" { origin.port = parts.port }
        var project = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if project.hasSuffix(".git") { project.removeLast(4) }
        let api = provider == .github && host.lowercased() == "github.com" ? "https://api.github.com" :
            (origin.string ?? "") + (provider == .gitlab ? "/api/v4" : "/api/v3")
        return CIConnection(provider: provider, remote: remote, apiBase: api, project: project)
    }

    func endpoint(_ path: [String], query: [URLQueryItem] = []) throws -> URL {
        let connection = try validated()
        var parts = URLComponents(string: connection.apiBase)!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#;")
        parts.percentEncodedPath += "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw CIError.message("Некорректный адрес API.") }
        return url
    }

    func browserURL(_ value: String?) -> URL? {
        guard let value, let url = URLComponents(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, let api = URLComponents(string: apiBase) else { return nil }
        let expected = api.host == "api.github.com" ? "github.com" : api.host
        guard host.lowercased() == expected?.lowercased(), url.port == api.port else { return nil }
        return url.url
    }
}

enum CIError: LocalizedError {
    case message(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(401): return "Токен недействителен или истёк. Замените его в настройках CI."
        case .http(403): return "Недостаточно прав или исчерпан лимит API. Для запуска GitLab job нужен токен с правом api и доступ к job и защищённому окружению."
        case .http(404): return "Ветка или проект не найдены либо токен не имеет доступа. Проверьте проект и права."
        case .http(429): return "Достигнут лимит API. Повторите позже."
        case .http(300..<400): return "API вернул перенаправление. Укажите конечный HTTPS-адрес API в настройках CI."
        case .http(let code): return "Сервер CI вернул HTTP \(code). Повторите позже."
        }
    }
}

protocol CITokenStorage {
    func read(_ id: String) throws -> String
    func save(_ token: String, id: String) throws
    func delete(_ id: String) throws
}

struct KeychainTokenStorage: CITokenStorage {
    func read(_ id: String) throws -> String { try TokenVault.read(id) }
    func save(_ token: String, id: String) throws { try TokenVault.save(token, id: id) }
    func delete(_ id: String) throws { try TokenVault.delete(id) }
}

enum TokenVault {
    private static let service = "local.branchdock.ci-token"
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    static func read(_ id: String) throws -> String {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data, let token = String(data: data, encoding: .utf8) else {
            throw CIError.message(status == errSecItemNotFound ? "Токен не найден в Keychain. Подключите CI заново." : "Не удалось прочитать токен из Keychain (\(status)).")
        }
        return token
    }
    static func save(_ token: String, id: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(id)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw CIError.message("Не удалось сохранить токен в Keychain (\(added)).") }
        } else if status != errSecSuccess { throw CIError.message("Не удалось обновить токен в Keychain (\(status)).") }
    }
    static func delete(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CIError.message("Не удалось удалить токен из Keychain (\(status)).")
        }
    }
}

enum CIStatus: String {
    case success, failed, running, waiting, manual, canceled, skipped, unknown, none
    var title: String {
        switch self {
        case .success: return "Успешно"
        case .failed: return "Ошибка"
        case .running: return "Выполняется"
        case .waiting: return "В очереди"
        case .manual: return "Ждёт запуска"
        case .canceled: return "Отменён"
        case .skipped: return "Пропущен"
        case .unknown: return "Неизвестно"
        case .none: return "Нет запусков для HEAD"
        }
    }
    static func gitlab(_ status: String) -> CIStatus {
        switch status {
        case "success": return .success
        case "failed": return .failed
        case "running", "canceling": return .running
        case "created", "pending", "preparing", "waiting_for_resource", "scheduled": return .waiting
        case "manual": return .manual
        case "canceled": return .canceled
        case "skipped": return .skipped
        default: return .unknown
        }
    }
    static func github(status: String, conclusion: String?) -> CIStatus {
        if status == "completed" {
            switch conclusion {
            case "success": return .success
            case "failure", "timed_out", "startup_failure", "action_required": return .failed
            case "cancelled": return .canceled
            case "skipped", "neutral": return .skipped
            default: return .unknown
            }
        }
        switch status {
        case "in_progress": return .running
        case "queued", "pending", "requested": return .waiting
        case "waiting": return .manual
        default: return .unknown
        }
    }
    static func combined(_ values: [CIStatus]) -> CIStatus {
        if values.isEmpty { return .none }
        for status in [CIStatus.failed, .running, .waiting, .manual, .unknown, .canceled] where values.contains(status) { return status }
        return values.contains(.success) ? .success : .skipped
    }
}

struct CIItem: Identifiable {
    let id: String
    let title: String
    let status: CIStatus
    let url: URL?
    var canPlay = false
    var isDeployment = false
}

struct CISnapshot {
    let branch: String
    let sha: String
    let status: CIStatus
    let url: URL?
    let items: [CIItem]
    let checkedAt: Date
}

// Never follow redirects with a private token, persist response caches, or print server bodies.
final class CIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct CIClient {
    let connection: CIConnection
    let token: String
    let session: URLSession

    init(connection: CIConnection, token: String, session: URLSession? = nil) {
        self.connection = connection; self.token = token
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 45
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config, delegate: CIRedirectGuard(), delegateQueue: nil)
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ path: [String], _ query: [URLQueryItem] = []) async throws -> T {
        try await request(type, path, query)
    }

    private func request<T: Decodable>(_ type: T.Type, _ path: [String], _ query: [URLQueryItem] = [],
                                       method: String = "GET") async throws -> T {
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw CIError.message("Введите access token без пробелов, переносов строк и управляющих символов.")
        }
        var request = URLRequest(url: try connection.endpoint(path, query: query))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if connection.provider == .gitlab { request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN") }
        else {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        request.setValue("BranchDock/0.3", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // URLSession diagnostics may contain URLs; expose a fixed message instead.
            throw CIError.message("Не удалось связаться с CI. Проверьте сеть, адрес API и сертификат сервера.")
        }
        guard let http = response as? HTTPURLResponse else { throw CIError.message("Некорректный ответ сервера CI.") }
        guard (200..<300).contains(http.statusCode) else { throw CIError.http(http.statusCode) }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CIError.message("Сервер CI вернул неожиданный формат данных. Проверьте адрес API и провайдера.") }
    }

    func snapshot(branch: String) async throws -> CISnapshot {
        if connection.provider == .gitlab { return try await gitlab(branch: branch) }
        return try await github(branch: branch)
    }

    func playManualJob(branch: String, sha: String, itemID: String, beforePlay: () async throws -> Void = {}) async throws {
        guard connection.provider == .gitlab, let jobID = Int(itemID), jobID > 0 else {
            throw CIError.message("Запуск доступен только для ручных jobs GitLab.")
        }
        let current = try await snapshot(branch: branch)
        guard current.sha == sha, current.items.contains(where: { $0.id == itemID && $0.canPlay }) else {
            throw CIError.message("HEAD ветки или состояние job изменились. Обновите CI и проверьте запуск заново.")
        }
        try Task.checkCancellation()
        try await beforePlay()
        _ = try await request(GLJob.self, ["projects", connection.project, "jobs", String(jobID), "play"], method: "POST")
    }

    private func validateSHA(_ sha: String) throws {
        guard [40, 64].contains(sha.count), sha.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw CIError.message("Сервер CI вернул некорректный HEAD ветки.")
        }
    }

    private func gitlab(branch: String) async throws -> CISnapshot {
        let base = ["projects", connection.project]
        let head = try await get(GLBranch.self, base + ["repository", "branches", branch])
        try validateSHA(head.commit.id)
        let pipelines = try await get([GLPipeline].self, base + ["pipelines"], [
            .init(name: "ref", value: branch), .init(name: "sha", value: head.commit.id),
            .init(name: "order_by", value: "id"), .init(name: "sort", value: "desc"), .init(name: "per_page", value: "1")])
        guard let pipeline = pipelines.first, pipeline.sha == head.commit.id else {
            return CISnapshot(branch: branch, sha: head.commit.id, status: .none, url: nil, items: [], checkedAt: Date())
        }
        var jobs: [GLJob] = []
        for page in 1...10 {
            let batch = try await get([GLJob].self, base + ["pipelines", String(pipeline.id), "jobs"], [
                .init(name: "per_page", value: "100"), .init(name: "page", value: String(page)), .init(name: "include_retried", value: "false")])
            jobs += batch
            if batch.count < 100 { break }
            if page == 10 { throw CIError.message("В пайплайне больше 1000 jobs. Откройте полный статус на сервере.") }
        }
        let items = jobs.sorted { $0.id < $1.id }.map {
            CIItem(id: String($0.id), title: "\($0.stage) / \($0.name)", status: .gitlab($0.status), url: connection.browserURL($0.web_url),
                   canPlay: $0.status == "manual",
                   isDeployment: ($0.stage + " " + $0.name).localizedCaseInsensitiveContains("deploy"))
        }
        return CISnapshot(branch: branch, sha: head.commit.id, status: .gitlab(pipeline.status),
                          url: connection.browserURL(pipeline.web_url), items: items, checkedAt: Date())
    }

    private func github(branch: String) async throws -> CISnapshot {
        let base = ["repos"] + connection.project.split(separator: "/").map(String.init)
        let head = try await get(GHBranch.self, base + ["branches", branch])
        try validateSHA(head.commit.sha)
        var runs: [GHRun] = []
        for page in 1...10 {
            let batch = try await get(GHRuns.self, base + ["actions", "runs"], [
                .init(name: "branch", value: branch), .init(name: "head_sha", value: head.commit.sha),
                .init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            runs += batch.workflow_runs.filter { $0.head_sha == head.commit.sha }
            if batch.workflow_runs.count < 100 { break }
            if page == 10 { throw CIError.message("Слишком много запусков Actions для HEAD. Откройте полный статус на GitHub.") }
        }
        let latest = Dictionary(grouping: runs, by: { "\($0.workflow_id):\($0.event)" }).values.compactMap { $0.max { $0.id < $1.id } }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        let items = latest.map {
            CIItem(id: String($0.id), title: "\($0.name ?? "Workflow") · \($0.event)",
                   status: .github(status: $0.status, conclusion: $0.conclusion), url: connection.browserURL($0.html_url))
        }
        return CISnapshot(branch: branch, sha: head.commit.sha, status: .combined(items.map(\.status)),
                          url: items.first?.url, items: items, checkedAt: Date())
    }
}

private struct GLBranch: Decodable { let commit: GLCommit }
private struct GLCommit: Decodable { let id: String }
private struct GLPipeline: Decodable { let id: Int; let sha: String; let status: String; let web_url: String? }
private struct GLJob: Decodable { let id: Int; let name: String; let stage: String; let status: String; let web_url: String? }
private struct GHBranch: Decodable { let commit: GHCommit }
private struct GHCommit: Decodable { let sha: String }
private struct GHRuns: Decodable { let workflow_runs: [GHRun] }
private struct GHRun: Decodable {
    let id: Int; let workflow_id: Int; let name: String?; let event: String
    let head_sha: String; let status: String; let conclusion: String?; let html_url: String?
}
