#!/bin/sh
# Lid-closed wake experiment (work order 136, Part 1). Books four one-time macOS wakes with the
# owner name "waketest", 4 minutes apart, and starts one detached watcher that notices each wake by a
# jump in the wall clock. A wake at booked wake N's time takes the assertion for mode N (1 none,
# 2 caffeinate -i, 3 caffeinate -u, 4 caffeinate -s -i); a wake at no booked time takes none. For up
# to 150 s it logs every 2 s whether a name lookup of chatgpt.com returns an address, from the system
# resolver (may be cached) and from the DNS server directly, and whether a default route exists.
# No request is sent to ChatGPT.
# It never touches the engine, its folder or the "warmup" wakes.
#   scripts/wake-test.sh                  book the wakes, start the watcher (asks for your password once)
#   scripts/wake-test.sh --allow-display  the same, even with an external display attached
#   scripts/wake-test.sh --quick          one wake 2 minutes out, mode 5 (caffeinate -u -s -i); about 5 minutes
#   scripts/wake-test.sh --report         read the newest run against pmset -g log; cancel leftover wakes
#   scripts/wake-test.sh --dry-run        print the pmset commands and the plan; change nothing
#   scripts/wake-test.sh --cancel         cancel the booked test wakes and stop a running watcher
#   scripts/wake-test.sh --self-test      check wake detection, mode choice and probes with stubs
# Logs: ~/Library/Logs/warmup-wake-test/<yyyyMMdd-HHmm>-<battery|ac>/ (plan.txt, watch.log)
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

OWNER=waketest
WARMUP_OWNER=warmup
LOOKUP_NAME=chatgpt.com
LOG_ROOT=$HOME/Library/Logs/warmup-wake-test
WAKE_COUNT=4
WAKE_STEP_S=240          # 4 minutes between test wakes
WAKE_SECOND=5            # each wake at second :05, as schedule-wakes.sh books them
WARMUP_GUARD_S=1500      # refuse when a warmup wake is booked within 25 minutes
GAP_S=15                 # a wall-clock jump of more than this between two loops is a wake
WINDOW_S=150             # seconds logged after each wake
TICK_S=2                 # one log line every 2 seconds
LOOKUP_TIMEOUT_S=8       # a lookup still running after this is killed and logged as a timeout
DNS_WAIT_S=3             # host -W: seconds to wait for the DNS server's answer
MATCH_BEFORE_S=10        # a detected wake belongs to a booked wake from 10 s before
MATCH_AFTER_S=120        # to 120 s after its time; otherwise it is unbooked (mode 0)
CACHE_BIN=/usr/bin/dscacheutil
DNS_BIN=/usr/bin/host
RUN_LIMIT_S=1500         # the watcher stops 25 minutes after it starts
LID_CLOSED_S=1200        # "leave it closed until" T+20 minutes
QUICK_MODE=5             # --quick: the one booked wake takes every hold at once
QUICK_LEAD_S=120         # --quick: one wake 2 minutes out
QUICK_RUN_LIMIT_S=480    # --quick: the watcher stops 8 minutes after it starts
QUICK_LID_CLOSED_S=300   # --quick: "leave it closed until" T+5 minutes

fail() { echo "wake-test: $*" >&2; exit 1; }

# Switches to the quick plan: one booked wake, mode 5, shorter limits.
use_quick() {
  quick=1 WAKE_COUNT=1 WAKE_STEP_S=$QUICK_LEAD_S RUN_LIMIT_S=$QUICK_RUN_LIMIT_S LID_CLOSED_S=$QUICK_LID_CLOSED_S
}

# The mode booked wake N takes: N in the four-wake run, mode 5 in the quick run; 0 stays 0.
wake_mode() {
  if [ "$quick" = 1 ] && [ "$1" != 0 ]; then echo "$QUICK_MODE"; else echo "$1"; fi
}

# A run folder's plan.txt marks a quick run with a "quick=1" line.
plan_is_quick() { grep -qx 'quick=1' "$1" 2>/dev/null; }

mode=run dry=0 allow_display=0 watch_dir= quick=0 quick_flag=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --allow-display) allow_display=1 ;;
    --quick) quick_flag=1 ;;
    --report) mode=report ;;
    --cancel) mode=cancel ;;
    --self-test) mode=selftest ;;
    --watch) [ $# -ge 2 ] || fail "--watch needs a run folder."; mode=watch; watch_dir=$2; shift ;;
    *) fail "unknown argument: $1 (use --dry-run, --allow-display, --quick, --report, --cancel or --self-test)" ;;
  esac
  shift
done
# Only booking reads the flag; the watcher and --report learn a quick run from plan.txt.
if [ "$mode" = run ] && [ "$quick_flag" = 1 ]; then use_quick; fi

[ "$(uname -s)" = Darwin ] || fail "macOS only."
[ "$(id -u)" != 0 ] || fail "run it as yourself, not with sudo; it asks for your password when it needs it."

self_dir=$(cd "$(dirname "$0")" && pwd) || fail "cannot find the script's folder."
SELF=$self_dir/$(basename "$0")

# ---------- shared helpers ----------

stamp() { date -r "$1" '+%Y-%m-%d %H:%M:%S'; }   # epoch -> pmset -g log time
pmset_when() { date -r "$1" '+%m/%d/%y %H:%M:%S'; }  # epoch -> the form pmset schedule accepts

