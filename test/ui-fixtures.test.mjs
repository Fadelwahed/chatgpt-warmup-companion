import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { execute } from "../warmup.mjs";
import { fakeClock, makeFixture } from "./helpers.mjs";

// Fixture parity for the native app. Each scenario runs the real CLI envelope (warmup.mjs
// execute) against a synthetic installation and must equal test/fixtures/ui/<name>.json
// byte-for-byte after removing the build digest. The Swift tests decode the same files, so a
// contract change fails here first. To regenerate after an intentional engine change, run
// this file and pass its TAP output to tools/extract-ui-fixtures.mjs.
const repo = process.env.WARMUP_REPO;
const fixtureDir = path.join(repo, "test", "fixtures", "ui");
const INSTALLATION = "install_ui_fixture_01";

async function installation() {
  const clock = fakeClock(Date.parse("2026-11-12T04:00:00Z")); // Thursday 06:00 Asia/Gaza
  const f = makeFixture({ clock });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, "pool.json"), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, "switch.json"), discoveryPath: path.join(f.routerRoot, "discovery.json") };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: INSTALLATION, phase: "uninitialized", paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, "compatibility.json"), { schemaVersion: 1, reviewedRevision: "a".repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash("sha256").update(String(n)).digest("hex")])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: "synthetic", reviewEvidence: "synthetic", semantics: "equivalent" });
  let probe = () => ({ outcome: "success", reason: "marker_confirmed", dispatched: true, firstTextMs: 900 });
  f.services.reader = {
    readRegistry: () => ({ kind: "ready", coordination: "idle", accounts: [{ routerAccountId: "router_a", eligible: true }, { routerAccountId: "router_b", eligible: true }] }),
    discoverIdentity: (_ctx, ref) => ({ kind: "ready", identity: { accountId: `workspace_${ref}`, userId: `user_${ref}` } }),
    checkCompatibility: () => ({ kind: "ready" }),
    readCredential: (_ctx, e) => ({ kind: "ready", identity: e.identity, accessToken: "synthetic", expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: "ready" }),
  };
  f.services.probe = async () => probe();
  f.services.context = { root: f.companionRoot, nodePath: "/opt/homebrew/opt/node@22/bin/node", scriptPath: path.join(repo, "warmup.mjs") };
  const cli = async argv => (await execute(argv, f.services)).json;
  assert.equal((await cli(["setup"])).outcome, "ready");
  for (const ref of ["router_a", "router_b"]) assert.equal((await cli(["enroll", "--account", ref])).outcome, "ready");
  assert.equal((await cli(["run"])).outcome, "success");
  assert.equal((await cli(["schedule", "enable"])).outcome, "ready");
  return { f, clock, cli, setProbe: fn => { probe = fn; } };
}

