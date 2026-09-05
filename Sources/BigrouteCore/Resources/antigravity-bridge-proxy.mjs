#!/usr/bin/env node
/**
 * Antigravity -> 9Router bridge.
 *
 * Cloud Code uses protobuf JSON envelopes. The bridge only translates the
 * generation payload; auth and all other endpoints stay transparent.
 */

import http from 'http';
import https from 'https';
import fs from 'fs';
import path from 'path';
import os from 'os';
import { pathToFileURL } from 'url';

const PORT = Number.parseInt(process.env.AG_PROXY_PORT || '50999', 10);
const HOST = process.env.AG_PROXY_HOST || '127.0.0.1';
const GOOGLE_UPSTREAM = 'https://daily-cloudcode-pa.googleapis.com';
const CONFIG_PATH = path.join(os.homedir(), '.gemini', 'antigravity', 'bridge_config.json');
const LOG_PATH = process.env.AG_PROXY_LOG || '/tmp/antigravity_bridge.log';
const FALLBACK_MODEL_IDS = [
  'gemini-3.8-flash-high',
  'gemini-3.8-flash-medium',
  'gemini-3.7-flash-high',
  'gemini-3.6-flash-high',
  'claude-sonnet-4-6',
  'claude-opus-4-6-thinking',
  'gpt-oss-120b-medium'
];

