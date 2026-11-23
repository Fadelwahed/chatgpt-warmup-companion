import test from 'node:test';
import assert from 'node:assert/strict';
import { fakeClock, requestStub } from './helpers.mjs';
import { probe, parseSSE, usageWindows } from '../chatgpt-probe.mjs';

const credential = { accessToken: 'CANARY_ACCESS', expiresAt: 4102444800000, identity: { accountId: 'workspace-a', userId: 'user-a' } };
const item = { id: 'item_1', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'WARMUP_OK' }] };
const binding = { item_id: item.id, output_index: 0, content_index: 0 };
const frame = (type, extra) => `event: ${type}\ndata: ${JSON.stringify({ type, ...extra })}\n\n`;
const stream = text => (async function* () { const bytes = Buffer.from(text); for (let i = 0; i < bytes.length; i += 3) yield bytes.subarray(i, i + 3); })();
const response = text => ({ statusCode: 200, headers: { 'content-encoding': 'identity' }, body: stream(text) });
function services(value) { return { clock: fakeClock(), request: requestStub(value) }; }

test('first text timing starts at dispatch and ignores metadata, reasoning, and empty deltas', async () => {
  const s = services(async (_options, _body, control) => {
    s.clock.advance(200);
    control.beforeSend(); control.onDispatch();
    return { statusCode: 200, headers: {}, body: (async function* () {
      s.clock.advance(5);
      yield Buffer.from(frame('response.created', { response: { status: 'in_progress' } }));
      s.clock.advance(7);
      yield Buffer.from(frame('response.reasoning_summary_text.delta', { delta: 'CANARY_REASONING' }));
      s.clock.advance(10);
      yield Buffer.from(frame('response.output_text.delta', { ...binding, delta: '' }));
      s.clock.setWall(s.clock.wall() + 7_000);
      s.clock.advance(20.25);
      yield Buffer.from(frame('response.output_text.delta', { ...binding, delta: 'WARMUP_' }));
      s.clock.advance(30);
      yield Buffer.from(frame('response.output_text.delta', { ...binding, delta: 'OK' }));
      s.clock.advance(50);
      yield Buffer.from(frame('response.completed', { response: { status: 'completed', output: [item] } }));
    })() };
  });
  const out = await probe({ credential }, s);
  assert.equal(out.reason, 'marker_confirmed');
  assert.equal(out.firstTextMs, 42);
  assert.equal(JSON.stringify(out).includes('CANARY'), false);
  assert.equal(JSON.stringify(out).includes('WARMUP_'), false);
});

test('first text timing uses the earlier validated item when a matching delta arrives later', async () => {
  for (const reconstruction of [true, false]) {
    const s = services(async (_options, _body, control) => {
      control.beforeSend(); control.onDispatch();
      return { statusCode: 200, headers: {}, body: (async function* () {
        if (reconstruction) {
          s.clock.advance(15);
          yield Buffer.from(frame('response.output_item.done', { output_index: 8, item }));
          s.clock.advance(20);
          yield Buffer.from(frame('response.output_text.delta', { ...binding, output_index: 8, delta: 'WARMUP_OK' }));
        }
        s.clock.advance(50);
        yield Buffer.from(frame('response.completed', { response: { status: 'completed', output: reconstruction ? [] : [item] } }));
        s.clock.advance(30);
      })() };
    });
    const out = await probe({ credential }, s);
    assert.equal(out.reason, 'marker_confirmed');
    assert.equal(out.firstTextMs, reconstruction ? 15 : 50);
  }
});

test('first text timing ignores deltas that cannot be matched to validated output', async () => {
  for (const delta of [
    { delta: 'WARMUP_OK' },
    { ...binding, item_id: 'unrelated', delta: 'WARMUP_OK' },
    { ...binding, output_index: 4, delta: 'WARMUP_OK' },
    { ...binding, content_index: 1, delta: 'WARMUP_OK' },
    { ...binding, delta: 'CANARY_MISMATCH' },
  ]) {
    const s = services(async (_options, _body, control) => {
      control.beforeSend(); control.onDispatch();
      return { statusCode: 200, headers: {}, body: (async function* () {
        s.clock.advance(10);
        yield Buffer.from(frame('response.output_text.delta', delta));
        s.clock.advance(40);
        yield Buffer.from(frame('response.completed', { response: { status: 'completed', output: [item] } }));
      })() };
    });
    const out = await probe({ credential }, s);
    assert.equal(out.reason, 'marker_confirmed');
    assert.equal(out.firstTextMs, 50);
    assert.equal(JSON.stringify(out).includes('CANARY'), false);
  }
});

