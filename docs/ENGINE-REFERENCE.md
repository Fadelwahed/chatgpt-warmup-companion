# Engine reference

This is the detailed reference for the Warm-up engine (`warmup.mjs` and its three modules): every command, its guards, its exit codes and its recovery rules. Start with the [README](../README.md) for installation and everyday use.

Paths below assume the default install folder, `~/.local/share/codex-router-warmup`, and Homebrew's `node@22`. Always call the engine through those two absolute paths, never through a `PATH` alias or a shell wrapper.

A "warm-up" is one minimal inference probe. Success proves that account/model completed that request then; it does not prove persistent warmth, faster future requests, renewed credentials or additional quota. Success, failure and uncertainty can consume allowance. There is no retry, refresh, switching, challenge workaround or provider/model fallback.

Ownership separation checks physical device/inode identities and existing ancestor chains, not only path spelling. Symlinked data/install ancestors remain forbidden. Two unresolved targets beneath the same physical parent are conservatively blocked until their separation can be established; different names alone are not ownership proof. This does not change the explicit Homebrew executable-link contract.

## Operator command contract

Run these against an installed copy (see the README), never against the repository checkout. The checkout has no instance, config or state, and test fixtures must never be copied into an installation.

With the default install, the syntax is:

```sh
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs list
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs status
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs run
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs run --account ENROLLMENT_ID
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs enroll --account ROUTER_ACCOUNT_ID
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs schedule enable
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs schedule disable
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs maintain --file /ABSOLUTE/PRIVATE/candidate.json
/opt/homebrew/opt/node@22/bin/node ~/.local/share/codex-router-warmup/warmup.mjs remove
```

Use the absolute installed script path, never a PATH alias or shell wrapper. `setup` is initial enrollment only, not a pilot or schedule enable. Repeating it preserves the frozen snapshot; later Router accounts require explicit `enroll`. `enroll --account` accepts only Router IDs; `run --account` accepts only enrollment IDs. Neither accepts a workspace ID, email or display label. `list` distinguishes the namespaces.

First setup requires the exact job, scheduled runner and plist to be absent before it changes the marker or discovers identities. An unknown or conflicting object blocks without being modified. A global identity-discovery failure leaves initialization `in_progress` and cannot silently freeze a partial cohort. Account-scoped exclusions are returned as bounded `excluded` entries containing only `routerAccountId` and a sanitized `reason`; they are not credential or email disclosures.

Manual runs work with scheduling disabled and without an earlier pilot, subject to the same compatibility, safety, cooldown, state and lock gates. A successful manual run creates the exact identity/model/contracts pilot; it never implicitly enables scheduling. After separately authorized enablement the independent LaunchAgent ticks every 30 seconds without an open Terminal. The default admission minutes are 08:00, 13:00 and 18:00. The scheduler sends only during an admission minute. It skips missed windows and never replays an interrupted batch.

Each command emits one bounded protocolVersion-1 JSON object with command, outcome, sanitized reason, installationId, engineVersion and observedAt. `run` also always reports selected, attempted and individual results. Attempted counts transport dispatches, not reservations, success or quota spent.

### Engine 1.2.6-offline (27 November 2026)

`schedule inspect --days N`, with N from 1 to 28, returns the same projection for N days: today plus N-1. `scripts/schedule-wakes.sh` uses it to book wakes 4 weeks ahead. `--days` combines with no other inspect option (the global `--expected-installation-id` still applies): with `--slot`, an edit preview, `--expected-revision`, a second `--days`, or an N of 0, 29, `07` or `7x` the reply is `invalid_invocation`. Plain `schedule inspect`, edit previews and `status` keep 7 days.

### Engine 1.2.5-offline (27 November 2026)

The batch power hold is now `/usr/bin/caffeinate -s -i -w <pid>`: `-s` asks macOS to keep the system awake on AC power and is ignored on battery. Whether it keeps a lid-closed Mac awake through a whole batch is not yet checked. Everything else about the hold is unchanged.

### Engine 1.2.4-offline (25 November 2026)

