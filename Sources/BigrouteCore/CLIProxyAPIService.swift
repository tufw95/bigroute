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
    public let account: String?
    public let accountType: String?
    public let authIndex: String?
    public let type: String?

    enum CodingKeys: String, CodingKey {
        case name, provider, disabled, status
        case statusMessage = "status_message"
        case email
        case projectId = "project_id"
        case success, failed, priority, weight, note, modified
        case account
        case accountType = "account_type"
        case authIndex = "auth_index"
        case type
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
        modified: Double? = nil,
        account: String? = nil,
        accountType: String? = nil,
        authIndex: String? = nil,
        type: String? = nil
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
        self.account = account
        self.accountType = accountType
        self.authIndex = authIndex
        self.type = type
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

    public static func apiCallURL(from baseURL: URL) -> URL {
        normalize(endpoint: baseURL, path: "/v0/management/api-call")
    }

    public static func apiKeysURL(from baseURL: URL) -> URL {
        normalize(endpoint: baseURL, path: "/v0/management/api-keys")
    }

    private static func normalize(endpoint: URL, path: String) -> URL {
        let baseString = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if baseString.hasSuffix(path) {
            return endpoint
        }
        return URL(string: "\(baseString)\(path)") ?? endpoint
    }

    private struct APICallPayload: Encodable {
        let authIndex: String?
        let method: String
        let url: String
        let header: [String: String]?
        let data: String?

        enum CodingKeys: String, CodingKey {
            case authIndex = "auth_index"
            case method
            case url
            case header
            case data
        }
    }

    private struct APICallResponse: Decodable {
        let statusCode: Int?
        let header: [String: [String]]?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case header
            case body
        }
    }

    private func executeAPICall(
        endpoint: URL,
        managementKey: String,
        payload: APICallPayload
    ) async throws -> APICallResponse {
        let url = Self.apiCallURL(from: endpoint)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CLIProxyAPIError.invalidResponse
        }
        return try JSONDecoder().decode(APICallResponse.self, from: data)
    }

    private func fetchAntigravityLiveQuota(
        file: CLIProxyAuthFile,
        endpoint: URL,
        managementKey: String
    ) async throws -> (quotas: [CodexQuotaWindow], limitReached: Bool, status: String, errorCode: String?)? {
        guard let authIndex = file.authIndex, !authIndex.isEmpty else { return nil }
        let project = file.projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projId = (project?.isEmpty == false) ? project! : "aicode-consumers"
        let dataString = "{\"project\":\"\(projId)\"}"

        let payload = APICallPayload(
            authIndex: authIndex,
            method: "POST",
            url: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            header: [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)"
            ],
            data: dataString
        )

        let resp = try await executeAPICall(endpoint: endpoint, managementKey: managementKey, payload: payload)
        guard let statusCode = resp.statusCode else { return nil }

        if statusCode == 401 || statusCode == 403 {
            return (quotas: [], limitReached: true, status: "invalid", errorCode: "auth_required")
        }
        if statusCode == 429 {
            return (quotas: [], limitReached: true, status: "rate_limited", errorCode: "rate_limit")
        }
        guard (200...299).contains(statusCode), let body = resp.body, let bodyData = body.data(using: .utf8) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else {
            return nil
        }

        var sessionRemaining: Double?
        var sessionReset: String?
        var weeklyRemaining: Double?
        var weeklyReset: String?

        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                let win = (bucket["window"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                guard let frac = bucket["remainingFraction"] as? Double else { continue }
                let pct = min(100, max(0, frac * 100))
                let rt = bucket["resetTime"] as? String
                if ["5h", "five-hour", "five_hour"].contains(win) {
                    if sessionRemaining == nil || pct < sessionRemaining! {
                        sessionRemaining = pct
                        sessionReset = rt
                    }
                } else if ["weekly", "week"].contains(win) {
                    if weeklyRemaining == nil || pct < weeklyRemaining! {
                        weeklyRemaining = pct
                        weeklyReset = rt
                    }
                }
            }
        }

        var windows: [CodexQuotaWindow] = []
        if let sRem = sessionRemaining {
            windows.append(CodexQuotaWindow(
                key: "session",
                used: 100 - sRem,
                total: 100,
                remaining: sRem,
                resetAt: sessionReset,
                unlimited: false
            ))
        }
        if let wRem = weeklyRemaining {
            windows.append(CodexQuotaWindow(
                key: "weekly",
                used: 100 - wRem,
                total: 100,
                remaining: wRem,
                resetAt: weeklyReset,
                unlimited: false
            ))
        }

        let isLimitReached = (sessionRemaining.map { $0 <= 0 } ?? false) || (weeklyRemaining.map { $0 <= 0 } ?? false)
        let status = isLimitReached ? "rate_limited" : "available"
        return (quotas: windows, limitReached: isLimitReached, status: status, errorCode: nil)
    }

    private func fetchCodexLiveQuota(
        file: CLIProxyAuthFile,
        endpoint: URL,
        managementKey: String
    ) async throws -> (quotas: [CodexQuotaWindow], plan: String?, resetCredits: Int, limitReached: Bool, status: String, errorCode: String?)? {
        guard let authIndex = file.authIndex, !authIndex.isEmpty else { return nil }
        let payload = APICallPayload(
            authIndex: authIndex,
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/usage",
            header: [
                "Authorization": "Bearer $TOKEN$",
                "User-Agent": "codex-tui/0.149.1"
            ],
            data: nil
        )

        let resp = try await executeAPICall(endpoint: endpoint, managementKey: managementKey, payload: payload)
        guard let statusCode = resp.statusCode else { return nil }

        if statusCode == 401 || statusCode == 403 {
            return (quotas: [], plan: nil, resetCredits: 0, limitReached: true, status: "invalid", errorCode: "auth_required")
        }
        if statusCode == 429 {
            return (quotas: [], plan: nil, resetCredits: 0, limitReached: true, status: "rate_limited", errorCode: "rate_limit")
        }
        guard (200...299).contains(statusCode), let body = resp.body, let bodyData = body.data(using: .utf8) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }

        let rawPlan = json["plan_type"] as? String
        let plan = rawPlan.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }

        var availableCredits = 0
        if let rc = json["rate_limit_reset_credits"] as? [String: Any],
           let count = rc["available_count"] as? Int {
            availableCredits = count
        }

        let rateLimit = json["rate_limit"] as? [String: Any]
        let explicitLimitReached = rateLimit?["limit_reached"] as? Bool ?? false

        var sessionWindow: CodexQuotaWindow?
        var weeklyWindow: CodexQuotaWindow?

        let windowKeys = ["primary_window", "secondary_window"]
        for wKey in windowKeys {
            guard let w = rateLimit?[wKey] as? [String: Any] else { continue }
            let usedPercent = (w["used_percent"] as? Double) ?? Double((w["used_percent"] as? Int) ?? 0)
            let winSec = (w["limit_window_seconds"] as? Int) ?? 0
            let remaining = max(0, min(100, 100 - usedPercent))

            var resetAtStr: String?
            if let resetAtSec = w["reset_at"] as? Double {
                let d = Date(timeIntervalSince1970: resetAtSec)
                resetAtStr = ISO8601DateFormatter().string(from: d)
            } else if let resetAtSec = w["reset_at"] as? Int {
                let d = Date(timeIntervalSince1970: TimeInterval(resetAtSec))
                resetAtStr = ISO8601DateFormatter().string(from: d)
            }

            if winSec <= 86400 && winSec > 0 {
                sessionWindow = CodexQuotaWindow(
                    key: "session",
                    used: usedPercent,
                    total: 100,
                    remaining: remaining,
                    resetAt: resetAtStr,
                    unlimited: false
                )
            } else if winSec > 86400 {
                weeklyWindow = CodexQuotaWindow(
                    key: "weekly",
                    used: usedPercent,
                    total: 100,
                    remaining: remaining,
                    resetAt: resetAtStr,
                    unlimited: false
                )
            }
        }

        var windows: [CodexQuotaWindow] = []
        if let sessionWindow {
            windows.append(sessionWindow)
        } else if weeklyWindow != nil {
            windows.append(CodexQuotaWindow(
                key: "session",
                used: 0,
                total: 100,
                remaining: 100,
                resetAt: nil,
                unlimited: true
            ))
        }

        if let weeklyWindow {
            windows.append(weeklyWindow)
        }

        let isExhausted = explicitLimitReached ||
            (sessionWindow.map { $0.remaining <= 0 } ?? false) ||
            (weeklyWindow.map { $0.remaining <= 0 } ?? false)
        let status = isExhausted ? "rate_limited" : "available"

        return (quotas: windows, plan: plan, resetCredits: availableCredits, limitReached: isExhausted, status: status, errorCode: nil)
    }

    private func fetchClaudeLiveQuota(
        file: CLIProxyAuthFile,
        endpoint: URL,
        managementKey: String
    ) async throws -> (quotas: [CodexQuotaWindow], limitReached: Bool, status: String, errorCode: String?)? {
        guard let authIndex = file.authIndex, !authIndex.isEmpty else { return nil }
        let payload = APICallPayload(
            authIndex: authIndex,
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/usage",
            header: [
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20"
            ],
            data: nil
        )

        let resp = try await executeAPICall(endpoint: endpoint, managementKey: managementKey, payload: payload)
        guard let statusCode = resp.statusCode else { return nil }

        if statusCode == 401 || statusCode == 403 {
            return (quotas: [], limitReached: true, status: "invalid", errorCode: "auth_required")
        }
        guard (200...299).contains(statusCode), let body = resp.body, let bodyData = body.data(using: .utf8) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }

        var windows: [CodexQuotaWindow] = []
        if let fiveHour = json["five_hour"] as? [String: Any],
           let util = (fiveHour["utilization"] as? Double) ?? (fiveHour["utilization"] as? Int).map(Double.init) {
            let rem = max(0, min(100, 100 - util))
            let reset = fiveHour["resets_at"] as? String
            windows.append(CodexQuotaWindow(key: "session", used: util, total: 100, remaining: rem, resetAt: reset, unlimited: false))
        }
        if let sevenDay = json["seven_day"] as? [String: Any],
           let util = (sevenDay["utilization"] as? Double) ?? (sevenDay["utilization"] as? Int).map(Double.init) {
            let rem = max(0, min(100, 100 - util))
            let reset = sevenDay["resets_at"] as? String
            windows.append(CodexQuotaWindow(key: "weekly", used: util, total: 100, remaining: rem, resetAt: reset, unlimited: false))
        }

        let isLimitReached = windows.contains { $0.remaining <= 0 }
        let status = isLimitReached ? "rate_limited" : "available"
        return (quotas: windows, limitReached: isLimitReached, status: status, errorCode: nil)
    }

    private func resolveAccount(
        file: CLIProxyAuthFile,
        endpoint: URL,
        managementKey: String
    ) async -> CodexQuotaAccount {
        let baseAccount = Self.mapToAccount(file)
        guard file.disabled != true, let authIndex = file.authIndex, !authIndex.isEmpty else {
            return baseAccount
        }

        let provider = baseAccount.provider.lowercased()
        let name = file.name.lowercased()

        do {
            if provider == "antigravity" || name.contains("antigravity") || name.contains("gemini") {
                if let live = try await fetchAntigravityLiveQuota(file: file, endpoint: endpoint, managementKey: managementKey) {
                    return CodexQuotaAccount(
                        id: baseAccount.id,
                        provider: baseAccount.provider,
                        label: baseAccount.label,
                        plan: baseAccount.plan,
                        limitReached: baseAccount.limitReached || live.limitReached,
                        quotas: live.quotas.isEmpty ? baseAccount.quotas : live.quotas,
                        resetCredits: baseAccount.resetCredits,
                        status: live.errorCode != nil ? "invalid" : (baseAccount.limitReached || live.limitReached ? "rate_limited" : live.status),
                        errorCode: live.errorCode ?? baseAccount.errorCode,
                        isActive: baseAccount.isActive
                    )
                }
            } else if provider == "codex" || name.contains("codex") || name.contains("chatgpt") || name.contains("openai") {
                if let live = try await fetchCodexLiveQuota(file: file, endpoint: endpoint, managementKey: managementKey) {
                    return CodexQuotaAccount(
                        id: baseAccount.id,
                        provider: baseAccount.provider,
                        label: baseAccount.label,
                        plan: live.plan ?? baseAccount.plan,
                        limitReached: baseAccount.limitReached || live.limitReached,
                        quotas: live.quotas.isEmpty ? baseAccount.quotas : live.quotas,
                        resetCredits: CodexQuotaAccount.ResetCredits(availableCount: live.resetCredits),
                        status: live.errorCode != nil ? "invalid" : (baseAccount.limitReached || live.limitReached ? "rate_limited" : live.status),
                        errorCode: live.errorCode ?? baseAccount.errorCode,
                        isActive: baseAccount.isActive
                    )
                }
            } else if provider == "claude" || name.contains("claude") {
                if let live = try await fetchClaudeLiveQuota(file: file, endpoint: endpoint, managementKey: managementKey) {
                    return CodexQuotaAccount(
                        id: baseAccount.id,
                        provider: baseAccount.provider,
                        label: baseAccount.label,
                        plan: baseAccount.plan,
                        limitReached: baseAccount.limitReached || live.limitReached,
                        quotas: live.quotas.isEmpty ? baseAccount.quotas : live.quotas,
                        resetCredits: baseAccount.resetCredits,
                        status: live.errorCode != nil ? "invalid" : (baseAccount.limitReached || live.limitReached ? "rate_limited" : live.status),
                        errorCode: live.errorCode ?? baseAccount.errorCode,
                        isActive: baseAccount.isActive
                    )
                }
            }
        } catch {
            // Keep baseAccount on error
        }

        return baseAccount
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

        return await withTaskGroup(of: CodexQuotaAccount.self) { group in
            for file in decoded.files {
                group.addTask {
                    await self.resolveAccount(file: file, endpoint: endpoint, managementKey: trimmedKey)
                }
            }
            var accounts: [CodexQuotaAccount] = []
            for await account in group {
                accounts.append(account)
            }
            let fileOrder = Dictionary(uniqueKeysWithValues: decoded.files.enumerated().map { ($0.element.name, $0.offset) })
            return accounts.sorted { (fileOrder[$0.id] ?? 0) < (fileOrder[$1.id] ?? 0) }
        }
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

    public func fetchAPIKeys(
        endpoint: URL,
        managementKey: String
    ) async throws -> [String] {
        let url = Self.apiKeysURL(from: endpoint)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyAPIError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            struct ResponseWrapper: Decodable {
                let apiKeys: [String]?
                enum CodingKeys: String, CodingKey {
                    case apiKeys = "api-keys"
                }
            }
            let decoded = try JSONDecoder().decode(ResponseWrapper.self, from: data)
            return decoded.apiKeys?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        case 401, 403:
            throw CLIProxyAPIError.unauthorized
        case 404:
            return []
        default:
            throw CLIProxyAPIError.serverError(http.statusCode)
        }
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
