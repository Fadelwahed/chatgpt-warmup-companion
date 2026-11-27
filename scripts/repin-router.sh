#!/bin/sh
# Re-pins the installed Warm-up engine to codex-router's current revision after codex-router updated
# itself (its menu's Update or Restart fast-forwards the checkout). It hashes the 13 files the engine
# reads, and when none of them changed it writes a new compatibility record through the engine's own
# `maintain --file`, pausing scheduling around it and resuming it if it was on. A changed pinned file
# stops it until you have read the diff and pass a review note. It never edits codex-router.
#   scripts/repin-router.sh                          re-pin when no pinned file changed
#   scripts/repin-router.sh --dry-run                print the new record; change nothing
#   scripts/repin-router.sh --accept-changed NOTE    re-pin although pinned files changed; NOTE says what you checked
#   scripts/repin-router.sh --self-test              check the script against a temporary router and a stub engine
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

NODE=${WARMUP_NODE:-/opt/homebrew/opt/node@22/bin/node}
ROOT=${WARMUP_ROOT:-$HOME/.local/share/codex-router-warmup}
USAGE="usage: repin-router.sh [--dry-run] [--accept-changed NOTE], or repin-router.sh --self-test"
MAX_NOTE=300

fail() { echo "repin-router: $*" >&2; exit 1; }
usage() { echo "repin-router: $* ($USAGE)" >&2; exit 2; }

# Node helpers. The engine's reply is parsed here so only its outcome and reason are ever printed.
JS='
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const [mode, ...args] = process.argv.slice(1);
const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const digests = (record, router) => Object.fromEntries(Object.keys(record.sourceDigests).map(name => {
  try { return [name, crypto.createHash("sha256").update(fs.readFileSync(path.join(router, name))).digest("hex")]; }
  catch { console.error("repin-router: pinned file missing in codex-router: " + name); process.exit(3); }
}));
if (mode === "names") console.log(Object.keys(read(args[0]).sourceDigests).join(" "));
else if (mode === "revision") console.log(read(args[0]).reviewedRevision);
else if (mode === "source") {
  // The codex-router folder named in the engine config.json: a non-empty absolute path, or exit 1.
  let root;
  try { root = read(args[0]).paths.sourceRoot; } catch { process.exit(1); }
  if (typeof root !== "string" || root === "" || !path.isAbsolute(root)) process.exit(1);
  console.log(root);
}
else if (mode === "changed") {
  const record = read(args[0]), now = digests(record, args[1]);
  console.log(Object.keys(now).filter(name => now[name] !== record.sourceDigests[name]).join(" "));
} else if (mode === "candidate") {
  const [compat, config, router, head, evidence, out] = args;
  const record = read(compat);
  const compatibility = { ...record, reviewedRevision: head, sourceDigests: digests(record, router), reviewEvidence: evidence };
  if (out === "-") { console.log(JSON.stringify(compatibility, null, 2)); process.exit(0); }
  const candidate = { schemaVersion: 1, config: read(config), compatibility, reviewEvidence: evidence };
  fs.writeFileSync(out, JSON.stringify(candidate, null, 2) + "\n", { mode: 0o600, flag: "wx" });
} else if (mode === "reply") {
  let text = "";
  process.stdin.on("data", chunk => text += chunk).on("end", () => {
    let reply = {};
    try { reply = JSON.parse(text); } catch { reply = { outcome: "unreadable", reason: "unreadable_reply" }; }
    const word = value => typeof value === "string" && /^[A-Za-z0-9_.-]+$/.test(value) ? value : "unknown";
    console.log([word(reply.outcome), word(reply.reason), reply.scheduleEnabled === true, word(reply.compatibility)].join(" "));
  });
} else process.exit(4);'

mode=repin dry=0 accept=0 note=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --accept-changed)
      [ $# -ge 2 ] || usage "--accept-changed needs a note"
      accept=1 note=$2
      shift ;;
    --self-test) mode=selftest ;;
    *) usage "unknown argument: $1" ;;
  esac
  shift
done
if [ "$accept" = 1 ]; then
  [ -n "$note" ] || usage "the review note is empty"
  [ "${#note}" -le "$MAX_NOTE" ] || usage "the review note is longer than $MAX_NOTE characters"
  case "$note" in *[[:cntrl:]]*) usage "the review note must be one line of printable text" ;; esac
