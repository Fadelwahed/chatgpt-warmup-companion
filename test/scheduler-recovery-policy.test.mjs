import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { runCommand, recoverInstance } from "../runtime.mjs";
import { makeFixture } from "./helpers.mjs";

const slot = "2026-11-12T08:00";
const success = () => ({ outcome: "success", reason: "marker_confirmed", dispatched: true });
async function prepared(count = 2) {
  const f = makeFixture();
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, "pool.json"), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, "switch.json"), discoveryPath: path.join(f.routerRoot, "discovery.json") };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: "install_recovery_01", phase: "uninitialized", paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, "compatibility.json"), { schemaVersion: 1, reviewedRevision: "a".repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash("sha256").update(String(n)).digest("hex")])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: "synthetic", reviewEvidence: "synthetic", semantics: "equivalent" });
  f.services.reader = {
    readRegistry: () => ({ kind: "ready", coordination: "idle", accounts: Array.from({ length: count }, (_, n) => ({ routerAccountId: `router_${n}`, eligible: true })) }),
    discoverIdentity: (_ctx, id) => ({ kind: "ready", identity: { accountId: `workspace-${id}`, userId: `user-${id}` } }),
    checkCompatibility: () => ({ kind: "ready" }),
    readCredential: (_ctx, e) => ({ kind: "ready", identity: e.identity, accessToken: "synthetic", expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: "ready" }),
  };
  f.services.probe = async () => success();
  const context = { root: f.companionRoot, nodePath: "/opt/homebrew/opt/node@22/bin/node", scriptPath: "/synthetic/warmup.mjs" };
  const call = command => runCommand(command, context, f.services);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  assert.equal((await call({ name: "setup" })).exitCode, 0);
  assert.equal((await call({ name: "run" })).exitCode, 0);
  assert.equal((await call({ name: "schedule", action: "enable" })).exitCode, 0);
  return { ...f, context, call, state };
}
const scheduledReservations = state => Object.entries(state.reservations).filter(([key]) => !key.startsWith("manual:"));

for (const cut of ["claim", "reservation", "result"]) test(`D cooperative crash fixture captures ${cut} durable bytes and recovers disabled`, async () => {
  const f = await prepared(1);
  try {
    const baseline = f.state().history.length, saved = path.join(f.root, "snapshot");
    let captured = false, sends = 0, sendsAtCut;
    f.services.probe = async () => { sends++; return success(); };
    f.services.fault = point => {
      if (point !== "after_state.json_rename" || captured) return;
      const s = f.state(), reservations = scheduledReservations(s).length;
      if (!s.activeBatch || (cut === "claim" && reservations !== 0) || (cut === "reservation" && (reservations !== 1 || s.history.length !== baseline)) || (cut === "result" && s.history.length !== baseline + 1)) return;
      assert.equal(fs.existsSync(path.join(f.companionRoot, "work.lock", "owner.json")), true);
      fs.cpSync(f.companionRoot, saved, { recursive: true });
      sendsAtCut = sends; captured = true;
    };
    await f.call({ name: "tick" });
    delete f.services.fault;
    assert.equal(captured, true);
    assert.equal(sendsAtCut, cut === "result" ? 1 : 0);
    // Restore only the synthetic captured state and proven fixture-owned orphan guard.
    assert.equal(fs.existsSync(path.join(f.companionRoot, "work.lock")), false);
    fs.copyFileSync(path.join(saved, "state.json"), f.statePath);
    fs.cpSync(path.join(saved, "work.lock"), path.join(f.companionRoot, "work.lock"), { recursive: true });
    fs.chmodSync(path.join(f.companionRoot, "work.lock"), 0o700);
    const before = f.state(), beforeSends = sends;
    assert.ok(before.slots[slot]); assert.equal(before.highWater, slot);
    assert.equal(scheduledReservations(before).length, cut === "claim" ? 0 : 1);
    if (cut !== "claim") assert.equal(scheduledReservations(before)[0][1].possibleSend, true);
    if (cut === "result") assert.equal(before.history.at(-1).outcome, "success");
    assert.equal((await f.call({ name: "tick" })).exitCode, 3);
    assert.equal(sends, beforeSends);
    const root = fs.lstatSync(f.companionRoot);
    const recovered = await recoverInstance(f.context, f.services, { installationId: "install_recovery_01", rootDev: root.dev, rootIno: root.ino,
      skipThrough: "2026-11-12T18:00", reviewEvidence: `synthetic cooperative crash ${cut}`, backupPath: null });
    assert.equal(recovered.reason, "recovered_disabled");
    const after = f.state();
    assert.equal(after.scheduleEnabled, false); assert.equal(after.skipThrough, "2026-11-12T18:00");
    assert.equal(after.highWater, slot); assert.deepEqual(after.slots, before.slots);
    assert.deepEqual(after.reservations, before.reservations); assert.deepEqual(after.history, before.history);
    assert.deepEqual(after.pilots, {}); assert.equal(after.activeBatch, null);
    assert.equal((await f.call({ name: "tick" })).reason, "schedule_disabled");
    assert.equal(sends, beforeSends);
  } finally { f.cleanup(); }
});

