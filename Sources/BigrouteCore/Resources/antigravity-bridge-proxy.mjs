#!/usr/bin/env node
/**
 * Antigravity -> CLI Proxy API bridge.
 *
 * Cloud Code uses protobuf JSON envelopes. The bridge only translates the
 * generation payload; auth and all other endpoints stay transparent.
 */

import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { StringDecoder } from 'node:string_decoder';
import { gunzipSync, inflateSync, brotliDecompressSync } from 'node:zlib';

const PORT = Number.parseInt(process.env.AG_PROXY_PORT || '50999', 10);
const HOST = '127.0.0.1';
const GOOGLE_UPSTREAM = 'https://daily-cloudcode-pa.googleapis.com';
const CONFIG_PATH = path.join(os.homedir(), '.gemini', 'antigravity', 'bridge_config.json');
const LOG_PATH = process.env.AG_PROXY_LOG || path.join(path.dirname(CONFIG_PATH), 'bridge-proxy', 'bridge.log');
const SCRIPT_HASH = createHash('sha256').update(fs.readFileSync(fileURLToPath(import.meta.url))).digest('hex');
const MAX_BODY_BYTES = 32 * 1024 * 1024;

function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.map(value => {
    if (typeof value === 'string') return value;
    try { return JSON.stringify(value); } catch (_) { return String(value); }
  }).join(' ')}\n`;
  try {
    if (fs.existsSync(LOG_PATH) && fs.statSync(LOG_PATH).size > 1024 * 1024) fs.truncateSync(LOG_PATH);
    fs.appendFileSync(LOG_PATH, line, { mode: 0o600 });
  } catch (_) {}
}

function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      const parsed = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
      const cliProxyUrl = typeof parsed.cliProxyUrl === 'string' ? parsed.cliProxyUrl
        : (typeof parsed.nineRouterUrl === 'string' ? parsed.nineRouterUrl : '');
      return {
        cliProxyUrl,
        nineRouterUrl: cliProxyUrl,
        apiKey: typeof parsed.apiKey === 'string' ? parsed.apiKey : '',
        modelMode: parsed.modelMode === 'custom' ? 'custom' : 'keep_official',
        customModels: Array.isArray(parsed.customModels) ? parsed.customModels : []
      };
    }
  } catch (error) {
    log('Could not read bridge config:', error.code || error.name);
  }
  return { cliProxyUrl: '', nineRouterUrl: '', apiKey: '', modelMode: 'keep_official', customModels: [] };
}

function normalizeCloudCodeURL(requestURL) {
  // Parse as a path, never as a new origin (including a leading //).
  const parsed = new URL(`http://127.0.0.1${requestURL?.startsWith('/') ? requestURL : '/'}`);
  const pathname = parsed.pathname
    .replace(/^.*\/dummy_path_padding/, '')
    .replace(/^\/v1internal\/x{7}/, '');
  return `${pathname || '/'}${parsed.search}`;
}