test('first text timing requires a dispatched probe with a confirmed marker', async () => {
  const delta = frame('response.output_text.delta', { ...binding, delta: 'CANARY_OUTPUT' });
  const wrong = { ...item, content: [{ type: 'output_text', text: 'WRONG' }] };
  const terminal = output => frame('response.completed', { response: { status: 'completed', output } });
  for (const [reason, s] of [
    ['stream_or_transport_uncertain', services(response(delta))],
    ['output_mismatch', services(response(delta + terminal([wrong])))],
    ['marker_confirmed', services(async () => response(terminal([item])))],
  ]) {
    const out = await probe({ credential }, s);
    assert.equal(out.reason, reason);
    assert.equal(Object.hasOwn(out, 'firstTextMs'), false);
    assert.equal(JSON.stringify(out).includes('CANARY'), false);
  }
});

test('C03 event-only frames are ignored and do not leak their event name', async () => {
  const events = [];
  for await (const event of parseSSE(stream('event: ignored\r\n\r\ndata: next\n\n'))) events.push(event);
  assert.deepEqual(events, [{ event: 'message', data: 'next' }]);
  const terminal = frame('response.completed', { response: { status: 'completed', output: [item] } });
  const s = services(response('event: keepalive\n\n' + terminal));
  assert.equal((await probe({ credential }, s)).outcome, 'success');
  assert.equal(s.request.calls.length, 1);
});

test('C06 oversize rejection aborts transport and stops consuming chunks without retry', async () => {
  let aborted = false, resumed = false, closed = false;
  const s = services(async (_options, _body, control) => {
    control.beforeSend(); control.onDispatch();
    control.signal.addEventListener('abort', () => { aborted = true; }, { once: true });
    return { statusCode: 200, headers: {}, body: (async function* () {
      try { yield Buffer.alloc(256 * 1024 + 1, 120); resumed = true; }
      finally { closed = true; }
    })() };
  });
  const out = await probe({ credential }, s);
  assert.equal(out.reason, 'protocol_failure'); assert.equal(out.outcome, 'uncertain');
  assert.equal(aborted, true); assert.equal(closed, true); assert.equal(resumed, false);
  assert.equal(s.request.calls.length, 1);
});

test('C07 post-dispatch disconnect and early EOF remain uncertain and never retry', async () => {
  for (const disconnect of [false, true]) {
    let aborted = false;
    const s = services(async (_options, _body, control) => {
      control.beforeSend(); control.onDispatch();
      control.signal.addEventListener('abort', () => { aborted = true; }, { once: true });
      return { statusCode: 200, headers: {}, body: (async function* () {
        yield Buffer.from(frame('response.output_item.done', { output_index: 0, item }));
        if (disconnect) throw new Error('CANARY_DISCONNECT');
      })() };
    });
    const out = await probe({ credential }, s);
    assert.equal(out.outcome, 'uncertain'); assert.equal(out.reason, 'stream_or_transport_uncertain');
    assert.equal(out.dispatched, true); assert.equal(aborted, true);
    assert.equal(s.request.calls.length, 1); assert.equal(JSON.stringify(out).includes('CANARY'), false);
  }
});

