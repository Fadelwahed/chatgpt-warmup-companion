# Changelog

Notable changes to Warm-up: the engine (`warmup.mjs` and its modules) and the menu-bar app (`ui/`). Full release notes: app versions in [`ui/README.md`](ui/README.md), engine versions in [`docs/ENGINE-REFERENCE.md`](docs/ENGINE-REFERENCE.md).

## Unreleased

- Engine 1.2.4-offline: a scheduled send that fails on DNS or the network before anything is sent is retried up to twice; the Mac is kept awake while a batch runs.
- `scripts/schedule-wakes.sh` books a one-time macOS wake 5 seconds into each warm-up of the next 7 days (one password prompt; `--dry-run`, `--cancel`), replacing only the wakes it booked before.

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
