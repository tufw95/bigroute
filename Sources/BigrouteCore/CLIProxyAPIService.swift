import Foundation

public enum CLIProxyAPIError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case unauthorized
    case unsupported
    case serverError(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The CLI Proxy API endpoint URL is invalid."
        case .unauthorized:
            return "Management key is invalid or required. Enter the secret-key in Settings."
        case .unsupported:
            return "This endpoint is not a valid CLI Proxy API server (management API not found)."
        case let .serverError(status):
            return "CLI Proxy API server returned HTTP \(status)."
        case .invalidResponse:
            return "The response from CLI Proxy API could not be parsed."
        }
    }
}

public struct CLIProxyAuthFile: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let provider: String?
    public let disabled: Bool?
    public let status: String?
    public let statusMessage: String?
    public let email: String?
    public let projectId: String?
    public let success: Int?
    public let failed: Int?
    public let priority: Int?
    public let weight: Int?
    public let note: String?
    public let modified: Double?

    enum CodingKeys: String, CodingKey {
        case name, provider, disabled, status
        case statusMessage = "status_message"
        case email
        case projectId = "project_id"
        case success, failed, priority, weight, note, modified
    }

    public init(
        name: String,
        provider: String? = nil,
        disabled: Bool? = nil,
        status: String? = nil,
        statusMessage: String? = nil,
        email: String? = nil,
        projectId: String? = nil,
        success: Int? = nil,
        failed: Int? = nil,
        priority: Int? = nil,
        weight: Int? = nil,
        note: String? = nil,
        modified: Double? = nil
    ) {
        self.name = name
        self.provider = provider
        self.disabled = disabled
        self.status = status
        self.statusMessage = statusMessage
        self.email = email
        self.projectId = projectId
        self.success = success
        self.failed = failed
        self.priority = priority
        self.weight = weight
        self.note = note
        self.modified = modified
    }
}

public struct CLIProxyAuthFilesResponse: Codable, Sendable {
    public let files: [CLIProxyAuthFile]
    public let total: Int?

    public init(files: [CLIProxyAuthFile], total: Int? = nil) {
        self.files = files
        self.total = total
    }
}

