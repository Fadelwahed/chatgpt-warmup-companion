#!/bin/sh
# Installs the Warm-up engine into ~/.local/share/codex-router-warmup.
# It only copies files and writes the install marker: it reads no account, sends no request
# and creates no LaunchAgent. Run `setup`, a manual `run` and `schedule enable` afterwards
# (see README.md, "Install the engine").
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

NODE=/opt/homebrew/opt/node@22/bin/node
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
ROUTER=${CODEX_ROUTER_SOURCE:-$HOME/.local/share/codex-router}
ROOT=$HOME/.local/share/codex-router-warmup
PLIST=$HOME/Library/LaunchAgents/local.codex-router-warmup.plist
LABEL=local.codex-router-warmup
MODULES="warmup.mjs runtime.mjs router-reader.mjs chatgpt-probe.mjs"

fail() { echo "install-engine: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "macOS only."
[ -x "$NODE" ] || fail "Homebrew node@22 not found at $NODE. Run: brew install node@22"
NODE_VERSION=$("$NODE" --version)
case "$NODE_VERSION" in
  v22.19.*|v22.[2-9][0-9].*) ;;
  *) fail "$NODE is $NODE_VERSION; the engine needs Node 22.19 or later in the 22 line. Run: brew upgrade node@22" ;;
esac
[ -d "$ROUTER/src" ] || fail "codex-router source not found at $ROUTER (set CODEX_ROUTER_SOURCE to its folder)."
for m in $MODULES; do [ -f "$REPO/$m" ] || fail "missing $m in $REPO"; done

# The engine reads codex-router's files directly, so it accepts only the reviewed source.
"$NODE" -e '
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const [compat, router] = process.argv.slice(1);
const record = JSON.parse(fs.readFileSync(compat, "utf8"));
const bad = Object.entries(record.sourceDigests).filter(([name, want]) => {
  try { return crypto.createHash("sha256").update(fs.readFileSync(path.join(router, name))).digest("hex") !== want; }
  catch { return true; }
}).map(([name]) => name);
if (bad.length) {
  console.error("codex-router differs from the reviewed revision " + record.reviewedRevision.slice(0, 8) + " in: " + bad.join(", "));
  process.exit(1);
}' "$REPO/compat/compatibility.json" "$ROUTER" \
  || fail "check out codex-router at the reviewed revision (see README.md, Requirements)."

# The engine also requires that exact Git revision with those files unmodified.
WANT_REV=$("$NODE" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).reviewedRevision)' "$REPO/compat/compatibility.json")
gitr() { /usr/bin/git --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$ROUTER" "$@"; }
HAVE_REV=$(gitr rev-parse HEAD 2>/dev/null) || fail "$ROUTER is not a Git checkout of codex-router."
[ "$HAVE_REV" = "$WANT_REV" ] || fail "codex-router is at $HAVE_REV, not the reviewed revision. Run: git -C \"$ROUTER\" checkout $WANT_REV"
NAMES=$("$NODE" -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).sourceDigests).join(" "))' "$REPO/compat/compatibility.json")
# shellcheck disable=SC2086 # the names are fixed src/ and bin/ paths without spaces
DIRTY=$(gitr status --porcelain --untracked-files=no -- $NAMES) || fail "could not read codex-router's Git status."
[ -z "$DIRTY" ] || fail "codex-router has local changes in files the engine reads: $DIRTY"

[ ! -e "$ROOT" ] || fail "$ROOT already exists. To reinstall, run the engine's \`remove\` first; to update, see README.md."
[ ! -e "$PLIST" ] || fail "$PLIST already exists. Remove the old LaunchAgent first."
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then fail "LaunchAgent $LABEL is loaded. Unload it first."; fi

# setup inspects the LaunchAgent folder even to confirm no job exists yet.
mkdir -p "$(dirname "$PLIST")"
umask 077
mkdir -p "$(dirname "$ROOT")"
# Build the install in a private sibling folder and move it into place only when complete, so
# an interrupted install never leaves a half-filled folder that blocks the next attempt.
STAGE=$(mktemp -d "$(dirname "$ROOT")/.codex-router-warmup.install.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
chmod 700 "$STAGE"
for m in $MODULES; do cp "$REPO/$m" "$STAGE/$m"; done
cp "$REPO/compat/compatibility.json" "$STAGE/compatibility.json"
cp "$REPO/docs/ENGINE-REFERENCE.md" "$STAGE/README.md"

"$NODE" -e '
const fs = require("fs"), crypto = require("crypto");
const [stage, router, home, plist] = process.argv.slice(1);
const state = home + "/.codex/codex-router";
const marker = {
  schemaVersion: 1,
  installationId: "install_" + crypto.randomBytes(12).toString("hex"),
  phase: "uninitialized",
  paths: {
    sourceRoot: router,
    stateRoot: state,
    codexHome: home + "/.codex",
    poolPath: state + "/chatgpt-account-pool.json",
    homesDir: state + "/chatgpt-accounts",
    switchPath: state + "/chatgpt-profile-switch.json",
    discoveryPath: state + "/discovery-mode.json",
  },
  plistPath: plist,
};
fs.writeFileSync(stage + "/instance.json", JSON.stringify(marker, null, 2) + "\n", { mode: 0o600, flag: "wx" });' \
  "$STAGE" "$(cd "$ROUTER" && pwd -P)" "$HOME" "$PLIST"
chmod 600 "$STAGE"/*
# mv onto a missing name is a single rename; if the folder appeared meanwhile, stop instead.
[ ! -e "$ROOT" ] || fail "$ROOT appeared during install; nothing was changed."
mv "$STAGE" "$ROOT"
trap - EXIT

echo "Engine installed in $ROOT"
echo "Next: $NODE $ROOT/warmup.mjs setup"