test('C-probe fixed request and reconstructed terminal success', async () => {
  const s = services(response(frame('response.output_item.done', { output_index: 9007199254740991, item }) + frame('response.completed', { response: { status: 'completed', output: [] } })));
  const result = await probe({ credential }, s);
  assert.equal(result.outcome, 'success'); assert.equal(result.dispatched, true);
  assert.equal(s.request.calls[0].options.hostname, 'chatgpt.com');
  assert.equal(s.request.calls[0].options.path, '/backend-api/codex/responses');
  assert.equal(s.request.calls[0].options.headers['chatgpt-account-id'], 'workspace-a');
  const body = JSON.parse(s.request.calls[0].body);
  assert.equal(body.max_output_tokens, undefined); assert.equal(body.stream, true); assert.equal(body.store, false);
  assert.deepEqual(body, { model: 'gpt-6-luna', instructions: 'Reply exactly WARMUP_OK.', input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Reply exactly WARMUP_OK.' }] }], tools: [], tool_choice: 'auto', parallel_tool_calls: false, reasoning: { effort: 'low' }, store: false, stream: true });
  assert.equal(s.request.calls[0].options.method, 'POST');
  assert.equal(s.request.calls[0].options.protocol, 'https:');
  assert.deepEqual(s.request.calls[0].options.headers, { Authorization: 'Bearer CANARY_ACCESS', 'chatgpt-account-id': 'workspace-a', 'Content-Type': 'application/json', Accept: 'text/event-stream', 'User-Agent': 'codex-router-warmup/1.0' });
});

test('C-probe fragmented SSE, multiline data, UTF-8 and CRLF', async () => {
  const events = [];
  for await (const event of parseSSE(stream(':comment\r\nevent: note\r\ndata: café\r\ndata: next\r\n\r\n'))) events.push(event);
  assert.deepEqual(events, [{ event: 'note', data: 'café\nnext' }]);
});

test('C05 response identities and terminal item IDs cannot be mixed across coherent completions', async () => {
  const done = frame('response.output_item.done', { response_id: 'response-a', output_index: 0, item });
  for (const id of ['response-b', '', 7]) {
    const terminal = frame('response.completed', { response: { id, status: 'completed', output: [] } });
    const result = await probe({ credential }, services(response(done + terminal)));
    assert.equal(result.outcome, 'uncertain'); assert.equal(result.reason, 'protocol_failure');
  }
  const valid = frame('response.completed', { response: { id: 'response-a', status: 'completed', output: [] } });
  assert.equal((await probe({ credential }, services(response(done + valid)))).outcome, 'success');
  const duplicate = frame('response.completed', { response: { status: 'completed', output: [
    { ...item, content: [{ type: 'output_text', text: 'WARMUP_' }] },
    { ...item, content: [{ type: 'output_text', text: 'OK' }] },
  ] } });
  assert.equal((await probe({ credential }, services(response(duplicate)))).reason, 'protocol_failure');
});

test('C05 distinct assistant messages cannot synthesize the final exact marker', async () => {
  const parts = [{ ...item, id: 'first', content: [{ type: 'output_text', text: 'WARMUP_' }] },
    { ...item, id: 'last', content: [{ type: 'output_text', text: 'OK' }] }];
  for (const collected of [false, true]) {
    const done = parts.map((part, i) => frame('response.output_item.done', { output_index: i, item: part })).join('');
    const terminal = frame('response.completed', { response: { status: 'completed', output: collected ? [] : parts } });
    const out = await probe({ credential }, services(response((collected ? done : '') + terminal)));
    assert.equal(out.outcome, 'blocked'); assert.equal(out.reason, 'output_mismatch');
  }
});

test('C-probe duplicate item accepted but conflict, unsafe index and later failure rejected', async () => {
  const done = frame('response.output_item.done', { output_index: 0, item });
  const terminal = frame('response.completed', { response: { status: 'completed', output: [item] } });
  assert.equal((await probe({ credential }, services(response(done + done + terminal)))).outcome, 'success');
  const conflict = frame('response.output_item.done', { output_index: 0, item: { ...item, content: [{ type: 'output_text', text: 'WRONG' }] } });
  const invalid = await probe({ credential }, services(response(done + conflict + terminal)));
  assert.equal(invalid.outcome, 'uncertain'); assert.equal(invalid.reason, 'protocol_failure');
  assert.equal((await probe({ credential }, services(response(frame('response.output_item.done', { output_index: 9007199254740992, item }) + terminal)))).outcome, 'uncertain');
  assert.equal((await probe({ credential }, services(response(terminal + frame('response.failed', {}))))).outcome, 'uncertain');
});

test('C-probe no false success on marker without completion, mismatch, redirect or encodings', async () => {
  const done = frame('response.output_item.done', { output_index: 0, item });
  assert.equal((await probe({ credential }, services(response(done + 'data: [DONE]\n\n')))).outcome, 'uncertain');
  const wrong = frame('response.completed', { response: { status: 'completed', output: [{ ...item, content: [{ type: 'output_text', text: 'NO' }] }] } });
  assert.equal((await probe({ credential }, services(response(wrong)))).reason, 'output_mismatch');
  assert.equal((await probe({ credential }, services({ statusCode: 302, headers: { location: 'https://other.example' }, body: stream('') }))).reason, 'redirect_refused');
  assert.equal((await probe({ credential }, services({ statusCode: 200, headers: { 'content-encoding': 'gzip' }, body: stream('') }))).reason, 'protocol_failure');
});

test('C-probe statuses, retry-after, deadline and dispatch uncertainty', async () => {
  for (const [status, reason] of [[401,'authentication_rejected'],[403,'forbidden_or_challenged'],[429,'rate_limited']]) {
    const r = await probe({ credential }, services({ statusCode: status, headers: { 'retry-after': '60' }, body: stream('secret') }));
    assert.equal(r.reason, reason); assert.equal(r.notBefore, Date.parse('2026-11-12T06:01:00Z'));
    assert.equal(JSON.stringify(r).includes('secret'), false);
  }
  const noSend = services(response(''));
  assert.equal((await probe({ credential, batchDeadline: 0 }, noSend)).dispatched, false);
  assert.equal(noSend.request.calls.length, 0);
  const uncertain = services(async (_options, _body, control) => { control.beforeSend(); control.onDispatch(); throw new Error('CANARY_UPSTREAM'); });
  const r = await probe({ credential }, uncertain);
  assert.equal(r.outcome, 'uncertain'); assert.equal(JSON.stringify(r).includes('CANARY'), false);
});

test('C-probe accepts realistic token length and refuses post-terminal items', async () => {
  const done = frame('response.output_item.done', { output_index: 0, item });
  const terminal = frame('response.completed', { response: { status: 'completed', output: [] } });
  const s = services({ statusCode: 200, headers: {}, body: (async function* () { yield Buffer.from(done + terminal); })() });
  assert.equal((await probe({ credential: { ...credential, accessToken: 'x'.repeat(1024) } }, s)).outcome, 'success');
  assert.equal((await probe({ credential }, services(response(terminal + done)))).outcome, 'uncertain');
});

test('C-probe deadline covers headers and stream after dispatch', async () => {
  const s = services(async (_options, _body, control) => {
    control.beforeSend(); control.onDispatch();
    s.clock.advance(45000);
    return response(frame('response.completed', { response: { status: 'completed', output: [item] } }));
  });
  const result = await probe({ credential }, s);
  assert.equal(result.outcome, 'uncertain');
  assert.equal(result.reason, 'deadline_exceeded');
});

test('C-probe rejects malformed and oversized streams without leaking bytes', async () => {
  const terminal = frame('response.completed', { response: { status: 'completed', output: [item] } });
  const invalidUtf8 = (async function* () { yield Buffer.from([0xff]); })();
  const invalid = await probe({ credential }, services({ statusCode: 200, headers: {}, body: invalidUtf8 }));
  assert.equal(invalid.outcome, 'uncertain'); assert.equal(invalid.reason, 'protocol_failure');
  const oversize = { statusCode: 200, headers: {}, body: (async function* () { yield Buffer.from(`data: ${'x'.repeat(256 * 1024)}\n\n`); })() };
  assert.equal((await probe({ credential }, services(oversize))).outcome, 'uncertain');
  assert.equal((await probe({ credential }, services(response(terminal.slice(0, -1))))).outcome, 'uncertain');
  assert.equal((await probe({ credential }, services(response(terminal.slice(0, -1))))).reason, 'stream_or_transport_uncertain');
  const beforeSend = services(async () => { throw new Error('CANARY_SECRET'); });
  const result = await probe({ credential }, beforeSend);
  assert.equal(result.dispatched, false);
  assert.equal(JSON.stringify(result).includes('CANARY'), false);
});

test('C-probe cancels an early HTTP response body and ignores invalid reset', async () => {
  let aborted = false;
  const s = services(async (_options, _body, control) => {
    control.beforeSend(); control.onDispatch();
    control.signal.addEventListener('abort', () => { aborted = true; }, { once: true });
    return { statusCode: 429, headers: { 'retry-after': 'not-a-date' }, body: (async function* () { await new Promise(() => {}); })() };
  });
  const result = await probe({ credential }, s);
  assert.equal(result.reason, 'rate_limited');
  assert.equal(result.notBefore, undefined);
  assert.equal(aborted, true);
});

test('C-probe transport errors cannot masquerade as local protocol failure', async () => {
  const s = services(async (_options, _body, control) => { control.beforeSend(); control.onDispatch(); throw new Error('bad_event'); });
  const result = await probe({ credential }, s);
  assert.equal(result.reason, 'stream_or_transport_uncertain');
});

test('C-probe rejects duplicate IDs across indices and inconsistent terminal output', async () => {
  const one = frame('response.output_item.done', { output_index: 0, item });
  const duplicateId = frame('response.output_item.done', { output_index: 1, item });
  const completed = frame('response.completed', { response: { status: 'completed', output: [] } });
  assert.equal((await probe({ credential }, services(response(one + duplicateId + completed)))).outcome, 'uncertain');
  const inconsistent = frame('response.completed', { response: { status: 'completed', output: [{ ...item, content: [{ type: 'output_text', text: 'OTHER' }] }] } });
  assert.equal((await probe({ credential }, services(response(one + inconsistent)))).outcome, 'uncertain');
});

test('C-probe rejects negative index, failed completion and marker-only deltas', async () => {
  const terminal = frame('response.completed', { response: { status: 'completed', output: [item] } });
  const badIndex = frame('response.output_item.done', { output_index: -1, item });
  assert.equal((await probe({ credential }, services(response(badIndex + terminal)))).outcome, 'uncertain');
  assert.equal((await probe({ credential }, services(response(frame('response.completed', { response: { status: 'failed', output: [item] } }))))).outcome, 'uncertain');
  assert.equal((await probe({ credential }, services(response(frame('response.output_text.delta', { delta: 'WARMUP_OK' }) + 'data: [DONE]\n\n')))).outcome, 'uncertain');
  assert.equal((await probe({ credential }, services(response(frame('response.done', { response: { status: 'completed', output: [item] } }))))).outcome, 'uncertain');
});

test('C-probe enforces combined item/terminal storage and batch deadline', async () => {
  const huge = { ...item, content: [{ type: 'output_text', text: 'x'.repeat(140 * 1024) }] };
  const done = frame('response.output_item.done', { output_index: 0, item: huge });
  const terminal = frame('response.completed', { response: { status: 'completed', output: [huge] } });
  const s = services({ statusCode: 200, headers: {}, body: (async function* () { yield Buffer.from(done + terminal); })() });
  assert.equal((await probe({ credential }, s)).outcome, 'uncertain');
  const before = services(response(''));
  assert.equal((await probe({ credential, batchDeadline: before.clock.mono() }, before)).reason, 'deadline_before_send');
  assert.equal(before.request.calls.length, 0);
  const oneSecond = services(response(frame('response.completed', { response: { status: 'completed', output: [item] } })));
  await probe({ credential, batchDeadline: 1000 }, oneSecond);
  assert.equal(oneSecond.request.calls[0].control.timeoutMs, 1000);
});

test('C03 bytewise UTF-8 and mixed LF/CRLF frames preserve a completed marker', async () => {
  const text = ': café\r\n\r\n' + frame('response.completed', { response: { status: 'completed', output: [item] } }).replaceAll('\n', '\r\n');
  const s = services({ statusCode: 200, headers: {}, body: (async function* () {
    for (const byte of Buffer.from(text)) yield Buffer.from([byte]);
  })() });
  assert.equal((await probe({ credential }, s)).outcome, 'success');
  assert.equal(s.request.calls.length, 1);
});

test('C04 sparse completed items are reconstructed in numeric order without index-sized allocation', async () => {
  const earlier = { ...item, id: 'earlier', content: [{ type: 'output_text', text: 'not the final message' }] };
  const text = frame('response.output_item.done', { output_index: Number.MAX_SAFE_INTEGER, item })
    + frame('response.output_item.done', { output_index: 2, item: earlier })
    + frame('response.completed', { response: { status: 'completed', output: [] } });
  const s = services(response(text));
  assert.equal((await probe({ credential }, s)).outcome, 'success');
  assert.equal(s.request.calls.length, 1);
});

test('C05 malformed structures, terminal status/event mismatch and HTTP 200 alone never succeed', async () => {
  const terminal = frame('response.completed', { response: { status: 'completed', output: [item] } });
  const cases = [
    '', 'data: {not-json}\n\n',
    frame('response.completed', { response: { status: 'completed', output: 'WARMUP_OK' } }),
    frame('response.completed', { response: { status: 'completed' } }),
    frame('response.completed', { response: { status: 'in_progress', output: [item] } }),
    'event: response.failed\ndata: ' + JSON.stringify({ type: 'response.completed', response: { status: 'completed', output: [item] } }) + '\n\n',
    frame('response.failed', {}) + terminal,
    frame('response.output_item.done', { output_index: 0, item: { ...item, role: 'user' } }) + terminal,
  ];
  for (const text of cases) {
    const s = services(response(text));
    const out = await probe({ credential }, s);
    assert.notEqual(out.outcome, 'success'); assert.equal(out.dispatched, true);
    assert.equal(s.request.calls.length, 1);
  }
});

test('C06 decoded event and cumulative stream accept exactly 256KiB and reject the next byte', async () => {
  const max = 256 * 1024;
  const chunks = text => (async function* () { const bytes = Buffer.from(text); for (let i = 0; i < bytes.length; i += 4096) yield bytes.subarray(i, i + 4096); })();
  for (const parts of [1, 2]) {
    const size = max / parts;
    const text = Array.from({ length: parts }, () => `data: ${'x'.repeat(size - 8)}\n\n`).join('');
    assert.equal(Buffer.byteLength(text), max);
    let count = 0;
    for await (const event of parseSSE(chunks(text))) { count++; assert.equal(event.data.length, size - 8); }
    assert.equal(count, parts);
    await assert.rejects(async () => { for await (const _event of parseSSE(chunks(text + ':'))) {} }, /stream_oversize/);
  }
});

test('C07 streamed chunks never reset the whole-request timer and abort without retry', async () => {
  let aborted = false;
  const s = services(async (_options, _body, control) => {
    control.beforeSend(); control.onDispatch();
    control.signal.addEventListener('abort', () => { aborted = true; }, { once: true });
    return { statusCode: 200, headers: {}, body: (async function* () {
      s.clock.advance(30000); yield Buffer.from(': heartbeat\n\n');
      s.clock.advance(15000); yield Buffer.from(frame('response.completed', { response: { status: 'completed', output: [item] } }));
    })() };
  });
  const out = await probe({ credential }, s);
  assert.equal(out.outcome, 'uncertain'); assert.equal(out.reason, 'deadline_exceeded');
  assert.equal(out.dispatched, true); assert.equal(out.durationMs, 45000);
  assert.equal(aborted, true); assert.equal(s.request.calls.length, 1);
});

test('C02/C08 unknown upstream bodies stay sanitized and valid retry-after seconds are not capped at one day', async () => {
  for (const [header, seconds] of [['0', 0], ['86400', 86400], ['86401', 86401], ['172800', 172800], ['9999999', 9999999], ['-1', null], ['+60', null], ['1e3', null], ['1.5', null], [undefined, null]]) {
    const s = services({ statusCode: 400, headers: { 'retry-after': header }, body: stream('UPSTREAM_SECRET unsupported_model') });
    const out = await probe({ credential }, s);
    assert.equal(out.reason, 'upstream_rejected');
    assert.equal(out.notBefore, seconds === null ? undefined : s.clock.wall() + seconds * 1000);
    assert.equal(JSON.stringify(out).includes('UPSTREAM_SECRET'), false);
    assert.equal(s.request.calls.length, 1);
  }
});

test('C08 unrepresentably large retry-after seconds never create earlier eligibility', async () => {
  const s = services({ statusCode: 429, headers: { 'retry-after': '9007199254740992' }, body: stream('PRIVATE_RESET=soon') });
  const out = await probe({ credential }, s);
  assert.equal(out.notBefore, Number.MAX_VALUE);
  assert.equal(JSON.stringify(out).includes('PRIVATE_RESET'), false);
});

test('C08 unsupported error-body encoding still preserves a validated retry-after without decoding or retry', async () => {
  const s = services({ statusCode: 429, headers: { 'content-encoding': 'gzip', 'retry-after': '172800' }, body: stream('PRIVATE_RESET=soon') });
  const out = await probe({ credential }, s);
  assert.equal(out.reason, 'protocol_failure');
  assert.equal(out.notBefore, s.clock.wall() + 172800000);
  assert.equal(JSON.stringify(out).includes('PRIVATE_RESET'), false);
  assert.equal(s.request.calls.length, 1);
});

test('C08 three HTTP-date retry-after forms honor their exact future epoch without guessing from bad dates', async () => {
  const now = fakeClock().wall();
  const future = now + 172800000;
  for (const [header, expected] of [
    [new Date(future).toUTCString(), future],
    ['Saturday, 14-Nov-26 06:00:00 GMT', future],
    ['Sat Nov 14 06:00:00 2026', future],
    [new Date(now - 1000).toUTCString(), undefined],
    ['Fri, 99 Nov 2026 08:00:00 GMT', undefined],
    ['Sat, 31 Feb 2027 06:00:00 GMT', undefined],
    ['Fri, 14 Nov 2026 06:00:00 GMT', undefined],
    ['Sat, 14 Nov 2026 06:00:00', undefined],
    ['Sat, 14 Nov 2026 06:00:00 GMT trailing', undefined],
    ['Sat Nov 14 06:00:00 2026 PST', undefined],
  ]) {
    const s = services({ statusCode: 429, headers: { 'retry-after': header }, body: stream('PRIVATE_RESET=soon') });
    const out = await probe({ credential }, s);
    assert.equal(out.reason, 'rate_limited');
    assert.equal(out.notBefore, expected, header);
    assert.equal(JSON.stringify(out).includes('PRIVATE_RESET'), false);
    assert.equal(s.request.calls.length, 1);
  }
});

test('C08 asctime space-padded day stays UTC under a non-UTC process timezone', async () => {
  const original = process.env.TZ;
  try {
    process.env.TZ = 'Pacific/Honolulu';
    const s = services({ statusCode: 429, headers: { 'retry-after': 'Tue Dec  1 06:00:00 2026' }, body: stream('') });
    assert.equal((await probe({ credential }, s)).notBefore, Date.parse('2026-12-01T06:00:00Z'));
  } finally {
    if (original === undefined) delete process.env.TZ;
    else process.env.TZ = original;
  }
});

test('C08 obsolete RFC850 two-digit years use the rolling 50-year window', async () => {
  const future = Date.parse('2075-11-14T06:00:00Z');
  const s = services({ statusCode: 429, headers: { 'retry-after': 'Thursday, 14-Nov-75 06:00:00 GMT' }, body: stream('') });
  assert.equal((await probe({ credential }, s)).notBefore, future);
  const past = services({ statusCode: 429, headers: { 'retry-after': 'Sunday, 14-Nov-76 06:00:00 GMT' }, body: stream('') });
  assert.equal((await probe({ credential }, past)).notBefore, undefined);
  const exact = services({ statusCode: 429, headers: { 'retry-after': 'Thursday, 12-Nov-76 06:00:00 GMT' }, body: stream('') });
  assert.equal((await probe({ credential }, exact)).notBefore, Date.parse('2076-11-12T06:00:00Z'));
  const beyond = services({ statusCode: 429, headers: { 'retry-after': 'Friday, 12-Nov-76 06:00:01 GMT' }, body: stream('') });
  assert.equal((await probe({ credential }, beyond)).notBefore, undefined);
});

test('C08 HTTP-date leap second waits through the following second', async () => {
  const s = services({ statusCode: 429, headers: { 'retry-after': 'Sat, 14 Nov 2026 06:00:60 GMT' }, body: stream('') });
  assert.equal((await probe({ credential }, s)).notBefore, Date.parse('2026-11-14T06:01:00Z'));
});


test('C02 reviewed exact model code is recognized only at supported HTTP statuses and envelopes', async () => {
  for (const statusCode of [400, 403, 404]) {
    const s = services({ statusCode, headers: { 'retry-after': '60' }, body: stream(JSON.stringify({ error: { code: 'model_not_found', message: 'CANARY_RESPONSE' } })) });
    const out = await probe({ credential }, s);
    assert.equal(out.reason, 'unsupported_model'); assert.equal(out.outcome, 'blocked');
    assert.equal(out.httpStatus, statusCode); assert.equal(out.dispatched, true);
    assert.equal(out.notBefore, s.clock.wall() + 60000);
    assert.equal(s.request.calls.length, 1); assert.equal(s.request.calls[0].control.signal.aborted, true);
    assert.equal(JSON.stringify(out).includes('CANARY'), false);
  }
  for (const event of [frame('error', { error: { code: 'model_not_found', message: 'CANARY' } }),
    frame('response.failed', { response: { error: { code: 'model_not_found', message: 'CANARY' } } })]) {
    const s = services(response(event)); const out = await probe({ credential }, s);
    assert.equal(out.reason, 'unsupported_model'); assert.equal(out.outcome, 'blocked');
    assert.equal(s.request.calls.length, 1); assert.equal(JSON.stringify(out).includes('CANARY'), false);
  }
});

test('C02 message/type/wrong nesting/code/status never establish model incompatibility', async () => {
  for (const body of [{ error: { message: 'model_not_found', type: 'model_not_found' } },
    { code: 'model_not_found' }, { response: { error: { code: 'model_not_found' } } },
    { error: { code: 'unsupported_model' } }, { error: { code: ['model_not_found'] } }, { error: { code: 'MODEL_NOT_FOUND' } }, null]) {
    for (const statusCode of [400, 403, 404]) {
      const out = await probe({ credential }, services({ statusCode, headers: {}, body: stream(JSON.stringify(body)) }));
      assert.equal(out.reason, statusCode === 403 ? 'forbidden_or_challenged' : 'upstream_rejected');
    }
  }
  for (const [statusCode, reason] of [[401, 'authentication_rejected'], [429, 'rate_limited'], [500, 'upstream_rejected']]) {
    const s = services({ statusCode, headers: {}, body: stream('{"error":{"code":"model_not_found"}}') });
    assert.equal((await probe({ credential }, s)).reason, reason); assert.equal(s.request.calls.length, 1);
  }
  for (const event of [frame('error', { response: { error: { code: 'model_not_found' } } }),
    frame('response.failed', { error: { code: 'model_not_found' } }),
    frame('response.incomplete', { response: { error: { code: 'model_not_found' } } }),
    frame('error', { error: { message: 'model_not_found' } })]) {
    assert.equal((await probe({ credential }, services(response(event)))).reason, 'stream_or_transport_uncertain');
  }
});

test('C02 HTTP error parsing is bounded, UTF-8 safe, private and does not promote partial bodies', async () => {
  for (const data of [Buffer.from('{"error":{"code":"model_not_found"}} CANARY'), Buffer.from([255]), Buffer.alloc(256 * 1024 + 1, 120)]) {
    let closed = false, resumed = false;
    const s = services({ statusCode: 403, headers: {}, body: (async function* () {
      try { yield data; resumed = true; } finally { closed = true; }
    })() });
    const out = await probe({ credential }, s);
    assert.notEqual(out.reason, 'unsupported_model'); assert.equal(JSON.stringify(out).includes('CANARY'), false);
    assert.equal(closed, true); assert.equal(s.request.calls.length, 1);
    if (data.length > 256 * 1024) assert.equal(resumed, false);
  }
  const s = services({ statusCode: 400, headers: {}, body: (async function* () {
    yield Buffer.from('{"error":{"code":"model_not_found"}}'); throw new Error('CANARY_DISCONNECT');
  })() });
  assert.notEqual((await probe({ credential }, s)).reason, 'unsupported_model');
});

test('C02 classification never bypasses stream coherence or the absolute body deadline', async () => {
  const failure = frame('error', { error: { code: 'model_not_found' } });
  const terminal = frame('response.completed', { response: { status: 'completed', output: [item] } });
  for (const text of [terminal + failure, failure + terminal, failure + frame('error', {})]) {
    assert.equal((await probe({ credential }, services(response(text)))).reason, 'protocol_failure');
  }
  for (const batchDeadline of [undefined, 1000]) {
    const s = services(async (_opts, _body, control) => {
      control.beforeSend(); control.onDispatch();
      return { statusCode: 403, headers: {}, body: (async function* () {
        yield Buffer.from('{"error":'); s.clock.advance(batchDeadline ?? 45000);
        yield Buffer.from('{"code":"model_not_found"}}');
      })() };
    });
    const out = await probe({ credential, batchDeadline }, s);
    assert.equal(out.reason, 'deadline_exceeded'); assert.equal(out.outcome, 'uncertain');
    assert.equal(s.request.calls.length, 1); assert.equal(s.request.calls[0].control.signal.aborted, true);
  }
});


test('C02/C08 validated Retry-After survives HTTP model-error body failures', async () => {
  for (const statusCode of [400, 403, 404]) {
    for (const failure of ['utf8', 'oversize', 'disconnect', 'deadline']) {
      const s = services(async (_options, _body, control) => {
        control.beforeSend(); control.onDispatch();
        return { statusCode, headers: { 'retry-after': '172800' }, body: (async function* () {
          if (failure === 'utf8') yield Buffer.from([255]);
          else if (failure === 'oversize') yield Buffer.alloc(256 * 1024 + 1, 120);
          else if (failure === 'disconnect') throw new Error('CANARY_DISCONNECT');
          else { s.clock.advance(45000); throw new Error('aborted'); }
        })() };
      });
      const notBefore = s.clock.wall() + 172800000;
      const out = await probe({ credential }, s);
      assert.equal(out.notBefore, notBefore, `${statusCode}/${failure}`);
      assert.equal(out.httpStatus, statusCode); assert.equal(out.outcome, 'uncertain');
      assert.equal(out.reason, failure === 'deadline' ? 'deadline_exceeded' : failure === 'disconnect' ? 'stream_or_transport_uncertain' : 'protocol_failure');
      assert.equal(JSON.stringify(out).includes('CANARY'), false); assert.equal(s.request.calls.length, 1);
      assert.equal(s.request.calls[0].control.signal.aborted, true);
    }
  }
});

// Backlog 1a: the usage-window headers become bounded evidence, never raw header text.
test('usage windows keep only bounded numbers from the primary and secondary headers', () => {
  const now = Date.parse('2026-11-21T12:00:00Z');
  assert.deepEqual(usageWindows({
    'x-codex-primary-used-percent': '37.5', 'x-codex-primary-window-minutes': '300', 'x-codex-primary-reset-after-seconds': '5400',
    'x-codex-secondary-used-percent': '12', 'x-codex-secondary-window-minutes': '10080', 'x-codex-secondary-reset-at': String(now / 1000 + 86400),
  }, now), {
    primary: { usedPercent: 37.5, windowMinutes: 300, resetsAt: now + 5400000 },
    secondary: { usedPercent: 12, windowMinutes: 10080, resetsAt: now + 86400000 },
  });
  assert.equal(usageWindows({}, now), undefined);
  assert.equal(usageWindows({
    'x-codex-primary-used-percent': '101', 'x-codex-primary-window-minutes': '-5', 'x-codex-primary-reset-at': 'CANARY',
    'x-codex-secondary-used-percent': ['10'], 'x-codex-secondary-reset-after-seconds': '1e9',
  }, now), undefined);
  assert.deepEqual(usageWindows({ 'x-codex-primary-reset-at': String(now / 1000 + 90 * 86400) }, now), undefined);
});

test('probe attaches usage windows to success and rate-limited results', async () => {
  const headers = { 'content-encoding': 'identity', 'x-codex-primary-used-percent': '80', 'x-codex-primary-window-minutes': '300' };
  const ok = services(async (_options, _body, control) => {
    control.beforeSend(); control.onDispatch();
    return { statusCode: 200, headers, body: stream(frame('response.output_text.delta', { ...binding, delta: 'WARMUP_OK' }) + frame('response.completed', { response: { status: 'completed', output: [item] } })) };
  });
  const success = await probe({ credential }, ok);
  assert.equal(success.reason, 'marker_confirmed');
  assert.deepEqual(success.usage, { primary: { usedPercent: 80, windowMinutes: 300 } });
  const limited = services(async (_options, _body, control) => {
    control.beforeSend(); control.onDispatch();
    return { statusCode: 429, headers: { ...headers, 'x-codex-primary-used-percent': '100', 'retry-after': '60' }, body: stream('') };
  });
  const blocked = await probe({ credential }, limited);
  assert.equal(blocked.reason, 'rate_limited');
  assert.deepEqual(blocked.usage, { primary: { usedPercent: 100, windowMinutes: 300 } });
  assert.equal(JSON.stringify(blocked).includes('CANARY'), false);
});
