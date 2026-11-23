import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import { EventEmitter } from 'node:events';
import { safeRead, checkRootAncestors } from '../router-reader.mjs';
import { probe, directRequest } from '../chatgpt-probe.mjs';
import { makeFixture, fakeClock, requestStub } from './helpers.mjs';

test('request fixture validates before dispatch and propagates refusals', async () => {
  const request = requestStub();
  const events = [];
  await request({}, '', { beforeSend: () => events.push('validate'), onDispatch: () => events.push('send') });
  assert.deepEqual(events, ['validate', 'send']);
  await assert.rejects(request({}, '', { beforeSend: () => { throw new Error('refused'); }, onDispatch: () => events.push('unexpected') }), /refused/);
  assert.deepEqual(events, ['validate', 'send']);
});

test('probe never exposes forged transport error properties', async () => {
  const canary = 'CANARY_PRIVATE_TRANSPORT_ERROR';
  for (const afterSend of [false, true]) {
    const clock = fakeClock();
    const request = async (_options, _body, control) => {
      if (afterSend) { control.beforeSend(); control.onDispatch(); }
      throw Object.assign(new Error(canary), { beforeSendReason: canary });
    };
    const result = await probe({ credential: { accessToken: 'SYNTHETIC', identity: { accountId: 'workspace' }, expiresAt: 4102444800000 } }, { clock, request });
    assert.equal(result.reason, afterSend ? 'stream_or_transport_uncertain' : 'transport_before_send');
    assert.equal(result.dispatched, afterSend);
    assert.equal(JSON.stringify(result).includes(canary), false);
  }
});

test('probe records a bounded pre-send transport code without upstream error text', async () => {
  for (const code of ['EAI_AGAIN', 'ECONNREFUSED', 'CERT_HAS_EXPIRED', 'CANARY_PRIVATE']) {
    const request = async () => { throw Object.assign(new Error('CANARY_PRIVATE'), { code }); };
    const credential = { accessToken: 'SYNTHETIC', identity: { accountId: 'workspace' }, expiresAt: 4102444800000 };
    const result = await probe({ credential }, { clock: fakeClock(), request });
    assert.equal(result.reason, 'transport_before_send');
    assert.equal(result.dispatched, false);
    assert.equal(result.transportCode, code === 'CANARY_PRIVATE' ? undefined : code);
    assert.equal(JSON.stringify(result).includes('CANARY_PRIVATE'), false);
  }
});

test('R7 checks ancestors on both parent validations and rejects a symlink ancestor', () => {
  const f = makeFixture();
  try {
    const parent = path.join(f.root, 'virtual'), root = path.join(parent, 'trusted'), file = path.join(root, 'input.json');
    const actual = path.join(f.companionRoot, 'input.json');
    fs.writeFileSync(actual, '{"ok":true}', { mode: 0o600 });
    let visits = 0, linked = false;
    const translate = p => p === root ? f.companionRoot : p === file ? actual : p;
    const files = { ...fs, lstatSync(p) {
      if (p === parent) { visits++; return { isDirectory: () => !linked, isSymbolicLink: () => linked }; }
      return fs.lstatSync(translate(p));
    }, openSync(p, ...args) { return fs.openSync(translate(p), ...args); } };
    assert.equal(safeRead(file, { ...f.services, files }, { root, limit: 100 }).value.ok, true);
    assert.equal(visits, 2);
    linked = true;
    assert.throws(() => safeRead(file, { ...f.services, files }, { root, limit: 100 }));
    assert.throws(() => checkRootAncestors(`${root}/..`, { ...f.services, files }));
    linked = false; visits = 0;
    const changed = { ...files, lstatSync(p) { if (p === parent && visits === 1) linked = true; return files.lstatSync(p); } };
    assert.throws(() => safeRead(file, { ...f.services, files: changed }, { root, limit: 100 }));
  } finally { f.cleanup(); }
});

test('guard permits only ancestor lstat metadata, not other external observations', () => {
  const ancestor = path.dirname(process.env.WARMUP_TEST_ROOT);
  assert.ok(fs.lstatSync(ancestor).isDirectory());
  assert.throws(() => fs.statSync(ancestor), /TEST_GUARD_DENIED/);
  assert.throws(() => fs.readdirSync(ancestor), /TEST_GUARD_DENIED/);
  assert.throws(() => fs.lstatSync(path.join(ancestor, 'unrelated')), /TEST_GUARD_DENIED/);
});

test('R5/R6 validate at secureConnect before dispatch and clean up refused sockets', async () => {
  const original = https.request;
  try {
    for (const scenario of [
      { name: 'deadline', mono: 45000, expiry: 1000000, send: false },
      { name: 'batch deadline', mono: 1000, batch: 1000, expiry: 1000000, send: false },
      { name: 'low expiry', mono: 1, expiry: 120000, send: false },
      { name: 'unknown expiry', mono: 0, expiry: undefined, send: false },
      { name: 'nonfinite expiry', mono: 0, expiry: Infinity, send: false },
      { name: 'exact margin', mono: 1, expiry: 120001, send: true },
      { name: 'just before deadline', mono: 44999, expiry: 164999, send: true },
    ]) {
      let mono = 0, sends = 0, destroyed = 0, timerCallback, cleared = 0, lateSocket, lateRequest;
      https.request = (_options, callback) => {
        const req = new EventEmitter(), socket = new EventEmitter();
        lateRequest = req; lateSocket = new EventEmitter();
        req.destroy = error => { destroyed++; if (error) queueMicrotask(() => req.emit('error', error)); };
        req.end = () => { sends++; const response = new EventEmitter(); response.statusCode = 429; response.headers = { 'retry-after': '60' }; response.destroy = () => {}; response[Symbol.asyncIterator] = async function* () {}; callback(response); };
        queueMicrotask(() => { req.emit('socket', socket); mono = scenario.mono; socket.emit('secureConnect'); });
        return req;
      };
      const clock = { wall: () => mono, mono: () => mono, setTimeout(fn) { timerCallback = fn; return 1; }, clearTimeout() { cleared++; } };
      const out = await probe({ credential: { accessToken: 'SYNTHETIC', identity: { accountId: 'workspace' }, expiresAt: scenario.expiry }, batchDeadline: scenario.batch }, { clock, request: directRequest });
      assert.equal(sends, Number(scenario.send), scenario.name);
      assert.equal(out.dispatched, scenario.send, scenario.name);
      if (scenario.name === 'deadline' || scenario.name === 'batch deadline') assert.equal(out.reason, 'deadline_before_send');
      if (['low expiry', 'unknown expiry', 'nonfinite expiry'].includes(scenario.name)) assert.equal(out.reason, 'credential_expired_or_unknown');
      assert.equal(cleared, 1);
      if (!scenario.send) assert.ok(destroyed >= 1, scenario.name);
      else { assert.equal(out.reason, 'rate_limited'); assert.equal(out.notBefore, scenario.mono + 60000); }
      if (!scenario.send) { lateRequest.emit('socket', lateSocket); lateSocket.emit('secureConnect'); }
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(sends, Number(scenario.send));
      assert.equal(typeof timerCallback, 'function');
    }
  } finally { https.request = original; }
});
