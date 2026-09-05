import test from 'node:test';
import assert from 'node:assert/strict';

import {
  relayRequestHeaders,
  relayResponseHeaders
} from '../Sources/BigrouteCore/Resources/antigravity-bridge-proxy.mjs';

test('request relay removes hop-by-hop and connection-token headers', () => {
  const headers = relayRequestHeaders({
    host: '127.0.0.1:50999',
    connection: 'keep-alive, x-custom-hop',
    'content-length': '12',
    'transfer-encoding': 'chunked',
    'x-custom-hop': 'drop-me',
    authorization: 'Bearer test'
  }, 'daily-cloudcode-pa.googleapis.com');

  assert.equal(headers.host, 'daily-cloudcode-pa.googleapis.com');
  assert.equal(headers.authorization, 'Bearer test');
  assert.equal(headers.connection, undefined);
  assert.equal(headers['content-length'], undefined);
  assert.equal(headers['transfer-encoding'], undefined);
  assert.equal(headers['x-custom-hop'], undefined);
});

test('discovery relay omits compression negotiation', () => {
  const headers = relayRequestHeaders({
    connection: 'close',
    'accept-encoding': 'gzip',
    authorization: 'Bearer test'
  }, 'daily-cloudcode-pa.googleapis.com', { stripAcceptEncoding: true });

  assert.equal(headers['accept-encoding'], undefined);
  assert.equal(headers.authorization, 'Bearer test');
});

test('response relay keeps end-to-end headers and removes connection framing', () => {
  const headers = relayResponseHeaders({
    connection: 'keep-alive, x-response-hop',
    'keep-alive': 'timeout=5',
    'transfer-encoding': 'chunked',
    'x-response-hop': 'drop-me',
    'content-type': 'application/json',
    'content-encoding': 'gzip'
  });

  assert.equal(headers['content-type'], 'application/json');
  assert.equal(headers['content-encoding'], 'gzip');
  assert.equal(headers.connection, undefined);
  assert.equal(headers['keep-alive'], undefined);
  assert.equal(headers['transfer-encoding'], undefined);
  assert.equal(headers['x-response-hop'], undefined);
});

import http from 'node:http';
import { once } from 'node:events';
import { Readable } from 'node:stream';
import { gzipSync } from 'node:zlib';
import {
  buildModelsResponse, buildOpenAIPayload, chatEndpoint, createBridgeServer, customModelSlug,
  geminiToOpenAIMessages, normalizeCloudCodeURL, resolveNineRouterModel, translatedEnvelopes
} from '../Sources/BigrouteCore/Resources/antigravity-bridge-proxy.mjs';

const config = { apiKey: 'test-key', nineRouterUrl: 'http://127.0.0.1', modelMode: 'keep_official', customModels: [] };
const generation = { model: 'gemini-current', request: { contents: [{ role: 'user', parts: [{ text: 'Hello' }] }] } };

async function listen(t, server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  });
  return `http://127.0.0.1:${server.address().port}`;
}

async function fixture(t, handler, options = {}) {
  const upstream = await listen(t, http.createServer(handler));
  const bridge = await listen(t, createBridgeServer({
    googleUpstream: upstream, configProvider: () => ({ ...config, nineRouterUrl: upstream }), ...options
  }));
  return { bridge, upstream };
}

function request(url, { body, headers = {}, method = body == null ? 'GET' : 'POST' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(url, { method, headers }, async res => {
      try {
        const chunks = [];
        for await (const chunk of res) chunks.push(chunk);
        resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) });
      } catch (error) { reject(error); }
    });
    req.on('error', reject);
    req.end(body);
  });
}

async function translated(chunks) {
  const result = [];
  for await (const chunk of translatedEnvelopes(Readable.from(chunks))) {
    result.push(JSON.parse(chunk.slice(6)).response);
  }
  return result;
}

const event = value => `data: ${JSON.stringify(value)}\r\n\r\n`;

