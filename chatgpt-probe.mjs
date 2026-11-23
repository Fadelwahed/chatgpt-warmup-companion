import https from 'node:https';

const MAX = 256 * 1024;
const MARKER = 'WARMUP_OK';
const PROBE_TIMEOUT_MS = 45000;
const transportCodes = new Set([
  'ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'EHOSTUNREACH', 'ENETUNREACH',
  'ERR_SSL_WRONG_VERSION_NUMBER', 'ERR_SSL_TLSV1_ALERT_PROTOCOL_VERSION', 'ERR_TLS_CERT_ALTNAME_INVALID',
  'CERT_HAS_EXPIRED', 'SELF_SIGNED_CERT_IN_CHAIN', 'DEPTH_ZERO_SELF_SIGNED_CERT', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
  'UNABLE_TO_GET_ISSUER_CERT', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY',
]);

export const safeTransportCode = value => transportCodes.has(value) ? value : undefined;
const protocolTag = Symbol('protocol_failure');
const protocolError = code => Object.assign(new Error(code), { [protocolTag]: true });
const clean = value => typeof value === 'string' && value.length > 0 && value.length <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
const token = value => typeof value === 'string' && value.length > 0 && value.length <= 65536 && !/[\u0000-\u001f\u007f]/.test(value);
const plain = value => value !== null && typeof value === 'object' && !Array.isArray(value);
// Reviewed Codex client signal, not an exhaustive backend model-error contract.
const modelNotFound = error => plain(error) && error.code === 'model_not_found';

export async function* parseSSE(chunks) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let pending = '', total = 0, lines = [], event = '';
  const emit = () => { const out = { event: event || 'message', data: lines.join('\n') }; lines = []; event = ''; return out; };
  for await (const chunk of chunks) {
    total += chunk.byteLength;
    if (total > MAX) throw protocolError('stream_oversize');
    try { pending += decoder.decode(chunk, { stream: true }); } catch { throw protocolError('invalid_utf8'); }
    if (Buffer.byteLength(pending) > MAX) throw protocolError('frame_oversize');
    while (true) {
      const index = pending.indexOf('\n');
      if (index < 0) break;
      const raw = pending.slice(0, index); pending = pending.slice(index + 1);
      const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
      if (line === '') { if (lines.length) yield emit(); else event = ''; continue; }
      if (line.startsWith(':')) continue;
      const colon = line.indexOf(':');
      const key = colon < 0 ? line : line.slice(0, colon);
      const value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
      if (key === 'event') event = value;
      if (key === 'data') lines.push(value);
      if (Buffer.byteLength(lines.join('\n')) > MAX) throw protocolError('frame_oversize');
    }
  }
  try { pending += decoder.decode(); } catch { throw protocolError('invalid_utf8'); }
  if (pending) throw new Error('stream_truncated');
  if (lines.length || event) throw new Error('stream_truncated');
}

// Requested reasoning may precede the reply; its content is never marker text.
// Key order is not content: streamed and terminal copies of an item are compared with sorted keys.
const canonical = value => JSON.stringify(value, (_key, v) => plain(v) ? Object.fromEntries(Object.keys(v).sort().map(key => [key, v[key]])) : v);
const reasoningItem = item => plain(item) && item.type === 'reasoning' && clean(item.id);

function assistantText(output) {
  if (!Array.isArray(output)) throw protocolError('bad_output');
  let text = '', total = 0;
  for (const item of output) {
    if (reasoningItem(item)) continue;
    if (!plain(item) || item.type !== 'message' || item.role !== 'assistant' || !Array.isArray(item.content)) throw protocolError('bad_output');
    text = '';
    for (const part of item.content) {
      if (!plain(part) || part.type !== 'output_text' || typeof part.text !== 'string') throw protocolError('bad_output');
      text += part.text;
      total += Buffer.byteLength(part.text);
      if (total > MAX) throw protocolError('output_oversize');
    }
  }
  return text;
}

