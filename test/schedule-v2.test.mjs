import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { runCommand, UI_CAPABILITY } from "../runtime.mjs";
import { execute } from "../warmup.mjs";
import { fakeClock, makeFixture } from "./helpers.mjs";

// Version 2 Increment A engine contract: weekday rules, seven-day projection, proposed-edit
// preview, stale-save guards and per-slot explanations. All synthetic; no network or host state.
async function prepared(start, { zone = "Asia/Gaza", probe } = {}) {
  const clock = fakeClock(start);
  clock.zone = () => zone;
  const f = makeFixture({ clock });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, "pool.json"), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, "switch.json"), discoveryPath: path.join(f.routerRoot, "discovery.json") };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: "install_v2_sched_01", phase: "uninitialized", paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, "compatibility.json"), { schemaVersion: 1, reviewedRevision: "a".repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash("sha256").update(String(n)).digest("hex")])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: "synthetic", reviewEvidence: "synthetic", semantics: "equivalent" });
  let sends = 0;
  f.services.reader = {
    readRegistry: () => ({ kind: "ready", coordination: "idle", accounts: [{ routerAccountId: "router_0", eligible: true }] }),
    discoverIdentity: () => ({ kind: "ready", identity: { accountId: "workspace", userId: "user" } }),
    checkCompatibility: () => ({ kind: "ready" }),
    readCredential: (_ctx, e) => ({ kind: "ready", identity: e.identity, accessToken: "synthetic", expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: "ready" }),
  };
  let nextProbe = probe ?? (() => ({ outcome: "success", reason: "marker_confirmed", dispatched: true }));
  f.services.probe = async () => { sends++; return nextProbe(); };
  const context = { root: f.companionRoot, nodePath: "/opt/homebrew/opt/node@22/bin/node", scriptPath: "/synthetic/warmup.mjs" };
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: "setup" })).exitCode, 0);
  assert.equal((await call({ name: "run" })).exitCode, 0);
  assert.equal((await call({ name: "schedule", action: "enable" })).exitCode, 0);
  return { ...f, clock, call, context, sends: () => sends, setProbe: fn => { nextProbe = fn; },
    stateBytes: () => fs.readFileSync(f.statePath, "utf8"), state: () => JSON.parse(fs.readFileSync(f.statePath)) };
}
const at = iso => Date.parse(iso);
const inspect = (f, extra = {}) => f.call({ name: "schedule", action: "inspect", ...extra });
const times = day => day.admissions.map(item => item.admission);

test("V2-A legacy installation projects all seven days with the default times and writes nothing", async () => {
  const f = await prepared(at("2026-11-12T04:00:00Z")); // Thursday 06:00 Gaza
  try {
    const before = f.stateBytes(), job = await f.services.jobs.inspect(f.services.jobs.binding);
    const out = await inspect(f);
    assert.equal(out.exitCode, 0); assert.equal(out.reason, "schedule_projection");
    assert.equal(out.localDate, "2026-11-12"); assert.equal(out.zone, "Asia/Gaza");
    assert.deepEqual(out.weekdays, [1, 2, 3, 4, 5, 6, 7]);
    assert.equal(out.days.length, 7);
    assert.deepEqual(out.days.map(d => d.date), ["2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18"]);
    for (const day of out.days) { assert.deepEqual(times(day), ["08:00", "13:00", "18:00"]); assert.equal(day.exclusion, null); assert.equal(day.attemptsPerAccount, 3); }
    assert.equal(out.next.slot, "2026-11-12T08:00");
    assert.equal(out.days[0].admissions[0].next, true);
    assert.equal(f.stateBytes(), before, "inspect must not write state");
    assert.equal(await f.services.jobs.inspect(f.services.jobs.binding), job);
    assert.equal(f.sends(), 1, "only the setup pilot was sent");
  } finally { f.cleanup(); }
});