A scheduled send that fails before anything is sent with `transport_before_send` and transport code `ENOTFOUND`, `EAI_AGAIN`, `ENETUNREACH`, `EHOSTUNREACH` or `ECONNREFUSED` is retried under the same reservation, up to 3 attempts in all, waiting 5 s before the second and 15 s before the third, and only while the batch deadline still leaves at least 45 s after the wait and every pre-send check passes again; manual runs keep a single attempt, and the history row describes only the last attempt. While a batch processes accounts the engine holds `/usr/bin/caffeinate -i -w <pid>` and releases it when the batch ends, and the hold fails open: if it cannot start, the batch runs exactly as before.

### Engine 1.2.3-offline (23 November 2026)

Slot ledger rows now expire by their admission date, a day beyond the 30-day retention status uses, instead of by when they were written, so a row written late for an old admission (after a long pause or a catch-up) no longer outlives that retention. After upgrading, rows already beyond it go at the next tick or other pruning save, such as pausing or resuming; schedule edits save without pruning, as before.

### Engine 1.2.2-offline (23 November 2026)

- **Job inspection:** the engine reads each `launchctl print` argument as one whole line, removing only launchctl's indentation, so an install path with a space is recognised as its own job and an argument that differs only by a trailing blank is not; it also requires the job's top-level `path` to be the engine's own plist. A same-label job loaded from another plist, or one with no `path` line, is `job_ownership_unknown`.
- **Pause evidence:** a time or settings edit made while scheduling is paused first settles what already passed under the settings that applied: paused slots as `schedule_disabled` with `pauseStartedAt`, and slots missed between the last tick and the pause as `no_tick_between`. It then keeps the pause current, so resuming records the later paused slots as `schedule_disabled` too, instead of as `no_tick_between`. Resuming and later ticks apply the edited schedule only to minutes still open at the edit, so a time added after its minute passed (for example in a fall-back hour) is never reported. Recovery and maintenance still end the pause evidence, as before. If the clock was set back after such an edit, the next paused edit or the resume drops that pause's rows whose occurrence inside the pause has not closed on the corrected clock (a repeated enable leaves history alone), so those slots run or are reported under it. A time-zone hold for the same minute replaces a paused-slot row, so it always holds.
- **Guidance:** `send_check_failed` now carries the guidance `review_router_state` instead of the fallback `review_history`.
- **Test guard:** the test guard denies any path that is not already in resolved form, so a `..` after a symlink can no longer be checked as one path and opened as another.

### Engine 1.2.1-offline (23 November 2026)

- **TLS:** the probe request sets `rejectUnauthorized: true` explicitly, so `NODE_TLS_REJECT_UNAUTHORIZED=0` in a shell cannot turn off certificate checks before the bearer token is sent.
- **Send-boundary check:** after DNS and TLS, just before the request is written, the engine revalidates Router eligibility and the scheduled clock again; a failure sends nothing and records the new reason `send_check_failed` for that account (a global Router block stops the batch as `reader_global_block`, a clock change as `batch_deadline_or_clock`), and the reservation is resolved as not sent.
- **Reasoning items:** a completed reply may carry `reasoning` items before the assistant message; they are accepted and never read as marker text, reasoning alone never confirms the marker, and other non-message item types are still rejected.
- **Bounded state:** each state write also prunes resolved reservations and slot claims older than 30 days (and a whole day before that cutoff), keeping unresolved reservations, keys the cap check cannot classify, and the claims and reservations of `highWater`, the active batch and the last outcome; this replaces "never pruned" in B4 below and cannot change a cap, which counts only today's reservations.

### Engine 1.2.0-offline: Increment B (21 November 2026)

Every Increment B command is a guarded schedule mutation. It runs under the lifecycle and work locks, takes `--expected-revision` and `--expected-installation-id`, and bumps the schedule revision. Each new state key is stored only when it differs from the default.

