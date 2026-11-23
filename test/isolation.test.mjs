import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import dns from 'node:dns';
import { spawnSync } from 'node:child_process';
import { Worker } from 'node:worker_threads';
import { makeFixture, requestStub } from './helpers.mjs';

test('guard is active before test body and HOME is synthetic', async () => {
  const fixture = makeFixture();
  try {
    assert.ok(process.env.HOME.startsWith(process.env.WARMUP_TEST_ROOT));
    assert.throws(() => fs.readFileSync('/Users/someone/.codex/auth.json'), /TEST_GUARD_DENIED/);
    assert.throws(() => readFile('/Users/someone/.codex/auth.json'), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.writeFileSync('/Users/someone/.codex/auth.json', 'never'), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.existsSync('/Users/someone/.codex/auth.json'), /TEST_GUARD_DENIED/);
    assert.throws(() => http.get('http://127.0.0.1:9'), /TEST_GUARD_DENIED/);
    assert.throws(() => https.request('https://example.invalid'), /TEST_GUARD_DENIED/);
    assert.throws(() => new net.Socket().connect(9, '127.0.0.1'), /TEST_GUARD_DENIED/);
    assert.throws(() => dns.lookup('localhost', () => {}), /TEST_GUARD_DENIED/);
    assert.throws(() => dns.promises.lookup('localhost'), /TEST_GUARD_DENIED/);
    assert.throws(() => fetch('https://example.invalid'), /TEST_GUARD_DENIED/);
    assert.throws(() => spawnSync('/bin/launchctl', ['list']), /TEST_GUARD_DENIED/);
    assert.throws(() => new Worker(''), /TEST_GUARD_DENIED/);
    assert.throws(() => process.kill(process.pid, 0), /TEST_GUARD_DENIED/);
    fs.writeFileSync(fixture.configPath, '{}');
    assert.equal(fs.readFileSync(fixture.configPath, 'utf8'), '{}');
  } finally { fixture.cleanup(); }
});

test('fixture capabilities remain synthetic and exact-owner scoped', async () => {
  const request = requestStub();
  const fixture = makeFixture({ routerSource: { 'src/synthetic.mjs': 'export const synthetic = true;' }, request });
  try {
    assert.equal(fs.readFileSync(`${fixture.routerRoot}/src/synthetic.mjs`, 'utf8'), 'export const synthetic = true;');
    let dispatches = 0;
    await fixture.services.request({}, '', { beforeSend: () => {}, onDispatch: () => { dispatches++; } });
    assert.equal(dispatches, 1);
    assert.equal(request.calls.length, 1);
    const binding = { root: fixture.companionRoot, installationId: 'synthetic' };
    await fixture.services.jobs.enable(binding);
    assert.equal(await fixture.services.jobs.runner(binding), null);
    fixture.services.processes.setAlive(true);
    assert.deepEqual(await fixture.services.jobs.runner(binding), fixture.owner);
    await fixture.services.jobs.disable(binding);
    await fixture.services.jobs.disable(binding);
    assert.equal(await fixture.services.jobs.inspect(binding), 'absent');
  } finally { fixture.cleanup(); }
});

test('real file and directory fsync work inside the private root', () => {
  const fixture = makeFixture();
  try {
    const fd = fs.openSync(fixture.statePath, 'wx', 0o600);
    fs.writeSync(fd, '{}');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    const dir = fs.openSync(fixture.companionRoot, 'r');
    fs.fsyncSync(dir);
    fs.closeSync(dir);
    assert.equal(fs.readFileSync(fixture.statePath, 'utf8'), '{}');
  } finally { fixture.cleanup(); }
});

test('unlisted filesystem, traversal, descriptor, and service paths deny before effects', async () => {
  const fixture = makeFixture();
  try {
    assert.throws(() => fs.cpSync('/Users/someone/.codex', fixture.root, { recursive: true }), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.cpSync(fixture.root, '/Users/someone/never'), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.symlinkSync('/Users/someone', path.join(fixture.root, 'escape')), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.readFileSync(path.join(fixture.root, '..', '..', 'Users', 'someone', '.codex')), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.fsyncSync(999999), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.ftruncateSync(999999, 0), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.promises.cp('/Users/someone/.codex', fixture.root, { recursive: true }), /TEST_GUARD_DENIED/);
    assert.throws(() => process.binding('fs'), /TEST_GUARD_DENIED/);
    assert.throws(() => process.dlopen({}, '/tmp/never.node'), /TEST_GUARD_DENIED/);
    assert.throws(() => process.chdir('/'), /TEST_GUARD_DENIED/);
    assert.throws(() => process._linkedBinding('fs'), /TEST_GUARD_DENIED/);
    assert.throws(() => process._debugProcess(process.pid), /TEST_GUARD_DENIED/);
    assert.throws(() => new WebSocket('ws://127.0.0.1:9'), /TEST_GUARD_DENIED/);
    const handle = await fs.promises.open(fixture.statePath, 'w');
    await handle.writeFile('{}');
    await handle.sync();
    await handle.close();
    assert.equal(fs.readFileSync(fixture.statePath, 'utf8'), '{}');
  } finally { fixture.cleanup(); }
});

test('read-only descriptors cannot mutate and closed descriptor capability is removed', async () => {
  const fixture = makeFixture();
  try {
    fs.writeFileSync(fixture.statePath, '{}');
    const source = path.join(process.env.WARMUP_REPO, 'test', 'isolation.test.mjs');
    const sourceFd = fs.openSync(source, 'r');
    assert.throws(() => fs.ftruncateSync(sourceFd, 0), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.fchmodSync(sourceFd, 0o600), /TEST_GUARD_DENIED/);
    fs.closeSync(sourceFd);
    assert.throws(() => fs.fsyncSync(sourceFd), /TEST_GUARD_DENIED/);
    const handle = await fs.promises.open(fixture.statePath, 'r');
    const oldFd = handle.fd;
    assert.throws(() => handle.chmod(0o600), /TEST_GUARD_DENIED/);
    await handle.close();
    assert.throws(() => fs.fsyncSync(oldFd), /TEST_GUARD_DENIED/);
    const replacement = fs.openSync(fixture.statePath, 'r');
    assert.throws(() => fs.ftruncateSync(replacement, 0), /TEST_GUARD_DENIED/);
    fs.closeSync(replacement);
    assert.equal(fs.readFileSync(fixture.statePath, 'utf8'), '{}');
  } finally { fixture.cleanup(); }
});

test('private fixture symlink can be inspected but never followed', () => {
  const fixture = makeFixture();
  try {
    fs.writeFileSync(fixture.statePath, '{}');
    const link = path.join(fixture.root, 'state-link');
    fs.symlinkSync(fixture.statePath, link);
    assert.equal(fs.lstatSync(link).isSymbolicLink(), true);
    assert.equal(fs.readlinkSync(link), fixture.statePath);
    assert.throws(() => fs.readFileSync(link), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.openSync(link, 'r'), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.statSync(link), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.symlinkSync('/Users/someone', path.join(fixture.root, 'external')), /TEST_GUARD_DENIED/);
    fs.unlinkSync(link);
  } finally { fixture.cleanup(); }
});