async function completed(body, expired, clock) {
  const items = new Map(), ids = new Map(), deltas = new Map();
  let terminal = null, failed = false, unsupported = false, storage = 0, responseId;
  let firstOutputAt;
  for await (const frame of parseSSE(body)) {
    if (expired()) throw new Error('deadline_exceeded');
    if (frame.data === '[DONE]') continue;
    if (terminal || failed) throw protocolError('event_after_terminal');
    let value;
    try { value = JSON.parse(frame.data); } catch { throw protocolError('bad_event'); }
    if (!plain(value) || typeof value.type !== 'string' || frame.event !== 'message' && frame.event !== value.type) throw protocolError('bad_event');
    for (const id of [value.response_id, value.response?.id]) {
      if (id === undefined) continue;
      if (!clean(id) || responseId !== undefined && responseId !== id) throw protocolError('conflicting_response');
      responseId = id;
    }
    if (value.type === 'response.output_text.delta') {
      const { item_id: itemId, output_index: index, content_index: partIndex, delta } = value;
      if (clean(itemId) && Number.isSafeInteger(index) && index >= 0 && Number.isSafeInteger(partIndex) && partIndex >= 0 &&
          typeof delta === 'string' && delta.length > 0) {
        const key = JSON.stringify([itemId, index, partIndex]);
        const part = deltas.get(key);
        if (part) part.text += delta;
        else deltas.set(key, { itemId, index, partIndex, text: delta, at: clock.mono() });
      }
    } else if (value.type === 'response.output_item.done') {
      const index = value.output_index, item = value.item;
      if (!Number.isSafeInteger(index) || index < 0 || !plain(item) || !clean(item.id) || item.type !== 'message' && !reasoningItem(item)) throw protocolError('bad_item');
      const text = assistantText([item]);
      const serial = canonical(item);
      storage += Buffer.byteLength(serial);
      if (storage > MAX) throw protocolError('output_oversize');
      if (items.has(index) && items.get(index) !== serial || ids.has(item.id) && ids.get(item.id) !== index) throw protocolError('conflicting_item');
      items.set(index, serial); ids.set(item.id, index);
      if (text.length > 0) firstOutputAt ??= clock.mono();
    } else if (value.type === 'response.completed') {
      if (terminal || value.response?.status !== 'completed') throw protocolError('bad_terminal');
      terminal = value.response;
      if (terminal.output !== undefined && !Array.isArray(terminal.output)) throw protocolError('bad_terminal');
      const terminalIds = new Set();
      for (const item of terminal.output ?? []) {
        if (item?.id === undefined) continue;
        if (!clean(item.id) || terminalIds.has(item.id)) throw protocolError('conflicting_terminal');
        terminalIds.add(item.id);
      }
      if (Buffer.byteLength(JSON.stringify(terminal.output ?? [])) + storage > MAX) throw protocolError('output_oversize');
      if (terminal.output?.length) firstOutputAt ??= clock.mono();
    } else if (value.type === 'response.failed' || value.type === 'response.incomplete' || value.type === 'error') {
      failed = true;
      unsupported = value.type === 'error' && modelNotFound(value.error) || value.type === 'response.failed' && modelNotFound(value.response?.error);
    }
  }
  if (unsupported) return { reason: 'unsupported_model' };
  if (failed || !terminal) throw new Error('incomplete_response');
  const reconstructed = new Map([...items].sort((a,b) => a[0] - b[0]).map(([index, serial]) => [index, JSON.parse(serial)]));
  const terminalOutput = terminal.output?.length ? terminal.output : null;
  const output = terminalOutput ?? [...reconstructed.values()];
  if (terminalOutput && items.size) {
    for (const [index, serial] of items) {
      const item = terminal.output[index];
      if (!item || canonical(item) !== serial) throw protocolError('conflicting_terminal');
    }
  }
  if (assistantText(output).trim() !== MARKER) return { reason: 'output_mismatch' };
  let firstTextAt = firstOutputAt ?? Infinity;
  for (const { itemId, index, partIndex, text, at } of deltas.values()) {
    const item = terminalOutput ? terminalOutput[index] : reconstructed.get(index);
    if (item?.type === 'message' && item.id === itemId && item.content[partIndex]?.text === text) firstTextAt = Math.min(firstTextAt, at);
  }
  return { reason: 'marker_confirmed', firstTextAt };
}