- **B1 vacations:** `schedule exclude START END` and `schedule include START END` take inclusive local dates and accept `--expected-local-date`. A range starts tomorrow at the earliest; to stop today's remaining slots, pause scheduling. Removing a range takes effect tomorrow too: past days and today never change. A range that has started ends today instead, so no slot of today reopens (one may already be under way); a range ending today or earlier cannot be removed (`vacation_not_future`). Ended ranges are kept until the last tick has passed them (dated in the last tick's zone), so a Mac that slept through a vacation never has those days counted as missed. A range may be up to 366 days. Ranges may not overlap, and at most 24 are saved. Ended ranges are dropped on the next change once the last tick has passed them. A vacation is a layer above the schedule: it suppresses a date's admissions, and `schedule inspect` labels the date `vacation`. It never enters the frozen per-day edit snapshot or the spacing check. So a time edit made during a vacation freezes the schedule's own admissions, removing a range restores exactly the underlying schedule from tomorrow, and a vacation can never hide a too-close recurring time. A `--today` edit on a vacation day is refused. State: `vacations`.
- **B2 scheduled accounts:** `schedule accounts all`, `schedule accounts --only [ENROLLMENT_ID...]`, or `schedule accounts --add ID` / `--remove ID`. The add and remove forms are applied under the lock to the enrollments the engine holds at that moment; from "all", the list becomes the accounts enabled then. A change that would exceed 1,000 IDs is refused (`invalid_account_selection`). An empty selection is allowed: a tick at an admission minute records that slot in the slot ledger as `no_scheduled_accounts` and returns `idle` with that reason, without claiming it (restoring the selection within the minute still lets the slot run); with no scheduled account, `status.next` and `schedule inspect` show no next run, the manual overlap guard does not refuse a run, and slots that pass meanwhile are recorded in the slot ledger as `no_scheduled_accounts` (the operator's choice), not as misses. Settings changes and saved time or weekday edits first record elapsed slots under the settings that applied to them, in the last tick's zone. After a zone change, an edit or settings change records the old zone's misses too; a tick records only the no-account skips there, and its zone logic owns the ordinary misses. A spacing refusal replaces a provisional no-account row for the same minute, and a zone-change hold replaces any such reporting row for its slot, so an edit made before the first tick in a new zone can never lift the hold. An edit records how far it settled (`settledAt`, cleared by the next tick), so a second edit never replays that interval under its own settings; it never moves backward. Known limit (report rows only): after a zone change, an edit landing inside an old-zone admission minute that exists only because of a same-day move made after the change can record that minute as missed. A tick filters its batch to the selection before any reservation. Manual runs still reach every enabled account. An account enrolled later stays outside an explicit selection until added. The tick, the projection, `status.next` and the manual overlap guard all size spacing from the same scheduled set. State: `scheduledAccounts`.
- **B3 one undo:** each saved `add`, `remove` or `move` stores `scheduleUndo` (the previous `scheduleEdits`, the revision after the edit, and the local date). `schedule undo` restores it only if the revision is unchanged and it is still the same local date (`undo_unavailable`, `undo_expired`). Every admission today that the reversal adds, removes or moves must still be ahead and unclaimed, by wall label and by every resolved instant, so a fall-back fold whose first occurrence has passed is refused (`schedule_time_elapsed`, `schedule_slot_unavailable`), and spacing is checked again. A refused undo writes nothing. Any other schedule change replaces or clears the record.
- **B4 daily caps:** `schedule cap ENROLLMENT_ID N|off`, with N from 1 to 48. Before any credential read, and again just before the reservation is written, a scheduled probe counts that account's scheduled reservations written on the current local date in the durable reservation ledger, which is never pruned. Counting by the write, not the slot, keeps a batch that crosses midnight inside the new day's cap. So restarts, unresolved possible sends and history cuts cannot reset the count. Any reservation key the engine would not write (a manual key that is not a UUID, or a scheduled tuple that disagrees with its record) keeps capped accounts from sending (fail closed). Separately, any scheduled reservation for the same slot and account, whatever identity its key names, blocks a second one (`already_reserved`). A capped account is skipped with `daily_cap_reached`; the app treats that as the operator's choice, not a problem, in alerts, the week strip and the weekly report, except in a batch the engine stopped (`blocked`), which is always reported. The final batch outcome is kept on the slot's claim and returned on that slot's `history` rows as `batchOutcome`, so the app's catch-up and weekly report still see a stopped batch after `lastSlotOutcome` moves on. `status.blockedSlots` lists recent stopped claims (newest first, at most 50, `at` = when the batch stopped) even when none of their account rows was saved. Manual runs are not capped. State: `caps`.
- `status` adds `scheduledAccounts`, `caps` and `undoAvailable`, and `status.schedule.vacations` lists the ranges. New capability features: `schedule_vacations`, `scheduled_accounts`, `schedule_undo`, `daily_caps`.
- **Rollback:** engines 1.0 and 1.1 reject the new state keys as `invalid_state`. Before rolling back, run `schedule accounts all`, remove every vacation, turn every cap off and make any other schedule change so the undo record is cleared, then check that `state.json` has none of `vacations`, `scheduledAccounts`, `caps` or `scheduleUndo`, and no `slotLedger` row with cause `no_scheduled_accounts`, and no `settledAt` (one tick clears it). A range that has started cannot be removed; it is dropped by the first change after a tick has passed its end. Ledger rows age out after 30 days; to roll back sooner, pause, back up `state.json`, and delete those rows and keys by hand. The `outcome` field on `slots` claims is ignored by 1.0 and 1.1.

### Engine 1.1.0-offline additions (21 November 2026)

- **Dead work-lock recovery.** When the work lock is busy, any locked command (including the scheduled `tick`) clears it only if its owner is proven dead. It uses the same proof `schedule disable` uses: a well-formed owner record, `inspect` is `dead`, an inode recheck and an owner re-read just before removal. Every dead-lock recovery, including the ones in `schedule disable`, `remove` and explicit recovery, runs under a recovery mutex. The mutex is a macOS `O_EXLOCK` file lock on the hidden sibling file `.codex-router-warmup.recovery.lock`, next to the installation folder rather than inside it, and the kernel releases it when its holder exits or is killed. So two recoverers cannot remove each other's fresh lock, and a crash during recovery leaves nothing held. The proven-dead directory is first renamed out of the lock path in one atomic step (`work.lock.dead-<uuid>`) and only then emptied. A crash mid-recovery can therefore leave a tombstone but never an ownerless lock; the next recovery, or `remove`, clears tombstones after checking the root's identity. A recoverer creates the mutex file only while `instance.json` exists, and stands down (removing the file it recreated) if the marker is gone once it holds the lock. `remove` takes the same mutex once the job is stopped, waiting up to five seconds for a recovery in progress (otherwise `lock_busy`). It holds the mutex to the end, re-checks the root's identity before its final cleanup, and deletes the sibling file after removing the folder. Because the mutex is outside the folder, a stalled recoverer can never block that removal. The engine creates the mutex complete in one step (written beside the path, then linked into place) with a fixed marker text and mode exactly 0600 (no special bits), and accepts only that exact file; a short write is never linked into place. Any other file at that path (empty, different text or a wider mode) makes recovery and removal refuse instead of using or deleting it. Removal deletes the sibling only if the path still names the very file it holds and that file still carries the marker, and treats a sibling that is already missing as clean. Node has no descriptor-based `rmdir`, so the final root removal re-checks the root's identity immediately before the call. A process running as you that swaps the folder within that single call is outside this boundary, as it is for the rest of the installation. Recovery never takes the lifecycle lock, and a process never clears a lock it holds itself. Alive, unknown, ownerless, malformed or unsafe owners keep the lock, and the command still reports `lock_busy` (exit 3). This fixes the 21 November host incident, where a lock left by a process that died at boot blocked every tick until a manual pause and resume.
- **`status.workLock`** is `{ state, since }`. `state` is one of `free`, `held` (owner alive), `stale` or `unknown`. `stale` means recovery's own read-only proof passes, so the next locked command clears the lock unless another recovery holds the mutex at that moment. `unknown` covers anything recovery would not clear. `since` is the lock directory's modification time in epoch milliseconds. Status never removes a lock.
- **`status.next.at`** is the selected admission's epoch milliseconds, so a client can tell the two occurrences of a repeated fall-back minute apart.
- **Scoped overlap override.** The `slot_overlap_risk` refusal now includes `overlap.at`, the admission instant. `run --allow-slot-overlap --overlap-at EPOCH_MS` accepts the overlap only when the next admission is exactly that instant. If the admission was moved (same slot ID, new minute), or the other occurrence of a repeated fall-back minute is next, the run is refused again. The value must directly follow its flag. The unscoped `--allow-slot-overlap` still works for existing scripts.
- **Usage-window evidence.** A dispatched, trusted probe result keeps the bounded numbers from the `x-codex-primary-*` and `x-codex-secondary-*` response headers (used percent, window minutes, reset time) on its history row as `usage`. `status.accounts[].usage` shows the latest observation per account, with `observedAt`, for at most 64 accounts (newest observations first; `status.usageTruncated` says when more were left out). If a status reply would still pass its 1 MiB output limit, the CLI drops all usage evidence from it (from `accounts` and from the last batch's results) and sets `usageTruncated`, before it would have to refuse the reply. Raw header text is never stored. This is an observation at send time, not a live meter.

`status` returns at most ten recent outcomes for current enrollments; `historyTruncated` is true whenever any saved history was omitted, including entries for removed enrollments. `lastSlotOutcome` remains the actual last recorded outcome, with its original date. `slotObservation` is either null (unknown) or an `unobserved` slot with an `asOf` heartbeat timestamp. It identifies only the latest fully elapsed admission minute on the local date recorded by durable `lastTick` for which no claim is recorded and the safety evidence is consistent. A stale heartbeat yields a dated, stale observation; no earlier days are backfilled. A claimed but unfinished slot is not unobserved. Current schedule enablement does not establish whether that slot was an obligation, and an observation does not establish sleep, cause, eligibility, or zero requests. If validation crosses the end of a minute after a heartbeat, the observation can appear only after a later heartbeat. Status also exposes the next available admission while scheduling is enabled, clock hold, per-account correction and cooldown evidence, the latest missed-slot ledger rows and unresolved reservations. A live scheduled lock owner and matching job runner are required to report an active batch as `running`. A gap between ticks alone provides no evidence of sleep. Status is read-only.

| Exit | Meaning |
|---|---|
| 0 | Successful local operation, nonempty all-success manual selection, or idle/already-claimed tick |
| 1 | A nonempty selected set has blocked, failed or uncertain work; preserve every known result |
| 2 | Invalid invocation, unsafe/missing/mismatched instance/config/state or unsupported source contract |
| 3 | Companion lock busy; never automatically retry |
| 4 | Valid all-account manual run with no enabled enrollments; no credentials or requests |

Example no-work result (timestamps/build shown illustratively):

```json
{"protocolVersion":1,"command":"run","outcome":"no_work","reason":"no_enabled_enrollments","installationId":"install_example_01","engineVersion":"1.0.0-offline","observedAt":"2026-11-12T06:00:00.000Z","selected":0,"attempted":0,"results":[]}
```

A nonempty all-blocked result is exit 1, **not** no_work. Busy/configuration validation take precedence over empty selection. Output is at most 1 MiB, sanitized stderr at most 64 KiB; manual output capacity is checked before dispatch, never by dropping selected accounts afterward.

If releasing the work guard fails after a dispatch, exit 2 with `lock_release_failed` retains the known selected/attempted/results evidence. It does not mean zero sends. Preserve the remaining guard for ownership review; never retry a request to repair cleanup.

## Maintenance candidate

First complete schedule disable. A private, bounded (1 MiB) candidate contains:

```json
{"schemaVersion":1,"config":{"...":"complete current config with permitted edits"},"compatibility":{"schemaVersion":1,"...":"complete reviewed compatibility record"},"reviewEvidence":"specific local review reference"}
```

This schematic is not an executable candidate. Use the complete current accepted records. Only existing enrollment model/enabled edits and explicitly reviewed source/compatibility changes are allowed. Do not add/remove accounts, replace identities, alter installationId/endpoint/body or include credentials/unknown fields. Schedule changes through maintenance require review and are limited to the one-date advance or the legacy `Asia/Gaza` to `local` migration described below. Apply the zone migration as a separate candidate. Source relocation needs fresh named review; consumed semantic changes need an adapter/request-contract version increase and pilot invalidation. Unlocked editor changes are rejected by accepted byte digests, not legitimized by maintenance.

Maintenance holds lifecycle then work exclusion, verifies disabled state/unloaded job/no owned runner, removes affected historical pilots durably **before** file replacements, commits accepted digests last and rereads the final pair. Model A→B→A cannot revive an old pilot. Any intermediate crash stays blocked/disabled; multi-file atomicity is not claimed.

## Recovery and removal

Never delete locks based on age, rerun setup to recreate missing state, invent an installation ID, restore a stale backup as current history, or use blind recursive deletion. A schema-compatible backup can predate a possibly sent request. Preserve surviving reservations/full-identity slot history/high-water records independently of 30-day detailed-history pruning. Recovery stays disabled and never resumes a batch.

An explicit recovery must prove the original root device/inode and installationId, private non-symlink paths and each lock owner's exact PID/start identity/nonce. Ambiguous/live owners block recovery. Under lifecycle exclusion, unload only the exact companion job, prove the scheduled runner ended, then clear only a proven orphan work guard and take work exclusion. Restore only a reviewed intended configuration with trustworthy surviving history; otherwise require an explicit conservative skip-through boundary covering every possibly executed slot, or remain blocked. Keep affected pilots invalid, persist scheduling disabled and accepted digests, reread all safety records, then release only the guards acquired. No backup is assumed. This is a decision-gated procedure, not an automatic generic recovery command.

The internal helper `recoverInstance(context, services, decision)` is not a CLI command. Its original decision has exactly `{installationId, rootDev, rootIno, skipThrough, reviewEvidence, backupPath}`. It may additionally contain `intendedPair: {path, sha256, baseConfigPath, baseCompatibilityPath}` to reconcile interrupted maintenance. The three paths must name explicit, absolute, private files: `path` is the existing maintenance candidate format; the two baseline files contain the exact predecessor config and compatibility bytes whose hashes were accepted in surviving state. A current file can serve as a baseline only if its bytes match the predecessor hash. The supplied `sha256` is the candidate-file digest recorded independently by the recovery review, not a digest computed and immediately trusted from an arbitrary file.

The operator's review binds the original installation and root identity, candidate digest, predecessor hashes, allowed transition and semantic disposition, skip-through boundary, and surviving-history evidence. A nonempty `reviewEvidence` is a reference to that decision; it is not cryptographic proof. The helper validates the candidate and transition, refuses unrelated current bytes, preserves surviving claims, reservations, cooldowns and correction blocks, clears pilots, and commits the disabled safety state before target files and accepted digests. It rereads the pair and verifies the job and runner are absent. The six-field decision remains available for recovery where accepted files already match. `backupPath` is null or an explicit private absolute backup; `skipThrough` must cover the current local day and every possibly executed slot.

A failed write may retain the owned work guard when durability is uncertain. Retry only the same explicitly reviewed decision after exact owner-death verification; a fully committed matching target is idempotent. Recovery never enables scheduling, launches a pilot, restores old pilots, discovers accounts or replaces enrollment identities. This procedure addresses interrupted maintenance; missing original identity, unreviewed files, conflicting history or unavailable predecessor evidence stays blocked. Synthetic tests do not qualify host recovery.

If `status.clockHold` follows a large wall-clock excursion, preserve the current state and keep scheduling paused while the clock and history are reviewed. Any decision to lower a future `lastWall` or `highWater` must prove there are no claims, reservations or history after the corrected time, retain all actual claims and reservations, and set a reviewed skip-through boundary at the current local slot or later. The existing recovery procedure preserves the highest surviving evidence and has no automatic clock reset.

`remove` retains lifecycle exclusion through disable and work exclusion through deletion. Manual work returns busy without deletion or manual-process termination. It durably sets removalPending and scheduling disabled before deletion, removes only proven companion files, and retains state/instance/guards until final cleanup. Partial removal stays blocked. Router code/accounts/locks/jobs and Homebrew Node are never removal targets; uninstalling Router does not implicitly uninstall this companion.

If the executable is already missing, **do not redeploy or run setup**. Preserve the remaining tree and its safety records. Using the reviewed recovery/removal procedure, verify the original instance and exact process/job ownership before any cleanup. An absent/corrupt marker, changed root or unknown history remains a blocker. A replacement root is never this operation's target. The synthetic partial-removal tests and final independent report determine what cleanup is actually verified; do not infer host readiness from these instructions.

The exact continuation helper is `resumeRemoval(context, services, decision)` exported by the retained, reviewed `runtime.mjs` package, not a CLI command. After separate recovery authorization:

1. Preserve the surviving instance and obtain the original recorded `{installationId, rootDev, rootIno}`; never derive a new identity from a replacement root.
2. Supply exactly those fields plus nonempty `reviewEvidence`. Use the original explicit context and ownership-checking services; do not recreate deleted files or copy fixture services/state into an installation.
3. The helper requires a complete matching marker and durable removal-pending proof. If state was already deleted, config and compatibility must also be absent. It clears only guards whose exact owners are proven dead, then reacquires lifecycle/work exclusion, verifies the exact job/runner stopped and continues the same bounded file deletion.
4. Accept only exit 0 after exact root/plist/job/runner absence is verified. Failure stays explicit; live/ambiguous owners, foreign files, symlinks and root replacement are not bypasses. Loss of the marker before final root removal remains **manual-review-only**, not recoverable through this helper.

`test/runtime.test.mjs` and `test/persistence-boundaries.test.mjs` exercise this exact export, including missing executable/config and each tested deletion boundary with competing commands. These are synthetic procedure checks, not authorization or proof of real macOS cleanup.

## One-date 13:00 advance

A separately authorized and independently reviewed `maintain --file PATH` candidate may add `schedule.advance13: {"date":"YYYY-MM-DD","time":"HH:mm"}` while retaining the normal zone/times. This is deliberately only one earlier 13:00 slot, not a general schedule editor. The time must be before 13:00 on the current scheduler date, honor the minimum gap after 08:00, and be at least three minute boundaries ahead, with fresh review evidence and no claimed/skipped/in-progress slot. Existing disabled/job/runner/digest/lock maintenance gates apply. No probe is sent by maintenance.

The advanced batch retains logical slot key `DATE T13:00` (without the space) in claims, reservations and outcomes; actual admission uses the configured earlier minute. It cannot run again at normal13:00, even if the earlier minute was missed. `status.schedule` exposes the exact configuration; an advanced `slotObservation` also includes `admissionTime`. Outcome `at` remains the actual timestamp. Other dates retain normal08/13/18. The advance record stays in configuration as historical evidence and cannot be changed/removed by maintenance; changing dates again needs a separate design/review, not an editor reset. History, accepted pilots, state schema and conservative18:00 recovery boundary are unchanged. Never roll back to an old engine that cannot read this config.

## Changing the warm-up schedule

Times use 24-hour `HH:MM` format. Fresh installations use the Mac’s system time zone. Existing installations configured for `Asia/Gaza` stay fixed until a reviewed maintenance candidate changes `schedule.zone` to `local`. The normal maintenance gates require a disabled schedule and an absent job. Review the current schedule, the new zone and the preserved slot keys together before enabling again. A0 can write state fields older runtimes reject even before the zone migration. After any A0 write, keep a compatible runtime and preserve the latest state. Never restore older state over possible requests. The zone migration is one-way through maintenance.

`status` shows the effective zone, last tick’s zone, most recent zone change, recurring times, date-specific admissions and the last scheduled results. The first tick that sees a changed zone records any skipped admission it can identify. Future ticks continue at their configured local minutes, deduplicated by the original local date and logical slot key.

Run these subcommands with the same deployed Node executable and `warmup.mjs` path shown above.

```sh
schedule add 21:05
schedule remove 18:00
schedule move 08:00 09:15
schedule move 08:00 05:30 --today
```

Recurring edits can be made while scheduling is enabled and start on the next scheduler date. Add `--today` to change an unclaimed future admission for today only. A one-day move retains the original logical slot and must preserve its order relative to other slots. Each admission has a one-minute window. The scheduler skips missed windows. Edits enforce at least 15 minutes between admissions, including across midnight, or the full scheduled batch bound if longer. There is no fixed daily slot limit. If a time-zone transition shortens the elapsed gap between two admissions, the scheduler records the spacing block and skips the second admission.

Append `--preview` to an edit to validate it and see the resulting schedule without writing state. To protect an edit based on `status`, pass `--expected-installation-id ID` and `--expected-revision N` with the reported values. A stale edit is refused. Edits and their revision are saved atomically in the companion state. They preserve enrollment, pilots, outcomes and compatibility records. The previous `advance13` record is still understood. Keep the current runtime when schedule edits or custom slot records exist in state.

### Weekdays, seven-day preview and slot explanations (Version 2 engine, offline)

```sh
schedule weekdays 1,2,3,4,5        # ISO days, Monday = 1; `all` restores every day
schedule inspect                   # today plus six days, read-only
schedule inspect --days 28         # up to 28 days (1 to 28), read-only
schedule inspect weekdays 1,2,3,4,5   # preview a proposed edit without saving
schedule inspect move 08:00 09:15 --today
schedule inspect --slot 2026-11-20T08:00
```

A weekday rule starts tomorrow in local time. It is a one-way state upgrade. After a rule or excluded date is saved, the A0 engine refuses the state with `invalid_state`. It sends nothing and does not replay. Keep this engine. Before any rollback, run `schedule weekdays all` on a date the rule includes. A reset made on an excluded date keeps that date's exclusion marker. Spacing is validated across nine resolved dates, so excluded days cannot hide two admissions that are too close. Today's resolved admissions stay as they were. A rule change cannot remove or reopen today. A today-only edit on an excluded date is refused with `schedule_date_excluded`. Guarded manual runs remain available. Tick, preview, spacing and edit validation use the same date resolver. Installations without a rule keep all seven days.

`schedule inspect` returns each day's logical slot keys, effective admission times, any exclusion, the next admission and configured attempts per account. A nonexistent DST minute is listed as `nonexistent_local_time`. A repeated minute appears twice under one logical slot. With a proposed edit, the reply includes the current projection plus the proposed one under `proposal`, using the same validator as the save. Nothing is written. Save the proposal with `--expected-revision N --expected-local-date YYYY-MM-DD` from that reply. A save after another edit or after local midnight is refused with `schedule_revision_conflict` or `schedule_date_changed`.

`schedule inspect --slot` explains one slot from recorded evidence only. It reports the verdict, ledger cause, heartbeat and, per account, whether a request was confirmed sent, ruled out or unknown. Separately it reports whether a response was confirmed, plus fixed recovery guidance. The usage-window effect is always `unverified`. Silence is reported as `unobserved` or `unknown` and never as sleep. Slots older than the 30-day evidence retention are `unknown`. New claims also record their effective admission minute.

`status` adds `capability` (version 1 and its feature names), the engine's own `engine.nodePath` and `engine.scriptPath`, and from the CLI an `engineBuild` SHA-256 over the four engine modules. The native app binds to these values.

`schedule disable` waits for a running batch within its remaining time bound, persists the pause, then unloads the job. When the schedule and zone are unchanged on resume, the ledger records full admission windows covered by the pause. `schedule disable --now` can interrupt a running batch and leave results uncertain. A manual `run` near a pending scheduled admission returns `slot_overlap_risk`. Pass `--allow-slot-overlap` to run anyway. The ledger records when a manual run held the work lock through an entire admission minute.

## Run history and first-response timing

Use the deployed Node and script paths to read the latest 50 retained results. Use `list` to find an enrollment ID and pass `--account ID` to either command to limit its output to that enrollment. `history --since 2026-11-12T08:00:00Z` filters the retained rows from the given UTC time.

```sh
/opt/homebrew/opt/node@22/bin/node "$HOME/.local/share/codex-router-warmup/warmup.mjs" history
/opt/homebrew/opt/node@22/bin/node "$HOME/.local/share/codex-router-warmup/warmup.mjs" timing
```

History includes success, skipped, failed, and uncertain results, and a recognized transport error code when one was recorded. New records distinguish manual runs from scheduled slots, include the zone, and use an opaque reservation ID when a dispatch was reserved. The unresolved list can include legacy reservations whose outcome could not be linked. Earlier entries stay readable with the fields originally saved. Individual skips from before this change may be unavailable. The existing 30-day retention applies.

Timing measures milliseconds from HTTP dispatch to the first visible model text in a confirmed warm-up response. It uses validated completed output when an earlier text delta cannot be linked to the confirmed result. The report groups results by enrollment and model. **Recent** means the preceding dispatched probe succeeded within 15 minutes. **Spaced** means it succeeded at least four hours earlier. The gaps are between probe completion timestamps. Other measurements remain unclassified. The difference is spaced median minus recent median. These observations use warm-up history only, so other ChatGPT activity and changing service conditions can affect the result. Both reports are read-only and send no requests.