for (const scheduled of [false, true]) test(`D ${scheduled ? "scheduled" : "manual"} result write failure stops two-account batch`, async () => {
  const f = await prepared();
  try {
    if (!scheduled) assert.equal((await f.call({ name: "schedule", action: "disable" })).exitCode, 0);
    let sends = 0, armed = false, hit = false;
    f.services.probe = async () => { sends++; armed = true; return success(); };
    f.services.fault = point => { if (armed && !hit && point === "before_state.json_create") { hit = true; throw Error("synthetic_fault"); } };
    const out = await f.call({ name: scheduled ? "tick" : "run", allowSlotOverlap: !scheduled });
    delete f.services.fault;
    assert.equal(hit, true); assert.equal(out.exitCode, 2);
    assert.deepEqual([out.selected, out.attempted, sends], [2, 1, 1]);
    assert.equal(out.results[0].reason, "marker_confirmed"); assert.equal(out.results[1].reason, "batch_unprocessed");
    assert.ok(Object.values(f.state().reservations).some(r => r.possibleSend));
    const tick = await f.call({ name: "tick" });
    assert.equal(tick.reason, scheduled ? "slot_already_claimed" : "schedule_disabled");
    assert.equal(sends, 1);
    if (!scheduled) {
      // This is a new explicit command, not an automatic retry.
      assert.equal((await f.call({ name: "run" })).attempted, 2);
      assert.equal(sends, 3);
    }
  } finally { f.cleanup(); }
});

for (const scheduled of [false, true]) for (const [boundary, reason] of [
  ["credential", "credential_expired_or_unknown"], ["credential", "login_lease"],
  ["credential", "registry_ineligible"], ["revalidate", "snapshot_changed"],
]) test(`D ${scheduled ? "scheduled" : "manual"} ${reason} skips while retaining pilots`, async () => {
  const f = await prepared(1);
  try {
    const pilots = f.state().pilots, reader = f.services.reader;
    const method = boundary === "credential" ? "readCredential" : "revalidate", original = reader[method];
    reader[method] = () => ({ kind: "blocked", scope: "account", reason });
    let sends = 0; f.services.probe = async () => { sends++; return success(); };
    const out = await f.call({ name: scheduled ? "tick" : "run", allowSlotOverlap: !scheduled });
    assert.equal(out.attempted, 0); assert.equal(out.results[0].reason, reason); assert.equal(sends, 0);
    assert.deepEqual(f.state().pilots, pilots);
    reader[method] = original;
    if (scheduled) f.services.clock.advance(5 * 3600000);
    const next = await f.call({ name: scheduled ? "tick" : "run", allowSlotOverlap: !scheduled });
    assert.equal(next.attempted, 1); assert.equal(sends, 1);
  } finally { f.cleanup(); }
});

for (const scheduled of [false, true]) test(`D ${scheduled ? "scheduled" : "manual"} global refusal preserves first result and pilots`, async () => {
  const f = await prepared();
  try {
    const pilots = f.state().pilots; let sends = 0;
    f.services.probe = async () => { sends++; return success(); };
    f.services.reader.revalidate = (_ctx, e) => e.routerAccountId === "router_1" ? { kind: "blocked", scope: "global", reason: "compatibility_unavailable" } : { kind: "ready" };
    const out = await f.call({ name: scheduled ? "tick" : "run", allowSlotOverlap: !scheduled });
    assert.equal(out.exitCode, 2); assert.deepEqual([out.selected, out.attempted, sends], [2, 1, 1]);
    assert.equal(out.results[0].reason, "marker_confirmed"); assert.equal(out.results[1].reason, "batch_unprocessed");
    assert.deepEqual(f.state().pilots, pilots);
  } finally { f.cleanup(); }
});

for (const scheduled of [false, true]) test(`D ${scheduled ? "scheduled" : "manual"} unknown upstream rejection retains eligibility without retry`, async () => {
  const f = await prepared(1);
  try {
    const pilots = f.state().pilots; let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: "blocked", reason: "upstream_rejected", dispatched: true }; };
    const out = await f.call({ name: scheduled ? "tick" : "run", allowSlotOverlap: !scheduled });
    assert.equal(out.attempted, 1); assert.equal(out.results[0].reason, "upstream_rejected"); assert.equal(sends, 1);
    assert.deepEqual(f.state().pilots, pilots); assert.deepEqual(f.state().blocks, {});
    if (scheduled) { assert.equal((await f.call({ name: "tick" })).reason, "slot_already_claimed"); assert.equal(sends, 1); f.services.clock.advance(5 * 3600000); }
    f.services.probe = async () => { sends++; return success(); };
    assert.equal((await f.call({ name: scheduled ? "tick" : "run", allowSlotOverlap: !scheduled })).attempted, 1); assert.equal(sends, 2);
  } finally { f.cleanup(); }
});

for (const scheduled of [false, true]) test(`D ${scheduled ? "scheduled" : "manual"} compatibility refusal preserves pilots without dispatch`, async () => {
  const f = await prepared(2);
  try {
    const pilots = f.state().pilots; let sends = 0;
    f.services.probe = async () => { sends++; return success(); };
    f.services.reader.checkCompatibility = () => ({ kind: "blocked", scope: "global", reason: "compatibility_unavailable" });
    const out = await f.call({ name: scheduled ? "tick" : "run", allowSlotOverlap: !scheduled });
    assert.equal(out.exitCode, 2); assert.equal(out.reason, "compatibility_blocked");
    assert.equal(out.attempted ?? 0, 0); assert.equal(sends, 0);
    assert.deepEqual(f.state().pilots, pilots);
  } finally { f.cleanup(); }
});
