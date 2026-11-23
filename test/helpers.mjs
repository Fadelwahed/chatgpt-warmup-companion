import fs from 'node:fs';
import path from 'node:path';

export function fakeClock(start = Date.parse('2026-11-12T06:00:00Z')) {
  let wall = start;
  let mono = 0;
  let next = 1;
  const timers = new Map();
  return {
    wall: () => wall,
    zone: () => 'Asia/Gaza',
    mono: () => mono,
    setTimeout(fn, ms) { const id = next++; timers.set(id, { at: mono + ms, fn }); return id; },
    clearTimeout(id) { timers.delete(id); },
    advance(ms) {
      wall += ms; mono += ms;
      for (const [id, timer] of [...timers]) if (timer.at <= mono) { timers.delete(id); timer.fn(); }
    },
    setWall(value) { wall = value; },
  };
}

export function requestStub(response = { statusCode: 200, headers: {}, body: [] }) {
  const calls = [];
  const request = async (options, body, control) => {
    calls.push({ options, body, control });
    if (typeof response === 'function') return response(options, body, control);
    control.beforeSend();
    control.onDispatch();
    return response;
  };
  request.calls = calls;
  return request;
}

export function makeFixture({ routerSource, files = fs, clock = fakeClock(), request = requestStub() } = {}) {
  const base = process.env.WARMUP_TEST_ROOT;
  if (!base || !path.isAbsolute(base)) throw new Error('Fixture requires guarded test runner');
  const root = fs.mkdtempSync(path.join(base, 'fixture-'));
  fs.chmodSync(root, 0o700);
  const routerRoot = path.join(root, 'router');
  const companionRoot = path.join(root, 'companion');
  const launchAgents = path.join(root, 'LaunchAgents');
  for (const dir of [routerRoot, companionRoot, launchAgents]) fs.mkdirSync(dir, { mode: 0o700 });
  const markerPath = path.join(companionRoot, 'instance.json');
  const configPath = path.join(companionRoot, 'config.json');
  const statePath = path.join(companionRoot, 'state.json');
  const plistPath = path.join(launchAgents, 'local.codex-router-warmup.plist');
  if (routerSource !== undefined) {
    if (typeof routerSource !== 'object' || routerSource === null || Array.isArray(routerSource)) throw new TypeError('routerSource must be a caller-supplied path/content map');
    for (const [relative, contents] of Object.entries(routerSource)) {
      const target = path.resolve(routerRoot, relative);
      if (!target.startsWith(`${routerRoot}${path.sep}`) || typeof contents !== 'string') throw new TypeError('Unsafe synthetic Router source');
      fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
      fs.writeFileSync(target, contents, { mode: 0o600 });
    }
  }
  const owner = { pid: 4242, startId: 'synthetic-start', nonce: 'synthetic-nonce' };
  let alive = false;
  const processes = {
    current: owner,
    inspect(target) { return JSON.stringify(target) === JSON.stringify(owner) && alive ? 'alive' : 'dead'; },
    async wait(target) { return JSON.stringify(target) === JSON.stringify(owner) && !alive; },
    async terminate(target) { if (JSON.stringify(target) !== JSON.stringify(owner)) throw new Error('Unknown synthetic owner'); alive = false; },
    setAlive(value) { alive = Boolean(value); },
  };
  const jobs = {
    binding: null,
    async inspect(binding) { return this.binding && JSON.stringify(this.binding) === JSON.stringify(binding) ? 'loaded' : 'absent'; },
    async enable(binding) { this.binding = structuredClone(binding); },
    async disable(binding) { if (this.binding && JSON.stringify(this.binding) !== JSON.stringify(binding)) throw new Error('Unknown synthetic job'); this.binding = null; },
    async runner(binding) { return await this.inspect(binding) === 'loaded' && alive ? owner : null; },
  };
  const services = { files, uid: process.getuid(), acl: () => true, clock, request, processes, jobs };
  return { root, routerRoot, companionRoot, launchAgents, markerPath, configPath, statePath, plistPath, owner, services,
    cleanup() { fs.rmSync(root, { recursive: true, force: true }); } };
}