function mapModelToCLIProxy(model) {
  if (!model) throw new Error('The generation request does not specify a model.');
  return model.replace(/^models\//, '');
}

function mapModelTo9Router(model) {
  return mapModelToCLIProxy(model);
}

function legacyModelSlug(model, index) {
  const normalized = model.id
    .replace(/^models\//, '')
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase();
  return `custom-${normalized || index}`;
}

function customModelSlug(model, index) {
  // Punctuation and case can distinguish two real router IDs. Keep a readable
  // prefix, but do not collapse both routes into the same picker entry.
  const digest = createHash('sha256').update(model.id).digest('hex').slice(0, 12);
  return `${legacyModelSlug(model, index)}-${digest}`;
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

function resolveCLIProxyModel(body, config) {
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
    const legacyMatches = config.customModels.filter((model, index) => model?.id
      && candidates.includes(legacyModelSlug(model, index)));
    if (legacyMatches.length === 1) return legacyMatches[0].id;
    if (legacyMatches.length > 1) throw new Error('This saved custom model ID is ambiguous. Select the model again.');
    // The language server may issue internal planner/checkpoint requests using
    // a placeholder from the official model metadata. Keep those requests on
    // the first configured custom route instead of falling back to Google.
    if (candidates.some(candidate => /^MODEL_PLACEHOLDER_M\d+$/.test(candidate))) {
      return config.customModels[0]?.id || mapModelToCLIProxy(candidates[0]);
    }
  }
  const model = candidates[0]?.replace(/^models\//, '');
  return mapModelToCLIProxy(config.modelAliases?.[model] || model);
}

const resolveNineRouterModel = resolveCLIProxyModel;

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
    ...template,
    displayName: displayName || id,
    description: `${displayName || id} (CLI Proxy)`,
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

function buildModelsResponse(officialResponse, config) {
  const official = officialResponse;
  // A future discovery schema must reach Antigravity unchanged. Never invent
  // a stale model catalogue when Google returns something we do not know.
  if (!Object.keys(modelMap(official)).length) return official;
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
  const result = { ...official, models };
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

  let nextToolCall = 0;
  for (const item of Array.isArray(contents) ? contents : []) {
    const role = item?.role === 'model' ? 'assistant' : item?.role === 'system' ? 'system' : 'user';
    const textParts = [];
    const multimodalParts = [];
    const toolCalls = [];
    const toolResponses = [];
    const thoughtParts = [];
    for (const part of Array.isArray(item?.parts) ? item.parts : []) {
      if (part?.text) (part.thought ? thoughtParts : textParts).push(part.text);
      if (part?.inlineData?.data) {
        if (!part.inlineData.mimeType?.startsWith('image/')) throw new Error('This bridge supports inline images; this media type is not supported.');
        multimodalParts.push({ type: 'image_url', image_url: {
          url: `data:${part.inlineData.mimeType || 'image/png'};base64,${part.inlineData.data}`
        } });
      }
      if (part?.fileData?.fileUri) {
        if (!part.fileData.mimeType?.startsWith('image/') || !/^https?:\/\//.test(part.fileData.fileUri)) throw new Error('This bridge requires an image URL or inline image data for file parts.');
        multimodalParts.push({ type: 'image_url', image_url: { url: part.fileData.fileUri } });
      }
      if (part?.functionCall) {
        const call = part.functionCall;
        const callID = call.id || `bridge_call_${nextToolCall++}`;
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
        const matchingIndex = response.id ? pendingIDs.indexOf(response.id) : 0;
        const matchedID = matchingIndex >= 0 ? pendingIDs.splice(matchingIndex, 1)[0] : undefined;
        toolResponses.push({
          role: 'tool',
          tool_call_id: response.id || matchedID || 'call_default',
          name: response.name || 'tool',
          content: typeof response.response === 'string' ? response.response : JSON.stringify(response.response || {})
        });
        pendingToolCallIDs.set(response.name, pendingIDs);
      }
    }
    const content = multimodalParts.length > 0
      ? [...(textParts.length > 0 ? [{ type: 'text', text: textParts.join('\n') }] : []), ...multimodalParts]
      : textParts.join('\n');
    // OpenAI requires all tool results immediately after their assistant call.
    // Do not insert an empty user message before a tool-only result.
    messages.push(...toolResponses);
    if (content.length > 0 || toolCalls.length > 0) {
      const message = { role, content };
      if (toolCalls.length > 0) message.tool_calls = toolCalls;
      if (thoughtParts.length > 0 && role === 'assistant') message.reasoning_content = thoughtParts.join('\n');
      messages.push(message);
    }
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
        parameters: normalizeJSONSchema(fn.parametersJsonSchema || fn.parameters || { type: 'object', properties: {} })
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
  const callingConfig = request.toolConfig?.functionCallingConfig;
  if (tools && callingConfig?.mode === 'NONE') payload.tool_choice = 'none';
  if (tools && callingConfig?.mode === 'ANY') {
    const allowed = callingConfig.allowedFunctionNames;
    if (Array.isArray(allowed) && allowed.length > 0) payload.tools = tools.filter(tool => allowed.includes(tool.function.name));
    if (!payload.tools.length) throw new Error('No declared tools match the allowed function names.');
    payload.tool_choice = payload.tools.length === 1
      ? { type: 'function', function: { name: payload.tools[0].function.name } }
      : 'required';
  }
  if (generationConfig.responseMimeType === 'application/json') payload.response_format = { type: 'json_object' };
  return payload;
}

function chatEndpoint(base) {
  const endpoint = new URL(base);
  if (!['https:', 'http:'].includes(endpoint.protocol)
    || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error('CLI Proxy API requires an HTTP or HTTPS endpoint without URL credentials or query parameters.');
  }
  const pathname = endpoint.pathname.replace(/\/+$/, '').replace(/\/v1\/(quota|models)$/, '/v1');
  if (/\/chat\/completions$/.test(pathname)) return endpoint;
  endpoint.pathname = pathname.endsWith('/v1') || pathname.endsWith('/api/v1')
    ? `${pathname}/chat/completions`
    : `${pathname}/v1/chat/completions`;
  return endpoint;
}

function sendJSON(res, status, value, headers = {}) {
  if (res.destroyed || res.headersSent || res.writableEnded) return;
  const body = JSON.stringify(value);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), ...headers });
  res.end(body);
}

// Hop-by-hop headers describe one HTTP connection and must not cross the
// bridge. Forwarding them can make Node reuse stale framing metadata when a
// large Remote Control response is relayed over a new connection.
const HOP_BY_HOP_HEADERS = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade'
]);

