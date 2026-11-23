import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execute } from '../warmup.mjs';
import { fakeClock, makeFixture } from './helpers.mjs';

test('history since is canonical and bounded; unresolved evidence is linked and sanitized', async () => {
  const f = makeFixture({ clock: fakeClock(Date.parse('2026-11-12T08:00:00.000Z')) });
  try {
    const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
      poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
      switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
    f.services.files.writeFileSync(f.markerPath, JSON.stringify({ schemaVersion: 1, installationId: 'install_history_01', phase: 'uninitialized', paths, plistPath: f.plistPath }), { mode: 0o600 });
    f.services.files.writeFileSync(path.join(f.companionRoot, 'compatibility.json'), JSON.stringify({ schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
      sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
      adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' }), { mode: 0o600 });
    f.services.reader = {
      readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_0', eligible: true }] }),
      discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'private_workspace', userId: 'private_user' } }),
      checkCompatibility: () => ({ kind: 'ready' }),
      readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
      revalidate: () => ({ kind: 'ready' }),
    };
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: fileURLToPath(new URL('../warmup.mjs', import.meta.url)) };
    const call = async args => (await execute(args, { ...f.services, context }));
    const setup = await call(['setup']);
    assert.equal(setup.exitCode, 0, JSON.stringify(setup.json));
    assert.equal((await call(['run'])).exitCode, 0);
    const state = JSON.parse(fs.readFileSync(f.statePath));
    const success = state.history.at(-1);
    assert.match(success.reservationId, /^res_/);
    assert.equal(success.reservationId, Object.values(state.reservations)[0].reservationId);
    const enrollment = success.enrollmentId;
    const identity = Object.values(state.reservations)[0].identity;
    const at = success.at;
    const missing = 'res_11111111-1111-4111-8111-111111111111';
    const uncertain = 'res_22222222-2222-4222-8222-222222222222';
    const noSend = 'res_33333333-3333-4333-8333-333333333333';
    for (const [key, id] of [['manual:missing', missing], ['manual:uncertain', uncertain], ['manual:no-send', noSend]])
      state.reservations[key] = { enrollmentId: enrollment, identity, at, possibleSend: true, reservationId: id, ...(id === noSend ? {resolved:true} : {}) };
    state.reservations[JSON.stringify(['2026-11-12T13:00', enrollment, identity.accountId, identity.userId])] = { enrollmentId: enrollment, identity, at, possibleSend: true };
    state.history.push({ enrollmentId: enrollment, reservationId: uncertain, outcome: 'uncertain', reason: 'stream_or_transport_uncertain', dispatched: true, at });
    state.history.push({ enrollmentId: enrollment, reservationId: noSend, outcome: 'blocked', reason: 'transport_before_send', dispatched: false, at });
    fs.writeFileSync(f.statePath, JSON.stringify(state));
    const status = (await call(['status'])).json;
    assert.deepEqual(status.unresolved.map(row => row.reservation), [missing, uncertain, status.unresolved[2].reservation]);
    assert.match(status.unresolved[2].reservation, /^legacy_[a-f0-9]{32}$/);
    assert.equal(status.unresolved[2].slot, '2026-11-12T13:00');
    assert.equal(JSON.stringify(status.unresolved).includes('private_'), false);
    const iso = new Date(at).toISOString();
    assert.equal((await call(['history', '--since', iso])).json.rows.length, 3);
    assert.equal((await call(['history', '--since', new Date(at + 1).toISOString()])).json.rows.length, 0);
    assert.equal((await call(['history', '--account', enrollment, '--since', iso])).json.rows[0].reservationId, noSend);
    assert.equal((await call(['history', '--since', '2026-11-12T08:00:00Z'])).json.rows.length, 3);
    assert.equal((await call(['history', '--since', '2026-11-12T08:00:00+00:00'])).json.reason, 'invalid_invocation');
    assert.equal((await call(['history', '--since', iso, '--since', iso])).json.reason, 'invalid_invocation');
    for (let i = 0; i < 55; i++) state.history.push({ enrollmentId: enrollment, outcome: 'blocked', reason: 'transport_before_send', dispatched: false, at });
    state.history.push({ enrollmentId: enrollment, outcome: 'blocked', reason: 'old', at: at - 31 * 86400000 });
    fs.writeFileSync(f.statePath, JSON.stringify(state));
    const bounded = (await call(['history'])).json;
    assert.equal(bounded.rows.length, 50);
    assert.equal(bounded.truncated, true);
    assert.equal(bounded.rows.some(row => row.reason === 'old'), false);
    state.history = state.history.filter(row => row.reservationId !== success.reservationId);
    fs.writeFileSync(f.statePath, JSON.stringify(state));
    assert.ok(!(await call(['status'])).json.unresolved.some(row => row.reservation === success.reservationId));
  } finally { f.cleanup(); }
});