public final class CLIProxyAPIService: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func authFilesURL(from baseURL: URL) -> URL {
        normalize(endpoint: baseURL, path: "/v0/management/auth-files")
    }

    public static func statusURL(from baseURL: URL) -> URL {
        normalize(endpoint: baseURL, path: "/v0/management/auth-files/status")
    }

    private static func normalize(endpoint: URL, path: String) -> URL {
        let baseString = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if baseString.hasSuffix(path) {
            return endpoint
        }
        return URL(string: "\(baseString)\(path)") ?? endpoint
    }

    public func fetchAccounts(
        endpoint: URL,
        managementKey: String
    ) async throws -> [CodexQuotaAccount] {
        let url = Self.authFilesURL(from: endpoint)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyAPIError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw CLIProxyAPIError.unauthorized
        case 404:
            throw CLIProxyAPIError.unsupported
        default:
            throw CLIProxyAPIError.serverError(http.statusCode)
        }

        let decoded: CLIProxyAuthFilesResponse
        do {
            decoded = try JSONDecoder().decode(CLIProxyAuthFilesResponse.self, from: data)
        } catch {
            throw CLIProxyAPIError.invalidResponse
        }

        return decoded.files.map(Self.mapToAccount)
    }

    public func setAccountDisabled(
        name: String,
        disabled: Bool,
        endpoint: URL,
        managementKey: String
    ) async throws {
        let url = Self.statusURL(from: endpoint)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = ["name": name, "disabled": disabled]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyAPIError.invalidResponse
        }

        switch http.statusCode {
        case 200...204:
            return
        case 401, 403:
            throw CLIProxyAPIError.unauthorized
        case 404:
            throw CLIProxyAPIError.unsupported
        default:
            throw CLIProxyAPIError.serverError(http.statusCode)
        }
    }

    public func bulkSetDisabled(
        names: [String],
        disabled: Bool,
        endpoint: URL,
        managementKey: String
    ) async throws -> Int {
        var count = 0
        for name in names {
            do {
                try await setAccountDisabled(name: name, disabled: disabled, endpoint: endpoint, managementKey: managementKey)
                count += 1
            } catch {
                // Continue with remaining accounts on individual failure
            }
        }
        return count
    }

    public func uploadAuthFile(
        fileURL: URL,
        endpoint: URL,
        managementKey: String
    ) async throws {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let url = Self.authFilesURL(from: endpoint)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyAPIError.invalidResponse
        }

        switch http.statusCode {
        case 200...204:
            return
        case 401, 403:
            throw CLIProxyAPIError.unauthorized
        case 404:
            throw CLIProxyAPIError.unsupported
        default:
            throw CLIProxyAPIError.serverError(http.statusCode)
        }
    }

    public static func mapToAccount(_ file: CLIProxyAuthFile) -> CodexQuotaAccount {
        let provider = file.provider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? file.provider!
            : inferProvider(from: file.name)

        let label = displayLabel(for: file)
        let plan = inferPlan(for: file, provider: provider)
        let isDisabled = file.disabled == true
        let rawStatus = file.status?.lowercased() ?? "available"

        let isRateLimited = rawStatus.contains("rate_limit") || rawStatus.contains("rate-limit")
        let isExpired = rawStatus.contains("expired")
        let limitReached = isDisabled || isRateLimited || isExpired

        let accountStatus: String
        if isDisabled {
            accountStatus = "disabled"
        } else if isExpired {
            accountStatus = "expired"
        } else if isRateLimited {
            accountStatus = "rate_limited"
        } else {
            accountStatus = "available"
        }

        let success = Double(file.success ?? 0)
        let failed = Double(file.failed ?? 0)
        let totalRequests = success + failed
        let remaining: Double
        if isDisabled || isRateLimited || isExpired {
            remaining = 0
        } else if totalRequests > 0 {
            remaining = max(0, min(100, (success / totalRequests) * 100))
        } else {
            remaining = 100
        }

        let quota = CodexQuotaWindow(
            key: "requests",
            used: failed,
            total: totalRequests > 0 ? totalRequests : 100,
            remaining: remaining,
            resetAt: nil,
            unlimited: false
        )

        return CodexQuotaAccount(
            id: file.name,
            provider: provider,
            label: label,
            plan: plan,
            limitReached: limitReached,
            quotas: [quota],
            resetCredits: CodexQuotaAccount.ResetCredits(availableCount: 0),
            status: accountStatus,
            errorCode: file.statusMessage,
            isActive: !isDisabled
        )
    }

    private static func inferProvider(from filename: String) -> String {
        let lower = filename.lowercased()
        if lower.contains("antigravity") || lower.contains("gemini") {
            return "antigravity"
        }
        if lower.contains("claude") {
            return "claude"
        }
        if lower.contains("codex") || lower.contains("openai") || lower.contains("chatgpt") {
            return "codex"
        }
        return "cliproxy"
    }

    private static func inferPlan(for file: CLIProxyAuthFile, provider: String) -> String {
        let lower = file.name.lowercased()
        if lower.contains("-plus") { return "Plus" }
        if lower.contains("-team") { return "Team" }
        if lower.contains("-pro") { return "Pro" }
        if provider == "antigravity" { return "Antigravity" }
        if provider == "claude" { return "Claude" }
        return provider.capitalized
    }

    private static func displayLabel(for file: CLIProxyAuthFile) -> String {
        if let email = file.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        if let note = file.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        var clean = file.name
        if clean.hasSuffix(".json") { clean = String(clean.dropLast(5)) }
        for prefix in ["antigravity-", "codex-", "claude-"] {
            if clean.hasPrefix(prefix) { clean = String(clean.dropFirst(prefix.count)) }
        }
        return clean
    }
}