test("V2-A weekday rule starts tomorrow, preserves today and gates tick through the shared resolver", async () => {
  const f = await prepared(at("2026-11-13T04:00:00Z")); // Friday 06:00 Gaza
  try {
    const rev = f.state().scheduleRevision;
    const saved = await f.call({ name: "schedule", action: "weekdays", days: [1, 2, 3, 4], expectedRevision: rev, expectedLocalDate: "2026-11-13" });
    assert.equal(saved.exitCode, 0, saved.reason); assert.equal(saved.scheduleRevision, rev + 1);
    assert.deepEqual(f.state().scheduleEdits.weekdays, [1, 2, 3, 4]);
    const out = await inspect(f);
    const byDate = Object.fromEntries(out.days.map(d => [d.date, d]));
    assert.deepEqual(times(byDate["2026-11-13"]), ["08:00", "13:00", "18:00"], "Friday excluded only from tomorrow");
    assert.equal(byDate["2026-11-13"].exclusion, null);
    for (const date of ["2026-11-14", "2026-11-15"]) { assert.equal(byDate[date].exclusion, "weekday"); assert.deepEqual(byDate[date].admissions, []); assert.equal(byDate[date].configuredAttempts, 0); }
    assert.deepEqual(times(byDate["2026-11-16"]), ["08:00", "13:00", "18:00"]);

    f.clock.setWall(at("2026-11-13T06:00:10Z")); // Friday 08:00 Gaza: today preserved
    assert.equal((await f.call({ name: "tick" })).attempted, 1);
    f.clock.setWall(at("2026-11-14T06:00:10Z")); // Saturday 08:00: excluded
    const sat = await f.call({ name: "tick" });
    assert.equal(sat.reason, "outside_admission_minute"); assert.equal(f.state().slots["2026-11-14T08:00"], undefined);
    const why = await inspect(f, { slot: "2026-11-14T08:00" });
    assert.equal(why.explanation.verdict, "excluded"); assert.equal(why.explanation.exclusion, "weekday");
    f.clock.setWall(at("2026-11-16T06:00:10Z")); // Monday 08:00
    const mon = await f.call({ name: "tick" });
    assert.equal(mon.attempted, 1, "no catch-up; the next eligible admission runs once");
    assert.deepEqual(Object.keys(f.state().slots).filter(s => s.startsWith("2026-11-1")), ["2026-11-13T08:00", "2026-11-16T08:00"]);
  } finally { f.cleanup(); }
});

test("V2-A excluding today keeps today, including today cannot reopen it, and today-only edits refuse an excluded date", async () => {
  const f = await prepared(at("2026-11-14T04:00:00Z")); // Saturday 06:00 Gaza
  try {
    assert.equal((await f.call({ name: "schedule", action: "weekdays", days: [1, 2, 3, 4, 5] })).exitCode, 0);
    let edits = f.state().scheduleEdits;
    assert.deepEqual(Object.keys(edits.admissions), ["08:00", "13:00", "18:00"], "today's admissions stay");
    assert.equal(edits.todayExclusion, undefined);
    f.clock.setWall(at("2026-11-15T04:00:00Z")); // Sunday, now excluded by yesterday's rule
    const sunday = (await inspect(f)).days[0];
    assert.equal(sunday.exclusion, "weekday"); assert.deepEqual(sunday.admissions, []);
    const add = await f.call({ name: "schedule", action: "add", time: "09:00", today: true });
    assert.equal(add.reason, "schedule_date_excluded");
    assert.equal((await f.call({ name: "schedule", action: "weekdays", days: [1, 2, 3, 4, 5, 6, 7] })).exitCode, 0);
    edits = f.state().scheduleEdits;
    assert.equal(edits.weekdays, undefined, "all seven days restores the legacy shape");
    assert.equal(edits.todayExclusion, "weekday"); assert.deepEqual(edits.admissions, {});
    const out = await inspect(f);
    assert.equal(out.days[0].exclusion, "weekday", "a policy edit cannot reopen today");
    assert.deepEqual(times(out.days[1]), ["08:00", "13:00", "18:00"]);
    f.clock.setWall(at("2026-11-15T06:00:10Z"));
    assert.equal((await f.call({ name: "tick" })).reason, "outside_admission_minute");
    const manual = await f.call({ name: "run", allowSlotOverlap: true });
    assert.equal(manual.attempted, 1, "guarded manual runs stay available on an excluded date");
  } finally { f.cleanup(); }
});