mode_name() {
  case "$1" in
    2) echo "caffeinate -i -t $WINDOW_S" ;;
    3) echo "caffeinate -u -t $WINDOW_S" ;;
    4) echo "caffeinate -s -i -t $WINDOW_S" ;;
    5) echo "caffeinate -u -s -i -t $WINDOW_S" ;;
    0) echo "none unbooked" ;;
    *) echo "none" ;;
  esac
}

power_source() {
  if pmset -g batt | head -n 1 | grep -q "'Battery Power'"; then echo battery; else echo ac; fi
}

# Test wakes booked now, as pmset accepts them back (MM/dd/yy HH:mm:ss).
booked_test_wakes() {
  pmset -g sched | sed -n "s#^ *\[[0-9]*\] *wake at \([0-9][0-9]/[0-9][0-9]/\)[0-9][0-9]\([0-9][0-9] [0-9:]*\) by '$OWNER'\$#\1\2#p"
}

# Warm-up wakes booked within the guard window, as pmset -g sched prints them (MM/dd/yyyy).
warmup_wakes_soon() {
  now_s=$1
  pmset -g sched | sed -n "s#^ *\[[0-9]*\] *wake[a-z]* at \([0-9/]* [0-9:]*\) by '$WARMUP_OWNER'\$#\1#p" |
    while IFS= read -r when; do
      at=$(date -j -f '%m/%d/%Y %H:%M:%S' "$when" +%s 2>/dev/null) || continue
      if [ "$at" -ge "$now_s" ] && [ "$at" -le $((now_s + WARMUP_GUARD_S)) ]; then echo "$when"; fi
    done
}

# Displays other than the built-in one, from system_profiler SPDisplaysDataType.
external_display_count() {
  system_profiler SPDisplaysDataType 2>/dev/null | awk '
    function indent(s) { return match(s, /[^ ]/) - 1 }
    function flush() { if (name != "" && !internal) n++; name = ""; internal = 0 }
    /^[ ]*$/ { next }
    /^[ ]*Displays:[ ]*$/ { flush(); in_d = 1; base = indent($0); next }
    in_d && indent($0) <= base { flush(); in_d = 0; next }
    in_d && indent($0) == base + 2 && /:[ ]*$/ { flush(); name = $0; next }
    in_d && name != "" { l = tolower($0); if (l ~ /connection type: internal/ || l ~ /built-in/) internal = 1 }
    END { flush(); print n + 0 }'
}

# Prints (dry run) or runs one pmset schedule command through sudo.
pmset_schedule() {
  if [ "$dry" = 1 ] && [ "$1" = add ]; then
    printf '/usr/bin/sudo /usr/bin/pmset schedule wake "%s" %s\n' "$2" "$OWNER"
  elif [ "$dry" = 1 ]; then
    printf '/usr/bin/sudo /usr/bin/pmset schedule cancel wake "%s" %s\n' "$2" "$OWNER"
  elif [ "$1" = add ]; then
    /usr/bin/sudo /usr/bin/pmset schedule wake "$2" "$OWNER"
  else
    /usr/bin/sudo /usr/bin/pmset schedule cancel wake "$2" "$OWNER"
  fi
}

cancel_test_wakes() {
  wakes=$(booked_test_wakes)
  [ -n "$wakes" ] || { echo "No $OWNER wakes are booked."; return 0; }
  [ "$dry" = 1 ] || /usr/bin/sudo -v || fail "sudo was refused; nothing changed."
  old_ifs=$IFS
  IFS='
'
  for when in $wakes; do
    pmset_schedule cancel "$when" || echo "wake-test: could not cancel the wake at $when" >&2
  done
  IFS=$old_ifs
  if [ "$dry" = 1 ]; then echo "Dry run: nothing cancelled."; else echo "Cancelled the $OWNER wakes still booked."; fi
}

# A PID from a watch.pid file counts only while it is this script's watcher.
is_watcher() {
  [ -n "$1" ] || return 1
  case "$(ps -p "$1" -o command= 2>/dev/null || true)" in
    *wake-test.sh\ --watch*) return 0 ;;
    *) return 1 ;;
  esac
}