function connectionHeaderTokens(headers) {
  const entry = Object.entries(headers).find(([name]) => name.toLowerCase() === 'connection');
  const value = entry?.[1];
  const values = Array.isArray(value) ? value : [value];
  return new Set(values
    .filter(item => typeof item === 'string')
    .flatMap(item => item.split(','))
    .map(token => token.trim().toLowerCase())
    .filter(Boolean));
}

function relayRequestHeaders(input, targetHost, { stripAcceptEncoding = false } = {}) {
  const tokens = connectionHeaderTokens(input);
  const headers = {};
  for (const [name, value] of Object.entries(input)) {
    const lower = name.toLowerCase();
    if (lower === 'host' || lower === 'content-length' || lower === 'connection'
      || HOP_BY_HOP_HEADERS.has(lower) || tokens.has(lower)
      || (stripAcceptEncoding && lower === 'accept-encoding')) continue;
    headers[name] = value;
  }
  headers.host = targetHost;
  return headers;
}

function relayResponseHeaders(input) {
  const tokens = connectionHeaderTokens(input);
  const headers = {};
  for (const [name, value] of Object.entries(input)) {
    const lower = name.toLowerCase();
    if (HOP_BY_HOP_HEADERS.has(lower) || tokens.has(lower)) continue;
    headers[name] = value;
  }
  return headers;
}

// Tie each upstream to its own downstream response. A completed request body
// does not mean the client has finished reading (or canceled) its response.
function attachUpstream(req, res, target, options, idleTimeoutMs) {
  const client = target.protocol === 'https:' ? https : http;
  const upstream = client.request(target, options);
  const cancel = () => upstream.destroy();
  req.once('aborted', cancel);
  res.once('close', cancel);
  upstream.once('close', () => {
    req.off('aborted', cancel);
    res.off('close', cancel);
  });
  upstream.setTimeout(idleTimeoutMs, () => upstream.destroy(new Error('Upstream response timed out.')));
  if (req.aborted || res.destroyed) upstream.destroy();
  return upstream;
}

function receiveResponse(upstream) {
  return new Promise((resolve, reject) => {
    upstream.once('response', resolve);
    upstream.once('error', reject);
  });
}