async function httpModelError(body, expired) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let text = '', total = 0;
  for await (const chunk of body) {
    if (expired()) throw new Error('deadline_exceeded');
    total += chunk.byteLength;
    if (total > MAX) throw protocolError('body_oversize');
    try { text += decoder.decode(chunk, { stream: true }); } catch { throw protocolError('invalid_utf8'); }
  }
  if (expired()) throw new Error('deadline_exceeded');
  try { text += decoder.decode(); } catch { throw protocolError('invalid_utf8'); }
  try { return modelNotFound(JSON.parse(text)?.error); } catch { return false; }
}

function retryAfter(headers, now) {
  const raw = headers?.['retry-after'];
  if (typeof raw !== 'string') return undefined;
  if (/^\d+$/.test(raw)) {
    const at = now + Number(raw) * 1000;
    // An unrepresentable valid delay blocks indefinitely instead of permitting an earlier retry.
    return Number.isSafeInteger(at) && at <= 8640000000000000 ? at : Number.MAX_VALUE;
  }
  let match, weekday, day, month, year, hour, minute, second, obsolete = false;
  if ((match = /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat), (\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/.exec(raw))) {
    [, weekday, day, month, year, hour, minute, second] = match;
  } else if ((match = /^(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday), (\d{2})-(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$/.exec(raw))) {
    [, weekday, day, month, year, hour, minute, second] = match;
    year = Number(year) + Math.floor((new Date(now).getUTCFullYear() + 50 - Number(year)) / 100) * 100;
    obsolete = true;
  } else if ((match = /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{2}| \d) (\d{2}):(\d{2}):(\d{2}) (\d{4})$/.exec(raw))) {
    [, weekday, month, day, hour, minute, second, year] = match;
  } else return undefined;
  [day, year, hour, minute, second] = [day, year, hour, minute, second].map(Number);
  month = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'].indexOf(month);
  if (day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return undefined;
  const date = new Date(0);
  date.setUTCFullYear(year, month, day);
  date.setUTCHours(hour, minute, Math.min(second, 59), 0);
  if (obsolete) {
    const boundary = new Date(now);
    boundary.setUTCFullYear(boundary.getUTCFullYear() + 50);
    if (date.getTime() + (second === 60 ? 1000 : 0) > boundary.getTime()) {
      year -= 100;
      date.setUTCFullYear(year, month, day);
    }
  }
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month || date.getUTCDate() !== day || ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][date.getUTCDay()] !== weekday.slice(0, 3)) return undefined;
  // Date cannot represent leap seconds; wait through the following representable second.
  const at = date.getTime() + (second === 60 ? 1000 : 0);
  return at > now ? at : undefined;
}

// Usage-window headers the Codex backend sends with each response (primary is the short window,
// secondary the weekly one). Read-only evidence: only bounded numbers are kept, never raw text.
const USAGE_WINDOWS = ['primary', 'secondary'];
function headerNumber(headers, name, pattern) {
  const raw = headers?.[name];
  return typeof raw === 'string' && pattern.test(raw) ? Number(raw) : undefined;
}
export function usageWindows(headers, now) {
  const usage = {};
  for (const window of USAGE_WINDOWS) {
    const prefix = `x-codex-${window}-`;
    const used = headerNumber(headers, `${prefix}used-percent`, /^\d{1,3}(?:\.\d{1,4})?$/);
    const minutes = headerNumber(headers, `${prefix}window-minutes`, /^\d{1,6}$/);
    const resetAt = headerNumber(headers, `${prefix}reset-at`, /^\d{9,11}$/);
    const resetAfter = headerNumber(headers, `${prefix}reset-after-seconds`, /^\d{1,8}$/);
    const row = {};
    if (used !== undefined && used <= 100) row.usedPercent = used;
    if (minutes !== undefined && minutes > 0 && minutes <= 527040) row.windowMinutes = minutes;
    const resetsAt = resetAt !== undefined ? resetAt * 1000 : resetAfter !== undefined ? now + resetAfter * 1000 : undefined;
    if (Number.isSafeInteger(resetsAt) && resetsAt > now - 86400000 && resetsAt < now + 40 * 86400000) row.resetsAt = resetsAt;
    if (Object.keys(row).length) usage[window] = row;
  }
  return Object.keys(usage).length ? usage : undefined;
}