async function scenarios() {
  const { f, clock, cli, setProbe } = await installation();
  const out = {};
  try {
    out["status-enabled"] = await cli(["status"]);
    out["projection-default"] = await cli(["schedule", "inspect"]);
    out["projection-proposal-workweek"] = await cli(["schedule", "inspect", "weekdays", "1,2,3,4,5"]);
    out["list"] = await cli(["list"]);
    clock.setWall(Date.parse("2026-11-12T06:00:05Z"));
    await cli(["tick"]);
    out["slot-admitted"] = await cli(["schedule", "inspect", "--slot", "2026-11-12T08:00"]);
    setProbe(() => ({ outcome: "uncertain", reason: "stream_or_transport_uncertain", dispatched: false }));
    clock.setWall(Date.parse("2026-11-12T11:00:05Z"));
    await cli(["tick"]);
    out["slot-uncertain"] = await cli(["schedule", "inspect", "--slot", "2026-11-12T13:00"]);
    clock.setWall(Date.parse("2026-11-12T19:00:00Z"));
    out["slot-unobserved"] = await cli(["schedule", "inspect", "--slot", "2026-11-12T18:00"]);
    await cli(["tick"]);
    out["slot-no-tick"] = await cli(["schedule", "inspect", "--slot", "2026-11-12T18:00"]);
    out["history"] = await cli(["history"]);
    out["revision-conflict"] = await cli(["schedule", "add", "20:30", "--expected-revision", "0"]);
    out["status-paused"] = (await cli(["schedule", "disable"]), await cli(["status"]));
    // A6 mutation replies, each carrying the guards the app always sends.
    const guard = ["--expected-installation-id", INSTALLATION];
    out["mutation-resume"] = await cli(["schedule", "enable", "--expected-revision", String(out["status-paused"].scheduleRevision), ...guard]);
    out["proposal-workweek-saved-shape"] = await cli(["schedule", "inspect", "weekdays", "1,2,3,4,5"]);
    const proposal = out["proposal-workweek-saved-shape"].proposal;
    out["mutation-edit-saved"] = await cli(["schedule", "weekdays", "1,2,3,4,5", "--expected-revision", String(proposal.expectedRevision), "--expected-local-date", proposal.localDate, ...guard]);
    clock.setWall(Date.parse("2026-11-13T05:59:30Z")); // Friday 07:59:30 Gaza, next admission 08:00
    out["mutation-edit-date-changed"] = await cli(["schedule", "add", "21:00", "--expected-revision", String(out["mutation-edit-saved"].scheduleRevision), "--expected-local-date", proposal.localDate, ...guard]);
    out["mutation-run-overlap"] = await cli(["run", ...guard]);
    clock.setWall(Date.parse("2026-11-13T07:00:00Z")); // 09:00 Gaza, clear of slots
    setProbe(() => ({ outcome: "success", reason: "marker_confirmed", dispatched: true, firstTextMs: 800 }));
    out["mutation-run-success"] = await cli(["run", ...guard]);
    out["mutation-enroll-already"] = await cli(["enroll", "--account", "router_a", ...guard]);
    out["mutation-pause"] = await cli(["schedule", "disable", "--expected-revision", String(out["mutation-edit-saved"].scheduleRevision), ...guard]);
  } finally { f.cleanup(); }
  return out;
}

// Random enrollment/reservation IDs and the checkout path vary per run; replace them with
// placeholders numbered by first appearance so fixtures stay byte-stable.
function stable(json) {
  const copy = structuredClone(json);
  delete copy.engineBuild;
  const seen = new Map();
  const text = JSON.stringify(copy)
    .replaceAll(JSON.stringify(path.join(repo, "warmup.mjs")).slice(1, -1), "<repo>/warmup.mjs")
    .replace(/\b(enr|res)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/g, (id, kind) => {
      if (!seen.has(id)) seen.set(id, `${kind}_${String([...seen.keys()].filter(key => key.startsWith(kind)).length + 1).padStart(2, "0")}`);
      return seen.get(id);
    });
  return JSON.parse(text);
}

test("UI fixtures match the real engine envelopes for synthetic installations", async () => {
  const generated = await scenarios();
  const missing = [];
  const drifted = [];
  for (const [name, json] of Object.entries(generated)) {
    assert.equal(json.protocolVersion, 1); assert.equal(json.installationId, INSTALLATION, name);
    assert.equal(JSON.stringify(json).includes("synthetic\""), false, `${name} must not echo credential material`);
    // Print before comparing so the extract tool still gets every fixture when some drifted.
    process.stdout.write(`# UI-FIXTURE ${name} ${JSON.stringify(stable(json))}\n`);
    const file = path.join(fixtureDir, `${name}.json`);
    let expected;
    try { expected = JSON.parse(fs.readFileSync(file, "utf8")); }
    catch { missing.push(name); continue; }
    try { assert.deepEqual(stable(json), stable(expected), `${name} drifted from its UI fixture`); }
    catch (error) { drifted.push({ name, error }); }
  }
  assert.deepEqual(missing, [], "regenerate missing UI fixtures with tools/extract-ui-fixtures.mjs");
  if (drifted.length) {
    const [{ error }] = drifted;
    // A new error, so the spec reporter (which prints the stack) shows the list too.
    throw new assert.AssertionError({
      message: `${drifted.length} UI fixtures drifted: ${drifted.map(entry => entry.name).join(", ")}; `
        + `regenerate with tools/extract-ui-fixtures.mjs and review the diff.\nFirst mismatch: ${error.message}`,
      actual: error.actual, expected: error.expected, operator: error.operator,
    });
  }
  assert.equal(typeof generated["status-enabled"].engineBuild, "string");
  assert.match(generated["status-enabled"].engineBuild, /^sha256:[a-f0-9]{64}$/);
});