test("V2-A proposed edits preview through inspect with the save validator and leave bytes unchanged", async () => {
  const f = await prepared(at("2026-11-12T02:00:00Z")); // Thursday 04:00 Gaza
  try {
    const before = f.stateBytes();
    const oneOff = await inspect(f, { proposal: { action: "add", time: "05:03", today: true } });
    assert.equal(oneOff.exitCode, 0, oneOff.reason);
    assert.deepEqual(times(oneOff.proposal.days[0]), ["05:03", "08:00", "13:00", "18:00"]);
    assert.deepEqual(times(oneOff.proposal.days[1]), ["08:00", "13:00", "18:00"], "the one-off does not change tomorrow");
    assert.deepEqual(times(oneOff.days[0]), ["08:00", "13:00", "18:00"], "current projection is unchanged");
    assert.equal(oneOff.proposal.localDate, "2026-11-12"); assert.equal(oneOff.proposal.expectedRevision, f.state().scheduleRevision);
    const workweek = await inspect(f, { proposal: { action: "weekdays", days: [1, 2, 3, 4, 5], today: false } });
    assert.deepEqual(workweek.proposal.days.map(d => d.exclusion), [null, null, "weekday", "weekday", null, null, null]);
    assert.equal((await inspect(f, { proposal: { action: "add", time: "08:10", today: false } })).reason, "schedule_spacing");
    assert.equal((await f.call({ name: "schedule", action: "add", time: "08:10" })).reason, "schedule_spacing", "save rejects the same edit");
    assert.equal((await inspect(f, { proposal: { action: "weekdays", days: [], today: false } })).reason, "invalid_weekdays");
    assert.equal(f.stateBytes(), before);
  } finally { f.cleanup(); }
});

test("V2-A stale proposals fail on revision or local-date change without writing", async () => {
  const f = await prepared(at("2026-11-12T20:00:00Z")); // Thursday 22:00 Gaza
  try {
    const rev = f.state().scheduleRevision;
    assert.equal((await f.call({ name: "schedule", action: "add", time: "21:00", expectedRevision: rev })).exitCode, 0);
    const before = f.stateBytes();
    const stale = await f.call({ name: "schedule", action: "weekdays", days: [1, 2, 3, 4, 5], expectedRevision: rev });
    assert.equal(stale.reason, "schedule_revision_conflict"); assert.equal(f.stateBytes(), before);
    f.clock.setWall(at("2026-11-12T22:30:00Z")); // Friday 00:30 Gaza, same revision
    const rolled = await f.call({ name: "schedule", action: "weekdays", days: [1, 2, 3, 4, 5], expectedRevision: rev + 1, expectedLocalDate: "2026-11-12" });
    assert.equal(rolled.reason, "schedule_date_changed"); assert.equal(f.stateBytes(), before);
  } finally { f.cleanup(); }
});

test("V2-A projection reports nonexistent and repeated local minutes around DST", async () => {
  const f = await prepared(at("2026-03-06T12:00:00Z"), { zone: "America/New_York" });
  try {
    assert.equal((await f.call({ name: "schedule", action: "add", time: "02:30" })).exitCode, 0);
    const spring = (await inspect(f)).days.find(d => d.date === "2026-03-08");
    const gap = spring.admissions.find(a => a.logicalTime === "02:30");
    assert.equal(gap.state, "nonexistent_local_time"); assert.equal(gap.at, null);
    assert.equal(spring.attemptsPerAccount, 3);
    f.clock.setWall(at("2026-10-30T12:00:00Z"));
    assert.equal((await f.call({ name: "schedule", action: "move", time: "02:30", target: "01:30" })).exitCode, 0);
    const fall = (await inspect(f)).days.find(d => d.date === "2026-11-01");
    const repeated = fall.admissions.filter(a => a.logicalTime === "01:30");
    assert.deepEqual(repeated.map(a => a.repeatedLocalTime), [1, 2]);
    assert.equal(repeated[1].at - repeated[0].at, 3600000);
    assert.equal(fall.attemptsPerAccount, 4, "a repeated minute is still one logical slot");
  } finally { f.cleanup(); }
});