test('remote back/open cycles preserve bodies, status and discovery flags', { timeout: 5000 }, async t => {
  let requests = 0;
  const { bridge } = await fixture(t, async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    requests++;
    res.writeHead(200, { 'Content-Type': 'application/json', 'X-Remote-Session': String(requests) });
    res.end(JSON.stringify({ request: Buffer.concat(chunks).toString(), relay: 'jetski-webchannel.googleapis.com', experiments: { future: true } }));
  });
  for (let i = 0; i < 20; i++) {
    const body = JSON.stringify({ conversation: i % 2 ? 'second' : 'first' });
    const result = await request(`${bridge}/v1internal:listExperiments?note=generateContent`, { body });
    assert.equal(result.status, 200);
    assert.equal(result.headers['x-remote-session'], String(i + 1));
    assert.deepEqual(JSON.parse(result.body), { request: body, relay: 'jetski-webchannel.googleapis.com', experiments: { future: true } });
  }
});

test('large compressed remote responses and unknown RPCs pass through unchanged', { timeout: 5000 }, async t => {
  const bytes = gzipSync(Buffer.from('remote conversation '.repeat(100_000)));
  const { bridge } = await fixture(t, (req, res) => {
    assert.equal(req.url, '/v2internal:newRemoteSession?session=second');
    res.writeHead(201, { 'Content-Encoding': 'gzip', 'Content-Length': bytes.length });
    res.end(bytes);
  });
  const result = await request(`${bridge}/v2internal:newRemoteSession?session=second`);
  assert.equal(result.status, 201);
  assert.equal(result.headers['content-encoding'], 'gzip');
  assert.deepEqual(result.body, bytes);
});

test('remote cancellation closes its upstream and the next conversation succeeds', { timeout: 5000 }, async t => {
  let closed;
  const canceled = new Promise(resolve => { closed = resolve; });
  const { bridge } = await fixture(t, (req, res) => {
    if (req.url === '/remote/first') {
      res.on('close', closed);
      res.write('waiting');
    } else res.end('second conversation');
  });
  await new Promise((resolve, reject) => {
    const req = http.get(`${bridge}/remote/first`, res => res.once('data', () => { req.destroy(); resolve(); }));
    req.on('error', reject);
  });
  await canceled;
  assert.equal((await request(`${bridge}/remote/second`)).body.toString(), 'second conversation');
});

test('generation cancellation stops upstream work', { timeout: 5000 }, async t => {
  let closed;
  const canceled = new Promise(resolve => { closed = resolve; });
  const { bridge } = await fixture(t, (req, res) => {
    req.resume();
    res.on('close', closed);
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write(event({ choices: [{ delta: { content: 'Hello' } }] }));
  });
  await new Promise((resolve, reject) => {
    const req = http.request(`${bridge}/v1internal:streamGenerateContent`, { method: 'POST' }, res => res.once('data', () => { req.destroy(); resolve(); }));
    req.on('error', reject);
    req.end(JSON.stringify(generation));
  });
  await canceled;
  assert.equal((await request(`${bridge}/health`)).status, 200);
});

test('truncated remote response is not reported as success and bridge remains alive', { timeout: 5000 }, async t => {
  const { bridge } = await fixture(t, (req, res) => {
    res.writeHead(200, { 'Content-Length': 1000 });
    res.write('partial');
    setImmediate(() => res.destroy());
  });
  await assert.rejects(request(`${bridge}/remote/first`));
  assert.equal((await request(`${bridge}/health`)).status, 200);
});

test('idle upstream fails within its deadline', { timeout: 5000 }, async t => {
  const { bridge } = await fixture(t, req => req.resume(), { idleTimeoutMs: 50 });
  assert.equal((await request(`${bridge}/remote/stalled`)).status, 502);
  assert.equal((await request(`${bridge}/health`)).status, 200);
});

test('discovery handles gzip even when upstream ignores identity encoding', { timeout: 5000 }, async t => {
  const official = { models: { current: { model: 'MODEL_PLACEHOLDER_M99', quotaInfo: { remainingFraction: 0 } } }, remoteControl: { version: 99 }, newField: ['keep'] };
  const { bridge } = await fixture(t, (req, res) => {
    assert.equal(req.headers['accept-encoding'], 'identity');
    res.writeHead(200, { 'Content-Encoding': 'gzip', 'Content-Type': 'application/json', ETag: 'old' });
    res.end(gzipSync(JSON.stringify(official)));
  });
  const result = await request(`${bridge}/v1internal:fetchAvailableModels`, { body: '{}' });
  const models = JSON.parse(result.body);
  assert.equal(models.models.current.quotaInfo.remainingFraction, 1);
  assert.deepEqual(models.remoteControl, official.remoteControl);
  assert.deepEqual(models.newField, official.newField);
  assert.equal(result.headers['content-encoding'], undefined);
  assert.equal(result.headers.etag, undefined);
});