running_watcher() {
  for pid_file in "$LOG_ROOT"/*/watch.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if is_watcher "$pid"; then echo "$pid $pid_file"; fi
  done
}

# Kills a process this script started, by PID, only while its command name still matches.
kill_own() {
  [ -n "$1" ] || return 0
  name=$(ps -p "$1" -o comm= 2>/dev/null || true)
  case "$name" in
    *"$2") kill "$1" 2>/dev/null || true ;;
  esac
}

# ---------- the watcher (also driven by --self-test with a fake clock) ----------

selftest=0 probes=1 FAKE_CLOCK= NOW=0 DIR= LOG= POWER= BOOKED=

reset_watch_state() {
  wake=0 wake_at=0 win_end=0 next_tick=0 last_t=0 cur_mode=0 cur_booked=0 last_done=0 used=' '
  cache_state=pending dns_state=pending caf_pid=
}

read_clock() {
  if [ "$selftest" = 1 ]; then
    # shellcheck disable=SC2086
    set -- $FAKE_CLOCK
    [ $# -gt 0 ] || return 1
    NOW=$1
    shift
    FAKE_CLOCK=$*
  else
    NOW=$(date +%s)
  fi
}

pause() { [ "$selftest" = 1 ] || sleep 1; }

log_line() { printf '%s %s\n' "$(date -r "$NOW" +%H:%M:%S)" "$*" >> "$LOG"; }

# The booked wake (1-4; 1 in a quick run) whose time is from MATCH_BEFORE_S before to MATCH_AFTER_S after the
# epoch and that no earlier wake matched; 0 when none does. BOOKED is "N:epoch N:epoch ...".
booked_wake() {
  for booking in $BOOKED; do
    bn=${booking%%:*} bat=${booking#*:}
    case "$used" in *" $bn "*) continue ;; esac
    if [ "$1" -ge $((bat - MATCH_BEFORE_S)) ] && [ "$1" -le $((bat + MATCH_AFTER_S)) ]; then
      echo "$bn"
      return 0
    fi
  done
  echo 0
}

start_assertion() {
  [ "$1" -ge 2 ] || return 0
  if [ "$selftest" = 1 ]; then
    log_line "ASSERT n=$wake mode=$1 self-test, not run: /usr/bin/$(mode_name "$1")"
    return 0
  fi
  case "$1" in
    2) /usr/bin/caffeinate -i -t "$WINDOW_S" </dev/null >/dev/null 2>&1 & ;;
    3) /usr/bin/caffeinate -u -t "$WINDOW_S" </dev/null >/dev/null 2>&1 & ;;
    5) /usr/bin/caffeinate -u -s -i -t "$WINDOW_S" </dev/null >/dev/null 2>&1 & ;;
    *) /usr/bin/caffeinate -s -i -t "$WINDOW_S" </dev/null >/dev/null 2>&1 & ;;
  esac
  caf_pid=$!
  log_line "ASSERT n=$wake mode=$1 pid=$caf_pid /usr/bin/$(mode_name "$1")"
}

stop_assertion() {
  kill_own "$caf_pid" caffeinate
  caf_pid=
}

# Two name lookups, each in the background so a slow resolver never stalls the loop past the gap
# limit: "cache" asks the system resolver (dscacheutil, may answer from its cache), "dns" asks the
# configured DNS server directly (host). Neither connects to ChatGPT. State lives in $DIR/<probe>.*.
probe_bin() { if [ "$1" = cache ]; then echo "$CACHE_BIN"; else echo "$DNS_BIN"; fi; }

probe_clear() { rm -f "$DIR/$1.sub" "$DIR/$1.pid" "$DIR/$1.out" "$DIR/$1.start" "$DIR/$1.done" "$DIR/$1.done.tmp"; }

stop_probe() {
  if [ -f "$DIR/$1.sub" ]; then kill_own "$(cat "$DIR/$1.sub" 2>/dev/null || true)" sh; fi
  if [ -f "$DIR/$1.pid" ]; then kill_own "$(cat "$DIR/$1.pid" 2>/dev/null || true)" "$(basename "$(probe_bin "$1")")"; fi
  probe_clear "$1"
}

start_probe() {
  [ "$probes" = 1 ] || return 0
  [ ! -f "$DIR/$1.sub" ] || return 0
  bin=$(probe_bin "$1")
  [ -x "$bin" ] || return 0
  probe_clear "$1"
  echo "$NOW" > "$DIR/$1.start"
  (
    if [ "$1" = cache ]; then
      "$bin" -q host -a name "$LOOKUP_NAME" > "$DIR/$1.out" 2>&1 &
    else
      # A records only: with no type, host also asks for AAAA and MX and can outlast the timeout.
      "$bin" -t A -W "$DNS_WAIT_S" "$LOOKUP_NAME" > "$DIR/$1.out" 2>&1 &
    fi
    echo $! > "$DIR/$1.pid"
    if wait $!; then rc=0; else rc=$?; fi
    echo "$(date +%s) $rc" > "$DIR/$1.done.tmp"
    mv "$DIR/$1.done.tmp" "$DIR/$1.done"
  ) </dev/null >/dev/null 2>&1 &
  echo $! > "$DIR/$1.sub"
}

# Prints the probe's new state (ok@+N, fail@+N, timeout@+N, unavailable), or nothing while it runs.
collect_probe() {
  [ "$probes" = 1 ] || { echo stub; return 0; }
  [ -x "$(probe_bin "$1")" ] || { echo unavailable; return 0; }
  [ -f "$DIR/$1.sub" ] || return 0
  if [ -s "$DIR/$1.done" ]; then
    read -r done_at rc < "$DIR/$1.done"
    result=fail
    if [ "$1" = cache ]; then
      if grep -q '_address:' "$DIR/$1.out" 2>/dev/null; then result=ok; fi
    elif grep -q 'has address' "$DIR/$1.out" 2>/dev/null; then
      result=ok
    fi
    probe_clear "$1"
    echo "$result@+$((done_at - wake_at))"
  elif [ $((NOW - $(cat "$DIR/$1.start" 2>/dev/null || echo "$NOW"))) -ge "$LOOKUP_TIMEOUT_S" ]; then
    stop_probe "$1"
    echo "timeout@+$((NOW - wake_at))"
  fi
}

tick() {
  last_t=$((NOW - wake_at))
  s=$(collect_probe cache)
  [ -z "$s" ] || cache_state=$s
  s=$(collect_probe dns)
  [ -z "$s" ] || dns_state=$s
  route=stub
  if [ "$selftest" = 0 ]; then
    if /sbin/route -n get default >/dev/null 2>&1; then route=yes; else route=no; fi
  fi
  log_line "TICK n=$wake t=+$last_t cache=$cache_state dns=$dns_state route=$route"
  start_probe cache
  start_probe dns
}

close_window() {
  [ "$win_end" != 0 ] || return 0
  stop_probe cache
  stop_probe dns
  stop_assertion
  log_line "END n=$wake mode=$cur_mode last_t=+$last_t reason=$1"
  win_end=0
  if [ "$cur_booked" = "$WAKE_COUNT" ]; then last_done=1; fi
}

watch_loop() {
  read_clock || return 0
  start=$NOW prev=$NOW deadline=$((NOW + RUN_LIMIT_S))
  log_line "START epoch=$start pid=$$ power=$POWER deadline=$deadline booked=$(echo $BOOKED | tr ' ' ',')"
  while read_clock; do
    gap=$((NOW - prev))
    prev=$NOW
    if [ "$gap" -gt "$GAP_S" ]; then
      close_window slept
      if [ "$last_done" = 1 ]; then log_line "EXIT reason=after-booked-wake-$WAKE_COUNT"; return 0; fi
      if [ "$NOW" -ge "$deadline" ]; then log_line "EXIT reason=time-limit"; return 0; fi
      cur_booked=$(booked_wake "$NOW")
      [ "$cur_booked" = 0 ] || used="$used$cur_booked "
      cur_mode=$(wake_mode "$cur_booked")
      wake=$((wake + 1)) wake_at=$NOW win_end=$((NOW + WINDOW_S)) next_tick=$NOW last_t=0
      cache_state=pending dns_state=pending
      log_line "WAKE n=$wake epoch=$NOW gap=$gap mode=$cur_mode assertion=$(mode_name "$cur_mode")"
      start_assertion "$cur_mode"
    fi
    if [ "$win_end" != 0 ] && [ "$NOW" -ge "$win_end" ]; then
      close_window window
      if [ "$last_done" = 1 ]; then log_line "EXIT reason=after-booked-wake-$WAKE_COUNT"; return 0; fi
    elif [ "$win_end" != 0 ] && [ "$NOW" -ge "$next_tick" ]; then
      tick
      next_tick=$((NOW + TICK_S))
    fi
    if [ "$NOW" -ge "$deadline" ]; then
      close_window time-limit
      log_line "EXIT reason=time-limit"
      return 0
    fi
    pause
  done
  close_window clock-ended
  log_line "EXIT reason=clock-ended"
}

run_watcher() {
  DIR=$watch_dir LOG=$watch_dir/watch.log
  [ -d "$DIR" ] || fail "no run folder at $DIR."
  [ -f "$DIR/plan.txt" ] || fail "no plan.txt in $DIR."
  if plan_is_quick "$DIR/plan.txt"; then use_quick; fi
  BOOKED=$(awk '$1 ~ /^[0-9]+$/ { printf "%s:%s ", $1, $2 }' "$DIR/plan.txt")
  [ -n "$BOOKED" ] || fail "plan.txt in $DIR lists no wakes."
  echo $$ > "$DIR/watch.pid"
  POWER=$(power_source)
  reset_watch_state
  trap 'stop_probe cache; stop_probe dns; stop_assertion; [ "$(cat "$DIR/watch.pid" 2>/dev/null || true)" != $$ ] || rm -f "$DIR/watch.pid"' EXIT
  trap 'NOW=$(date +%s); close_window stopped; log_line "EXIT reason=stopped"; exit 0' TERM INT
  watch_loop
}

# ---------- --self-test ----------

fake_range() {  # first last step
  i=$1 out=$1
  while [ "$i" -lt "$2" ]; do i=$((i + $3)); out="$out $i"; done
  printf '%s' "$out"
}

# Writes an executable stub that stands in for dscacheutil or host in the probe test.
stub() {  # path, then the shell body
  printf '#!/bin/sh\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

self_test() {
  selftest=1 probes=0 POWER=self-test
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/wake-test.XXXXXX") || fail "cannot make a temporary folder."
  trap 'rm -rf "$tmp"' EXIT
  DIR=$tmp failures=0
  check() {  # description, then the test command
    what=$1
    shift
    if "$@"; then echo "pass: $what"; else echo "FAIL: $what"; failures=$((failures + 1)); fi
  }
  count_in() { c=$(grep -c "$2" "$1" || true); [ "$c" -eq "$3" ]; }
  # Booked wakes at second :05 of fake minutes; detected wakes land a few seconds later.
  BOOKED="1:1060 2:1300 3:1540 4:1780"

  # 1. A steady clock, with one step of exactly 15 s (not more than 15): no wake.
  LOG=$tmp/steady.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1010 1) 1025 $(fake_range 1026 1040 1)"
  watch_loop
  check "no wake without a gap of more than ${GAP_S} s" count_in "$LOG" ' WAKE ' 0

  # 2. The order's case: a 60 s gap at booked wake 1 is wake 1, mode 1 (no assertion).
  LOG=$tmp/gap.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1005 1) $(fake_range 1065 1075 1)"
  watch_loop
  check "exactly one wake" count_in "$LOG" ' WAKE ' 1
  check "a 60 s gap is wake 1 with mode 1" count_in "$LOG" ' WAKE n=1 epoch=1065 gap=60 mode=1 assertion=none$' 1
  check "mode 1 takes no assertion" count_in "$LOG" ' ASSERT ' 0
  check "wake 1 is logged every ${TICK_S} s from its first second" count_in "$LOG" ' TICK n=1 t=+0 ' 1

  # 3. Four booked wakes: modes 1-4 in order, a window cut short by sleep, exit after wake 4's window.
  LOG=$tmp/four.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1004 1) $(fake_range 1065 1225 10) $(fake_range 1300 1320 10)"
  FAKE_CLOCK="$FAKE_CLOCK $(fake_range 1540 1700 10) $(fake_range 1780 1940 10) 2000"
  watch_loop
  check "four wakes" count_in "$LOG" ' WAKE ' 4
  n=1
  while [ "$n" -le 4 ]; do
    check "wake $n uses mode $n ($(mode_name "$n"))" count_in "$LOG" " WAKE n=$n .* mode=$n assertion=$(mode_name "$n")\$" 1
    n=$((n + 1))
  done
  check "modes 2-4 would take caffeinate (not run in the self-test)" count_in "$LOG" ' ASSERT n=[234] mode=[234] self-test, not run: /usr/bin/caffeinate ' 3
  check "wake 1 ends at its 150 s window" count_in "$LOG" ' END n=1 mode=1 .* reason=window$' 1
  check "wake 2 ends when the clock jumps again (slept)" count_in "$LOG" ' END n=2 mode=2 last_t=+20 reason=slept$' 1
  check "the watcher stops after booked wake 4's window" count_in "$LOG" ' EXIT reason=after-booked-wake-4$' 1

  # 4. An unbooked wake between booked wakes 1 and 2 takes no assertion and leaves wake 2 on mode 2.
  LOG=$tmp/unbooked.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1004 1) $(fake_range 1065 1225 10) $(fake_range 1250 1270 10) $(fake_range 1300 1320 10)"
  watch_loop
  check "the unbooked wake logs mode 0" count_in "$LOG" ' WAKE n=2 epoch=1250 gap=25 mode=0 assertion=none unbooked$' 1
  check "the unbooked wake takes no assertion" count_in "$LOG" ' ASSERT n=2 ' 0
  check "booked wake 2 after it still uses mode 2" count_in "$LOG" ' WAKE n=3 epoch=1300 .* mode=2 assertion=caffeinate -i -t 150$' 1

  # 5. Booked wake 2 is missed (no gap): later wakes keep their own modes.
  LOG=$tmp/missed.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1004 1) $(fake_range 1065 1460 10) $(fake_range 1540 1700 10) $(fake_range 1780 1940 10) 2000"
  watch_loop
  check "three wakes when booked wake 2 is missed" count_in "$LOG" ' WAKE ' 3
  check "booked wake 3 uses mode 3" count_in "$LOG" ' WAKE n=2 epoch=1540 .* mode=3 assertion=caffeinate -u -t 150$' 1
  check "booked wake 4 uses mode 4" count_in "$LOG" ' WAKE n=3 epoch=1780 .* mode=4 assertion=caffeinate -s -i -t 150$' 1
  check "no wake uses mode 2" count_in "$LOG" ' WAKE .* mode=2 ' 0
  check "the watcher still stops after booked wake 4's window" count_in "$LOG" ' EXIT reason=after-booked-wake-4$' 1

  # 6. The quick plan (as the watcher reads it from a plan.txt with quick=1): one booked wake, mode 5.
  printf '# wake-test plan\nquick=1\nstart 1000 x\n1 1060 x mode=5\n' > "$tmp/plan.txt"
  check "a plan.txt with quick=1 is read as a quick run" plan_is_quick "$tmp/plan.txt"
  use_quick
  BOOKED="1:1060"
  LOG=$tmp/quick.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1005 1) $(fake_range 1065 1225 10) 1300"
  watch_loop
  check "quick: the watcher stops 8 minutes after it starts" count_in "$LOG" ' START epoch=1000 .* deadline=1480 ' 1
  check "quick: exactly one wake" count_in "$LOG" ' WAKE ' 1
  check "quick: a 60 s gap at the booked time is wake 1 with mode 5" count_in "$LOG" ' WAKE n=1 epoch=1065 gap=60 mode=5 assertion=caffeinate -u -s -i -t 150$' 1
  check "quick: mode 5 would take caffeinate -u -s -i (not run)" count_in "$LOG" ' ASSERT n=1 mode=5 self-test, not run: /usr/bin/caffeinate -u -s -i -t 150$' 1
  check "quick: wake 1 ends at its 150 s window" count_in "$LOG" ' END n=1 mode=5 .* reason=window$' 1
  check "quick: the watcher stops after the one booked wake's window" count_in "$LOG" ' EXIT reason=after-booked-wake-1$' 1

  LOG=$tmp/quick-unbooked.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1004 1) $(fake_range 1030 1040 10) $(fake_range 1065 1225 10)"
  watch_loop
  check "quick: a wake at no booked time is mode 0" count_in "$LOG" ' WAKE n=1 epoch=1030 gap=26 mode=0 assertion=none unbooked$' 1
  check "quick: the unbooked wake takes no assertion" count_in "$LOG" ' ASSERT n=1 ' 0
  check "quick: the booked wake after it still uses mode 5" count_in "$LOG" ' WAKE n=2 epoch=1065 .* mode=5 ' 1

  LOG=$tmp/quick-limit.log
  reset_watch_state
  FAKE_CLOCK="$(fake_range 1000 1600 10)"
  watch_loop
  check "quick: with no wake the watcher stops at its 8-minute limit" count_in "$LOG" ' EXIT reason=time-limit$' 1
  check "quick: no wake without a gap" count_in "$LOG" ' WAKE ' 0

  # 7. The two probes, run in the background with stubs in place of dscacheutil and host
  #    (no real lookup). The clock is real here; NOW is moved by hand for the timeout.
  probes=1 wake_at=$(date +%s)
  mkdir -p "$tmp/bin"
  CACHE_BIN=$tmp/bin/dscacheutil DNS_BIN=$tmp/bin/host
  stub "$CACHE_BIN" 'echo "ip_address: 192.0.2.1"'
  stub "$DNS_BIN" 'echo "chatgpt.com has address 192.0.2.1"'
  probe_until_done() {  # probe -> its state once it has finished (at most about 5 s)
    k=0 got=
    while [ "$k" -lt 25 ] && [ -z "$got" ]; do sleep 0.2; NOW=$(date +%s); got=$(collect_probe "$1"); k=$((k + 1)); done
    echo "$got"
  }
  NOW=$(date +%s)
  start_probe cache
  start_probe dns
  check "cache probe with an address reads ok" match "$(probe_until_done cache)" 'ok@+*'
  check "dns probe with an address reads ok" match "$(probe_until_done dns)" 'ok@+*'
  stub "$DNS_BIN" 'echo "Host chatgpt.com not found: 2(SERVFAIL)"; exit 1'
  NOW=$(date +%s)
  start_probe dns
  check "dns probe without an address reads fail" match "$(probe_until_done dns)" 'fail@+*'
  stub "$DNS_BIN" 'exec /bin/sleep 2'
  NOW=$(date +%s)
  start_probe dns
  NOW=$((NOW + LOOKUP_TIMEOUT_S))
  check "a dns probe still running after ${LOOKUP_TIMEOUT_S} s reads timeout" match "$(collect_probe dns)" 'timeout@+*'
  check "a timed-out probe leaves no state behind" no_files "$tmp"/dns.*
  DNS_BIN=$tmp/bin/missing
  check "a missing host reads unavailable" match "$(collect_probe dns)" unavailable

  if [ "$failures" -ne 0 ]; then
    echo "Self-test failed ($failures). Log of the 60 s gap case:"
    cat "$tmp/gap.log"
    exit 1
  fi
  echo "Self-test passed: no caffeinate, pmset, route or real lookup was run (stubs stood in for dscacheutil and host)."
}

match() { case "$1" in $2) return 0 ;; *) return 1 ;; esac; }
no_files() { for f in "$@"; do [ ! -e "$f" ] || return 1; done; }

# ---------- --report ----------

newest_run() {
  ls -1 "$LOG_ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{4}-(battery|ac)$' | sort | tail -n 1 || true
}

# pmset -g log lines of type Sleep, Wake or DarkWake with lo <= time <= hi.
log_lines() {  # text lo hi
  printf '%s\n' "$1" | awk -v lo="$2" -v hi="$3" '
    { ts = substr($0, 1, 19); split(substr($0, 27), f, "\t"); t = f[1]; sub(/ +$/, "", t) }
    (t == "Sleep" || t == "Wake" || t == "DarkWake") && ts >= lo && ts <= hi { print t "\t" $0 }'
}

# The value of key=value on a watch.log line (to the end of the line for "assertion").
field() { printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

# Watcher wakes that matched no booked wake (mode 0, for example a maintenance dark wake).
unbooked_wakes() {  # watch.log
  grep ' WAKE .* mode=0 ' "$1" 2>/dev/null | while IFS= read -r l; do
    echo "  watcher wake $(field "$l" n) at $(date -r "$(field "$l" epoch)" +%H:%M:%S) (gap $(field "$l" gap) s): no booked time, no assertion"
  done
}

# The first second at which a probe (cache or dns) succeeded during watcher wake n, or nothing.
first_ok() {  # watch.log, wake n, probe
  awk -v n="$2" -v p="$3=ok@+" '$2 == "TICK" && $3 == "n=" n {
      for (i = 5; i <= NF; i++) if (index($i, p) == 1) { v = substr($i, length(p) + 1) + 0; if (best == "" || v < best) best = v }
    } END { print best }' "$1"
}

report() {
  run_name=$(newest_run)
  [ -n "$run_name" ] || fail "no run found in $LOG_ROOT."
  dir=$LOG_ROOT/$run_name
  [ -f "$dir/plan.txt" ] || fail "no plan.txt in $dir."
  if plan_is_quick "$dir/plan.txt"; then use_quick; fi
  watch_log=$dir/watch.log
  [ -f "$watch_log" ] || watch_log=/dev/null
  start=$(awk '$1 == "start" { print $2 }' "$dir/plan.txt")
  [ -n "$start" ] || fail "plan.txt has no start time."
  last=$(awk '$1 ~ /^[0-9]+$/ { e = $2 } END { print e }' "$dir/plan.txt")
  d1=$(date -r "$start" +%Y-%m-%d) d2=$(date -r $((last + 180)) +%Y-%m-%d)
  plog=$(pmset -g log | grep -E "^($d1|$d2) " || true)

  echo "Run $run_name ($dir)"
  if running_watcher | grep -q .; then echo "Note: the watcher is still running; it stops by itself, or use --cancel."; fi
  if grep -q ' TICK .* dns=unavailable ' "$watch_log" 2>/dev/null; then
    echo "Note: $DNS_BIN was missing, so the direct DNS lookup did not run; only the cached lookup was logged."
  fi
  table=
  prev=$(stamp "$start")
  for row in $(awk '$1 ~ /^[0-9]+$/ { print $1 ":" $2 }' "$dir/plan.txt"); do
    n=${row%%:*} at=${row#*:}
    m=$(wake_mode "$n")
    at_s=$(stamp "$at")
    echo
    echo "Wake $n, booked for $at_s:"
    lines=$(log_lines "$plog" "$(stamp $((at - 120)))" "$(stamp $((at + 180)))")
    if [ -n "$lines" ]; then printf '%s\n' "$lines" | cut -f 2- | sed 's/^/  | /'; else echo "  (no Sleep, Wake or DarkWake line from 2 minutes before to 3 minutes after)"; fi

    slept=$(log_lines "$plog" "$prev" "$at_s" | awk -F '\t' -v p="$prev" '$1 == "Sleep" && substr($2, 1, 19) > p { s = substr($2, 12, 8) } END { print s }')
    prev=$at_s
    first=$(log_lines "$plog" "$(stamp $((at - 5)))" "$(stamp $((at + 60)))" | awk -F '\t' '$1 != "Sleep" { print $1 " " substr($2, 12, 8); exit }')
    case "$first" in
      DarkWake*)
        full=$(log_lines "$plog" "$(stamp $((at - 5)))" "$(stamp $((at + 180)))" | awk -F '\t' '$1 == "DarkWake" { dark = 1 } dark && $1 == "Sleep" { exit } $1 == "Wake" { print substr($2, 12, 8); exit }')
        kind=dark
        [ -z "$full" ] || kind="dark, then full at $full" ;;
      Wake*) kind=full ;;
      *) kind="no wake line" ;;
    esac

    # The watcher logs the booked wake it matched as the mode (wake N = mode N; mode 5 in a quick run).
    wline=$(awk -v m="mode=$m" '$2 == "WAKE" && $6 == m { print; exit }' "$watch_log")
    if [ -n "$wline" ]; then
      wn=$(field "$wline" n)
      wassert=$(printf '%s\n' "$wline" | sed -n 's/.* assertion=//p')
      awake=$(awk -v n="$wn" '$2 == "TICK" && $3 == "n=" n { t = substr($4, 4) + 0 } END { print t + 0 }' "$watch_log")
      reason=$(awk -v n="$wn" '$2 == "END" && $3 == "n=" n { for (i = 4; i <= NF; i++) if ($i ~ /^reason=/) print substr($i, 8) }' "$watch_log")
      dns_ok=$(first_ok "$watch_log" "$wn" dns)
      cache_ok=$(first_ok "$watch_log" "$wn" cache)
      case "$reason" in
        window) awake_txt="$awake+ (still awake when the ${WINDOW_S} s window ended)" ;;
        slept) awake_txt="$awake (last line; it slept within ${TICK_S} s after)" ;;
        *) awake_txt="$awake (watcher end: ${reason:-not recorded})" ;;
      esac
      echo "  Watcher: wake $wn at $(date -r "$(field "$wline" epoch)" +%H:%M:%S), mode $m ($wassert)"
      echo "  Seconds awake: $awake_txt"
    else
      wassert=$(mode_name "$m") awake=- dns_ok= cache_ok=
      echo "  Watcher: no wake detected at this booked time (mode $m not used)."
    fi
    if [ -n "$slept" ]; then echo "  Slept before: yes (Sleep at $slept)"; void=; else echo "  VOID: the Mac did not sleep"; void=VOID; fi
    echo "  Kind: $kind"
    if [ -n "$dns_ok" ]; then dns_txt="+$dns_ok s"; elif grep -q " TICK n=${wn:-x} .* dns=unavailable " "$watch_log" 2>/dev/null; then dns_txt=unavailable; else dns_txt=never; fi
    if [ -n "$cache_ok" ]; then cache_txt="+$cache_ok s"; else cache_txt=never; fi
    echo "  First lookup success (DNS server, host): $dns_txt"
    echo "  First lookup success (system resolver, may be cached): $cache_txt"
    table="$table
$n|$(date -r "$at" +%H:%M:%S)|$m|$wassert|$kind|$awake|$dns_txt|$cache_txt|$void"
    wn=
  done

  extras=$(unbooked_wakes "$watch_log")
  if [ -n "$extras" ]; then echo; echo "Wakes the watcher saw at no booked time (they do not change the modes):"; echo "$extras"; fi

  echo
  echo "Summary ($run_name):"
  printf '%-4s %-8s %-4s %-26s %-28s %-6s %-12s %-12s %s\n' wake booked mode assertion kind awake lookup-ok cached-ok note
  printf '%s\n' "$table" | while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9; do
    [ -n "$c1" ] || continue
    printf '%-4s %-8s %-4s %-26s %-28s %-6s %-12s %-12s %s\n' "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9"
  done
  echo
  cancel_test_wakes
}

# ---------- --cancel ----------

cancel() {
  # The watcher first: a refused password must not leave it running.
  found=$(running_watcher)
  if [ -z "$found" ]; then
    echo "No watcher is running."
  else
    printf '%s\n' "$found" | while read -r pid pid_file; do
      if [ "$dry" = 1 ]; then echo "Dry run: would stop the watcher (PID $pid, $pid_file)."; continue; fi
      kill "$pid" 2>/dev/null && echo "Stopped the watcher (PID $pid, $pid_file)." || echo "wake-test: could not stop PID $pid" >&2
    done
  fi
  cancel_test_wakes
}

# ---------- book and start ----------

book_and_start() {
  now=$(date +%s)
  problems=
  displays=$(external_display_count)
  if [ "$displays" -gt 0 ] && [ "$allow_display" = 0 ]; then
    problems="$problems
an external display is attached ($displays); unplug it, or pass --allow-display."
  fi
  soon=$(warmup_wakes_soon "$now")
  if [ -n "$soon" ]; then
    problems="$problems
a warm-up wake is booked within 25 minutes ($(echo $soon)); run the test after it."
  fi
  if [ -n "$(running_watcher)" ]; then
    problems="$problems
a watcher is already running; wait for it or use --cancel."
  fi
  if [ -n "$problems" ]; then
    [ "$dry" = 1 ] || fail "refusing to start:$problems"
    echo "Dry run: a real run would refuse now:$problems" | sed '2,$s/^/  /'
  fi

  power=$(power_source)
  if [ "$dry" = 0 ]; then
    /usr/bin/sudo -v || fail "sudo was refused; nothing changed."
    now=$(date +%s)  # the password prompt may have taken a while
  fi
  run_name=$(date -r "$now" +%Y%m%d-%H%M)-$power
  dir=$LOG_ROOT/$run_name
  base=$((now - now % 60))
  plan="start $now $(stamp "$now")"
  n=1
  while [ "$n" -le "$WAKE_COUNT" ]; do
    at=$((base + n * WAKE_STEP_S + WAKE_SECOND))
    m=$(wake_mode "$n")
    plan="$plan
$n $at $(stamp "$at") mode=$m $(mode_name "$m")"
    n=$((n + 1))
  done
  until_hm=$(date -r $((now + LID_CLOSED_S)) +%H:%M)
  lid_txt="Close the lid now. Leave it closed until $until_hm (T+$((LID_CLOSED_S / 60)) min). Then run scripts/wake-test.sh --report."

  if [ "$dry" = 1 ]; then
    echo "Dry run: nothing booked, nothing started. Power: $power; the run folder would be $dir."
    printf '%s\n' "$plan" | awk '$1 ~ /^[0-9]+$/ { print $2 }' | while read -r at; do pmset_schedule add "$(pmset_when "$at")"; done
    echo "Plan:"
    printf '%s\n' "$plan" | awk '$1 ~ /^[0-9]+$/ { $2 = ""; print "  wake " $0 }'
    echo "A real run would then say: $lid_txt"
    return 0
  fi

  [ ! -e "$dir" ] || fail "$dir already exists; wait a minute and run again."
  mkdir -p "$dir" || fail "cannot create $dir."
  if [ "$quick" = 1 ]; then
    printf '# wake-test plan, owner %s, quick run: wake 1 uses mode %s\nquick=1\n%s\n' "$OWNER" "$QUICK_MODE" "$plan" > "$dir/plan.txt"
  else
    printf '# wake-test plan, owner %s, wake N uses mode N\n%s\n' "$OWNER" "$plan" > "$dir/plan.txt"
  fi

  leftovers=$(booked_test_wakes)
  if [ -n "$leftovers" ]; then cancel_test_wakes; fi
  for at in $(printf '%s\n' "$plan" | awk '$1 ~ /^[0-9]+$/ { print $2 }'); do
    if ! pmset_schedule add "$(pmset_when "$at")"; then
      cancel_test_wakes
      fail "pmset refused the wake at $(pmset_when "$at"); the test wakes were cancelled."
    fi
  done

  # Detached: own process group (job control), no terminal input, output to the run log.
  set -m
  nohup /bin/sh "$SELF" --watch "$dir" </dev/null >>"$dir/watch.log" 2>&1 &
  watcher=$!
  set +m
  echo "$watcher" > "$dir/watch.pid"
  sleep 1
  is_watcher "$watcher" || { cancel_test_wakes; fail "the watcher did not start; see $dir/watch.log."; }

  if [ "$quick" = 1 ]; then echo "Booked one $OWNER wake:"; else echo "Booked four $OWNER wakes:"; fi
  pmset -g sched | grep "by '$OWNER'" || true
  echo "Power: $power (run $run_name). Watcher PID $watcher; log $dir/watch.log"
  echo "$lid_txt"
}

case "$mode" in
  selftest) self_test ;;
  watch) run_watcher ;;
  report) report ;;
  cancel) cancel ;;
  run) book_and_start ;;
esac
