import AppKit
import CryptoKit
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

public actor AntigravityBridgeManager {
    public static let shared = AntigravityBridgeManager()

    private static let logger = Logger(subsystem: "com.routerquota.app", category: "AntigravityBridge")

    private let geminiDir: URL
    private let endpointFileURL: URL
    private let configJsonURL: URL
    private let proxyScriptURL: URL
    private let patcherScriptURL: URL
    private var proxyProcess: Process?
    private var startTask: Task<Bool, Error>?
    private var isSwitching = false
    private let endpointBackupURL: URL

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
        endpointBackupURL = geminiDir.appending(path: "bridge-proxy/previous-endpoint.json")
        configJsonURL = geminiDir.appending(path: "bridge_config.json")
        proxyScriptURL = geminiDir.appending(path: "bridge-proxy/antigravity-bridge-proxy.mjs", directoryHint: .notDirectory)
        patcherScriptURL = geminiDir.appending(path: "bridge-proxy/antigravity-asar-patcher.mjs", directoryHint: .notDirectory)
    }

    public nonisolated var isCurrentlyPointedToBridge: Bool {
        guard let content = try? String(contentsOf: endpointFileURL, encoding: .utf8) else { return false }
        return Self.isBridgeEndpoint(content)
    }

    public nonisolated static func isBridgeEndpoint(_ content: String) -> Bool {
        guard let url = URL(string: content.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme == "http" && RouterEndpoint.isLoopbackHost(url.host ?? "") && url.port == 50999
            && url.user == nil && url.password == nil
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    public func checkHealth(timeout: TimeInterval = 1.5, scriptHash: String? = nil) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:50999/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return payload["status"] as? String == "ok"
                && payload["proxy"] as? String == "antigravity-9router-bridge"
                && (scriptHash == nil || payload["scriptHash"] as? String == scriptHash)
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

    @discardableResult
    public func ensurePatcherScriptInstalled() throws -> Bool {
        let bundledURL = resourceBundle.url(
            forResource: "antigravity-asar-patcher",
            withExtension: "mjs",
            subdirectory: "Resources"
        ) ?? resourceBundle.url(forResource: "antigravity-asar-patcher", withExtension: "mjs")
        guard let bundledURL else {
            throw NSError(domain: "AntigravityBridge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Bundled Antigravity ASAR patcher is missing."
            ])
        }
        let proxyDir = patcherScriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        let source = try Data(contentsOf: bundledURL)
        if FileManager.default.fileExists(atPath: patcherScriptURL.path),
           try Data(contentsOf: patcherScriptURL) == source {
            return false
        }
        try source.write(to: patcherScriptURL, options: Data.WritingOptions.atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: patcherScriptURL.path)
        return true
    }

    public func checkAntigravityPatchStatus() async -> (appExists: Bool, isPatched: Bool) {
        guard let node = nodePath() else { return (false, false) }
        do {
            _ = try ensurePatcherScriptInstalled()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [patcherScriptURL.path, "check"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let appExists = obj["appExists"] as? Bool,
               let isPatched = obj["isPatched"] as? Bool,
               let integrityMatches = obj["integrityMatches"] as? Bool {
                return (appExists, isPatched && integrityMatches)
            }
        } catch {
            Self.logger.error("Error checking patch status: \(error.localizedDescription)")
        }
        return (false, false)
    }

    @discardableResult
    public func patchAntigravityIfNeeded() async throws -> Bool {
        guard let node = nodePath() else {
            throw NSError(domain: "AntigravityBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Node.js binary not found. Install Node.js and try again."
            ])
        }
        _ = try ensurePatcherScriptInstalled()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [patcherScriptURL.path, "patch"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "AntigravityBridge", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Could not patch Antigravity: \(msg)"
            ])
        }
        Self.logger.info("Antigravity app verified and patched successfully for bridge")
        return true
    }

    public func saveBridgeConfig(
        nineRouterUrl: String,
        apiKey: String,
        modelMode: AntigravityModelMode,
        customModelsText: String
    ) throws {
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let safeURL = try RouterEndpoint.normalizedURL(from: nineRouterUrl)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError("Choose an enabled 9Router provider with an API key before enabling the bridge.")
        }
        let parsedCustomModels = customModelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ["id": $0, "name": $0, "contextWindow": 200_000] as [String: Any] }
        if modelMode == .custom && (parsedCustomModels.isEmpty || parsedCustomModels.count > 200) {
            throw BridgeError("Enter between 1 and 200 custom model IDs.")
        }
        let ids = parsedCustomModels.compactMap { $0["id"] as? String }
        guard Set(ids).count == ids.count else { throw BridgeError("Custom model IDs must be unique.") }
        let config: [String: Any] = [
            "nineRouterUrl": safeURL.absoluteString,
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
        var candidates = [
            "\(home)/.local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.local/share/mise/shims/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/node" }
        let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? []
        candidates += versions.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appending(path: "bin/node").path }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    @discardableResult
    public func startProxy() async throws -> Bool {
        if let startTask { return try await startTask.value }
        let task = Task {
            do { return try await self.launchProxy() }
            catch {
                try? self.restoreOfficialEndpoint()
                throw error
            }
        }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    private func launchProxy() async throws -> Bool {
        _ = try? ensurePatcherScriptInstalled()
        _ = try? await patchAntigravityIfNeeded()
        let scriptUpdated = try ensureBridgeScriptInstalled()
        let scriptHash = SHA256.hash(data: try Data(contentsOf: proxyScriptURL)).map { String(format: "%02x", $0) }.joined()
        Self.logger.info("Starting Antigravity bridge proxy; scriptUpdated=\(scriptUpdated, privacy: .public)")
        if await checkHealth(timeout: 0.25, scriptHash: scriptHash) {
            try pointToBridge()
            return false
        }
        stopProxy()
        for _ in 0..<20 {
            if !(await checkHealth(timeout: 0.1)) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
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
            if !process.isRunning { break }
            if await checkHealth(timeout: 0.5, scriptHash: scriptHash) {
                try pointToBridge()
                Self.logger.info("Antigravity bridge proxy started")
                return true
            }
        }
        stopProxy()
        try? restoreOfficialEndpoint()
        throw NSError(domain: "AntigravityBridge", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Antigravity bridge proxy did not become healthy on port 50999."
        ])
    }

    public func restoreBridgeForStartup() async throws {
        // A Bigroute OTA/relaunch must never terminate the remote user's IDE.
        _ = try? await patchAntigravityIfNeeded()
        _ = try await startProxy()
    }

    public func validateAntigravityConnection() async throws {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        lookup.arguments = ["-f", "^/Applications/Antigravity\\.app/Contents/Resources/bin/language_server( |$)"]
        let ids = Pipe()
        lookup.standardOutput = ids
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        let data = ids.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()
        let pids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        guard !pids.isEmpty else { return }
        let inspect = Process()
        inspect.executableURL = URL(fileURLWithPath: "/bin/ps")
        inspect.arguments = ["-p", pids.map(String.init).joined(separator: ","), "-o", "args="]
        let output = Pipe()
        inspect.standardOutput = output
        inspect.standardError = FileHandle.nullDevice
        try inspect.run()
        let arguments = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        inspect.waitUntilExit()
        let endpoints = arguments.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if let flag = words.firstIndex(of: "--cloud_code_endpoint"), words.indices.contains(flag + 1) {
                return words[flag + 1]
            }
            return words.first(where: { $0.hasPrefix("--cloud_code_endpoint=") })
                .map { String($0.dropFirst("--cloud_code_endpoint=".count)) }
        }
        guard endpoints.count == pids.count, endpoints.allSatisfy(Self.isBridgeEndpoint) else {
            let patchStatus = await checkAntigravityPatchStatus()
            if patchStatus.appExists && !patchStatus.isPatched {
                _ = try? await patchAntigravityIfNeeded()
                throw BridgeError("Antigravity was updated. Bigroute has automatically re-applied the bridge patch. Please restart Antigravity to apply.")
            }
            throw BridgeError("Antigravity is using its official endpoint. Relaunch Antigravity to apply the bridge settings.")
        }
    }

    public func stopProxy() {
        if proxyProcess?.isRunning == true { proxyProcess?.terminate() }
        proxyProcess = nil
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // Match only this installed script, including after a Bigroute relaunch.
        stop.arguments = ["-f", NSRegularExpression.escapedPattern(for: proxyScriptURL.path) + "$" ]
        stop.standardOutput = FileHandle.nullDevice
        stop.standardError = FileHandle.nullDevice
        do { try stop.run(); stop.waitUntilExit() } catch { Self.logger.error("Could not stop bridge process") }
    }

    private struct PreviousEndpoint: Codable { let content: String? }

    private func pointToBridge() throws {
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        if !isCurrentlyPointedToBridge {
            let content = try? String(contentsOf: endpointFileURL, encoding: .utf8)
            let data = try JSONEncoder().encode(PreviousEndpoint(content: content))
            try data.write(to: endpointBackupURL, options: .atomic)
        }
        try "http://127.0.0.1:50999".write(to: endpointFileURL, atomically: true, encoding: .utf8)
    }

    public func restoreOfficialEndpoint() throws {
        guard isCurrentlyPointedToBridge else { return }
        let previous = (try? Data(contentsOf: endpointBackupURL)).flatMap { try? JSONDecoder().decode(PreviousEndpoint.self, from: $0) }
        if let content = previous?.content {
            try content.write(to: endpointFileURL, atomically: true, encoding: .utf8)
        } else {
            // Let Antigravity choose its current official default after updates.
            try FileManager.default.removeItem(at: endpointFileURL)
        }
    }

    @MainActor
    public func relaunchAntigravityApp() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/Antigravity.app")
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == appURL }
        for app in running {
            guard app.terminate() else { throw BridgeError("Antigravity could not quit. Save your work and restart it to apply the bridge settings.") }
        }
        for _ in 0..<100 {
            if running.allSatisfy(\.isTerminated) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard running.allSatisfy(\.isTerminated) else {
            throw BridgeError("Antigravity is still closing. Save your work and restart it to apply the bridge settings.")
        }
        _ = try? await patchAntigravityIfNeeded()
        let options = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: options)
    }

    public func setBridgeEnabled(
        _ enabled: Bool,
        nineRouterUrl: String,
        apiKey: String,
        modelMode: AntigravityModelMode,
        customModelsText: String
    ) async throws {
        guard !isSwitching else { throw BridgeError("A bridge change is already in progress.") }
        isSwitching = true
        defer { isSwitching = false }
        if let startTask { _ = try? await startTask.value }
        if enabled {
            try saveBridgeConfig(nineRouterUrl: nineRouterUrl, apiKey: apiKey, modelMode: modelMode, customModelsText: customModelsText)
            _ = try? await patchAntigravityIfNeeded()
            try await startProxy()
        } else {
            try restoreOfficialEndpoint()
            stopProxy()
            if FileManager.default.fileExists(atPath: configJsonURL.path) {
                try FileManager.default.removeItem(at: configJsonURL)
            }
        }
    }
}

private struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