fi
if [ "$mode" = selftest ] && [ "$dry$accept" != 00 ]; then usage "--self-test takes no other argument"; fi

gitr() { /usr/bin/git --no-pager --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$ROUTER" "$@"; }
short() { printf '%.8s' "$1"; }

# Runs one engine command and sets `reply` to "outcome reason scheduleEnabled compatibility". The engine
# exits non-zero on a blocked reply, so the exit status is kept for the record but the reply decides.
engine() {
  out=$("$NODE" "$ROOT/warmup.mjs" "$@" 2>/dev/null) && rc=0 || rc=$?
  reply=$(printf '%s' "$out" | "$NODE" -e "$JS" reply) || reply="unreadable unreadable_reply false unknown"
  outcome=${reply%% *}
  rest=${reply#* }
  reason=${rest%% *}
}

repin() {
  [ "$(id -u)" != 0 ] || fail "run it as yourself, not with sudo."
  [ -x "$NODE" ] || fail "node not found at $NODE (set WARMUP_NODE)."
  [ -f "$ROOT/warmup.mjs" ] || fail "engine not found at $ROOT/warmup.mjs (set WARMUP_ROOT)."
  COMPAT=$ROOT/compatibility.json CONFIG=$ROOT/config.json
  [ -f "$COMPAT" ] || fail "$COMPAT not found."
  [ -f "$CONFIG" ] || fail "$CONFIG not found."
  ROUTER=$("$NODE" -e "$JS" source "$CONFIG") || fail "could not read codex-router's folder from $CONFIG."
  [ -d "$ROUTER" ] || fail "codex-router not found at $ROUTER (the folder the engine's config names)."
  HEAD=$(gitr rev-parse HEAD 2>/dev/null) || fail "$ROUTER is not a Git checkout of codex-router."

  OLD=$("$NODE" -e "$JS" revision "$COMPAT") || fail "could not read $COMPAT."
  NAMES=$("$NODE" -e "$JS" names "$COMPAT") || fail "could not read $COMPAT."
  # shellcheck disable=SC2086 # the names are fixed src/ and bin/ paths without spaces
  DIRTY=$(gitr status --porcelain --untracked-files=no -- $NAMES) || fail "could not read codex-router's Git status."
  if [ -n "$DIRTY" ]; then
    fail "codex-router has local changes in pinned files: $(printf '%s\n' "$DIRTY" | cut -c4- | paste -sd ' ' -)"
  fi

  CHANGED=$("$NODE" -e "$JS" changed "$COMPAT" "$ROUTER") || exit 1
  if [ "$HEAD" = "$OLD" ] && [ -z "$CHANGED" ]; then
    echo "Already pinned to $(short "$OLD")."
    exit 0
  fi

  if gitr merge-base --is-ancestor "$OLD" HEAD 2>/dev/null; then
    count=$(gitr rev-list --count "$OLD..HEAD") || fail "could not count codex-router's commits."
    noun=commits; [ "$count" != 1 ] || noun=commit
    moved="$count $noun after $(short "$OLD")"
  else
    moved="not a fast-forward from $(short "$OLD")"
  fi
  changed_list=$(printf '%s' "$CHANGED" | sed 's/ /, /g')
  echo "Pinned revision: $(short "$OLD")"
  echo "codex-router now: $(short "$HEAD") ($moved)"
  if [ -z "$CHANGED" ]; then
    echo "Pinned files: no pinned file changed."
  else
    echo "Pinned files changed: $changed_list"
  fi

  if [ -n "$CHANGED" ] && [ "$accept" != 1 ]; then
    # shellcheck disable=SC2086 # as above
    gitr diff --stat "$OLD" HEAD -- $CHANGED || true
    fail "review the diff (git -C $ROUTER diff $(short "$OLD") $(short "$HEAD") -- $CHANGED), then rerun with --accept-changed \"what you checked\"."
  fi

  EVIDENCE="$(date +%Y-%m-%d) router $(short "$HEAD") re-pin by repin-router.sh: $moved"
  if [ -z "$CHANGED" ]; then
    EVIDENCE="$EVIDENCE, no pinned file changed"
  else
    EVIDENCE="$EVIDENCE, changed $changed_list; review: $note"
  fi

  if [ "$dry" = 1 ]; then
    # Printed from memory: a dry run writes nothing and runs no engine command.
    "$NODE" -e "$JS" candidate "$COMPAT" "$CONFIG" "$ROUTER" "$HEAD" "$EVIDENCE" - || fail "could not build the new record."
    echo "Dry run: nothing changed."
    exit 0
  fi

  # The engine refuses a file under a symlinked folder (macOS /tmp and /var are symlinks), or one
  # open to others, so the candidate goes in a private folder beside the engine's, by its real path.
  umask 077
  WORK=$(mktemp -d "$(dirname "$ROOT")/.warmup-repin.XXXXXX") || fail "could not make a private folder."
  trap 'rm -rf "$WORK"' EXIT
  # A signal ends the script through exit, so the EXIT trap removes the folder in every sh.
  trap 'exit 130' INT TERM HUP
  WORK=$(cd -P "$WORK" && pwd -P) || fail "could not resolve $WORK."
  CANDIDATE=$WORK/candidate.json
  "$NODE" -e "$JS" candidate "$COMPAT" "$CONFIG" "$ROUTER" "$HEAD" "$EVIDENCE" "$CANDIDATE" \
    || fail "could not build the new record; nothing changed."

  engine status
  [ "$outcome" = ready ] || fail "the engine's status failed ($reason); nothing changed."
  case "$reply" in *" true "*) was_on=1 ;; *) was_on=0 ;; esac

  if [ "$was_on" = 1 ]; then
    engine schedule disable
    [ "$outcome" = ready ] || fail "could not pause scheduling ($reason); nothing changed."
    trap 'echo "repin-router: interrupted; this run paused scheduling. Resume it with Resume Scheduling in the app." >&2; exit 130' INT TERM HUP
  fi

  engine maintain --file "$CANDIDATE"
  if [ "$outcome" != ready ] || [ "$reason" != maintenance_applied ]; then
    # schedule enable checks compatibility too, so it would be refused while the router is unpinned.
    msg="The old pin is still in place ($reason)."
    if [ "$was_on" = 1 ]; then
      msg="$msg Scheduling was on and is now paused; after a successful repin-router, resume it with Resume Scheduling in the app or \`schedule enable\`."
    fi
    fail "$msg"
  fi

  if [ "$was_on" = 1 ]; then
    engine schedule enable
    [ "$outcome" = ready ] || fail "Re-pinned to $(short "$HEAD"), but scheduling could not be resumed ($reason). Resume it in the app."
    trap 'exit 130' INT TERM HUP
  else
    echo "Scheduling is paused; it stays paused."
  fi

  engine status
  compatibility=${reply##* }
  echo "Re-pinned to $(short "$HEAD"); compatibility: $compatibility."
  echo "Also update compat/compatibility.json in the Warm-up repository: copy $ROOT/compatibility.json there and commit it."
  [ "$compatibility" = ready ] || exit 1
}

# ---------- --self-test ----------

self_test() {
  SELF=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
  REPO_COMPAT=$(cd "$(dirname "$0")/.." && pwd -P)/compat/compatibility.json
  [ -x "$NODE" ] || fail "node not found at $NODE (set WARMUP_NODE)."
  [ -f "$REPO_COMPAT" ] || fail "$REPO_COMPAT not found."
  # Left unresolved on purpose: the script itself must resolve the candidate's folder.
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/repin-router-test.XXXXXX") || fail "cannot make a temporary folder."
  trap 'rm -rf "$tmp"' EXIT
  failures=0
  check() {  # case, then the test command
    what=$1
    shift
    if "$@"; then echo "ok $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
  }
  has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
  lacks() { ! has "$1" "$2"; }

  router=$tmp/router root=$tmp/share/codex-router-warmup stubdir=$tmp/stub
  tgit() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 /usr/bin/git -c core.hooksPath=/dev/null \
      -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -C "$router" "$@"
  }
  mkdir -p "$router" "$root"
  tgit init -q
  for name in $("$NODE" -e "$JS" names "$REPO_COMPAT"); do
    mkdir -p "$router/$(dirname "$name")"
    printf 'dummy %s\n' "$name" > "$router/$name"
  done
  printf 'unpinned\n' > "$router/README.md"
  tgit add -A
  tgit commit -q -m pinned
  pinned=$(tgit rev-parse HEAD)

  "$NODE" -e 'require("fs").writeFileSync(process.argv[2], JSON.stringify({ paths: { sourceRoot: process.argv[1] } }) + "\n");' \
    "$router" "$root/config.json"
  "$NODE" -e '
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const [repo, router, head, out] = process.argv.slice(1);
const record = JSON.parse(fs.readFileSync(repo, "utf8"));
record.reviewedRevision = head;
for (const name of Object.keys(record.sourceDigests))
  record.sourceDigests[name] = crypto.createHash("sha256").update(fs.readFileSync(path.join(router, name))).digest("hex");
fs.writeFileSync(out, JSON.stringify(record, null, 2) + "\n");' "$REPO_COMPAT" "$router" "$pinned" "$root/compatibility.json"

  # The stub engine logs each call and answers from REPIN_STUB: on (schedule on), off (paused),
  # refuse (schedule on, maintain refused). It exits non-zero on a blocked reply, like the engine.
  cat > "$root/warmup.mjs" <<'STUB'
import fs from "node:fs";
import path from "node:path";
const dir = process.env.REPIN_STUB_DIR, mode = process.env.REPIN_STUB, args = process.argv.slice(2);
const log = path.join(dir, "calls.log");
const reply = (outcome, reason, extra = {}) => {
  console.log(JSON.stringify({ protocolVersion: 1, command: args[0], outcome, reason, ...extra }));
  process.exitCode = outcome === "ready" ? 0 : 1;
};
const before = fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "";
fs.appendFileSync(log, args.join(" ") + "\n");
if (args[0] === "status") {
  const applied = before.includes("maintain --file") && mode !== "refuse";
  reply("ready", "status", { scheduleEnabled: mode !== "off", compatibility: applied ? "ready" : "blocked" });
} else if (args[0] === "schedule") reply("ready", "schedule_" + args[1] + "d");
else if (args[0] === "maintain") {
  const file = args[2], folder = path.dirname(file);
  fs.copyFileSync(file, path.join(dir, "candidate.json"));
  const resolved = path.isAbsolute(file) && fs.realpathSync(folder) === folder;
  fs.writeFileSync(path.join(dir, "folder"), resolved ? "resolved\n" : "symlinked\n");
  if (mode === "refuse") reply("blocked", "candidate_source_unreviewed");
  else reply("ready", "maintenance_applied");
} else reply("blocked", "unknown_command");
STUB

  run() {  # stub mode, then the script's arguments; sets out and rc
    stub=$1
    shift
    rm -rf "$stubdir"
    mkdir -p "$stubdir"
    : > "$stubdir/calls.log"
    out=$(env WARMUP_NODE="$NODE" WARMUP_ROOT="$root" REPIN_STUB="$stub" \
      REPIN_STUB_DIR="$stubdir" "$SELF" "$@" 2>&1) && rc=0 || rc=$?
  }
  calls() { sed 's#^maintain --file /.*/candidate\.json$#maintain --file <abs>#' "$stubdir/calls.log" | tr '\n' ';'; }
  no_calls() { [ ! -s "$stubdir/calls.log" ]; }
  candidate_ok() {  # expected revision, then text the evidence must contain
    [ -f "$stubdir/candidate.json" ] && [ "$(cat "$stubdir/folder")" = resolved ] && "$NODE" -e '
const fs = require("fs");
const [file, head, want, router] = process.argv.slice(1);
const c = JSON.parse(fs.readFileSync(file, "utf8"));
const ok = JSON.stringify(Object.keys(c)) === JSON.stringify(["schemaVersion", "config", "compatibility", "reviewEvidence"])
  && c.schemaVersion === 1 && JSON.stringify(c.config) === JSON.stringify({ paths: { sourceRoot: router } })
  && Object.keys(c.compatibility.sourceDigests).length === 13 && c.reviewEvidence === c.compatibility.reviewEvidence
  && c.compatibility.reviewedRevision === head && c.compatibility.semantics === "equivalent" && c.reviewEvidence.includes(want);
process.exit(ok ? 0 : 1);' "$stubdir/candidate.json" "$1" "$2" "$router"
  }

  # (a) At the pinned commit.
  run on
  check "a: at the pinned commit says Already pinned" eval '[ "$rc" = 0 ] && has "$out" "Already pinned to $(short "$pinned")." && no_calls'

  # (k) CODEX_ROUTER_SOURCE is ignored: the engine's config.json names codex-router's folder.
  export CODEX_ROUTER_SOURCE="$tmp/missing"
  run on
  unset CODEX_ROUTER_SOURCE
  check "k: CODEX_ROUTER_SOURCE is ignored" eval '[ "$rc" = 0 ] && has "$out" "Already pinned to $(short "$pinned")." && no_calls'

  # (l) A config.json without paths.sourceRoot stops before any engine call.
  cp "$root/config.json" "$tmp/config.json"
  printf '{"paths":{}}\n' > "$root/config.json"
  run on
  cp "$tmp/config.json" "$root/config.json"
  no_source="could not read codex-router's folder from $root/config.json."
  check "l: a config.json without the router folder stops" eval '[ "$rc" = 1 ] && has "$out" "$no_source" && no_calls'

  # (b) A commit touching only an unpinned file.
  printf 'unpinned, edited\n' > "$router/README.md"
  tgit commit -q -am "unpinned only"
  head=$(tgit rev-parse HEAD)
  run on --dry-run
  check "b: an unpinned change re-pins with no pinned file changed" eval '[ "$rc" = 0 ] && has "$out" "\"reviewedRevision\": \"$head\"" && has "$out" "no pinned file changed" && has "$out" "1 commit after $(short "$pinned")" && lacks "$out" "1 commits" && has "$out" "Dry run: nothing changed."'

  # (j) The dry run called no engine command.
  check "j: a dry run calls no engine command" no_calls

  # (g) Real run, schedule on, maintain ok.
  run on
  check "g: pause, maintain, resume, status in order" eval '[ "$rc" = 0 ] && [ "$(calls)" = "status;schedule disable;maintain --file <abs>;schedule enable;status;" ] && candidate_ok "$head" "1 commit after $(short "$pinned"), no pinned file changed" && has "$out" "Re-pinned to $(short "$head"); compatibility: ready."'

  # (h) Real run, schedule on, maintain refused.
  run refuse
  check "h: a refused maintain leaves scheduling paused" eval '[ "$rc" = 1 ] && [ "$(calls)" = "status;schedule disable;maintain --file <abs>;" ] && has "$out" "The old pin is still in place (candidate_source_unreviewed)." && has "$out" "now paused"'

  # (i) Real run, scheduling already paused.
  run off
  check "i: paused scheduling stays paused" eval '[ "$rc" = 0 ] && [ "$(calls)" = "status;maintain --file <abs>;status;" ] && has "$out" "stays paused"'

  # (c) A commit changing a pinned file.
  printf 'npm lookup\n' >> "$router/bin/install"
  tgit commit -q -am "bin/install"
  head=$(tgit rev-parse HEAD)
  run on
  check "c: a changed pinned file stops without a note" eval '[ "$rc" = 1 ] && has "$out" "Pinned files changed: bin/install" && has "$out" "--accept-changed" && no_calls'

  # (d) The same with a review note.
  digest=$("$NODE" -e 'console.log(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$router/bin/install")
  run on --accept-changed "npm lookup only"
  check "d: a review note accepts the changed file" eval '[ "$rc" = 0 ] && candidate_ok "$head" "changed bin/install; review: npm lookup only" && grep -q "\"bin/install\": \"$digest\"" "$stubdir/candidate.json"'

  # (e) A pinned file edited and not committed.
  printf 'local edit\n' >> "$router/src/paths.mjs"
  run on --accept-changed "npm lookup only"
  check "e: an uncommitted pinned edit is refused" eval '[ "$rc" = 1 ] && has "$out" "local changes in pinned files: src/paths.mjs" && no_calls'
  tgit checkout -q -- src/paths.mjs

  # (f) Bad notes and arguments are usage errors.
  run on --accept-changed ""
  check "f: an empty note is a usage error" eval '[ "$rc" = 2 ] && no_calls'
  run on --accept-changed "first line
second line"
  check "f: a two-line note is a usage error" eval '[ "$rc" = 2 ] && no_calls'
  run on --bogus
  check "f: an unknown argument is a usage error" eval '[ "$rc" = 2 ] && no_calls'

  if [ "$failures" -ne 0 ]; then
    echo "Self-test failed ($failures). Last output:"
    printf '%s\n' "$out"
    exit 1
  fi
  echo "Self-test passed: a temporary router and a stub engine stood in; no real engine or \$HOME path was used."
}

case "$mode" in
  selftest) self_test ;;
  *) repin ;;
esac