test("V2-A slot explanation separates confirmed, uncertain, ruled-out and unobserved outcomes", async () => {
  const f = await prepared(at("2026-11-12T04:00:00Z"));
  try {
    f.clock.setWall(at("2026-11-12T06:00:05Z"));
    await f.call({ name: "tick" });
    const ok = (await inspect(f, { slot: "2026-11-12T08:00" })).explanation;
    assert.equal(ok.verdict, "admitted"); assert.equal(ok.admission, "08:00");
    assert.deepEqual(ok.accounts.map(a => [a.dispatch, a.response, a.windowEffect]), [["confirmed", "confirmed", "unverified"]]);
    assert.equal(f.state().slots["2026-11-12T08:00"].admission, "08:00", "new claims record the effective minute");

    f.setProbe(() => ({ outcome: "uncertain", reason: "stream_or_transport_uncertain", dispatched: false }));
    f.clock.setWall(at("2026-11-12T11:00:05Z"));
    await f.call({ name: "tick" });
    const unsure = (await inspect(f, { slot: "2026-11-12T13:00" })).explanation;
    assert.equal(unsure.accounts[0].dispatch, "unknown"); assert.equal(unsure.accounts[0].response, "uncertain");
    assert.equal(unsure.accounts[0].reservationUnresolved, true);

    const later = (await inspect(f, { slot: "2026-11-12T18:00" })).explanation;
    assert.equal(later.verdict, "scheduled"); assert.deepEqual(later.accounts, []);

    f.clock.setWall(at("2026-11-12T19:00:00Z")); // 21:00 Gaza, no tick since 13:00
    const silent = (await inspect(f, { slot: "2026-11-12T18:00" })).explanation;
    assert.equal(silent.verdict, "unobserved"); assert.equal(silent.heartbeat.observedAfterAdmission, false);
    assert.equal(JSON.stringify(silent).includes("sleep"), false, "no sleep inference");
    await f.call({ name: "tick" });
    const missed = (await inspect(f, { slot: "2026-11-12T18:00" })).explanation;
    assert.equal(missed.verdict, "not_admitted"); assert.equal(missed.notAdmitted.cause, "no_tick_between");
    assert.equal(missed.notAdmitted.guidance, "check_job_and_mac_awake");

    f.setProbe(() => ({ outcome: "success", reason: "marker_confirmed", dispatched: true }));
    // Synthetic cooldown so the next scheduled account is skipped before any reservation.
    const state = f.state();
    const id = state.slots["2026-11-12T08:00"].enrollmentIds[0];
    state.cooldowns[id] = at("2026-11-14T00:00:00Z");
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    f.clock.setWall(at("2026-11-13T06:00:05Z"));
    await f.call({ name: "tick" });
    const cool = (await inspect(f, { slot: "2026-11-13T08:00" })).explanation;
    assert.deepEqual([cool.accounts[0].dispatch, cool.accounts[0].reason, cool.accounts[0].guidance], ["ruled_out", "cooldown", "wait_for_cooldown"]);

    assert.equal((await inspect(f, { slot: "2026-02-30T08:00" })).reason, "invalid_slot");
    const old = (await inspect(f, { slot: "2026-10-01T08:00" })).explanation;
    assert.equal(old.verdict, "unknown", "past evidence outside the record stays unknown");
  } finally { f.cleanup(); }
});

test("V2-A status exposes the UI capability and engine binding; CLI adds the engine build", async () => {
  const f = await prepared(at("2026-11-12T04:00:00Z"));
  try {
    const status = await f.call({ name: "status" });
    assert.deepEqual(status.capability, UI_CAPABILITY);
    assert.deepEqual(status.engine, { nodePath: f.context.nodePath, scriptPath: f.context.scriptPath });
    for (const feature of ["schedule_inspect", "schedule_weekdays", "slot_explanation", "expected_local_date"]) assert.ok(status.capability.features.includes(feature));
  } finally { f.cleanup(); }
  const repo = process.env.WARMUP_REPO;
  const out = await execute(["status"], { context: { root: "/nonexistent", nodePath: "/opt/homebrew/opt/node@22/bin/node", scriptPath: path.join(repo, "warmup.mjs") } });
  assert.equal(out.json.engineBuild, undefined, "build is only reported with a ready status");
});

test("V2-A parser accepts the documented inspect and weekday shapes and rejects the rest", async () => {
  const bad = [
    ["schedule", "weekdays"], ["schedule", "weekdays", "0,1"], ["schedule", "weekdays", "8"], ["schedule", "weekdays", "1,1"],
    ["schedule", "weekdays", "1,2", "--today"], ["schedule", "inspect", "--slot"], ["schedule", "inspect", "--slot", "2026-11-12"],
    ["schedule", "inspect", "add", "09:00", "--preview"], ["schedule", "inspect", "--expected-revision", "1"],
    ["schedule", "enable", "--expected-local-date", "2026-11-12"], ["status", "--expected-local-date", "2026-11-12"],
  ];
  for (const argv of bad) assert.equal((await execute(argv)).json.reason, "invalid_invocation", argv.join(" "));
  const good = [["schedule", "inspect"], ["schedule", "inspect", "--slot", "2026-11-12T08:00"], ["schedule", "inspect", "weekdays", "5,1,3"],
    ["schedule", "inspect", "move", "08:00", "09:00", "--today"], ["schedule", "weekdays", "all", "--preview"],
    ["schedule", "weekdays", "1,2,3,4,5", "--expected-revision", "3", "--expected-local-date", "2026-11-12"]];
  for (const argv of good) assert.equal((await execute(argv)).json.reason, "invalid_context", argv.join(" "));
});

