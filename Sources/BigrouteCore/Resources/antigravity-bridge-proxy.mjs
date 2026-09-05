#!/usr/bin/env node
/**
 * Antigravity 9Router Bridge Proxy
 * Intercepts Google Cloud Code requests from Antigravity Language Server (port 50999)
 * and translates / routes them between Google Upstream and 9Router.
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
      const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
      return JSON.parse(raw);
    }
  } catch (err) {
    console.error('[Bridge] Failed to read config:', err.message);
  }
  return {
    nineRouterUrl: 'https://9router.bigroll.vn',
    apiKey: '',
    modelMode: 'keep_official', // 'keep_official' | 'custom'
    customModels: []
  };
}

// Convert Gemini format contents to OpenAI messages format
function geminiToOpenAIMessages(contents, systemInstruction) {
  const messages = [];

  if (systemInstruction?.parts) {
    const sysText = systemInstruction.parts
      .map(p => p.text || '')
      .filter(Boolean)
      .join('\n');
    if (sysText) {
      messages.push({ role: 'system', content: sysText });
    }
  }

  if (Array.isArray(contents)) {
    for (const item of contents) {
      const role = item.role === 'model' ? 'assistant' : (item.role === 'system' ? 'system' : 'user');
      const parts = item.parts || [];

      // Check if there are tool responses or tool calls
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
        const msg = { role, content: textParts.join('\n') || '' };
        if (toolCalls.length > 0) {
          msg.tool_calls = toolCalls;
        }
        messages.push(msg);
      }
    }
  }

  return messages;
}

// Convert Gemini tools to OpenAI tools
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

// Forward request to upstream Google
function forwardToGoogle(req, res, pathName, rawBody) {
  const targetUrl = new URL(pathName, GOOGLE_UPSTREAM);
  const headers = { ...req.headers, host: targetUrl.host };
  delete headers['content-length'];

  const requestOptions = {
    method: req.method,
    headers: {
      ...headers,
      ...(rawBody && rawBody.length > 0 ? { 'content-length': rawBody.length } : {})
    }
  };

  const proxyReq = https.request(targetUrl, requestOptions, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (err) => {
    console.error('[Bridge] Error proxying to Google:', err.message);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: { message: `Google upstream error: ${err.message}` } }));
    }
  });

  if (rawBody && rawBody.length > 0) {
    proxyReq.write(rawBody);
  }
  proxyReq.end();
}

const server = http.createServer(async (req, res) => {
  // Clean URL padding
  let cleanUrl = (req.url || '/')
    .replace(/^.*\/dummy_path_padding/, '')
    .replace(/\/v1internal\/x{7}/, '')
    .replace(/^\/v1internal\/xxxxxxx/, '');

  if (cleanUrl === '' || cleanUrl === '/') {
    cleanUrl = '/';
  }

  console.log(`[Bridge] ${req.method} ${cleanUrl}`);

  // Health check
  if (cleanUrl === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', proxy: 'antigravity-9router-bridge', port: PORT }));
    return;
  }

  // Read request body
  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', async () => {
    const rawBody = Buffer.concat(chunks);
    let bodyJson = null;
    try {
      if (rawBody.length > 0) {
        bodyJson = JSON.parse(rawBody.toString('utf8'));
      }
    } catch (_) {}

    const config = loadConfig();

    // 1. Route /v1internal:fetchAvailableModels
    if (cleanUrl.includes('/v1internal:fetchAvailableModels')) {
      try {
        // Fetch official Google models first to keep 100% full metadata
        const targetUrl = new URL(cleanUrl, GOOGLE_UPSTREAM);
        const headers = { ...req.headers, host: targetUrl.host };
        delete headers['content-length'];

        const googleResponse = await new Promise((resolve, reject) => {
          const proxyReq = https.request(targetUrl, {
            method: req.method,
            headers: {
              ...headers,
              ...(rawBody.length > 0 ? { 'content-length': rawBody.length } : {})
            }
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
          try {
            modelsData = JSON.parse(googleResponse.body);
          } catch (_) {}
        }

        if (!modelsData.models) {
          modelsData.models = {};
        }

        // Base 9Router models to inject
        const extra9RouterModels = [
          { id: 'cx/gpt-5.5', name: '9Router · GPT-5.5', contextWindow: 200000 },
          { id: 'cx/gpt-5.6-sol', name: '9Router · GPT-5.6 Sol', contextWindow: 200000 },
          { id: 'cx/gpt-5.6-terra', name: '9Router · GPT-5.6 Terra', contextWindow: 200000 },
          { id: 'ag/claude-sonnet-4-6', name: '9Router · Claude Sonnet 4.6', contextWindow: 200000 },
          { id: 'ag/claude-opus-4-6-thinking', name: '9Router · Claude Opus 4.6', contextWindow: 200000 },
          { id: 'ag/gpt-oss-120b-medium', name: '9Router · GPT-OSS 120B', contextWindow: 128000 },
          { id: 'ag/gemini-3.7-flash-high', name: '9Router · Gemini 3.7 Flash High', contextWindow: 1048576 },
          { id: 'ag/gemini-3.6-flash-high', name: '9Router · Gemini 3.6 Flash High', contextWindow: 1048576 }
        ];

        // Add custom models if configured
        if (Array.isArray(config.customModels) && config.customModels.length > 0) {
          for (const cm of config.customModels) {
            if (cm && cm.id) {
              extra9RouterModels.push({
                id: cm.id,
                name: cm.name || cm.id,
                contextWindow: cm.contextWindow || 200000
              });
            }
          }
        }

        for (const m of extra9RouterModels) {
          modelsData.models[m.id] = {
            displayName: m.name,
            description: `${m.name} routed via 9Router Pool`,
            quotaInfo: {
              remainingFraction: 1.0,
              resetTime: new Date(Date.now() + 86400000 * 7).toISOString()
            },
            supportedFeatures: ['CHAT', 'COMPLETION', 'AGENT', 'STREAMING'],
            contextWindow: m.contextWindow,
            maxOutput: 65536
          };
        }

        const outBody = JSON.stringify(modelsData);
        res.writeHead(200, {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(outBody)
        });
        res.end(outBody);
        return;
      } catch (err) {
        console.error('[Bridge] Error in fetchAvailableModels:', err.message);
        forwardToGoogle(req, res, cleanUrl, rawBody);
        return;
      }
    }

    // 2. Route /v1internal:streamGenerateContent
    if (cleanUrl.includes('/v1internal:streamGenerateContent')) {
      const model = bodyJson?.model || '';
      const is9RouterModel = model.startsWith('cx/') || model.startsWith('ag/') || model.startsWith('venice/') || config.modelMode === 'custom' || !model.startsWith('gemini-');

      if (is9RouterModel && config.apiKey) {
        console.log(`[Bridge] Routing model "${model}" via 9Router API`);
        try {
          const messages = geminiToOpenAIMessages(bodyJson.contents, bodyJson.systemInstruction);
          const tools = geminiToOpenAITools(bodyJson.tools);

          const openAiPayload = {
            model: model,
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
              const lines = buffer.split('\n');
              buffer = lines.pop() || '';

              for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed || !trimmed.startsWith('data:')) continue;
                const dataStr = trimmed.slice(5).trim();
                if (dataStr === '[DONE]') {
                  const endCandidate = {
                    candidates: [{
                      content: { role: 'model', parts: [] },
                      finishReason: 'STOP'
                    }],
                    usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 50, totalTokenCount: 150 }
                  };
                  res.write(`data: ${JSON.stringify(endCandidate)}\n\n`);
                  continue;
                }

                try {
                  const parsed = JSON.parse(dataStr);
                  const delta = parsed.choices?.[0]?.delta;
                  if (delta?.content) {
                    const candidate = {
                      candidates: [{
                        content: {
                          role: 'model',
                          parts: [{ text: delta.content }]
                        },
                        finishReason: null
                      }]
                    };
                    res.write(`data: ${JSON.stringify(candidate)}\n\n`);
                  }
                } catch (_) {}
              }
            });

            openAiRes.on('end', () => {
              res.end();
            });
          });

          openAiReq.on('error', (err) => {
            console.error('[Bridge] 9Router request failed:', err.message);
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

      // Default: forward directly to Google
      forwardToGoogle(req, res, cleanUrl, rawBody);
      return;
    }

    // 3. All other Google Cloud Code routes
    forwardToGoogle(req, res, cleanUrl, rawBody);
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[Bridge] Antigravity 9Router Bridge running at http://127.0.0.1:${PORT}`);
});
