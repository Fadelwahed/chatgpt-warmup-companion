# Changelog

Notable changes to Warm-up: the engine (`warmup.mjs` and its modules) and the menu-bar app (`ui/`). Full release notes: app versions in [`ui/README.md`](ui/README.md), engine versions in [`docs/ENGINE-REFERENCE.md`](docs/ENGINE-REFERENCE.md).

## Unreleased

### App 0.6.7

- **Pause reminder.** With alerts on, when scheduling has been paused for a day or more, the app posts one reminder, then at most one a day, until scheduling is resumed. Nothing is resumed automatically. Each new pause starts its own day.
- **Help.** Help › Warm-up Help (Cmd-?) opens a one-page guide: what a warm-up is, the accounts-you-own rule, when warm-ups run, what the marks mean, pausing (automatic warm-ups only; Warm Up Now still works), and what the app stores. The Help window keeps the app in the Dock and Cmd-Tab while it is open.

## App 0.6.6 and engine 1.2.3-offline (24 November 2026)

- App: copied slot summaries pass an allowlist. Saved alert state is scoped to the bound engine installation. The pending-alert limit is 256 KB.
- Engine: slot ledger rows expire by the slot's date, not by when they were written.

## Earlier

See the version sections in [`ui/README.md`](ui/README.md) (app 0.2 to 0.6.5) and [`docs/ENGINE-REFERENCE.md`](docs/ENGINE-REFERENCE.md) (engine 1.0 to 1.2.2).
