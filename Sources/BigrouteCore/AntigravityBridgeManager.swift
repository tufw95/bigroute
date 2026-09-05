import Foundation
import OSLog
#if canImport(AppKit)
import AppKit
#endif

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

    private static let logger = Logger(
        subsystem: "com.routerquota.app",
        category: "AntigravityBridge"
    )

    private let geminiDir: URL
    private let endpointFileURL: URL
    private let configJsonURL: URL
    private let proxyScriptURL: URL
    private var proxyProcess: Process?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.geminiDir = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        self.endpointFileURL = geminiDir.appendingPathComponent("cloud_code_endpoint.txt")
        self.configJsonURL = geminiDir.appendingPathComponent("bridge_config.json")
        self.proxyScriptURL = geminiDir.appendingPathComponent("bridge-proxy/antigravity-bridge-proxy.mjs")
    }

    public var isCurrentlyPointedToBridge: Bool {
        guard FileManager.default.fileExists(atPath: endpointFileURL.path) else { return false }
        let content = (try? String(contentsOf: endpointFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return content.contains("127.0.0.1:50999") || content.contains("localhost:50999")
    }

    public func checkHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:50999/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            return String(data: data, encoding: .utf8)?.contains("ok") == true
        } catch {
            return false
        }
    }

    public func ensureBridgeScriptInstalled() throws {
        let proxyDir = proxyScriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)

        let scriptContent = """
        #!/usr/bin/env node
        /**
         * Antigravity 9Router Bridge Proxy
         */
        import http from 'http';
        import https from 'https';
        import fs from 'fs';
        import path from 'path';
        import os from 'os';

        const PORT = 50999;
        const GOOGLE_UPSTREAM = 'https://daily-cloudcode-pa.googleapis.com';
        const CONFIG_PATH = path.join(os.homedir(), '.gemini', 'antigravity', 'bridge_config.json');

        function loadConfig() {
          try {
            if (fs.existsSync(CONFIG_PATH)) {
              return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
            }
          } catch (err) {
            console.error('[Bridge] Failed to read config:', err.message);
          }
          return { nineRouterUrl: 'https://9router.bigroll.vn', apiKey: '', modelMode: 'keep_official', customModels: [] };
        }

        function mapModelTo9Router(model) {
          if (!model) return 'ag/gemini-3.7-flash-high';
          if (model.startsWith('ag/') || model.startsWith('cx/') || model.startsWith('venice/')) {
            return model;
          }
          return `ag/${model}`;
        }

        function geminiToOpenAIMessages(contents, systemInstruction) {
          const messages = [];
          if (systemInstruction?.parts) {
            const sysText = systemInstruction.parts.map(p => p.text || '').filter(Boolean).join('\\n');
            if (sysText) messages.push({ role: 'system', content: sysText });
          }
          if (Array.isArray(contents)) {
            for (const item of contents) {
              const role = item.role === 'model' ? 'assistant' : (item.role === 'system' ? 'system' : 'user');
              const parts = item.parts || [];
              const textParts = [];
              const toolCalls = [];
              for (const part of parts) {
                if (part.text) {
                  textParts.push(part.text);
                } else if (part.functionCall) {
                  toolCalls.push({
                    id: part.functionCall.id || `call_${Math.random().toString(36).slice(2, 9)}`,
                    type: 'function',
                    function: {
                      name: part.functionCall.name,
                      arguments: JSON.stringify(part.functionCall.args || {})
                    }
                  });
                } else if (part.functionResponse) {
                  messages.push({
                    role: 'tool',
                    tool_call_id: part.functionResponse.id || 'call_default',
                    name: part.functionResponse.name,
                    content: typeof part.functionResponse.response === 'string'
                      ? part.functionResponse.response
                      : JSON.stringify(part.functionResponse.response || {})
                  });
                }
              }
              if (textParts.length > 0 || toolCalls.length > 0) {
                const msg = { role, content: textParts.join('\\n') || '' };
                if (toolCalls.length > 0) msg.tool_calls = toolCalls;
                messages.push(msg);
              }
            }
          }
          return messages;
        }

        function geminiToOpenAITools(geminiTools) {
          if (!Array.isArray(geminiTools)) return undefined;
          const tools = [];
          for (const toolGroup of geminiTools) {
            if (Array.isArray(toolGroup.functionDeclarations)) {
              for (const fn of toolGroup.functionDeclarations) {
                tools.push({
                  type: 'function',
                  function: {
                    name: fn.name,
                    description: fn.description || '',
                    parameters: fn.parameters || { type: 'object', properties: {} }
                  }
                });
              }
            }
          }
          return tools.length > 0 ? tools : undefined;
        }

        function forwardToGoogle(req, res, pathName, rawBody) {
          const targetUrl = new URL(pathName, GOOGLE_UPSTREAM);
          const headers = { ...req.headers, host: targetUrl.host };
          delete headers['content-length'];
          const proxyReq = https.request(targetUrl, {
            method: req.method,
            headers: { ...headers, ...(rawBody && rawBody.length > 0 ? { 'content-length': rawBody.length } : {}) }
          }, (proxyRes) => {
            res.writeHead(proxyRes.statusCode, proxyRes.headers);
            proxyRes.pipe(res);
          });
          proxyReq.on('error', (err) => {
            console.error('[Bridge] Google upstream error:', err.message);
            if (!res.headersSent) {
              res.writeHead(502, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: { message: `Google upstream error: ${err.message}` } }));
            }
          });
          if (rawBody && rawBody.length > 0) proxyReq.write(rawBody);
          proxyReq.end();
        }

        const server = http.createServer(async (req, res) => {
          let cleanUrl = (req.url || '/')
            .replace(/^.*\\/dummy_path_padding/, '')
            .replace(/\\/v1internal\\/x{7}/, '')
            .replace(/^\\/v1internal\\/xxxxxxx/, '');
          if (cleanUrl === '' || cleanUrl === '/') cleanUrl = '/';

          if (cleanUrl === '/health') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ status: 'ok', proxy: 'antigravity-9router-bridge', port: PORT }));
            return;
          }

          const chunks = [];
          req.on('data', chunk => chunks.push(chunk));
          req.on('end', async () => {
            const rawBody = Buffer.concat(chunks);
            let bodyJson = null;
            try {
              if (rawBody.length > 0) bodyJson = JSON.parse(rawBody.toString('utf8'));
            } catch (_) {}

            const config = loadConfig();

            if (cleanUrl.includes('/v1internal:fetchAvailableModels')) {
              try {
                const targetUrl = new URL(cleanUrl, GOOGLE_UPSTREAM);
                const headers = { ...req.headers, host: targetUrl.host };
                delete headers['content-length'];

                const googleResponse = await new Promise((resolve, reject) => {
                  const proxyReq = https.request(targetUrl, {
                    method: req.method,
                    headers: { ...headers, ...(rawBody.length > 0 ? { 'content-length': rawBody.length } : {}) }
                  }, (proxyRes) => {
                    const resChunks = [];
                    proxyRes.on('data', c => resChunks.push(c));
                    proxyRes.on('end', () => resolve({
                      statusCode: proxyRes.statusCode,
                      headers: proxyRes.headers,
                      body: Buffer.concat(resChunks).toString('utf8')
                    }));
                  });
                  proxyReq.on('error', reject);
                  if (rawBody.length > 0) proxyReq.write(rawBody);
                  proxyReq.end();
                });

                let modelsData = { models: {} };
                if (googleResponse.statusCode >= 200 && googleResponse.statusCode < 300) {
                  try { modelsData = JSON.parse(googleResponse.body); } catch (_) {}
                }
                if (!modelsData.models || Object.keys(modelsData.models).length === 0) {
                  modelsData.models = {
                    'gemini-3.8-flash-high': { displayName: 'Gemini 3.8 Flash High', contextWindow: 1048576 },
                    'gemini-3.8-flash-medium': { displayName: 'Gemini 3.8 Flash Medium', contextWindow: 1048576 },
                    'gemini-3.7-flash-high': { displayName: 'Gemini 3.7 Flash High', contextWindow: 1048576 },
                    'gemini-3.6-flash-high': { displayName: 'Gemini 3.6 Flash High', contextWindow: 1048576 },
                    'claude-sonnet-4-6': { displayName: 'Claude Sonnet 4.6', contextWindow: 200000 },
                    'claude-opus-4-6-thinking': { displayName: 'Claude Opus 4.6', contextWindow: 200000 },
                    'gpt-oss-120b-medium': { displayName: 'GPT-OSS 120B', contextWindow: 128000 },
                    'gemini-pro-agent': { displayName: 'Gemini Pro Agent', contextWindow: 1048576 }
                  };
                }

                if (config.modelMode === 'custom' && Array.isArray(config.customModels) && config.customModels.length > 0) {
                  const customModelsMap = {};
                  for (const cm of config.customModels) {
                    if (cm && cm.id) {
                      customModelsMap[cm.id] = {
                        displayName: cm.name || cm.id,
                        description: `${cm.name || cm.id} (9Router)`,
                        quotaInfo: {
                          remainingFraction: 1.0,
                          resetTime: new Date(Date.now() + 86400000 * 7).toISOString()
                        },
                        supportedFeatures: ['CHAT', 'COMPLETION', 'AGENT', 'STREAMING'],
                        contextWindow: cm.contextWindow || 200000,
                        maxOutput: 65536
                      };
                    }
                  }
                  modelsData.models = customModelsMap;
                } else {
                  for (const [k, v] of Object.entries(modelsData.models)) {
                    if (!v.quotaInfo) {
                      v.quotaInfo = {
                        remainingFraction: 1.0,
                        resetTime: new Date(Date.now() + 86400000 * 7).toISOString()
                      };
                    }
                  }
                }

                const outBody = JSON.stringify(modelsData);
                res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(outBody) });
                res.end(outBody);
                return;
              } catch (err) {
                forwardToGoogle(req, res, cleanUrl, rawBody);
                return;
              }
            }

            if (cleanUrl.includes('/v1internal:streamGenerateContent')) {
              const model = bodyJson?.model || '';
              const mappedModel = mapModelTo9Router(model);

              if (config.apiKey) {
                try {
                  const messages = geminiToOpenAIMessages(bodyJson.contents, bodyJson.systemInstruction);
                  const tools = geminiToOpenAITools(bodyJson.tools);
                  const openAiPayload = {
                    model: mappedModel,
                    messages,
                    stream: true,
                    ...(tools ? { tools } : {}),
                    ...(bodyJson.generationConfig?.temperature != null ? { temperature: bodyJson.generationConfig.temperature } : {}),
                    ...(bodyJson.generationConfig?.maxOutputTokens != null ? { max_tokens: bodyJson.generationConfig.maxOutputTokens } : {})
                  };
                  const nineRouterEndpoint = new URL('/v1/chat/completions', config.nineRouterUrl || 'https://9router.bigroll.vn');
                  const client = nineRouterEndpoint.protocol === 'https:' ? https : http;

                  const openAiReq = client.request(nineRouterEndpoint, {
                    method: 'POST',
                    headers: {
                      'Content-Type': 'application/json',
                      'Authorization': `Bearer ${config.apiKey}`
                    }
                  }, (openAiRes) => {
                    res.writeHead(200, {
                      'Content-Type': 'text/event-stream; charset=utf-8',
                      'Cache-Control': 'no-cache',
                      'Connection': 'keep-alive'
                    });

                    let buffer = '';
                    openAiRes.on('data', (chunk) => {
                      buffer += chunk.toString('utf8');
                      const lines = buffer.split('\\n');
                      buffer = lines.pop() || '';
                      for (const line of lines) {
                        const trimmed = line.trim();
                        if (!trimmed || !trimmed.startsWith('data:')) continue;
                        const dataStr = trimmed.slice(5).trim();
                        if (dataStr === '[DONE]') {
                          const endCandidate = {
                            candidates: [{ content: { role: 'model', parts: [] }, finishReason: 'STOP' }],
                            usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 50, totalTokenCount: 150 }
                          };
                          res.write(`data: ${JSON.stringify(endCandidate)}\\n\\n`);
                          continue;
                        }
                        try {
                          const parsed = JSON.parse(dataStr);
                          const delta = parsed.choices?.[0]?.delta;
                          if (delta?.content) {
                            const candidate = {
                              candidates: [{
                                content: { role: 'model', parts: [{ text: delta.content }] },
                                finishReason: null
                              }]
                            };
                            res.write(`data: ${JSON.stringify(candidate)}\\n\\n`);
                          }
                        } catch (_) {}
                      }
                    });
                    openAiRes.on('end', () => res.end());
                  });

                  openAiReq.on('error', (err) => {
                    if (!res.headersSent) {
                      res.writeHead(502, { 'Content-Type': 'application/json' });
                      res.end(JSON.stringify({ error: { message: `9Router request error: ${err.message}` } }));
                    }
                  });
                  openAiReq.write(JSON.stringify(openAiPayload));
                  openAiReq.end();
                  return;
                } catch (err) {
                  console.error('[Bridge] Conversion error:', err.message);
                }
              }
              forwardToGoogle(req, res, cleanUrl, rawBody);
              return;
            }

            forwardToGoogle(req, res, cleanUrl, rawBody);
          });
        });

        server.listen(PORT, '127.0.0.1', () => {
          console.log(`[Bridge] Antigravity 9Router Bridge running at http://127.0.0.1:${PORT}`);
        });
        """
        try scriptContent.write(to: proxyScriptURL, atomically: true, encoding: .utf8)
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
            .map { id -> [String: Any] in
                ["id": id, "name": id, "contextWindow": 200000]
            }

        let dict: [String: Any] = [
            "nineRouterUrl": nineRouterUrl.isEmpty ? "https://9router.bigroll.vn" : nineRouterUrl,
            "apiKey": apiKey,
            "modelMode": modelMode.rawValue,
            "customModels": parsedCustomModels
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        try data.write(to: configJsonURL)
    }

    public func startProxy() async throws {
        if await checkHealth() {
            Self.logger.info("Proxy is already healthy and running on 50999.")
            return
        }

        try ensureBridgeScriptInstalled()

        let nodePaths = [
            "/Users/tutran/.local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        guard let nodePath = nodePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "AntigravityBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Node.js binary not found. Please install node."])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [proxyScriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.proxyProcess = process

        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await checkHealth() {
                Self.logger.info("Proxy started successfully.")
                return
            }
        }
    }

    public func stopProxy() {
        proxyProcess?.terminate()
        proxyProcess = nil

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", "antigravity-bridge-proxy.mjs"]
        try? killProcess.run()
    }

    public func relaunchAntigravityApp() async {
        Self.logger.info("Closing Antigravity app...")
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-x", "Antigravity"]
        try? killProcess.run()
        killProcess.waitUntilExit()

        try? await Task.sleep(nanoseconds: 1_200_000_000)

        Self.logger.info("Reopening Antigravity app...")
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "/Applications/Antigravity.app"]
        try? openProcess.run()
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
            try "http://127.0.0.1:50999".write(to: endpointFileURL, atomically: true, encoding: .utf8)
        } else {
            try "https://daily-cloudcode-pa.googleapis.com".write(to: endpointFileURL, atomically: true, encoding: .utf8)
            stopProxy()
        }

        await relaunchAntigravityApp()
    }
}
