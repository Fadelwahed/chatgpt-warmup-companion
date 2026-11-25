#!/bin/sh
# Books a one-time macOS wake 5 seconds after each upcoming warm-up in the engine's 7-day
# projection, so a sleeping Mac wakes in time to send it. A Mac that is shut down is not started.
# It replaces the wakes it booked before (they carry the owner name "warmup") and leaves every
# other scheduled power event alone. Rerun it weekly and after any schedule change.
#   scripts/schedule-wakes.sh            book the wakes (asks for your password once)
#   scripts/schedule-wakes.sh --dry-run  print the pmset commands; change nothing
#   scripts/schedule-wakes.sh --cancel   remove the wakes this script booked
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

NODE=${WARMUP_NODE:-/opt/homebrew/opt/node@22/bin/node}
ENGINE=${WARMUP_ROOT:-$HOME/.local/share/codex-router-warmup}/warmup.mjs
OWNER=warmup
WAKE_AFTER_MS=5000

fail() { echo "schedule-wakes: $*" >&2; exit 1; }

mode=book dry=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --cancel) mode=cancel ;;
    *) fail "unknown argument: $arg (use --dry-run or --cancel)" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || fail "macOS only."
# The engine must never run as root: it would leave root-owned files in its folder.
[ "$(id -u)" != 0 ] || fail "run it as yourself, not with sudo; it asks for your password when it needs it."
[ -x "$NODE" ] || fail "node not found at $NODE (set WARMUP_NODE)."
[ -f "$ENGINE" ] || fail "engine not found at $ENGINE (set WARMUP_ROOT)."

# Wakes this script booked earlier, as pmset accepts them back (MM/dd/yy HH:mm:ss).
booked=$(pmset -g sched | sed -n "s#^ *\[[0-9]*\] *wake at \([0-9][0-9]/[0-9][0-9]/\)[0-9][0-9]\([0-9][0-9] [0-9:]*\) by '$OWNER'\$#\1\2#p")

planned=
if [ "$mode" = book ]; then
  projection=$("$NODE" "$ENGINE" schedule inspect) || fail "the engine's schedule inspect failed."
  planned=$(printf '%s' "$projection" | "$NODE" -e '
let text = "";
process.stdin.on("data", chunk => text += chunk).on("end", () => {
  const out = JSON.parse(text);
  if (out.outcome !== "ready" || out.reason !== "schedule_projection" || !Array.isArray(out.days)) {
    console.error(`schedule-wakes: unexpected engine output: ${out.outcome}/${out.reason}`); process.exit(1);
  }
  if (out.scheduleEnabled !== true) { console.error("schedule-wakes: the schedule is paused; no wakes booked."); return; }
  const pad = n => String(n).padStart(2, "0"), soon = Date.now() + 60000;
  for (const day of out.days) for (const a of day.admissions ?? []) {
    if (a.state !== "upcoming" || !Number.isFinite(a.at) || a.at < soon) continue;
    const d = new Date(a.at + Number(process.argv[1]));  // the Mac local time, which pmset uses
    console.log(`${pad(d.getMonth() + 1)}/${pad(d.getDate())}/${pad(d.getFullYear() % 100)} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`);
  }
});' "$WAKE_AFTER_MS") || fail "could not read the engine's projection."
fi

run() {
  if [ "$dry" = 1 ]; then printf 'sudo'; printf ' "%s"' "$@"; echo; else sudo "$@"; fi
}

[ "$dry" = 1 ] || [ -z "$booked$planned" ] || sudo -v || fail "sudo was refused; nothing changed."

old_ifs=$IFS
IFS='
'
for when in $booked; do
  run /usr/bin/pmset schedule cancel wake "$when" "$OWNER" || echo "schedule-wakes: could not cancel the wake at $when" >&2
done
count=0
for when in $planned; do
  run /usr/bin/pmset schedule wake "$when" "$OWNER" || fail "pmset refused the wake at $when."
  count=$((count + 1))
done
IFS=$old_ifs

if [ "$dry" = 1 ]; then echo "Dry run: nothing changed."; exit 0; fi
echo "Removed $(printf '%s' "$booked" | grep -c . || true) earlier wake(s); booked $count."
pmset -g sched | grep "by '$OWNER'" || true
