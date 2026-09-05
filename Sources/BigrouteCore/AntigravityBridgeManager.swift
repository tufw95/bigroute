import Foundation
import OSLog

public enum AntigravityModelMode: String, Codable, CaseIterable, Sendable {
    case keepOfficial = "keep_official"
    case custom = "custom"

    public var title: String {
        switch self {
        case .keepOfficial: "Keep Official Models (Auto-mapped to 9Router)"
        case .custom: "Custom Models"
        }
    }
}

public struct AntigravityBridgeConfig: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var modelMode: AntigravityModelMode
    public var customModelsText: String

    public init(
        isEnabled: Bool = false,
        modelMode: AntigravityModelMode = .keepOfficial,
        customModelsText: String = "cx/gpt-5.6-sol, ag/gemini-3.8-flash-high, cx/gpt-5.5, ag/claude-sonnet-4-6"
    ) {
        self.isEnabled = isEnabled
        self.modelMode = modelMode
        self.customModelsText = customModelsText
    }
}

public final class AntigravityBridgeManager: @unchecked Sendable {
    public static let shared = AntigravityBridgeManager()

    private static let logger = Logger(subsystem: "com.routerquota.app", category: "AntigravityBridge")

    private let geminiDir: URL
    private let endpointFileURL: URL
    private let configJsonURL: URL
    private let proxyScriptURL: URL
    private var proxyProcess: Process?

    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        geminiDir = home.appending(path: ".gemini/antigravity", directoryHint: .isDirectory)
        endpointFileURL = geminiDir.appending(path: "cloud_code_endpoint.txt")
        configJsonURL = geminiDir.appending(path: "bridge_config.json")
        proxyScriptURL = geminiDir.appending(path: "bridge-proxy/antigravity-bridge-proxy.mjs", directoryHint: .notDirectory)
    }

    public var isCurrentlyPointedToBridge: Bool {
        guard let content = try? String(contentsOf: endpointFileURL, encoding: .utf8) else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).contains("127.0.0.1:50999")
            || content.trimmingCharacters(in: .whitespacesAndNewlines).contains("localhost:50999")
    }

    public func checkHealth(timeout: TimeInterval = 1.5) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:50999/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return payload["status"] as? String == "ok"
                && payload["proxy"] as? String == "antigravity-9router-bridge"
        } catch {
            return false
        }
    }

    @discardableResult
    public func ensureBridgeScriptInstalled() throws -> Bool {
        let bundledURL = resourceBundle.url(
            forResource: "antigravity-bridge-proxy",
            withExtension: "mjs",
            subdirectory: "Resources"
        ) ?? resourceBundle.url(forResource: "antigravity-bridge-proxy", withExtension: "mjs")
        guard let bundledURL else {
            throw NSError(domain: "AntigravityBridge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Bundled Antigravity bridge proxy is missing."
            ])
        }
        let proxyDir = proxyScriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let source = try Data(contentsOf: bundledURL)
        if FileManager.default.fileExists(atPath: proxyScriptURL.path),
           try Data(contentsOf: proxyScriptURL) == source {
            return false
        }
        try source.write(to: proxyScriptURL, options: Data.WritingOptions.atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxyScriptURL.path)
        return true
    }

    public func saveBridgeConfig(
        nineRouterUrl: String,
        apiKey: String,
        modelMode: AntigravityModelMode,
        customModelsText: String
    ) throws {
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let parsedCustomModels = customModelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ["id": $0, "name": $0, "contextWindow": 200_000] as [String: Any] }
        let config: [String: Any] = [
            "nineRouterUrl": nineRouterUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "https://9router.bigroll.vn" : nineRouterUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            "apiKey": apiKey,
            "modelMode": modelMode.rawValue,
            "customModels": parsedCustomModels
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configJsonURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configJsonURL.path)
    }

    private func nodePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    @discardableResult
    public func startProxy() async throws -> Bool {
        let scriptUpdated = try ensureBridgeScriptInstalled()
        Self.logger.info("Starting Antigravity bridge proxy; scriptUpdated=\(scriptUpdated, privacy: .public)")
        if !scriptUpdated, await checkHealth(timeout: 0.25) {
            try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
            try "http://127.0.0.1:50999".write(to: endpointFileURL, atomically: true, encoding: .utf8)
            return false
        }
        stopProxy()
        guard let node = nodePath() else {
            throw NSError(domain: "AntigravityBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Node.js binary not found. Install Node.js and try again."
            ])
        }
        Self.logger.info("Launching Antigravity bridge proxy with Node at \(node, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [proxyScriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        proxyProcess = process

        // The proxy is local; short polling keeps a failed toggle responsive
        // while still allowing Node a moment to initialize.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(200))
            if await checkHealth(timeout: 0.5) {
                try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
                try "http://127.0.0.1:50999".write(to: endpointFileURL, atomically: true, encoding: .utf8)
                Self.logger.info("Antigravity bridge proxy started")
                return true
            }
        }
        stopProxy()
        try? "https://daily-cloudcode-pa.googleapis.com".write(
            to: endpointFileURL,
            atomically: true,
            encoding: .utf8
        )
        throw NSError(domain: "AntigravityBridge", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Antigravity bridge proxy did not become healthy on port 50999."
        ])
    }

    public func restoreBridgeForStartup() async throws {
        let didStartProxy = try await startProxy()
        if didStartProxy, isProcessRunning(named: "Antigravity") {
            await relaunchAntigravityApp()
        }
    }

    public func stopProxy() {
        proxyProcess?.terminate()
        proxyProcess = nil
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", proxyScriptURL.path]
        try? kill.run()
        kill.waitUntilExit()
    }

    public func restoreOfficialEndpoint() {
        try? "https://daily-cloudcode-pa.googleapis.com".write(
            to: endpointFileURL,
            atomically: true,
            encoding: .utf8
        )
    }

    public func relaunchAntigravityApp() async {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-x", "Antigravity"]
        try? kill.run()
        kill.waitUntilExit()
        for _ in 0..<20 {
            if !isProcessRunning(named: "Antigravity") { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "/Applications/Antigravity.app"]
        try? open.run()
    }

    private func isProcessRunning(named name: String) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-x", name]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do {
            try check.run()
            check.waitUntilExit()
            return check.terminationStatus == 0
        } catch {
            return false
        }
    }

    public func setBridgeEnabled(
        _ enabled: Bool,
        nineRouterUrl: String,
        apiKey: String,
        modelMode: AntigravityModelMode,
        customModelsText: String
    ) async throws {
        try saveBridgeConfig(
            nineRouterUrl: nineRouterUrl,
            apiKey: apiKey,
            modelMode: modelMode,
            customModelsText: customModelsText
        )
        if enabled {
            try await startProxy()
        } else {
            try "https://daily-cloudcode-pa.googleapis.com".write(to: endpointFileURL, atomically: true, encoding: .utf8)
            stopProxy()
        }
        await relaunchAntigravityApp()
    }
}