test("V2-A review: spacing is still enforced when a weekday rule excludes the following days", async () => {
  const f = await prepared(at("2026-11-18T04:00:00Z")); // Wednesday 06:00 Gaza
  try {
    assert.equal((await f.call({ name: "schedule", action: "weekdays", days: [1] })).exitCode, 0);
    f.clock.setWall(at("2026-11-19T04:00:00Z")); // Thursday: Thu..Sun excluded, next included day Monday
    const before = f.stateBytes();
    assert.equal((await f.call({ name: "schedule", action: "add", time: "08:05" })).reason, "schedule_spacing");
    assert.equal((await inspect(f, { proposal: { action: "add", time: "13:10", today: false } })).reason, "schedule_spacing");
    assert.equal(f.stateBytes(), before);
    assert.equal((await f.call({ name: "schedule", action: "add", time: "21:00" })).exitCode, 0, "a well-spaced edit still saves");
    // Monday and Tuesday included: the Monday 23:55 -> Tuesday 00:05 boundary must be checked.
    assert.equal((await f.call({ name: "schedule", action: "weekdays", days: [1, 2] })).exitCode, 0);
    assert.equal((await f.call({ name: "schedule", action: "add", time: "23:55" })).exitCode, 0);
    assert.equal((await f.call({ name: "schedule", action: "add", time: "00:05" })).reason, "schedule_spacing");
  } finally { f.cleanup(); }
});

test("V2-A review: a later skipped row cannot hide an unresolved or uncertain send", async () => {
  const f = await prepared(at("2026-11-12T04:00:00Z"));
  try {
    f.setProbe(() => ({ outcome: "uncertain", reason: "stream_or_transport_uncertain", dispatched: false }));
    f.clock.setWall(at("2026-11-12T06:00:05Z"));
    await f.call({ name: "tick" });
    // Synthetic recovery residue: an `already_reserved` skip appended for the same slot and account.
    const state = f.state();
    const first = state.history.findLast(entry => entry.slot === "2026-11-12T08:00");
    state.history.push({ enrollmentId: first.enrollmentId, outcome: "blocked", reason: "already_reserved", mode: "scheduled",
      model: first.model, zone: first.zone, slot: first.slot, skipped: true, dispatched: false, at: first.at + 1000 });
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    const account = (await inspect(f, { slot: "2026-11-12T08:00" })).explanation.accounts[0];
    assert.deepEqual([account.dispatch, account.response, account.reason, account.possibleSend, account.reservationUnresolved],
      ["unknown", "uncertain", "stream_or_transport_uncertain", true, true]);
  } finally { f.cleanup(); }
});

test("V2-A review: transport guidance follows whether the request may have been sent", async () => {
  const f = await prepared(at("2026-11-12T04:00:00Z"));
  try {
    f.setProbe(() => ({ outcome: "uncertain", reason: "transport_unavailable", dispatched: true }));
    f.clock.setWall(at("2026-11-12T06:00:05Z"));
    await f.call({ name: "tick" });
    const sent = (await inspect(f, { slot: "2026-11-12T08:00" })).explanation.accounts[0];
    assert.deepEqual([sent.dispatch, sent.guidance], ["confirmed", "outcome_unknown_no_resend"]);
    f.setProbe(() => ({ outcome: "blocked", reason: "transport_unavailable", dispatched: false }));
    f.clock.setWall(at("2026-11-12T11:00:05Z"));
    await f.call({ name: "tick" });
    const unsent = (await inspect(f, { slot: "2026-11-12T13:00" })).explanation.accounts[0];
    assert.deepEqual([unsent.dispatch, unsent.guidance, unsent.possibleSend], ["ruled_out", "check_network", false]);
  } finally { f.cleanup(); }
});
