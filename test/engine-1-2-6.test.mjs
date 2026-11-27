import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { runCommand, MAX_PROJECTION_DAYS } from '../runtime.mjs';
import { engineVersion, execute } from '../warmup.mjs';
import { fakeClock, makeFixture } from './helpers.mjs';

// Engine 1.2.6: `schedule inspect --days N` (1 to 28) projects N days for scripts/schedule-wakes.sh.
// Plain `schedule inspect`, edit previews and status keep 7 days. The fake clock starts on
// Thursday 12 Nov 2026 at 06:00 Asia/Gaza; everything runs through execute(), so the parser's
// command is the one the runtime sees.
async function prepared() {
  const clock = fakeClock(Date.parse('2026-11-12T04:00:00Z'));
  clock.zone = () => 'Asia/Gaza';
  const f = makeFixture({ clock });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_engine_126', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_0', eligible: true }] }),
    discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'workspace', userId: 'user' } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: fileURLToPath(new URL('../warmup.mjs', import.meta.url)) };
  f.services.context = context;
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  assert.equal((await call({ name: 'run' })).exitCode, 0);
  assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
  const cli = async argv => (await execute(argv, f.services)).json;
  return { ...f, cli, stateBytes: () => fs.readFileSync(f.statePath, 'utf8') };
}
const inspect = ['schedule', 'inspect'];
const dates = (first, count) => Array.from({ length: count }, (_, n) => new Date(Date.parse(`${first}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10));

test('1.2.6: the engine version is 1.2.6-offline and the projection cap is 28 days', () => {
  assert.equal(engineVersion, '1.2.6-offline');
  assert.equal(MAX_PROJECTION_DAYS, 28);
});

test('1.2.6: schedule inspect --days 28 returns 28 days whose first 7 equal plain inspect', async () => {
  const f = await prepared();
  try {
    const before = f.stateBytes();
    const plain = await f.cli(inspect);
    const long = await f.cli([...inspect, '--days', '28']);
    for (const out of [plain, long]) { assert.equal(out.outcome, 'ready'); assert.equal(out.reason, 'schedule_projection'); }
    assert.equal(plain.days.length, 7);
    assert.equal(long.days.length, 28);
    assert.deepEqual(long.days.map(d => d.date), dates('2026-11-12', 28));
    assert.deepEqual(long.days.slice(0, 7), plain.days);
    for (const day of long.days) assert.deepEqual(day.admissions.map(a => a.admission), ['08:00', '13:00', '18:00']);
    assert.ok(long.days.at(-1).admissions.every(a => a.state === 'upcoming'));
    const { days: _a, ...plainRest } = plain, { days: _b, ...longRest } = long;
    assert.deepEqual({ ...longRest, observedAt: null }, { ...plainRest, observedAt: null }, 'only days differ');
    assert.equal(f.stateBytes(), before, 'inspect must not write state');
  } finally { f.cleanup(); }
});

test('1.2.6: schedule inspect --days 1 returns today only; plain inspect and previews keep 7 days', async () => {
  const f = await prepared();
  try {
    const one = await f.cli([...inspect, '--days', '1']);
    assert.deepEqual(one.days.map(d => d.date), ['2026-11-12']);
    assert.deepEqual(one.days[0], (await f.cli(inspect)).days[0]);
    assert.equal((await f.cli([...inspect, '--days', '7'])).days.length, 7);
    assert.equal((await f.cli(inspect)).days.length, 7);
    const preview = await f.cli([...inspect, 'weekdays', '1,2,3']);
    assert.equal(preview.reason, 'schedule_projection');
    assert.equal(preview.days.length, 7);
    assert.equal(preview.proposal.days.length, 7);
  } finally { f.cleanup(); }
});

test('1.2.6: the parser accepts --days 1 to 28 alone and rejects every other --days shape', async () => {
  const slot = '2026-11-12T08:00';
  const bad = [
    ['--days'], ['--days', '0'], ['--days', '29'], ['--days', '100'], ['--days', 'abc'], ['--days', '7x'], ['--days', '07'],
    ['--days', '-1'], ['--days', '1.5'], ['--days', ''], ['--days', '7', '--days', '7'], ['--days', '7', '--slot', slot],
    ['--slot', slot, '--days', '7'], ['weekdays', '1,2', '--days', '7'], ['add', '09:00', '--days', '7'],
    ['--days', '7', 'weekdays', '1,2'], ['--days', '7', '--expected-revision', '1'],
  ];
  for (const args of bad) assert.equal((await execute([...inspect, ...args])).json.reason, 'invalid_invocation', args.join(' '));
  // A valid shape without services reaches the context check, as every accepted command does.
  for (const n of ['1', '7', '9', '10', '28']) assert.equal((await execute([...inspect, '--days', n])).json.reason, 'invalid_context', n);
  assert.equal((await execute([...inspect, '--days', '28', '--expected-installation-id', 'install_engine_126'])).json.reason, 'invalid_context');
});