function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.map(value => {
    if (typeof value === 'string') return value;
    try { return JSON.stringify(value); } catch (_) { return String(value); }
  }).join(' ')}\n`;
  try { fs.appendFileSync(LOG_PATH, line); } catch (_) {}
  console.log('[Bridge]', ...args);
}

function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      const parsed = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
      return {
        nineRouterUrl: parsed.nineRouterUrl || 'https://9router.bigroll.vn',
        apiKey: typeof parsed.apiKey === 'string' ? parsed.apiKey : '',
        modelMode: parsed.modelMode === 'custom' ? 'custom' : 'keep_official',
        customModels: Array.isArray(parsed.customModels) ? parsed.customModels : []
      };
    }
  } catch (error) {
    log('Could not read bridge config:', error.message);
  }
  return { nineRouterUrl: 'https://9router.bigroll.vn', apiKey: '', modelMode: 'keep_official', customModels: [] };
}

function normalizeCloudCodeURL(requestURL) {
  const parsed = new URL(requestURL || '/', 'http://127.0.0.1');
  const pathname = parsed.pathname
    .replace(/^.*\/dummy_path_padding/, '')
    .replace(/\/v1internal\/x{7}/, '')
    .replace(/^\/v1internal\/xxxxxxx/, '');
  return `${pathname || '/'}${parsed.search}`;
}

function mapModelTo9Router(model) {
  if (!model) return 'ag/gemini-3.8-flash-high';
  if (/^(ag|cx|venice)\//.test(model)) return model;
  return `ag/${model}`;
}

function customModelSlug(model, index) {
  const normalized = model.id
    .replace(/^models\//, '')
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase();
  return `custom-${normalized || index}`;
}

function customModelPlaceholder(index) {
  return `MODEL_PLACEHOLDER_M${400 + (index % 200)}`;
}

function collectModelPlaceholders(value, result = new Set()) {
  if (typeof value === 'string') {
    for (const match of value.matchAll(/MODEL_PLACEHOLDER_M\d+/g)) result.add(match[0]);
  } else if (Array.isArray(value)) {
    for (const item of value) collectModelPlaceholders(item, result);
  } else if (value && typeof value === 'object') {
    for (const item of Object.values(value)) collectModelPlaceholders(item, result);
  }
  return result;
}

function resolveNineRouterModel(body, config) {
  const request = generationRequest(body);
  const candidates = modelCandidates(body, request);
  if (config.modelMode === 'custom') {
    for (const [index, model] of config.customModels.entries()) {
      if (!model || typeof model.id !== 'string') continue;
      const slug = customModelSlug(model, index);
      const placeholder = customModelPlaceholder(index);
      if (candidates.some(candidate => candidate === model.id
        || candidate === slug
        || candidate === placeholder
        || candidate === `models/${placeholder}`)) return model.id;
    }
    // The language server may issue internal planner/checkpoint requests using
    // a placeholder from the official model metadata. Keep those requests on
    // the first configured custom route instead of falling back to Google.
    if (candidates.some(candidate => /^MODEL_PLACEHOLDER_M\d+$/.test(candidate))) {
      return config.customModels[0]?.id || mapModelTo9Router(candidates[0]);
    }
  }
  return mapModelTo9Router(candidates[0]);
}

function readJSON(rawBody) {
  if (!rawBody || rawBody.length === 0) return null;
  try { return JSON.parse(rawBody.toString('utf8')); } catch (_) { return null; }
}

function generationRequest(body) {
  if (body && body.request && typeof body.request === 'object') return body.request;
  return body || {};
}

function modelCandidates(body, request) {
  return [
    body?.model, body?.requestedModel, body?.planModel, body?.modelId,
    body?.requested_model, body?.plan_model, body?.model_id,
    request?.model, request?.requestedModel, request?.planModel, request?.modelId,
    request?.requested_model, request?.plan_model, request?.model_id
  ].filter(value => typeof value === 'string' && value.length > 0);
}

function modelMap(response) {
  return response && response.models && typeof response.models === 'object' && !Array.isArray(response.models)
    ? response.models
    : {};
}

function validQuotaInfo(previous) {
  const quota = previous && typeof previous === 'object' ? { ...previous } : {};
  quota.remainingFraction = 1;
  quota.resetTime = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
  return quota;
}

function cloneModelDetails(source, id, displayName) {
  const template = source && typeof source === 'object' ? source : {};
  return {
    displayName: displayName || id,
    description: `${displayName || id} (9Router)`,
    supportsImages: template.supportsImages ?? true,
    supportsThinking: template.supportsThinking ?? true,
    thinkingBudget: template.thinkingBudget ?? 8192,
    minThinkingBudget: template.minThinkingBudget ?? 32,
    recommended: true,
    maxTokens: template.maxTokens ?? 200000,
    maxOutputTokens: template.maxOutputTokens ?? 65536,
    quotaInfo: validQuotaInfo()
  };
}

function replaceModelIds(value, ids) {
  if (!Array.isArray(value)) return value;
  return value.map(sort => {
    if (!sort || typeof sort !== 'object') return sort;
    const next = { ...sort };
    if (Array.isArray(next.groups)) {
      next.groups = next.groups.map(group => group && typeof group === 'object'
        ? { ...group, modelIds: ids }
        : group);
    }
    return next;
  });
}

function fallbackModelsResponse() {
  const models = {};
  for (const id of FALLBACK_MODEL_IDS) {
    models[id] = {
      displayName: id,
      description: id,
      supportsImages: true,
      supportsThinking: /thinking|gemini/i.test(id),
      maxTokens: 200000,
      maxOutputTokens: 65536,
      quotaInfo: validQuotaInfo()
    };
  }
  return {
    models,
    defaultAgentModelId: FALLBACK_MODEL_IDS[0],
    agentModelSorts: [{ displayName: 'Models', groups: [{ displayName: 'Models', modelIds: FALLBACK_MODEL_IDS }] }],
    commandModelIds: FALLBACK_MODEL_IDS,
    tabModelIds: FALLBACK_MODEL_IDS
  };
}

function buildModelsResponse(officialResponse, config) {
  const received = officialResponse && typeof officialResponse === 'object' ? officialResponse : {};
  const official = Object.keys(modelMap(received)).length > 0 ? received : fallbackModelsResponse();
  const officialModels = modelMap(official);
  const officialIds = Object.keys(officialModels);
  const custom = config.modelMode === 'custom'
    ? config.customModels.filter(model => model && typeof model.id === 'string' && model.id.length > 0)
    : [];

  if (custom.length === 0) {
    const models = {};
    for (const [id, details] of Object.entries(officialModels)) {
      models[id] = { ...details, quotaInfo: validQuotaInfo(details?.quotaInfo) };
    }
    return { ...official, models };
  }

  const template = officialModels[officialIds[0]] || {
    maxTokens: 200000,
    maxOutputTokens: 65536,
    supportsImages: true,
    supportsThinking: true
  };
  const models = {};
  const ids = [];
  for (const [index, customModel] of custom.entries()) {
    const id = customModelSlug(customModel, index);
    ids.push(id);
    models[id] = cloneModelDetails(template, customModel.id, customModel.name || customModel.id);
    models[id].model = customModelPlaceholder(index);
  }
  // Official experiment strings reference internal placeholder keys (most
  // notably M50 for checkpointing). Preserve them as non-listed aliases so
  // the language server can resolve its config without exposing extra picker
  // entries or stale official model metadata.
  for (const placeholder of collectModelPlaceholders(official)) {
    if (models[placeholder]) continue;
    models[placeholder] = cloneModelDetails(models[ids[0]], custom[0].id, custom[0].name || custom[0].id);
    models[placeholder].model = placeholder;
  }
  const result = { models };
  result.defaultAgentModelId = ids[0];
  result.commandModelIds = ids;
  result.tabModelIds = ids;
  result.agentModelSorts = replaceModelIds(official.agentModelSorts, ids)
    || [{ displayName: 'Models', groups: [{ displayName: 'Models', modelIds: ids }] }];
  return result;
}

function buildQuotaResponse(officialResponse) {
  if (!officialResponse || typeof officialResponse !== 'object') return officialResponse;
  const result = { ...officialResponse };
  const updateBucket = bucket => bucket && typeof bucket === 'object'
    ? { ...bucket, remainingFraction: 1, resetTime: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString() }
    : bucket;
  if (Array.isArray(result.buckets)) result.buckets = result.buckets.map(updateBucket);
  if (Array.isArray(result.groups)) {
    result.groups = result.groups.map(group => {
      if (!group || typeof group !== 'object' || !Array.isArray(group.buckets)) return group;
      return { ...group, buckets: group.buckets.map(updateBucket) };
    });
  }
  return result;
}

function textFromParts(parts) {
  return (Array.isArray(parts) ? parts : []).map(part => part?.text || '').filter(Boolean).join('\n');
}

function geminiToOpenAIMessages(contents, systemInstruction) {
  const messages = [];
  const pendingToolCallIDs = new Map();
  const systemText = textFromParts(systemInstruction?.parts);
  if (systemText) messages.push({ role: 'system', content: systemText });

  for (const item of Array.isArray(contents) ? contents : []) {
    const role = item?.role === 'model' ? 'assistant' : item?.role === 'system' ? 'system' : 'user';
    const textParts = [];
    const multimodalParts = [];
    const toolCalls = [];
    const toolResponses = [];
    for (const part of Array.isArray(item?.parts) ? item.parts : []) {
      if (part?.text) textParts.push(part.text);
      if (part?.inlineData?.data) {
        multimodalParts.push({ type: 'image_url', image_url: {
          url: `data:${part.inlineData.mimeType || 'image/png'};base64,${part.inlineData.data}`
        } });
      }
      if (part?.fileData?.fileUri) multimodalParts.push({ type: 'text', text: `[File: ${part.fileData.fileUri}]` });
      if (part?.functionCall) {
        const call = part.functionCall;
        const callID = call.id || `call_${Math.random().toString(36).slice(2, 10)}`;
        toolCalls.push({
          id: callID,
          type: 'function',
          function: {
            name: call.name || 'unknown',
            arguments: typeof call.args === 'string' ? call.args : JSON.stringify(call.args || {})
          }
        });
        const ids = pendingToolCallIDs.get(call.name) || [];
        ids.push(callID);
        pendingToolCallIDs.set(call.name, ids);
      }
      if (part?.functionResponse) {
        const response = part.functionResponse;
        const pendingIDs = pendingToolCallIDs.get(response.name) || [];
        toolResponses.push({
          role: 'tool',
          tool_call_id: response.id || pendingIDs.shift() || 'call_default',
          name: response.name || 'tool',
          content: typeof response.response === 'string' ? response.response : JSON.stringify(response.response || {})
        });
        pendingToolCallIDs.set(response.name, pendingIDs);
      }
    }
    const content = multimodalParts.length > 0
      ? [...(textParts.length > 0 ? [{ type: 'text', text: textParts.join('\n') }] : []), ...multimodalParts]
      : textParts.join('\n');
    if (content || toolCalls.length > 0 || role === 'user') {
      const message = { role, content };
      if (toolCalls.length > 0) message.tool_calls = toolCalls;
      messages.push(message);
    }
    messages.push(...toolResponses);
  }
  return messages;
}

function geminiToOpenAITools(geminiTools) {
  const tools = [];
  for (const group of Array.isArray(geminiTools) ? geminiTools : []) {
    for (const fn of Array.isArray(group?.functionDeclarations) ? group.functionDeclarations : []) {
      if (!fn?.name) continue;
      tools.push({ type: 'function', function: {
        name: fn.name,
        description: fn.description || '',
        parameters: normalizeJSONSchema(fn.parameters || { type: 'object', properties: {} })
      } });
    }
  }
  return tools.length > 0 ? tools : undefined;
}

function normalizeJSONSchema(value) {
  if (Array.isArray(value)) return value.map(normalizeJSONSchema);
  if (!value || typeof value !== 'object') return value;
  const result = {};
  for (const [key, child] of Object.entries(value)) result[key] = normalizeJSONSchema(child);
  if (typeof result.type === 'string') {
    const type = result.type.toLowerCase();
    result.type = type === 'type_unspecified' ? 'object' : type;
  }
  return result;
}

function buildOpenAIPayload(body, config = loadConfig()) {
  const request = generationRequest(body);
  const generationConfig = request.generationConfig || {};
  const payload = {
    model: resolveNineRouterModel(body, config),
    messages: geminiToOpenAIMessages(request.contents, request.systemInstruction),
    stream: true
  };
  if (generationConfig.temperature != null) payload.temperature = generationConfig.temperature;
  if (generationConfig.topP != null) payload.top_p = generationConfig.topP;
  if (generationConfig.maxOutputTokens != null) payload.max_tokens = generationConfig.maxOutputTokens;
  if (Array.isArray(generationConfig.stopSequences)) payload.stop = generationConfig.stopSequences;
  const tools = geminiToOpenAITools(request.tools);
  if (tools) payload.tools = tools;
  return payload;
}

function chatEndpoint(base) {
  const endpoint = new URL(base || 'https://9router.bigroll.vn');
  const pathname = endpoint.pathname.replace(/\/$/, '');
  if (/\/chat\/completions$/.test(pathname)) return endpoint;
  endpoint.pathname = pathname.endsWith('/v1') || pathname.endsWith('/api/v1')
    ? `${pathname}/chat/completions`
    : `${pathname}/v1/chat/completions`;
  return endpoint;
}

function sendJSON(res, status, value, headers = {}) {
  if (res.headersSent || res.writableEnded) return;
  const body = JSON.stringify(value);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), ...headers });
  res.end(body);
}

function forwardToGoogle(req, res, cleanURL, rawBody) {
  const targetURL = new URL(cleanURL, GOOGLE_UPSTREAM);
  const headers = { ...req.headers, host: targetURL.host };
  delete headers['content-length'];
  delete headers.connection;
  const client = targetURL.protocol === 'https:' ? https : http;
  const upstream = client.request(targetURL, {
    method: req.method,
    headers: { ...headers, ...(rawBody.length > 0 ? { 'content-length': rawBody.length } : {}) }
  }, upstreamResponse => {
    res.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
    upstreamResponse.pipe(res);
  });
  upstream.on('error', error => sendJSON(res, 502, { error: { message: `Google upstream error: ${error.message}` } }));
  if (rawBody.length > 0) upstream.write(rawBody);
  upstream.end();
}

function forwardJSONToGoogle(req, cleanURL, rawBody) {
  return new Promise((resolve, reject) => {
    const targetURL = new URL(cleanURL, GOOGLE_UPSTREAM);
    const headers = { ...req.headers, host: targetURL.host };
    delete headers['content-length'];
    delete headers.connection;
    // Buffered discovery responses must be plain JSON; otherwise Node leaves
    // gzip bytes for readJSON() and the language server receives an empty map.
    delete headers['accept-encoding'];
    const client = targetURL.protocol === 'https:' ? https : http;
    const upstream = client.request(targetURL, {
      method: req.method,
      headers: { ...headers, ...(rawBody.length > 0 ? { 'content-length': rawBody.length } : {}) }
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode || 502, headers: response.headers, body: Buffer.concat(chunks) }));
      response.on('error', reject);
    });
    upstream.on('error', reject);
    if (rawBody.length > 0) upstream.write(rawBody);
    upstream.end();
  });
}

function emitEnvelope(res, response) {
  res.write(`data: ${JSON.stringify({ response })}\n\n`);
}

function usageMetadata(usage) {
  if (!usage || typeof usage !== 'object') return undefined;
  return {
    promptTokenCount: usage.prompt_tokens || 0,
    candidatesTokenCount: usage.completion_tokens || 0,
    totalTokenCount: usage.total_tokens || 0
  };
}

function translateOpenAIStream(upstreamResponse, res) {
  if (upstreamResponse.statusCode < 200 || upstreamResponse.statusCode >= 300) {
    const chunks = [];
    upstreamResponse.on('data', chunk => chunks.push(chunk));
    upstreamResponse.on('end', () => {
      const body = Buffer.concat(chunks).toString('utf8');
      let parsed;
      try { parsed = JSON.parse(body); } catch (_) { parsed = { error: { message: body || `9Router returned ${upstreamResponse.statusCode}` } }; }
      sendJSON(res, upstreamResponse.statusCode, parsed);
    });
    return;
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive'
  });
  let buffer = '';
  let finalSent = false;
  let usage;
  const toolCalls = {};
  const emitFinal = finishReason => {
    if (finalSent) return;
    finalSent = true;
    const parts = [];
    for (const call of Object.values(toolCalls)) {
      let args = {};
      try { args = JSON.parse(call.arguments || '{}'); } catch (_) { args = { raw: call.arguments || '' }; }
      parts.push({ functionCall: { id: call.id, name: call.name, args } });
    }
    emitEnvelope(res, {
      candidates: [{ content: { role: 'model', parts }, finishReason: finishReason || 'STOP', index: 0 }],
      ...(usage ? { usageMetadata: usageMetadata(usage) } : {})
    });
  };
  const processEvent = event => {
    const dataLines = event.split('\n').filter(line => line.trim().startsWith('data:'));
    if (dataLines.length === 0) return;
    const data = dataLines.map(line => line.slice(line.indexOf(':') + 1).trim()).join('\n');
    if (!data || data === '[DONE]') { emitFinal(Object.keys(toolCalls).length > 0 ? 'TOOL_CALL' : 'STOP'); return; }
    let parsed;
    try { parsed = JSON.parse(data); } catch (_) { return; }
    if (parsed.usage) usage = parsed.usage;
    const choice = parsed.choices?.[0];
    const delta = choice?.delta;
    if (delta?.content) emitEnvelope(res, { candidates: [{ content: { role: 'model', parts: [{ text: delta.content }] }, index: 0 }] });
    const reasoning = delta?.reasoning_content || delta?.reasoning || delta?.thought;
    if (reasoning) emitEnvelope(res, { candidates: [{ content: { role: 'model', parts: [{ text: reasoning, thought: true }] }, index: 0 }] });
    for (const call of Array.isArray(delta?.tool_calls) ? delta.tool_calls : []) {
      const index = call.index ?? 0;
      if (!toolCalls[index]) toolCalls[index] = { id: call.id || `call_${index}`, name: '', arguments: '' };
      if (call.id) toolCalls[index].id = call.id;
      if (call.function?.name) toolCalls[index].name += call.function.name;
      if (call.function?.arguments) toolCalls[index].arguments += call.function.arguments;
    }
    if (choice?.finish_reason) {
      const reason = choice.finish_reason === 'length'
        ? 'MAX_TOKENS'
        : choice.finish_reason === 'tool_calls' ? 'TOOL_CALL' : 'STOP';
      emitFinal(reason);
    }
  };
  upstreamResponse.on('data', chunk => {
    buffer += chunk.toString('utf8').replace(/\r\n/g, '\n');
    const events = buffer.split(/\n\n/);
    buffer = events.pop() || '';
    for (const event of events) processEvent(event);
  });
  upstreamResponse.on('end', () => {
    if (buffer.trim()) processEvent(buffer);
    emitFinal('STOP');
    res.end();
  });
  upstreamResponse.on('error', error => {
    log('9Router stream error:', error.message);
    if (!res.writableEnded) res.end();
  });
}

function routeGeneration(req, res, body, config, cleanURL, rawBody) {
  if (!config.apiKey) {
    forwardToGoogle(req, res, cleanURL, rawBody);
    return;
  }
  let endpoint;
  try { endpoint = chatEndpoint(config.nineRouterUrl); } catch (error) {
    sendJSON(res, 500, { error: { message: `Invalid 9Router URL: ${error.message}` } });
    return;
  }
  const client = endpoint.protocol === 'https:' ? https : http;
  const payload = buildOpenAIPayload(body, config);
  log(`Routing ${modelCandidates(body, generationRequest(body))[0] || 'default'} -> ${payload.model}`);
  const upstream = client.request(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
      Authorization: `Bearer ${config.apiKey}`
    }
  }, response => translateOpenAIStream(response, res));
  upstream.on('error', error => sendJSON(res, 502, { error: { message: `9Router request error: ${error.message}` } }));
  upstream.end(JSON.stringify(payload));
}

const server = http.createServer((req, res) => {
  const cleanURL = normalizeCloudCodeURL(req.url);
  if (cleanURL === '/health') {
    sendJSON(res, 200, { status: 'ok', proxy: 'antigravity-9router-bridge', port: PORT });
    return;
  }
  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', async () => {
    const rawBody = Buffer.concat(chunks);
    const body = readJSON(rawBody);
    const config = loadConfig();
    log(`[${req.method}] ${cleanURL}`);

    if (cleanURL.includes('fetchAvailableModels')) {
      try {
        const upstream = await forwardJSONToGoogle(req, cleanURL, rawBody);
        if (upstream.status >= 200 && upstream.status < 300) {
          const official = readJSON(upstream.body) || {};
          sendJSON(res, 200, buildModelsResponse(official, config));
        } else {
          res.writeHead(upstream.status, upstream.headers);
          res.end(upstream.body);
        }
      } catch (error) {
        sendJSON(res, 502, { error: { message: `Google model discovery failed: ${error.message}` } });
      }
      return;
    }

    if (cleanURL.includes('retrieveUserQuotaSummary')) {
      try {
        const upstream = await forwardJSONToGoogle(req, cleanURL, rawBody);
        if (upstream.status >= 200 && upstream.status < 300) {
          sendJSON(res, 200, buildQuotaResponse(readJSON(upstream.body) || {}));
        } else {
          res.writeHead(upstream.status, upstream.headers);
          res.end(upstream.body);
        }
      } catch (error) {
        sendJSON(res, 502, { error: { message: `Google quota discovery failed: ${error.message}` } });
      }
      return;
    }

    if (cleanURL.includes('listExperiments')) {
      // Remote Control discovers its Google relay through this response.
      forwardToGoogle(req, res, cleanURL, rawBody);
      return;
    }

    if (cleanURL.includes('streamGenerateContent') || cleanURL.includes('generateContent')) {
      routeGeneration(req, res, body, config, cleanURL, rawBody);
      return;
    }

    forwardToGoogle(req, res, cleanURL, rawBody);
  });
});

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  server.keepAliveTimeout = 0;
  server.headersTimeout = 0;
  server.requestTimeout = 0;
  server.listen(PORT, HOST, () => log(`Antigravity 9Router Bridge running at http://${HOST}:${PORT}`));
}

export {
  buildModelsResponse,
  buildQuotaResponse,
  buildOpenAIPayload,
  customModelPlaceholder,
  customModelSlug,
  geminiToOpenAIMessages,
  normalizeCloudCodeURL,
  resolveNineRouterModel,
  translateOpenAIStream
};
