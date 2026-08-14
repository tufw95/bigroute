import Foundation

public struct NineRouterCredentialFile: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct NineRouterAccountImportResult: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let index: Int
        public let status: String
        public let reason: String?
    }

    public let importedCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let results: [Item]
}

public enum NineRouterAccountImportError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case unauthorized
    case noFiles
    case tooManyFiles(Int)
    case fileTooLarge(String)
    case selectionTooLarge
    case invalidJSON(String)
    case noAccounts(String)
    case tooManyAccounts(Int)
    case missingAccessToken(String)
    case credentialTooLarge(String)
    case duplicateAccount
    case invalidResponse
    case serverError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "Account import is available only for providers configured as 9Router."
        case .unauthorized:
            return "The saved API key cannot import accounts into this 9Router."
        case .noFiles:
            return "Select at least one ChatGPT account JSON file."
        case let .tooManyFiles(limit):
            return "Select no more than \(limit) JSON files at once."
        case let .fileTooLarge(name):
            return "\(name) is too large to be an account credential file."
        case .selectionTooLarge:
            return "The selected credential files are too large to import in one request."
        case let .invalidJSON(name):
            return "\(name) is not a valid account JSON file."
        case let .noAccounts(name):
            return "No account credentials were found in \(name)."
        case let .tooManyAccounts(limit):
            return "Import no more than \(limit) accounts at once."
        case let .missingAccessToken(name):
            return "\(name) does not contain an access token."
        case let .credentialTooLarge(name):
            return "\(name) contains a credential value that is unexpectedly large."
        case .duplicateAccount:
            return "The selected files contain the same account more than once."
        case .invalidResponse:
            return "9Router returned an invalid account import response."
        case let .serverError(status, message):
            return message ?? "9Router could not import the accounts (HTTP \(status))."
        }
    }
}

public enum NineRouterAccountImportParser {
    public static let maximumFileCount = 100
    public static let maximumAccountCount = 100
    public static let maximumFileBytes = 128 * 1024
    public static let maximumSelectionBytes = 1024 * 1024
    private static let maximumCredentialCharacters = 128 * 1024

    public static func parse(files: [NineRouterCredentialFile]) throws -> [NineRouterImportAccount] {
        guard !files.isEmpty else { throw NineRouterAccountImportError.noFiles }
        guard files.count <= maximumFileCount else {
            throw NineRouterAccountImportError.tooManyFiles(maximumFileCount)
        }

        var totalBytes = 0
        var accounts: [NineRouterImportAccount] = []
        for file in files {
            guard file.data.count <= maximumFileBytes else {
                throw NineRouterAccountImportError.fileTooLarge(file.name)
            }
            totalBytes += file.data.count
            guard totalBytes <= maximumSelectionBytes else {
                throw NineRouterAccountImportError.selectionTooLarge
            }

            let rawAccounts = try accountObjects(in: file)
            for rawAccount in rawAccounts {
                accounts.append(try normalize(rawAccount, sourceName: file.name))
                guard accounts.count <= maximumAccountCount else {
                    throw NineRouterAccountImportError.tooManyAccounts(maximumAccountCount)
                }
            }
        }

        guard !accounts.isEmpty else {
            throw NineRouterAccountImportError.noFiles
        }
        for index in accounts.indices {
            if accounts[..<index].contains(where: { isDuplicate(accounts[index], $0) }) {
                throw NineRouterAccountImportError.duplicateAccount
            }
        }
        return accounts
    }

