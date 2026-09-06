import Foundation

public struct NineRouterCredentialFile: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct CLIProxyAccountImportResult: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let index: Int
        public let status: String
        public let reason: String?

        public init(index: Int, status: String, reason: String? = nil) {
            self.index = index
            self.status = status
            self.reason = reason
        }
    }

    public let importedCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let results: [Item]

    public init(
        importedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        results: [Item]
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.results = results
    }
}

public typealias NineRouterAccountImportResult = CLIProxyAccountImportResult

public enum CLIProxyAccountImportError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case unauthorized
    case noFiles
    case fileTooLarge(String)
    case invalidJSON(String)
    case invalidResponse
    case serverError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "Account import is available for CLI Proxy API providers."
        case .unauthorized:
            return "The management key cannot import accounts into this CLI Proxy API."
        case .noFiles:
            return "Select at least one account JSON file."
        case let .fileTooLarge(name):
            return "\(name) is too large to be an account credential file."
        case let .invalidJSON(name):
            return "\(name) is not a valid account JSON file."
        case .invalidResponse:
            return "Invalid response from CLI Proxy API server."
        case let .serverError(code, message):
            if let message, !message.isEmpty {
                return "\(message) (HTTP \(code))"
            }
            return "CLI Proxy API server error (HTTP \(code))."
        }
    }
}

public typealias NineRouterAccountImportError = CLIProxyAccountImportError

public final class CLIProxyAccountImportService: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func importFiles(
        _ urls: [URL],
        provider: CustomQuotaProvider
    ) async throws -> CLIProxyAccountImportResult {
        guard !urls.isEmpty else { throw CLIProxyAccountImportError.noFiles }
        guard let endpoint = try? RouterEndpoint.normalizedURL(from: provider.endpoint) else {
            throw CLIProxyAccountImportError.invalidResponse
        }
        let key = provider.effectiveManagementKey
        let cliService = CLIProxyAPIService(session: session)

        var imported = 0
        var failed = 0
        var results: [CLIProxyAccountImportResult.Item] = []

        for (index, url) in urls.enumerated() {
            do {
                try await cliService.uploadAuthFile(fileURL: url, endpoint: endpoint, managementKey: key)
                imported += 1
                results.append(CLIProxyAccountImportResult.Item(index: index, status: "imported"))
            } catch {
                failed += 1
                results.append(CLIProxyAccountImportResult.Item(index: index, status: "failed", reason: error.localizedDescription))
            }
        }

        return CLIProxyAccountImportResult(
            importedCount: imported,
            skippedCount: 0,
            failedCount: failed,
            results: results
        )
    }

    public func importFiles(
        _ files: [NineRouterCredentialFile],
        provider: CustomQuotaProvider
    ) async throws -> CLIProxyAccountImportResult {
        guard !files.isEmpty else { throw CLIProxyAccountImportError.noFiles }
        // Write temp files to upload
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cliproxy_import_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var urls: [URL] = []
        for file in files {
            let fileURL = tempDir.appendingPathComponent(file.name)
            try file.data.write(to: fileURL)
            urls.append(fileURL)
        }

        return try await importFiles(urls, provider: provider)
    }
}

public typealias NineRouterAccountImportService = CLIProxyAccountImportService