export async function probe({ credential, model = 'gpt-6-luna', batchDeadline, finalCheck } = {}, services) {
  const clock = services?.clock;
  const start = clock?.wall?.(), mono = clock?.mono?.();
  let dispatched = false, dispatchAt, timer, timedOut = false, rejection = {};
  const result = (outcome, reason, extra = {}) => ({ outcome, reason, dispatched, startedAt: start, endedAt: clock.wall(), durationMs: Math.max(0, clock.mono() - mono), ...extra });
  if (!clock || typeof services.request !== 'function' || !token(credential?.accessToken) || !clean(credential?.identity?.accountId) || !clean(model) || finalCheck !== undefined && typeof finalCheck !== 'function') return { outcome: 'blocked', reason: 'invalid_probe', dispatched: false, startedAt: start, endedAt: start, durationMs: 0 };
  const remaining = batchDeadline === undefined ? PROBE_TIMEOUT_MS : Math.min(PROBE_TIMEOUT_MS, batchDeadline - mono);
  if (!Number.isFinite(remaining) || remaining <= 0) return result('blocked', 'deadline_before_send');
  const body = JSON.stringify({ model, instructions: 'Reply exactly WARMUP_OK.', input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Reply exactly WARMUP_OK.' }] }], tools: [], tool_choice: 'auto', parallel_tool_calls: false, reasoning: { effort: 'low' }, store: false, stream: true });
  const options = { protocol: 'https:', hostname: 'chatgpt.com', port: 443, method: 'POST', path: '/backend-api/codex/responses', headers: { Authorization: `Bearer ${credential.accessToken}`, 'chatgpt-account-id': credential.identity.accountId, 'Content-Type': 'application/json', Accept: 'text/event-stream', 'User-Agent': 'codex-router-warmup/1.0' } };
  const controller = new AbortController();
  const deadlineError = new Error('deadline_before_send'), credentialError = new Error('credential_expired_or_unknown'), sendCheckError = new Error('send_check_failed');
  const passesFinalCheck = () => {
    try {
      const ok = finalCheck();
      // A promise is never a synchronous pass; observe it so a rejection can't go unhandled.
      if (typeof ok?.then === 'function') { Promise.resolve(ok).catch(() => {}); return false; }
      return Boolean(ok);
    } catch { return false; }
  };
  const inTime = () => {
    if (controller.signal.aborted || !Number.isFinite(clock.mono()) || clock.mono() - mono >= remaining) throw deadlineError;
    if (!Number.isFinite(credential.expiresAt) || !Number.isFinite(clock.wall()) || credential.expiresAt - clock.wall() < 120000) throw credentialError;
  };
  const beforeSend = () => {
    inTime();
    if (finalCheck && !passesFinalCheck()) throw sendCheckError;
    inTime();  // the Router check runs synchronously and may use the last of the budget
  };
  try {
    timer = clock.setTimeout(() => { timedOut = true; controller.abort(); }, remaining);
    const onDispatch = () => {
      dispatched = true;
      dispatchAt ??= clock.mono();
    };
    const response = await services.request(options, body, { signal: controller.signal, timeoutMs: remaining, beforeSend, onDispatch });
    if (controller.signal.aborted || clock.mono() - mono >= remaining) return result(dispatched ? 'uncertain' : 'blocked', 'deadline_exceeded');
    const status = response?.statusCode;
    if (!Number.isInteger(status)) return result(dispatched ? 'uncertain' : 'blocked', 'transport_unavailable');
    if (status >= 300 && status < 400) return result('blocked', 'redirect_refused', { httpStatus: status });
    const notBefore = status === 200 ? undefined : retryAfter(response.headers, clock.wall());
    const usage = Number.isFinite(clock.wall()) ? usageWindows(response.headers, clock.wall()) : undefined;
    rejection = { httpStatus: status, ...(notBefore === undefined ? {} : { notBefore }), ...(usage ? { usage } : {}) };
    const encoding = response.headers?.['content-encoding'];
    if (encoding && encoding !== 'identity') return result('blocked', 'protocol_failure', rejection);
    if (status !== 200) {
      const unsupported = [400, 403, 404].includes(status) && await httpModelError(response.body, () => controller.signal.aborted || clock.mono() - mono >= remaining);
      if (controller.signal.aborted || clock.mono() - mono >= remaining) return result(dispatched ? 'uncertain' : 'blocked', 'deadline_exceeded', rejection);
      const reason = unsupported ? 'unsupported_model' : status === 401 ? 'authentication_rejected' : status === 403 ? 'forbidden_or_challenged' : status === 429 ? 'rate_limited' : 'upstream_rejected';
      return result('blocked', reason, rejection);
    }
    const { reason, firstTextAt } = await completed(response.body, () => controller.signal.aborted || clock.mono() - mono >= remaining, clock);
    if (controller.signal.aborted || clock.mono() - mono >= remaining) return result(dispatched ? 'uncertain' : 'blocked', 'deadline_exceeded');
    const confirmed = reason === 'marker_confirmed';
    const elapsed = firstTextAt - dispatchAt;
    const extra = { httpStatus: status, ...(usage ? { usage } : {}) };
    if (confirmed && dispatched && Number.isFinite(elapsed)) {
      extra.firstTextMs = Math.min(PROBE_TIMEOUT_MS, Math.max(0, Math.round(elapsed)));
    }
    return result(confirmed ? 'success' : 'blocked', reason, extra);
  } catch (error) {
    const reason = timedOut ? 'deadline_exceeded' : error === deadlineError ? 'deadline_before_send' : error === credentialError ? 'credential_expired_or_unknown' : error === sendCheckError ? 'send_check_failed' : error?.[protocolTag] ? 'protocol_failure' : dispatched ? 'stream_or_transport_uncertain' : 'transport_before_send';
    const transportCode = reason === 'transport_before_send' ? safeTransportCode(error?.code) : undefined;
    return result(dispatched ? 'uncertain' : 'blocked', reason, transportCode ? { ...rejection, transportCode } : rejection);
  } finally { if (timer !== undefined) clock.clearTimeout(timer); controller.abort(); }
}

export function directRequest(options, body, { signal, beforeSend, onDispatch }) {
  return new Promise((resolve, reject) => {
    let received, refused = false;
    // Explicit, so NODE_TLS_REJECT_UNAUTHORIZED=0 in a shell cannot disable checks before the bearer is sent.
    const req = https.request({ ...options, agent: false, rejectUnauthorized: true }, response => { received = response; resolve({ statusCode: response.statusCode, headers: response.headers, body: response }); });
    req.on('error', reject);
    req.on('socket', socket => socket.once('secureConnect', () => {
      if (refused || signal?.aborted) return;
      try {
        if (typeof beforeSend !== 'function') throw new Error('missing_send_validation');
        beforeSend();
        onDispatch?.();
        req.end(body);
      } catch (error) { refused = true; req.destroy(); reject(error); }
    }));
    signal?.addEventListener('abort', () => { received?.destroy(); req.destroy(new Error('aborted')); }, { once: true });
    if (signal?.aborted) return req.destroy(new Error('aborted'));
  });
}