async function readBounded(source, maximumBytes = MAX_BODY_BYTES) {
  const chunks = [];
  let size = 0;
  for await (const chunk of source) {
    size += chunk.length;
    if (size > maximumBytes) throw new Error('Bridge payload exceeds the size limit.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function decodedBody(body, encoding) {
  const options = { maxOutputLength: MAX_BODY_BYTES };
  switch (encoding?.toLowerCase()) {
    case 'gzip': return gunzipSync(body, options);
    case 'deflate': return inflateSync(body, options);
    case 'br': return brotliDecompressSync(body, options);
    case undefined: case 'identity': return body;
    default: throw new Error('Unsupported content encoding.');
  }
}

async function forwardToGoogle(req, res, target, idleTimeoutMs, transform) {
  const headers = relayRequestHeaders(req.headers, target.host, { stripAcceptEncoding: Boolean(transform) });
  if (transform) headers['accept-encoding'] = 'identity';
  const upstream = attachUpstream(req, res, target, { method: req.method, headers }, idleTimeoutMs);
  const responsePromise = receiveResponse(upstream);
  // Start receiving concurrently: servers can reject a request before all of
  // its body has arrived. pipeline handles errors and bounded backpressure.
  const upload = pipeline(req, upstream);
  upload.catch(() => {});
  try {
    const response = await responsePromise;
    if (transform && response.statusCode >= 200 && response.statusCode < 300) {
      const rawBody = await readBounded(response);
      let value;
      try { value = readJSON(decodedBody(rawBody, response.headers['content-encoding'])); } catch (_) {}
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        const transformed = transform(value);
        if (transformed !== value) {
          const responseHeaders = relayResponseHeaders(response.headers);
          for (const name of ['content-length', 'content-encoding', 'content-type', 'etag', 'content-md5']) delete responseHeaders[name];
          sendJSON(res, response.statusCode, transformed, responseHeaders);
          return;
        }
      }
      // Unknown or compressed discovery formats are relayed byte-for-byte.
      res.writeHead(response.statusCode, relayResponseHeaders(response.headers));
      res.end(rawBody);
      return;
    }
    res.writeHead(response.statusCode || 502, relayResponseHeaders(response.headers));
    await pipeline(response, res);
  } finally {
    upstream.destroy();
  }
}

function usageMetadata(usage) {
  if (!usage || typeof usage !== 'object') return undefined;
  return {
    promptTokenCount: usage.prompt_tokens || 0,
    candidatesTokenCount: usage.completion_tokens || 0,
    totalTokenCount: usage.total_tokens || 0
  };
}

function finishReason(reason) {
  switch (reason) {
    case 'length': return 'MAX_TOKENS';
    case 'content_filter': return 'SAFETY';
    // Function calls are parts, not a Gemini finish-reason enum value.
    default: return 'STOP';
  }
}

function envelope(response) {
  return `data: ${JSON.stringify({ response })}\n\n`;
}

async function* openAIEvents(source) {
  const decoder = new StringDecoder('utf8');
  let buffer = '';
  const parse = event => {
    const lines = event.split(/\r?\n/).filter(line => line.startsWith('data:'));
    if (!lines.length) return null;
    const data = lines.map(line => line.slice(5).replace(/^ /, '')).join('\n');
    if (!data) return null;
    if (data.trim() === '[DONE]') return { done: true };
    try { return JSON.parse(data); } catch (_) { throw new Error('CLI Proxy API returned malformed stream data.'); }
  };
  for await (const chunk of source) {
    buffer += decoder.write(chunk);
    let boundary;
    while ((boundary = /\r?\n\r?\n/.exec(buffer))) {
      const event = parse(buffer.slice(0, boundary.index));
      buffer = buffer.slice(boundary.index + boundary[0].length);
      if (event) yield event;
      if (event?.done) return;
    }
    if (Buffer.byteLength(buffer) > MAX_BODY_BYTES) throw new Error('CLI Proxy API stream event exceeds the size limit.');
  }
  buffer += decoder.end();
  if (buffer.trim()) {
    const event = parse(buffer);
    if (event) yield event;
  }
}

async function* translatedEnvelopes(source) {
  const toolCalls = new Map();
  let reason;
  let usage;
  let receivedChoice = false;
  let finished = false;
  let argumentBytes = 0;
  for await (const parsed of openAIEvents(source)) {
    if (parsed.error) throw new Error('CLI Proxy API returned a generation error in the stream.');
    if (parsed.done) { finished = true; break; }
    if (parsed.usage) usage = parsed.usage;
    const choice = parsed.choices?.[0];
    if (!choice) continue;
    receivedChoice = true;
    const delta = choice.delta || {};
    if (delta.content) yield envelope({ candidates: [{ content: { role: 'model', parts: [{ text: delta.content }] }, index: 0 }] });
    const reasoning = delta.reasoning_content || delta.reasoning || delta.thought;
    if (reasoning) yield envelope({ candidates: [{ content: { role: 'model', parts: [{ text: reasoning, thought: true }] }, index: 0 }] });
    for (const call of Array.isArray(delta.tool_calls) ? delta.tool_calls : []) {
      const index = call.index ?? 0;
      const current = toolCalls.get(index) || { id: call.id || `call_${index}`, name: '', arguments: '' };
      if (call.id) current.id = call.id;
      if (call.function?.name) current.name += call.function.name;
      if (call.function?.arguments) {
        argumentBytes += Buffer.byteLength(call.function.arguments);
        if (argumentBytes > MAX_BODY_BYTES) throw new Error('CLI Proxy API tool arguments exceed the size limit.');
        current.arguments += call.function.arguments;
      }
      toolCalls.set(index, current);
    }
    if (choice.finish_reason) reason = finishReason(choice.finish_reason);
  }
  if (!receivedChoice || (!finished && !reason)) throw new Error('CLI Proxy API closed the stream before generation completed.');
  const parts = [...toolCalls.values()].map(call => {
    const args = JSON.parse(call.arguments || '{}');
    if (!call.name || !args || typeof args !== 'object' || Array.isArray(args)) throw new Error('CLI Proxy API returned an invalid function call.');
    return { functionCall: { id: call.id, name: call.name, args } };
  });
  yield envelope({
    candidates: [{ content: { role: 'model', parts }, finishReason: reason || 'STOP', index: 0 }],
    ...(usage ? { usageMetadata: usageMetadata(usage) } : {})
  });
}

async function translateOpenAIStream(response, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform'
  });
  await pipeline(response, translatedEnvelopes, res);
}

