import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { runCommand } from "../runtime.mjs";
import { fakeClock, makeFixture } from "./helpers.mjs";

async function prepared(start) {
  const f = makeFixture({ clock: fakeClock(start) });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, "pool.json"), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, "switch.json"), discoveryPath: path.join(f.routerRoot, "discovery.json") };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: "install_admission_01", phase: "uninitialized", paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, "compatibility.json"), { schemaVersion: 1, reviewedRevision: "a".repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash("sha256").update(String(n)).digest("hex")])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: "synthetic", reviewEvidence: "synthetic", semantics: "equivalent" });
  let reads = 0, sends = 0;
  f.services.reader = {
    readRegistry: () => ({ kind: "ready", coordination: "idle", accounts: [{ routerAccountId: "router_0", eligible: true }] }),
    discoverIdentity: () => ({ kind: "ready", identity: { accountId: "workspace", userId: "user" } }),
    checkCompatibility: () => ({ kind: "ready" }),
    readCredential: (_ctx, e) => { reads++; return { kind: "ready", identity: e.identity, accessToken: "synthetic", expiresAt: 4102444800000, snapshot: {} }; },
    revalidate: () => ({ kind: "ready" }),
  };
  f.services.probe = async () => { sends++; return { outcome: "success", reason: "marker_confirmed", dispatched: true }; };
  const context = { root: f.companionRoot, nodePath: "/opt/homebrew/opt/node@22/bin/node", scriptPath: "/synthetic/warmup.mjs" };
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: "setup" })).exitCode, 0);
  assert.equal((await call({ name: "run" })).exitCode, 0);
  assert.equal((await call({ name: "schedule", action: "enable" })).exitCode, 0);
  return { ...f, call, state: () => JSON.parse(fs.readFileSync(f.statePath)), reads: () => reads, sends: () => sends };
}

// On this dated fixture Gaza is UTC+02. These are the configured local slots,
// not a claim that DST repeats or skips any of their hours.
const slots = [
  ["08:00", "2026-11-12T06:00:00Z"],
  ["13:00", "2026-11-12T11:00:00Z"],
  ["18:00", "2026-11-12T16:00:00Z"],
];
const withoutHeartbeat = s => { const copy = structuredClone(s); delete copy.lastTick; delete copy.lastWall; delete copy.lastTickZone; return copy; };

for (const [local, utc] of slots) for (const [label, offset, admitted] of [
  ["before", -1, false], ["start", 0, true], ["last millisecond", 59999, true], ["after", 60000, false],
]) test(`D05 ${local} ${label} admission and deduplication`, async () => {
  const at = Date.parse(utc) + offset, f = await prepared(at);
  try {
    const before = f.state(), reads = f.reads(), sends = f.sends();
    const out = await f.call({ name: "tick" });
    const after = f.state(), key = `2026-11-12T${local}`;
    assert.equal(after.lastTick, at); assert.equal(after.lastWall, at);
    if (admitted) {
      assert.equal(out.attempted, 1); assert.equal(f.reads(), reads + 1); assert.equal(f.sends(), sends + 1);
      assert.deepEqual(Object.keys(after.slots), [key]); assert.equal(after.highWater, key);
      assert.equal(after.activeBatch, null); assert.equal(after.lastSlotOutcome.slot, key);
      const repeat = await f.call({ name: "tick" });
      assert.equal(repeat.reason, "slot_already_claimed");
      assert.deepEqual(f.state(), after); assert.equal(f.reads(), reads + 1); assert.equal(f.sends(), sends + 1);
    } else {
      assert.equal(out.reason, "outside_admission_minute");
      assert.deepEqual(withoutHeartbeat(after), withoutHeartbeat(before));
      assert.deepEqual(after.slots, {}); assert.equal(after.highWater, null);
      assert.equal(f.reads(), reads); assert.equal(f.sends(), sends);
    }
  } finally { f.cleanup(); }
});

for (const [local, utc] of slots) test(`D05 ${local} compatibility crosses admission end without claim`, async () => {
  const at = Date.parse(utc) + 59900, f = await prepared(at);
  try {
    const before = f.state(), reads = f.reads(), sends = f.sends();
    let checks = 0;
    f.services.reader.checkCompatibility = () => { checks++; f.services.clock.advance(200); return { kind: "ready" }; };
    const out = await f.call({ name: "tick" });
    const after = f.state();
    assert.equal(checks, 1); assert.equal(out.reason, "outside_admission_minute");
    assert.equal(after.lastTick, at); assert.equal(after.lastWall, at);
    assert.deepEqual(withoutHeartbeat(after), withoutHeartbeat(before));
    assert.deepEqual(after.slots, {}); assert.equal(after.highWater, null);
    assert.equal(f.reads(), reads); assert.equal(f.sends(), sends);
  } finally { f.cleanup(); }
});

for (const [local, utc] of slots) test(`D05 ${local} manual work holds actual lock across admission end`, async () => {
  const at = Date.parse(utc) + 59900, f = await prepared(at);
  let release;
  try {
    let entered;
    const started = new Promise(resolve => { entered = resolve; });
    const gate = new Promise(resolve => { release = resolve; });
    let manualSends = 0;
    f.services.probe = async () => { manualSends++; entered(); await gate; return { outcome: "success", reason: "marker_confirmed", dispatched: true }; };
    const manual = f.call({ name: "run", allowSlotOverlap:true });
    await started;
    assert.equal(fs.existsSync(path.join(f.companionRoot, "work.lock", "owner.json")), true);
    const before = fs.readFileSync(f.statePath, "utf8"), reads = f.reads();
    const busy = await f.call({ name: "tick" });
    assert.equal(busy.exitCode, 3); assert.equal(fs.readFileSync(f.statePath, "utf8"), before);
    assert.equal(f.reads(), reads); assert.equal(manualSends, 1);
    f.services.clock.advance(200);
    release();
    const result = await manual;
    assert.deepEqual([result.selected, result.attempted, result.results[0].reason], [1, 1, "marker_confirmed"]);
    assert.equal(fs.existsSync(path.join(f.companionRoot, "work.lock")), false);
    const afterManual = f.state();
    const tick = await f.call({ name: "tick" });
    const afterTick = f.state();
    assert.equal(tick.reason, "outside_admission_minute");
    assert.equal(afterTick.lastTick, at + 200); assert.equal(afterTick.lastWall, at + 200);
    assert.deepEqual(withoutHeartbeat(afterTick), withoutHeartbeat(afterManual));
    assert.deepEqual(afterTick.slots, {}); assert.equal(afterTick.highWater, null);
    assert.equal(f.reads(), reads); assert.equal(manualSends, 1);
  } finally { release?.(); f.cleanup(); }
});