test('unknown discovery schema is not replaced by a hardcoded catalogue', { timeout: 5000 }, async t => {
  const body = '{ "newModelsSchema": ["future"], "remote": true }';
  const { bridge } = await fixture(t, (req, res) => res.end(body));
  const result = await request(`${bridge}/v1internal:fetchAvailableModels`, { body: '{}' });
  assert.equal(result.body.toString(), body);
});

test('custom model discovery preserves unknown official metadata', () => {
  const official = { models: { gemini: { model: 'MODEL_PLACEHOLDER_M50', futureCapability: true } }, remoteFlags: { relay: 'keep' } };
  const result = buildModelsResponse(official, { ...config, modelMode: 'custom', customModels: [{ id: 'cx/example' }] });
  assert.deepEqual(result.remoteFlags, official.remoteFlags);
  assert.equal(result.models[customModelSlug({ id: 'cx/example' }, 0)].futureCapability, true);
});

test('distinct custom routes never collapse into the same normalized picker ID', () => {
  const custom = { ...config, modelMode: 'custom', customModels: [{ id: 'cx/model.1' }, { id: 'cx/model-1' }] };
  const official = { models: { current: { model: 'MODEL_PLACEHOLDER_M50' } } };
  const result = buildModelsResponse(official, custom);
  assert.equal(new Set(result.commandModelIds).size, 2);
  for (const [index, model] of custom.customModels.entries()) {
    assert.equal(resolveNineRouterModel({ model: result.commandModelIds[index] }, custom), model.id);
  }
  assert.throws(() => resolveNineRouterModel({ model: 'custom-cx-model-1' }, custom), /ambiguous/);
  assert.equal(resolveNineRouterModel({ model: 'custom-cx-example' }, { ...custom, customModels: [{ id: 'cx/example' }] }), 'cx/example');
});

test('model aliases use current discovery and routed model prefixes remain intact', () => {
  assert.equal(resolveNineRouterModel({ model: 'models/MODEL_PLACEHOLDER_M99' }, { ...config, modelAliases: { MODEL_PLACEHOLDER_M99: 'current-model' } }), 'ag/current-model');
  assert.equal(resolveNineRouterModel({ model: 'new-provider/model' }, config), 'new-provider/model');
});

test('SSE decoding preserves Vietnamese and emoji across every byte boundary', async () => {
  const bytes = Buffer.from(event({ choices: [{ delta: { content: 'Xin chào 👋' } }] }) + event({ choices: [{ delta: {}, finish_reason: 'stop' }] }) + 'data: [DONE]\r\n\r\n');
  const results = await translated([...bytes].map(byte => Buffer.from([byte])));
  assert.equal(results[0].candidates[0].content.parts[0].text, 'Xin chào 👋');
  assert.equal(results.at(-1).candidates[0].finishReason, 'STOP');
  assert.equal(results.filter(r => r.candidates[0].finishReason).length, 1);
});

test('tool calls produce a valid Gemini finish reason and include trailing usage', async () => {
  const results = await translated([Buffer.from(
    event({ choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_a', function: { name: 'read_file', arguments: '{"path":' } }] } }] })
    + event({ choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '"test.swift"}' } }] }, finish_reason: 'tool_calls' }] })
    + event({ choices: [], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })
    + 'data: [DONE]\n\n'
  )]);
  const final = results.at(-1);
  assert.equal(final.candidates[0].finishReason, 'STOP');
  assert.deepEqual(final.candidates[0].content.parts, [{ functionCall: { id: 'call_a', name: 'read_file', args: { path: 'test.swift' } } }]);
  assert.equal(final.usageMetadata.totalTokenCount, 15);
});