function translateOpenAIResponse(value) {
  if (value?.error || !value?.choices?.[0]?.message) throw new Error('CLI Proxy API returned an invalid generation response.');
  const choice = value.choices[0];
  const message = choice.message;
  const parts = [];
  if (message.reasoning_content) parts.push({ text: message.reasoning_content, thought: true });
  if (message.content) parts.push({ text: message.content });
  for (const call of message.tool_calls || []) {
    const args = JSON.parse(call.function.arguments || '{}');
    if (!call.function.name || !args || typeof args !== 'object' || Array.isArray(args)) throw new Error('CLI Proxy API returned an invalid function call.');
    parts.push({ functionCall: { id: call.id, name: call.function.name, args } });
  }
  return { response: {
    candidates: [{ content: { role: 'model', parts }, finishReason: finishReason(choice.finish_reason), index: 0 }],
    ...(value.usage ? { usageMetadata: usageMetadata(value.usage) } : {})
  } };
}

async function routeGeneration(req, res, config, stream, idleTimeoutMs) {
  if (!config.apiKey) {
    sendJSON(res, 503, { error: { message: 'Configure an enabled CLI Proxy API provider with an API key in Bigroute.' } });
    req.resume();
    return;
  }
  let endpoint;
  let payload;
  try {
    endpoint = chatEndpoint(config.nineRouterUrl);
    const body = readJSON(decodedBody(await readBounded(req), req.headers['content-encoding']));
    if (!body || !Array.isArray(generationRequest(body).contents)) throw new Error('Unsupported generation request format.');
    payload = buildOpenAIPayload(body, config);
    payload.stream = stream;
    if (stream) payload.stream_options = { include_usage: true };
  } catch (error) {
    sendJSON(res, 400, { error: { message: error.message } });
    return;
  }
  const upstream = attachUpstream(req, res, endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: stream ? 'text/event-stream' : 'application/json', Authorization: `Bearer ${config.apiKey}` }
  }, idleTimeoutMs);
  const responsePromise = receiveResponse(upstream);
  upstream.end(JSON.stringify(payload));
  try {
    const response = await responsePromise;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      res.writeHead(response.statusCode || 502, relayResponseHeaders(response.headers));
      await pipeline(response, res);
    } else if (stream && response.headers['content-type']?.includes('text/event-stream')) {
      await translateOpenAIStream(response, res);
    } else {
      const result = translateOpenAIResponse(readJSON(decodedBody(await readBounded(response), response.headers['content-encoding'])));
      if (stream) {
        res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-cache, no-transform' });
        res.end(envelope(result.response));
      } else {
        sendJSON(res, 200, result);
      }
    }
  } finally {
    upstream.destroy();
  }
}

