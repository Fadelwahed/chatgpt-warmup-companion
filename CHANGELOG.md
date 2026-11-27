# Changelog

Notable changes to Warm-up: the engine (`warmup.mjs` and its modules) and the menu-bar app (`ui/`). Full release notes: app versions in [`ui/README.md`](ui/README.md), engine versions in [`docs/ENGINE-REFERENCE.md`](docs/ENGINE-REFERENCE.md).

## Unreleased

- Engine 1.2.5-offline: a batch holds `caffeinate -s -i` instead of `-i`, which asks macOS to keep the Mac awake on the charger; nothing changes on battery. Whether it carries a lid-closed batch is not yet checked.
- Engine 1.2.4-offline: a scheduled send that fails on DNS or the network before anything is sent is retried up to twice; the Mac is kept awake while a batch runs.
- `scripts/schedule-wakes.sh` books a one-time macOS wake 5 seconds into each warm-up of the next 7 days (one password prompt; `--dry-run`, `--cancel`), replacing only the wakes it booked before.
- `scripts/wake-test.sh` tests whether a booked wake with the lid closed stays awake long enough for a warm-up: four `waketest` wakes, a detached watcher, and `--report` against `pmset -g log` (`--dry-run`, `--cancel`, `--self-test`).
- `scripts/wake-test.sh --quick`: one test wake with every hold at once, about 5 minutes per run.

### App 0.7.4

- Wake wording from the 27 Nov lid-closed test: on battery with the lid closed the Mac sleeps again within seconds.

### App 0.7.3

- A time still to come no longer says the background job was not seen running; a time-off day's detail is headed "Skipped: time off".
- `--status` docs say an opened problem does not change the exit code.
- **Accounts and VoiceOver.** With every account turned off the table lists them instead of staying blank, and the lines under the table no longer describe a row that was just hidden. VoiceOver reads a week day with the same times its cells show when a time was moved for a day.

### App 0.7.2

- **Advice that matches what happened.** A missed time's advice, Schedule's wake line and Help say a booked wake needs the lid open; with the lid closed on battery it may last only seconds. The week's cause line says "at least N while the Mac was recorded asleep". Help says where to look when the menu-bar icon is missing.
- **`--status` agrees with the window.** Sends marked reviewed in the app no longer count in `--status` and `--json` (verdict, "Sends without a result" line, `unresolvedSends`, exit code); `unresolvedSends` now means unreviewed sends. The CLI also reads the last eight days of `history`, so Today's marks and the headline match the window; if that read fails it falls back to status alone.

### App 0.7.1

- **Date pickers.** The time-off and start-date pickers show the day in words beside them ("Fri 27 Nov"); the system field itself prints digits only.

### App 0.7.0

- **Honest headline.** After a missed or unconfirmed warm-up today has been seen, the headline reads "Next 13:10 · 1 missed today" instead of returning to "All good". Health shows how many of the last 7 days' warm-ups were confirmed.
- **Wakes on Schedule.** Each upcoming time shows whether a macOS wake is booked for it, one line says how far the bookings reach, and with alerts on one notification arrives the day before they run out.
- **Why warm-ups were missed.** The week shows one cause line; a missed time says what happened, whether it still applies and what to do; a blocked headline says since when.
- **Accounts.** Each reading shows when it was taken, an old one says "last seen Tue", turned-off accounts are tucked away, and the table and `--status` agree on blocked and cooling-down accounts.
- **Wording.** "Sends without a result" is the one name in the window, menu and `--status`. Days off read "Skipped: …" in every Schedule list. Measurement says "Decision period hasn't started." until a start date is set.
- **Menu bar.** A Schedule menu with "Warm Up Now…" and "Pause/Resume Scheduling…".
- **CLI.** The `verdict` text in `--status` and `--json` follows the new wording. In `--json`, keys and values other than `verdict` are unchanged; exit codes are unchanged.

### App 0.6.10

- **Alert when Router blocks Warm-up.** With alerts on, one notification as soon as the engine reports Router compatibility blocked (for example after a codex-router update), once per blocking episode, instead of only after a warm-up is skipped.

### App 0.6.9

- **One time for each warm-up everywhere.** The Overview headline, "Needs a look", "Warming up", the sends-without-result groups, `--status`/`--json` and alerts name a time moved for one day (`--today`) at the minute it runs, as Today does. Slot labels stay the key for clicks, acknowledgements, alerts and copied diagnostics.

### App 0.6.8

- **Today shows when warm-ups run.** Overview's Today cells, the menu's Today line and `WarmupMenu --status`/`--json` show a moved time at the minute it runs (13:10, not 13:00), in that order, as Schedule already did.

## App 0.6.7 (24 November 2026)

- **Pause reminder.** With alerts on, when scheduling has been paused for a day or more, the app posts one reminder, then at most one a day, until scheduling is resumed. Nothing is resumed automatically. Each new pause starts its own day.
- **Help.** Help › Warm-up Help (Cmd-?) opens a one-page guide: what a warm-up is, the accounts-you-own rule, when warm-ups run, what the marks mean, pausing (automatic warm-ups only; Warm Up Now still works), and what the app stores. The Help window keeps the app in the Dock and Cmd-Tab while it is open.

## App 0.6.6 and engine 1.2.3-offline (24 November 2026)

- App: copied slot summaries pass an allowlist. Saved alert state is scoped to the bound engine installation. The pending-alert limit is 256 KB.
- Engine: slot ledger rows expire by the slot's date, not by when they were written.

## Earlier

See the version sections in [`ui/README.md`](ui/README.md) (app 0.2 to 0.6.5) and [`docs/ENGINE-REFERENCE.md`](docs/ENGINE-REFERENCE.md) (engine 1.0 to 1.2.2).