test('malformed tool JSON and incomplete streams fail instead of fabricating success', async () => {
  await assert.rejects(translated([Buffer.from(event({ choices: [{ delta: { tool_calls: [{ function: { name: 'tool', arguments: '{bad' } }] }, finish_reason: 'tool_calls' }] }))]));
  await assert.rejects(translated([Buffer.from(event({ choices: [{ delta: { content: 'partial' } }] }))]));
  await assert.rejects(translated([Buffer.from('data: {not-json}\n\n')]));
});

test('tool responses immediately follow their calls and explicit IDs leave no stale queue', () => {
  const messages = geminiToOpenAIMessages([
    { role: 'model', parts: [{ functionCall: { name: 'read', id: 'a', args: {} } }, { functionCall: { name: 'read', id: 'b', args: {} } }] },
    { role: 'user', parts: [{ functionResponse: { name: 'read', id: 'a', response: {} } }] },
    { role: 'user', parts: [{ functionResponse: { name: 'read', response: { done: true } } }, { text: 'Next' }] }
  ]);
  assert.deepEqual(messages.map(m => m.role), ['assistant', 'tool', 'tool', 'user']);
  assert.equal(messages[2].tool_call_id, 'b');
});

test('payload preserves tool policy and does not put thoughts in visible content', () => {
  const payload = buildOpenAIPayload({ model: 'gemini-current', request: {
    contents: [{ role: 'model', parts: [{ text: 'internal', thought: true }, { text: 'visible' }] }],
    tools: [{ functionDeclarations: [{ name: 'read', parametersJsonSchema: { type: 'OBJECT', properties: {} } }] }],
    toolConfig: { functionCallingConfig: { mode: 'NONE' } }
  } }, config);
  assert.equal(payload.messages[0].content, 'visible');
  assert.equal(payload.messages[0].reasoning_content, 'internal');
  assert.equal(payload.tool_choice, 'none');
  assert.equal(payload.tools[0].function.parameters.type, 'object');
});

test('unsupported media is explicit rather than silently discarded', () => {
  assert.throws(() => geminiToOpenAIMessages([{ parts: [{ inlineData: { mimeType: 'audio/wav', data: 'abc' } }] }]));
});

test('quota endpoints resolve to inference paths and credentials never go to insecure hosts', () => {
  assert.equal(chatEndpoint('https://router.example/base/v1/quota').pathname, '/base/v1/chat/completions');
  assert.equal(chatEndpoint('https://router.example/v1/chat/completions/').pathname, '/v1/chat/completions/');
  for (const url of ['http://router.example', 'https://user:pass@router.example', 'https://router.example?key=value', 'file:///tmp/test']) assert.throws(() => chatEndpoint(url));
});

test('synchronous generation returns JSON instead of SSE', { timeout: 5000 }, async t => {
  const { bridge } = await fixture(t, async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks));
    assert.equal(payload.stream, false);
    assert.equal(req.url, '/v1/chat/completions');
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ choices: [{ message: { content: 'answer' }, finish_reason: 'stop' }] }));
  });
  const result = await request(`${bridge}/v1internal:generateContent`, { body: JSON.stringify(generation) });
  assert.match(result.headers['content-type'], /application\/json/);
  assert.equal(JSON.parse(result.body).response.candidates[0].content.parts[0].text, 'answer');
});

test('missing API key fails clearly without silently billing Google', { timeout: 5000 }, async t => {
  let upstreamCalls = 0;
  const { bridge } = await fixture(t, (req, res) => { upstreamCalls++; res.end('{}'); }, { configProvider: () => ({ ...config, apiKey: '' }) });
  const result = await request(`${bridge}/v1internal:generateContent`, { body: JSON.stringify(generation) });
  assert.equal(result.status, 503);
  assert.equal(upstreamCalls, 0);
});

test('path padding is normalized without interpreting another upstream origin', () => {
  assert.equal(normalizeCloudCodeURL('/v1internal/xxxxxxx/v1internal:listExperiments?x=1'), '/v1internal:listExperiments?x=1');
  assert.equal(normalizeCloudCodeURL('/dummy_path_padding/v1internal:fetchAvailableModels'), '/v1internal:fetchAvailableModels');
  assert.equal(normalizeCloudCodeURL('//other.example/v1internal:fetchAvailableModels'), '//other.example/v1internal:fetchAvailableModels');
});