function createBridgeServer({ googleUpstream = GOOGLE_UPSTREAM, configProvider = loadConfig, idleTimeoutMs = 300_000 } = {}) {
  let modelAliases = {};
  const server = http.createServer(async (req, res) => {
    try {
      const cleanURL = normalizeCloudCodeURL(req.url);
      const target = new URL(googleUpstream);
      const parsed = new URL(`http://127.0.0.1${cleanURL}`);
      target.pathname = parsed.pathname;
      target.search = parsed.search;
      if (parsed.pathname === '/health' && req.method === 'GET') {
        sendJSON(res, 200, { status: 'ok', proxy: 'antigravity-cliproxy-bridge', version: '1.7.0', scriptHash: SCRIPT_HASH, pid: process.pid });
        return;
      }
      // Only exact, known Cloud Code RPCs are translated. New paths, remote
      // sessions, experiment flags and all other services are transparent.
      const rpc = req.method === 'POST' ? /^\/v\d+[a-z]*:(\w+)$/.exec(parsed.pathname)?.[1] : undefined;
      if (rpc === 'streamGenerateContent' || rpc === 'generateContent') {
        await routeGeneration(req, res, { ...configProvider(), modelAliases }, rpc === 'streamGenerateContent', idleTimeoutMs);
      } else if (rpc === 'fetchAvailableModels') {
        await forwardToGoogle(req, res, target, idleTimeoutMs, official => {
          modelAliases = {};
          for (const [id, details] of Object.entries(modelMap(official))) {
            if (typeof details?.model === 'string') modelAliases[details.model] = id;
          }
          const config = configProvider();
          return config.apiKey ? buildModelsResponse(official, config) : official;
        });
      } else if (rpc === 'retrieveUserQuotaSummary') {
        await forwardToGoogle(req, res, target, idleTimeoutMs, official => configProvider().apiKey ? buildQuotaResponse(official) : official);
      } else {
        await forwardToGoogle(req, res, target, idleTimeoutMs);
      }
    } catch (error) {
      // Never turn a truncated reply into a successful response, or leave the
      // client waiting forever after response headers have been sent.
      if (!res.destroyed) {
        log('Request failed:', error.code || error.name);
        if (res.headersSent) res.destroy();
        else sendJSON(res, 502, { error: { message: 'Bridge upstream request failed. Please retry.' } });
      }
    }
  });
  server.requestTimeout = 120_000;
  server.headersTimeout = 60_000;
  server.keepAliveTimeout = 5_000;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const server = createBridgeServer();
  server.on('error', error => { log('Bridge server error:', error.code); process.exitCode = 1; });
  server.listen(PORT, HOST, () => log(`Bridge 1.6.0 listening on ${HOST}:${PORT}`));
  const shutdown = () => {
    server.close();
    server.closeAllConnections();
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
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
  relayRequestHeaders,
  relayResponseHeaders,
  translateOpenAIStream,
  translatedEnvelopes,
  chatEndpoint,
  createBridgeServer
};