    private static func accountObjects(in file: NineRouterCredentialFile) throws -> [[String: Any]] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: file.data)
        } catch {
            throw NineRouterAccountImportError.invalidJSON(file.name)
        }

        if let accounts = object as? [[String: Any]], !accounts.isEmpty {
            return accounts
        }
        if let wrapper = object as? [String: Any],
           let accounts = wrapper["accounts"] as? [[String: Any]],
           !accounts.isEmpty {
            return accounts
        }
        if let account = object as? [String: Any] {
            return [account]
        }
        throw NineRouterAccountImportError.noAccounts(file.name)
    }

    private static func normalize(
        _ object: [String: Any],
        sourceName: String
    ) throws -> NineRouterImportAccount {
        guard let accessToken = string(in: object, keys: ["accessToken", "access_token"]),
              !accessToken.isEmpty else {
            throw NineRouterAccountImportError.missingAccessToken(sourceName)
        }

        let providerData = object["providerSpecificData"] as? [String: Any]
        let account = NineRouterImportAccount(
            name: string(in: object, keys: ["name", "nickname", "displayName", "display_name"]),
            email: string(in: object, keys: ["email"]),
            accountID: string(in: object, keys: ["accountId", "account_id"])
                ?? providerData.flatMap { string(in: $0, keys: ["chatgptAccountId", "chatgpt_account_id"]) },
            accessToken: accessToken,
            refreshToken: string(in: object, keys: ["refreshToken", "refresh_token"]),
            idToken: string(in: object, keys: ["idToken", "id_token"]),
            expiresAt: string(in: object, keys: ["expiresAt", "expires_at"]),
            expiresIn: integer(in: object, keys: ["expiresIn", "expires_in"]),
            tokenType: string(in: object, keys: ["tokenType", "token_type"]),
            scope: string(in: object, keys: ["scope"])
        )

        let credentials = [account.accessToken, account.refreshToken, account.idToken].compactMap { $0 }
        guard credentials.allSatisfy({ $0.count <= maximumCredentialCharacters }) else {
            throw NineRouterAccountImportError.credentialTooLarge(sourceName)
        }
        return account
    }

    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func integer(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func isDuplicate(
        _ left: NineRouterImportAccount,
        _ right: NineRouterImportAccount
    ) -> Bool {
        if left.accessToken == right.accessToken { return true }
        if let leftID = left.accountID, let rightID = right.accountID {
            return leftID == rightID
        }
        if let leftEmail = left.email?.lowercased(), let rightEmail = right.email?.lowercased() {
            return leftEmail == rightEmail
        }
        return false
    }
}

public struct NineRouterImportAccount: Encodable, Equatable, Sendable {
    public let name: String?
    public let email: String?
    public let accountID: String?
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresAt: String?
    public let expiresIn: Int?
    public let tokenType: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case name
        case email
        case accountID = "accountId"
        case accessToken
        case refreshToken
        case idToken
        case expiresAt
        case expiresIn
        case tokenType
        case scope
    }
}

public final class NineRouterAccountImportService: @unchecked Sendable {
    private struct RequestBody: Encodable {
        let operation = "bulk_import_codex"
        let accounts: [NineRouterImportAccount]
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func importFiles(
        _ urls: [URL],
        provider: CustomQuotaProvider
    ) async throws -> NineRouterAccountImportResult {
        guard !urls.isEmpty else { throw NineRouterAccountImportError.noFiles }
        guard urls.count <= NineRouterAccountImportParser.maximumFileCount else {
            throw NineRouterAccountImportError.tooManyFiles(
                NineRouterAccountImportParser.maximumFileCount
            )
        }

        var files: [NineRouterCredentialFile] = []
        files.reserveCapacity(urls.count)
        var totalBytes = 0

        for url in urls {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

            let name = url.lastPathComponent
            if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                guard fileSize <= NineRouterAccountImportParser.maximumFileBytes else {
                    throw NineRouterAccountImportError.fileTooLarge(name)
                }
                guard fileSize <= NineRouterAccountImportParser.maximumSelectionBytes - totalBytes else {
                    throw NineRouterAccountImportError.selectionTooLarge
                }
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try readBounded(
                from: handle,
                maximumBytes: NineRouterAccountImportParser.maximumFileBytes
            )
            guard data.count <= NineRouterAccountImportParser.maximumFileBytes else {
                throw NineRouterAccountImportError.fileTooLarge(name)
            }
            totalBytes += data.count
            guard totalBytes <= NineRouterAccountImportParser.maximumSelectionBytes else {
                throw NineRouterAccountImportError.selectionTooLarge
            }
            files.append(NineRouterCredentialFile(name: name, data: data))
        }
        return try await importFiles(files, provider: provider)
    }

    public func importFiles(
        _ files: [NineRouterCredentialFile],
        provider: CustomQuotaProvider
    ) async throws -> NineRouterAccountImportResult {
        guard provider.apiKind == .nineRouter else {
            throw NineRouterAccountImportError.unsupportedProvider
        }
        guard !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NineRouterAccountImportError.unauthorized
        }

        let accounts = try NineRouterAccountImportParser.parse(files: files)
        let baseURL = try RouterEndpoint.normalizedURL(from: provider.endpoint)
        var request = URLRequest(
            url: QuotaService.quotaURL(from: baseURL),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(RequestBody(accounts: accounts))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NineRouterAccountImportError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(NineRouterAccountImportResult.self, from: data)
            } catch {
                throw NineRouterAccountImportError.invalidResponse
            }
        case 401, 403:
            throw NineRouterAccountImportError.unauthorized
        default:
            let message = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            throw NineRouterAccountImportError.serverError(http.statusCode, message ?? nil)
        }
    }

    private func readBounded(from handle: FileHandle, maximumBytes: Int) throws -> Data {
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }
}
